# ==============================================================================
# DevTools2 설치 시작 스크립트 (Windows + WSL2)
#   irm https://raw.githubusercontent.com/devers2/_devtools2-setup/main/install.ps1 | iex
# ==============================================================================
# 하는 일
#   1) 관리자 권한으로 다시 실행 (UAC)
#   2) WSL2 에 필요한 Windows 기능 켜기 (처음이면 재시작 후 같은 명령을 다시 실행)
#   3) WSL 엔진 설치·업데이트, devtools2 전용 배포판 만들기 (Canonical rootfs 를 wsl --import — 다른 배포판은 건드리지 않음)
#   4) 배포판 안에서 install.sh 로 Bitwarden 로그인 → 비공개 _devtools2 를 /var/opt/_devtools2 로 clone
#   5) clone 한 저장소의 Windows 설치 스크립트(scripts/windows/setup-devtools2-wsl.ps1)를 실행
# 다시 실행하면 이미 된 단계는 건너뛰고 저장소를 최신으로 맞춘 뒤 설치를 이어 갑니다(업데이트).
#
# 계정 사용: WSL 안 install.sh 가 정합니다 — 저장된 계정이 저장소에 접근되면 묻지 않고 그대로,
#   접근이 안 되면 일회성/중단, 계정이 없으면 y/n 을 묻습니다. DT2_KEEP_ACCOUNT=y|n 로 묻지 않고 지정:
#   y: 이 PC 에 Bitwarden 로그인과 GitHub 계정 정보(PAT·gh 로그인)를 저장합니다.
#   n: 일회성 설치 — 설치에만 사용하고, 끝나면 이 PC 에 계정 정보를 남기지 않습니다.
#
# 이 파일에 있는 WSL 엔진·배포판 만들기의 원본은 여기 하나입니다(_devtools2 의 0.setup-wsl.ps1 은 그 뒤의 설정만 맡음).
# 출력·질문·승격 공용 함수는 lib/ui.ps1(_devtools2 의 _common.ps1 도 같은 파일을 씀).
# ⚠️ 공개 저장소입니다. 회사·고객 정보, 접속 주소, 비밀값을 넣지 마십시오.
# ⚠️ PS 5.1 호환: ?? 연산자 금지, .Trim() 앞 널 검사, 파일은 UTF-8 로 읽어 스크립트블록으로 실행.
# ==============================================================================

# --- 한글 깨짐 방지: 출력 인코딩을 UTF-8 NoBOM 으로 설정
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# --- 윈도우 PowerShell 기본 파란색 프로그레스바 팝업 끄기 (텍스트 깨짐 및 커서 겹침 방지)
$ProgressPreference = 'SilentlyContinue'


# ── 공용 함수(lib/ui.ps1): 이 스크립트와 같은 커밋의 파일을 받습니다 ──
#   main 의 최신 커밋을 먼저 정해, 받는 도중 push 가 있어도 install.ps1·ui.ps1·install.sh 가 같은 커밋이 되게 합니다.
$SETUP_REPO = 'devers2/_devtools2-setup'
if (-not $env:DT2_SETUP_REF) {
    $env:DT2_SETUP_REF = 'main'
    try {
        $_sha = (Invoke-RestMethod -Uri "https://api.github.com/repos/$SETUP_REPO/commits/main" -Headers @{ 'User-Agent' = 'PowerShell' } -TimeoutSec 10 -ErrorAction Stop).sha
        if ($_sha) { $env:DT2_SETUP_REF = $_sha }
    } catch {}
}
$SETUP_RAW = "https://raw.githubusercontent.com/$SETUP_REPO/$($env:DT2_SETUP_REF)"
$_noCache = @{ 'Cache-Control' = 'no-cache, no-store, must-revalidate'; 'Pragma' = 'no-cache' }
. ([scriptblock]::Create((Invoke-RestMethod -Uri "$SETUP_RAW/lib/ui.ps1" -Headers $_noCache -ErrorAction Stop)))

# 세션 한정 마우스 클릭 멈춤(프리징) 방지: QuickEdit 모드 안전 비활성화 (스크립트 종료/Ctrl+C 시 자동 복원)
Disable-ConsoleQuickEdit | Out-Null

# 중간에 끝낼 때(exit)도 빠른 편집 모드를 되돌린 뒤 끝냅니다.
function Exit-Devtools2Setup([int]$Code) {
    Restore-ConsoleQuickEdit | Out-Null
    exit $Code
}

# ==============================================================================
# [Step 0] 관리자 권한 확인 및 재실행
# ==============================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

# 관리자 권한이 없는 경우에만 UAC 권한 승격 재실행 (이미 관리자 모드이면 이 블록 건너뜀)
if (-not $isAdmin) {
    # PowerShell 7(pwsh) UAC 승격 가능 여부 판단:
    # - Microsoft Store 설치 경로(WindowsApps)는 Start-Process -Verb RunAs 가 차단됩니다.
    # - winget 직접 설치(C:\Program Files\PowerShell\)는 UAC 승격이 정상 동작합니다.
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    $pwshPath = if ($pwshCmd) { $pwshCmd.Source } else { $null }
    $isStorePwsh = $pwshPath -and ($pwshPath -like '*WindowsApps*')

    # 안내 메시지 출력 및 종료 헬퍼
    $showElevationGuide = {
        param(
            [string]$CmdToRun,
            [string]$Reason = "관리자 권한 자동 승격이 지원되지 않거나 취소되었습니다."
        )
        Write-Host ""
        Write-Host "=============================================================================" -ForegroundColor Red
        Write-Host " [안내] $Reason" -ForegroundColor Red
        Write-Host "=============================================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host " PowerShell 을 '관리자 권한으로 실행' 후 아래 명령어를 입력해 주세요:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "   $CmdToRun" -ForegroundColor Cyan
        Write-Host ""
        if (-not [string]::IsNullOrEmpty($PSCommandPath)) {
            Write-Host " (또는 탐색기에서 install.ps1 우클릭 → PowerShell 관리자로 실행)" -ForegroundColor DarkGray
            Write-Host ""
            Pause-Script
        }
        # ⚠️ exit 대신 return 사용: irm | iex 환경에서 exit 을 호출하면 터미널 창 자체가
        # 즉시 닫혀버려 사용자가 안내 메시지를 읽을 수 없습니다. return 으로 프롬프트에 메시지를 보존합니다.
        return
    }

    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        # ── 온라인 실행 모드 (irm ... | iex) ──────────────────────────────────
        # ⚠️ [보안 주의 - Base64 EncodedCommand 절대 금지]:
        # -EncodedCommand 는 Windows Defender 및 백신/EDR 머신러닝 엔진에 의해
        # 'Trojan:Win32/Commando.A!ml' 트로이목마 드로퍼로 오탐되어 차단됩니다.
        # 따라서 평문 -Command 명령줄을 전달하며, UAC 승격 실패 시 명확한 수동 안내를 제공합니다.
        Write-Warn "관리자 권한이 필요합니다. UAC 승격 후 설치를 계속합니다..."
        # 같은 커밋으로 다시 실행되도록 커밋을 명령 안에서 지정합니다(승격 창은 환경 변수를 물려받지 않음).
        $onlineCmd = "`$env:DT2_SETUP_REF='$($env:DT2_SETUP_REF)'; irm $SETUP_RAW/install.ps1 | iex"
        $psExe = if ($pwshPath -and -not $isStorePwsh) { $pwshPath } else { 'powershell.exe' }
        # ⚠️ conhost.exe로 감싸서 -Verb RunAs 승격 시도 금지 — "액세스 거부"로 실패함(실측).
        #   (목적: WT 자기파괴 방지였음 — 2.setup-windows-terminal.ps1의 WT_SESSION 감지로만 방어 중)
        try {
            Start-Process $psExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$onlineCmd`"" -Verb RunAs -ErrorAction Stop
            Exit-Devtools2Setup 0
        } catch {
            & $showElevationGuide -CmdToRun $onlineCmd
            return
        }
    } else {
        # ── 로컬 파일 실행 모드 ────────────────────────────────────────────────
        $localCmd = "Set-ExecutionPolicy Bypass -Scope Process -Force; & `"$PSCommandPath`""
        if ($isStorePwsh) {
            # Store 버전 pwsh는 -Verb RunAs 차단됨 → 사용자에게 수동 실행 안내
            & $showElevationGuide -CmdToRun $localCmd -Reason "Microsoft Store 설치 PowerShell 은 UAC 자동 권한 승격이 차단됩니다."
            return
        } else {
            # 직접 설치 pwsh 또는 powershell.exe → UAC 자동 승격 재실행
            $psExe = if ($pwshPath) { $pwshPath } else { 'powershell.exe' }
            Write-Warn "전체 환경 구축을 위해 관리자 권한으로 스크립트를 재실행합니다..."
            # ⚠️ conhost.exe로 감싸서 -Verb RunAs 승격 시도 금지 — "액세스 거부"로 실패함(실측).
            #   (목적: WT 자기파괴 방지였음 — 2.setup-windows-terminal.ps1의 WT_SESSION 감지로만 방어 중)
            try {
                Start-Process $psExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs -ErrorAction Stop
                Exit-Devtools2Setup 0
            } catch {
                & $showElevationGuide -CmdToRun $localCmd
                return
            }
        }
    }
}

# UAC 에 다른 관리자 계정을 입력해 승격된 경우 경고 후 중단(Confirm-ElevatedUserMatchesDesktop — lib/ui.ps1)
if (-not (Confirm-ElevatedUserMatchesDesktop)) { return }

Clear-Host
Write-Host ""
Write-Host "===========================================================================" -ForegroundColor DarkCyan
Write-Host "🌟 DevTools2 설치 시작 (Windows + WSL2)" -ForegroundColor DarkCyan
Write-Host "===========================================================================" -ForegroundColor DarkCyan

# ==============================================================================
# [Step 0-1] 순정 Windows 감지: WSL2 필수 선택적 기능 활성화 및 점검
# ==============================================================================
$_wslResumeFlagFile = "$env:TEMP\.devtools2_wsl_resume"

# 1. Windows 필수 선택적 기능 상태 확인 헬퍼
function Get-IsFeatureEnabled {
    param([string]$FeatureName)
    try {
        $feat = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
        return ($null -ne $feat -and $feat.State -eq 'Enabled')
    } catch {
        return $false
    }
}

# WSL2 엔진 고속 작동 확인 (이미 설치 및 정상 작동 중이면 0.03초 만에 즉시 통과)
$wslWorking = $false
try {
    $null = wsl.exe --status 2>$null
    if ($LASTEXITCODE -eq 0) {
        $wslWorking = $true
    }
} catch {}

if ($wslWorking) {
    $wslFeatEnabled = $true
    $vmFeatEnabled  = $true
} else {
    Write-Info "WSL2 환경 및 Windows 필수 기능 점검 중..."
    $wslFeatEnabled = Get-IsFeatureEnabled "Microsoft-Windows-Subsystem-Linux"
    $vmFeatEnabled  = Get-IsFeatureEnabled "VirtualMachinePlatform"
}

# 필수 선택적 기능 중 하나라도 비활성화되어 있고 재개 플래그도 없는 경우 활성화 수행
if (-not ($wslFeatEnabled -and $vmFeatEnabled) -and -not (Test-Path $_wslResumeFlagFile)) {
    Write-Step "[Step 0-1] WSL2 필수 선택적 기능 활성화"
    Write-Warn "WSL2 실행에 필요한 Windows 선택적 기능이 비활성화되어 있습니다."
    Write-Info "선택적 기능(VirtualMachinePlatform 및 Microsoft-Windows-Subsystem-Linux)을 활성화합니다..."

    if (-not $wslFeatEnabled) {
        $p1 = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"`$ProgressPreference = 'SilentlyContinue'; Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -WarningAction SilentlyContinue | Out-Null`"" -PassThru -NoNewWindow
        Wait-WithSpinner -Message "Microsoft-Windows-Subsystem-Linux 기능 활성화" -Condition { $p1.HasExited }
    }
    if (-not $vmFeatEnabled) {
        $p2 = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"`$ProgressPreference = 'SilentlyContinue'; Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -WarningAction SilentlyContinue | Out-Null`"" -PassThru -NoNewWindow
        Wait-WithSpinner -Message "VirtualMachinePlatform 기능 활성화" -Condition { $p2.HasExited }
    }

    # wsl --install 로 WSL2 커널 및 기본 컴포넌트 설치 (배포판 없이)
    $pKernel = Start-Process wsl.exe -ArgumentList "--install --no-distribution" -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\wsl_kernel_install.txt" -ErrorAction SilentlyContinue
    Wait-WithSpinner -Message "WSL2 커널 컴포넌트 확인/설치" -Condition { $pKernel.HasExited }
    Remove-Item "$env:TEMP\wsl_kernel_install.txt" -Force -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "===========================================================================" -ForegroundColor Yellow
    Write-Host "  ✅ WSL2 필수 선택적 기능 활성화 완료!" -ForegroundColor Green
    Write-Host "  🔄 변경 사항을 적용하려면 Windows를 재시작해야 합니다." -ForegroundColor Yellow
    Write-Host "===========================================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  재시작 후 이 스크립트를 다시 실행하면 WSL2 배포판 설치부터 자동으로 이어서 진행됩니다." -ForegroundColor White
    Write-Host ""

    # 재개 플래그 파일 저장 (재시작 후 이어서 진행하기 위해, UTF-8 NoBOM 보장)
    [System.IO.File]::WriteAllText($_wslResumeFlagFile, (Get-Date).ToString(), [System.Text.UTF8Encoding]::new($false))

    Write-Warn "재시작하기 전에 열려 있는 다른 프로그램의 작업을 저장해 주세요."
    if (Prompt-Confirm "👉 지금 바로 컴퓨터를 재시작하시겠습니까?" "Y") {
        Write-Info "컴퓨터를 재시작합니다..."
        Start-Sleep -Seconds 2
        # -Force 를 쓰지 않습니다 — -Force 는 저장하지 않은 문서가 있는 프로그램도 묻지 않고 닫아 작업이 사라집니다.
        #   -Force 없이 실행하면 Windows 가 각 프로그램에 종료를 요청하고, 저장 안 된 작업이 있으면 프로그램이 재시작을 막을 수 있습니다.
        try {
            Restart-Computer -ErrorAction Stop
        } catch {
            Write-Warn "재시작하지 못했습니다: $($_.Exception.Message)"
            Write-Warn "작업을 저장하고 프로그램을 닫은 뒤 직접 재시작한 다음, 이 스크립트를 다시 실행해 주세요."
            Pause-Script
        }
        Exit-Devtools2Setup 0
    } else {
        Write-Warn "재시작을 건너뛰었습니다. 수동으로 컴퓨터를 재시작한 후 이 스크립트를 다시 실행해 주세요."
        Write-Host ""
        Write-Host "   irm https://raw.githubusercontent.com/devers2/_devtools2-setup/main/install.ps1 | iex" -ForegroundColor Cyan
        Write-Host ""
        Pause-Script
        Exit-Devtools2Setup 0
    }
}

# 재개 플래그가 있으면 이전 실행에서 WSL 기능을 설치하고 재부팅한 것이므로 바로 진행
if (Test-Path $_wslResumeFlagFile) {
    Write-Info "재시작 후 설치 재개 감지. WSL2 배포판 설치를 이어서 진행합니다."
    Remove-Item $_wslResumeFlagFile -Force -ErrorAction SilentlyContinue

    # WSL2를 기본 버전으로 설정
    wsl --set-default-version 2 2>$null | Out-Null
}


# ==============================================================================
# WSL 엔진·devtools2 배포판 (예전 _devtools2 의 0.setup-wsl.ps1 앞부분)
# ==============================================================================
# 중간에 끝낼 때(exit)도 빠른 편집 모드를 되돌린 뒤 끝냅니다 — 예전에는 정상 종료 때만 Restore-ConsoleQuickEdit 를 불러,
# 오류로 끝나면 창(또는 이 스크립트를 실행한 부모 셸)에서 마우스 선택이 꺼진 채로 남았습니다.
# 함수 안의 exit 이므로 예전과 같이 스크립트 전체를 끝냅니다.
function Exit-WslSetup([int]$Code) {
    Restore-ConsoleQuickEdit | Out-Null
    exit $Code
}

# wsl.exe 출력 파일 읽기 — wsl.exe 는 메시지를 UTF-16LE 로 내고, 오류도 stderr 가 아니라 stdout 으로 냅니다(실측).
#   예전에는 stderr 파일만 Get-Content 로 읽어서(0바이트, 또는 UTF-16 이라 글자 사이에 NUL) "--update"·"0x80370102"·
#   "가상화" 같은 키워드 검사가 항상 거짓이었습니다 → 업데이트 필요 감지·BIOS 가상화 안내가 동작하지 않았음.
#   NUL 바이트가 있으면 UTF-16LE, 없으면 UTF-8 로 읽고, 남은 NUL 은 지웁니다. 파일이 없으면 빈 문자열.
function Read-WslOutputFile {
    param([string[]]$Path)
    $texts = @()
    foreach ($p in $Path) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($p)
        if ($bytes.Length -eq 0) { continue }
        $texts += (ConvertFrom-WslOutputBytes $bytes)
    }
    return ($texts -join "`n")
}

# wsl.exe 출력 바이트를 문자열로 바꿉니다(Read-WslOutputFile 와 같은 판정 — NUL 이 있으면 UTF-16LE, 없으면 UTF-8).
#   파일을 거치지 않고 프로세스 출력 스트림을 직접 받은 경우(배포판 가져오기 등)에 씁니다.
function ConvertFrom-WslOutputBytes {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return "" }
    $enc = if ([Array]::IndexOf($Bytes, [byte]0) -ge 0) { [System.Text.Encoding]::Unicode } else { [System.Text.Encoding]::UTF8 }
    return ($enc.GetString($Bytes) -replace "`0", "" -replace ("^" + [char]0xFEFF), "")
}

function Show-BiosVirtualizationHelp {
    Write-Host ""
    Write-Host "===========================================================================" -ForegroundColor Red
    Write-Host "  ❌ 메인보드(BIOS/UEFI) 가상화(Virtualization) 비활성화 오류" -ForegroundColor Red
    Write-Host "===========================================================================" -ForegroundColor Red
    Write-Host "  WSL2 가상 머신을 실행하려면 CPU 가상화 기능(VT-x / AMD-V)이" -ForegroundColor Yellow
    Write-Host "  BIOS/UEFI 설정에서 활성화되어 있어야 합니다." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [BIOS/UEFI 가상화 활성화 방법 안내]" -ForegroundColor White
    Write-Host "  1. 컴퓨터를 재부팅한 후, 부팅 화면에서 [F2], [Del], 또는 [F12] 키를 누릅니다." -ForegroundColor White
    Write-Host "  2. Advanced / CPU Configuration / Security 메뉴로 이동합니다." -ForegroundColor White
    Write-Host "     • Intel CPU : 'Intel Virtualization Technology' 또는 'VT-x' → [Enabled]" -ForegroundColor Cyan
    Write-Host "     • AMD CPU   : 'SVM Mode' 또는 'AMD-V' → [Enabled]" -ForegroundColor Cyan
    Write-Host "  3. [F10] 키를 눌러 저장 후 재부팅(Save & Exit)을 진행합니다." -ForegroundColor White
    Write-Host "  4. 윈도우 재부팅 후 이 스크립트를 다시 실행해 주세요." -ForegroundColor Yellow
    Write-Host "===========================================================================" -ForegroundColor Red
    Write-Host ""
}

# ------------------------------------------------------------------------------
# wsl --update 실행 헬퍼
# ------------------------------------------------------------------------------
# Step 1 의 두 경로가 함께 사용합니다:
#   ● 5번 "업데이트 필수" 경로 (wsl --list 가 업데이트를 요구하며 동작하지 않는 경우)
#   ● 5-1번 "최신 버전 유지" 경로 (정상 동작하지만 새 정식 릴리스가 나온 경우)
# 반환값: 업데이트가 정상 완료되면 $true, 시간 초과/실패로 건너뛰면 $false.
# 재부팅이 필요(3010)하면 안내 후 스크립트를 종료합니다.
# 업데이트 실패는 설치 전체를 막지 않습니다 — 기존 WSL 버전 그대로 다음 단계를 계속합니다.
function Invoke-WslUpdate {
    $updateProc = Start-Process wsl.exe -ArgumentList "--update" -PassThru -NoNewWindow -ErrorAction SilentlyContinue
    if (-not $updateProc) {
        Write-Warn "WSL 업데이트 프로세스를 시작할 수 없습니다. 업데이트를 건너뛰고 계속 진행합니다."
        return $false
    }
    # 설계 원칙 7번(ExitCode $null 트랩): -Wait 없이 대기하면 PS 5.1 에서 ExitCode 가 $null 이 되어
    # 아래 3010(재부팅 필요) 판정이 조용히 빗나갑니다. Handle 을 미리 열어 두면 종료 코드가 보존됩니다
    # (_common.ps1 Install-OrUpdateWingetPackage 와 같은 방식).
    $null = $updateProc.Handle

    $waitSuccess = Wait-WithSpinner -Message "WSL 패키지 업데이트 진행 중" -Condition {
        return $updateProc.HasExited
    } -MaxTimeoutSeconds 600

    # ⚠️ 위 설치 단계와 동일한 이유로 타임아웃 여부를 먼저 확인합니다 — 체크하지
    # 않으면 업데이트가 실제로 끝나지 않았는데도 조용히 다음 단계로 넘어갑니다.
    if (-not $waitSuccess) {
        Write-Warn "WSL 업데이트가 제한 시간(600초) 내에 완료되지 않았습니다. 업데이트를 건너뛰고 계속 진행합니다."
        return $false
    }
    if ($updateProc.ExitCode -eq 3010) {
        Write-Host ""
        Write-Host "===========================================================================" -ForegroundColor Red
        Write-Host "  ⚠️  WSL 업데이트 적용을 완료하기 위해 시스템 재부팅이 필요합니다." -ForegroundColor Red
        Write-Host "===========================================================================" -ForegroundColor Red
        Write-Host "  컴퓨터를 재부팅한 후 이 스크립트를 다시 실행해 주세요." -ForegroundColor Yellow
        Write-Host "===========================================================================" -ForegroundColor Red
        Pause-Script
        Exit-WslSetup 3010
    }
    # 종료 코드를 끝내 읽지 못한($null) 경우는 실패로 단정하지 않습니다(설치 단계와 같은 이유).
    if ($null -ne $updateProc.ExitCode -and $updateProc.ExitCode -ne 0) {
        Write-Warn "WSL 업데이트가 실패했습니다. (종료 코드: $($updateProc.ExitCode)) 기존 버전으로 계속 진행합니다."
        return $false
    }
    return $true
}

# 버전 문자열에서 첫 번째 "a.b.c[.d]" 숫자 패턴을 [version] 으로 정규화합니다(빠진 자리는 0).
#   ● wsl --version 의 항목명은 OS 언어마다 다르므로("WSL 버전:" / "WSL version:") 숫자만 봅니다.
#     첫 줄이 WSL 본체 버전이라 첫 번째 일치를 사용합니다.
#   ● 로컬은 "2.6.1.0", GitHub 태그는 "2.6.1" 처럼 자릿수가 달라 문자열 비교로는 틀립니다.
# 추출 실패 시 $null 을 반환합니다.
function ConvertTo-WslVersion {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match(($Text -replace "`0", ""), '(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $m.Success) { return $null }
    $rev = if ($m.Groups[4].Success) { [int]$m.Groups[4].Value } else { 0 }
    return [version]::new([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value, $rev)
}


# 고정된 인스턴스 이름
$wslName = "devtools2"

# ==============================================================================
# [Step 1] WSL2 가상 머신 상태 확인 및 설치 진행
# ==============================================================================
Write-Step "[Step 1] WSL2 가상 머신 상태 확인"

# 1. wsl.exe 파일 존재 확인 (구형 Windows 대응)
$wslExePath = "$env:SystemRoot\System32\wsl.exe"
if (-not (Test-Path $wslExePath)) {
    Write-Host ""
    Write-Host "===========================================================================" -ForegroundColor Red
    Write-Host "  ❌ wsl.exe 를 찾을 수 없습니다." -ForegroundColor Red
    Write-Host "===========================================================================" -ForegroundColor Red
    Write-Host "  WSL2 설치에는 Windows 10 버전 2004 이상 또는 Windows 11 이 필요합니다." -ForegroundColor Yellow
    Write-Host "  Windows 업데이트를 실행한 후 이 스크립트를 다시 실행해 주세요." -ForegroundColor Yellow
    Write-Host "===========================================================================" -ForegroundColor Red
    Pause-Script
    Exit-WslSetup 1
}

# 2. wsl --version 으로 WSL 엔진 설치 여부 확인
# (WSL 미설치/인박스 환경에서는 wsl --version 이 무한 대기하거나 오래 멈출 수 있으므로 5초 타임아웃을 적용합니다)
$versionProc = Start-Process wsl.exe -ArgumentList "--version" -PassThru -NoNewWindow `
    -RedirectStandardOutput "$env:TEMP\wsl_version_check.txt" `
    -RedirectStandardError "$env:TEMP\wsl_version_error.txt" `
    -ErrorAction SilentlyContinue
# 설계 원칙 7번(ExitCode $null 트랩): Handle 을 미리 열지 않으면 PS 5.1 에서 아래 ExitCode 가 항상 $null 이 되어
# 설치된 WSL 도 "미설치"로 판정됩니다(실측: PS 5.1.26100 에서 wsl --version 정상 종료 후 ExitCode = $null).
# 그러면 매번 wsl --install 을 다시 실행하고, 5-1번(최신 버전 유지)도 건너뛰게 됩니다.
if ($versionProc) { $null = $versionProc.Handle }

Wait-WithSpinner -Message "WSL 엔진 버전 확인 중" -Condition {
    return (-not $versionProc) -or $versionProc.HasExited
} -MaxTimeoutSeconds 5 | Out-Null

if ($versionProc -and -not $versionProc.HasExited) {
    try { $versionProc | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
}

$isWslEngineInstalled = ($versionProc -and $versionProc.HasExited -and $versionProc.ExitCode -eq 0)

# 아래 5-1번(최신 버전 유지)에서 비교할 현재 WSL 버전을 임시 파일 삭제 전에 읽어 둡니다.
$installedWslVersion = $null
if ($isWslEngineInstalled -and (Test-Path "$env:TEMP\wsl_version_check.txt")) {
    $installedWslVersion = ConvertTo-WslVersion ([string](Get-Content "$env:TEMP\wsl_version_check.txt" -Raw -ErrorAction SilentlyContinue))
}

if (Test-Path "$env:TEMP\wsl_version_check.txt") { Remove-Item "$env:TEMP\wsl_version_check.txt" -Force -ErrorAction SilentlyContinue }
if (Test-Path "$env:TEMP\wsl_version_error.txt") { Remove-Item "$env:TEMP\wsl_version_error.txt" -Force -ErrorAction SilentlyContinue }

# 3. WSL 엔진 미설치 → wsl --install --no-distribution 으로 설치
if (-not $isWslEngineInstalled) {
    Write-Warn "WSL2 구성 요소가 설치되어 있지 않거나 반응하지 않습니다. 설치를 진행합니다..."
    # stderr를 캡처해두는 이유: 아래에서 실패 원인이 실제로 BIOS/UEFI 가상화 비활성화인지,
    # 아니면 네트워크/Windows Update 등 다른 이유인지 구분해야 하기 때문입니다.
    #   (wsl.exe 는 오류를 stdout 으로도 내므로 두 파일을 함께 받아 Read-WslOutputFile 로 읽습니다)
    $installErrPath = "$env:TEMP\wsl_install_error.txt"
    $installOutPath = "$env:TEMP\wsl_install_output.txt"
    $installProc = Start-Process wsl.exe -ArgumentList "--install --no-distribution" -PassThru -NoNewWindow `
        -RedirectStandardOutput $installOutPath -RedirectStandardError $installErrPath -ErrorAction SilentlyContinue
    # 설계 원칙 7번: Handle 을 미리 열어 아래 3010(재부팅 필요)·실패 종료 코드를 PS 5.1 에서도 읽을 수 있게 합니다.
    if ($installProc) { $null = $installProc.Handle }

    if ($null -eq $installProc) {
        Write-Fail "WSL 설치 프로세스를 시작할 수 없습니다."
        Pause-Script
        Exit-WslSetup 1
    }

    $waitSuccess = Wait-WithSpinner -Message "WSL2 구성 요소 다운로드 및 기능 활성화 진행 중" -Condition {
        return $installProc.HasExited
    } -MaxTimeoutSeconds 900

    # ⚠️ $waitSuccess를 체크하지 않으면, 타임아웃(900초) 후에도 프로세스가 아직 실행
    # 중인 상태로 바로 아래 ExitCode를 확인하게 됩니다. PowerShell은 이 경우 예외를
    # 던지지 않고 그냥 빈 값을 반환하므로(직접 테스트로 확인) "-eq 3010"이 조용히
    # false가 되어, 설치가 실제로 끝나지도 않았는데 아무 경고 없이 다음 단계로
    # 넘어가 버립니다. 타임아웃을 명시적으로 처리합니다.
    if (-not $waitSuccess) {
        Write-Fail "WSL2 설치가 제한 시간(900초) 내에 완료되지 않았습니다."
        Write-Warn "설치가 백그라운드에서 계속 진행 중일 수 있습니다. 잠시 기다린 후 이 스크립트를 다시 실행해 주세요."
        Pause-Script
        Exit-WslSetup 1
    }

    $installErrContent = [string](Read-WslOutputFile -Path $installErrPath, $installOutPath)
    Remove-Item $installErrPath, $installOutPath -Force -ErrorAction SilentlyContinue

    if ($installProc.ExitCode -eq 3010) {
        Write-Host ""
        Write-Host "===========================================================================" -ForegroundColor Red
        Write-Host "  ⚠️  WSL2 설치를 완료하기 위해 시스템 재부팅이 필요합니다." -ForegroundColor Red
        Write-Host "===========================================================================" -ForegroundColor Red
        Write-Host "  컴퓨터를 재부팅한 후 이 스크립트를 다시 실행해 주세요." -ForegroundColor Yellow
        Write-Host "===========================================================================" -ForegroundColor Red
        Pause-Script
        Exit-WslSetup 3010
    }
    # ⚠️ $installProc.ExitCode가 $null인 경우가 실제로 발생합니다(HasExited는 true인데
    # ExitCode 프로퍼티만 비어 있는 케이스). PowerShell에서 "$null -ne 0"은 $true이므로,
    # 이 상태를 걸러내지 않으면 "종료 코드를 못 읽음"까지 전부 "설치 실패"로 오판됩니다.
    # 이런 애매한 경우는 여기서 바로 실패 처리하지 않고, 뒤이은 "wsl --list" 등
    # 실제 설치 상태 확인 단계로 넘겨 판단합니다.
    # (원인은 Handle 미선점이었습니다 — 위에서 Handle 을 미리 열어 대부분 막지만, 방어용으로 이 처리는 유지합니다)
    elseif ($null -ne $installProc.ExitCode -and $installProc.ExitCode -ne 0) {
        Write-Fail "WSL2 설치가 실패했습니다. (종료 코드: $($installProc.ExitCode))"
        if (-not [string]::IsNullOrWhiteSpace($installErrContent)) {
            Write-Host "  [상세 오류 메시지]" -ForegroundColor Yellow
            Write-Host "  $($installErrContent.Trim())" -ForegroundColor Gray
        }
        # ⚠️ 이 단계(--install --no-distribution)는 Windows 기능 활성화/커널 다운로드
        # 단계일 뿐입니다. BIOS/UEFI 가상화(VT-x/AMD-V) 비활성화는 보통 이 단계가 아니라
        # "VM을 실제로 구동"할 때 나는 오류이므로, 여기서 나는 모든 실패를 가상화
        # 문제로 단정하면 오탐이 발생합니다(원인은 네트워크/Windows Update/재부팅
        # 대기 등 다양함). 오류 메시지에 가상화 관련 키워드가 실제로 포함된 경우에만
        # BIOS 안내를 보여주고, 그 외에는 일반 실패 안내만 표시합니다.
        if ($installErrContent -match "0x80370102|0x80370109|가상화|Virtualization|Hyper-V") {
            Show-BiosVirtualizationHelp
        } else {
            Write-Warn "네트워크 연결, Windows Update 서비스 상태, 또는 재부팅 대기 여부를 확인한 후 스크립트를 다시 실행해 주세요."
        }
        Pause-Script
        Exit-WslSetup 1
    }
}

# 4. 배포판 목록 확인 (wsl --list --quiet, 5초 타임아웃)
$registeredDistros = @()
$isUpdateRequired = $false

$listProc = Start-Process wsl.exe -ArgumentList "--list --quiet" -PassThru -NoNewWindow `
    -RedirectStandardOutput "$env:TEMP\wsl_list_check.txt" `
    -RedirectStandardError "$env:TEMP\wsl_list_error.txt" `
    -ErrorAction SilentlyContinue

Wait-WithSpinner -Message "WSL2 배포판 목록 확인 중" -Condition {
    return (-not $listProc) -or $listProc.HasExited
} -MaxTimeoutSeconds 5 | Out-Null

if ($listProc -and -not $listProc.HasExited) {
    try { $listProc | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
}

# 업데이트 경고 감지 (wsl.exe 는 안내를 stdout 으로 내므로 stdout·stderr 를 함께 봄)
$errContent = [string](Read-WslOutputFile -Path "$env:TEMP\wsl_list_error.txt")
$listContent = [string](Read-WslOutputFile -Path "$env:TEMP\wsl_list_check.txt")
Remove-Item "$env:TEMP\wsl_list_error.txt", "$env:TEMP\wsl_list_check.txt" -Force -ErrorAction SilentlyContinue
if ("$errContent`n$listContent" -match "업데이트해야 합니다|--update") {
    $isUpdateRequired = $true
}

# stdout 에서 배포판 목록 읽기
if (-not $isUpdateRequired) {
    $registeredDistros = @($listContent -split "`r?`n" |
        Where-Object { $_.Trim() -ne "" } |
        ForEach-Object { $_.Trim() })
}

# 5. 업데이트 필요 → wsl --update 실행
if ($isUpdateRequired) {
    Write-Warn "Linux용 Windows 하위 시스템(WSL)의 최신 버전 업데이트가 필요합니다. 업데이트를 진행합니다..."
    # 실행/대기/타임아웃/3010 재부팅 처리는 Invoke-WslUpdate 헬퍼(상단)에 있습니다 — 5-1번과 공용.
    $null = Invoke-WslUpdate

    # 업데이트 완료 후 배포판 목록 재확인
    $listProc2 = Start-Process wsl.exe -ArgumentList "--list --quiet" -PassThru -NoNewWindow `
        -RedirectStandardOutput "$env:TEMP\wsl_list_check.txt" -ErrorAction SilentlyContinue
    $listProc2 | Wait-Process -Timeout 3 -ErrorAction SilentlyContinue
    if (Test-Path "$env:TEMP\wsl_list_check.txt") {
        $registeredDistros = @(([string](Read-WslOutputFile -Path "$env:TEMP\wsl_list_check.txt")) -split "`r?`n" |
            Where-Object { $_.Trim() -ne "" } |
            ForEach-Object { $_.Trim() })
        Remove-Item "$env:TEMP\wsl_list_check.txt" -Force -ErrorAction SilentlyContinue
    }
}

# 5-1. 이미 설치된 WSL 최신 버전 유지 (새 정식 릴리스가 있을 때만 wsl --update)
# [설계 원칙 / Rationale]
#   ● Neovim · VS Code 등 winget 앱(Install-OrUpdateWingetPackage)과 같은 "설치돼 있으면 최신으로" 정책입니다.
#     위 5번은 WSL 이 업데이트 없이는 동작하지 않을 때만 실행되므로, 정상 동작하는 구버전은 계속 묵게 됩니다
#     (Store 자동 업데이트가 꺼진 PC 등). WSLg · --no-distribution · --list --online 등 최신 WSL 기능에 의존합니다.
#   ● 건너뛰는 경우: 이번 실행에서 새로 설치한 경우(--install 이 최신을 받음), 5번에서 이미 업데이트한 경우.
#   ● 최신 판단: GitHub microsoft/WSL 의 releases/latest(정식 릴리스만, pre-release 제외) tag_name 과
#     wsl --version 의 WSL 버전을 비교합니다. winget(Microsoft.WSL) 은 wsl --install 로 설치된 WSL 을
#     같은 패키지로 인식한다는 보장이 없어 공용 winget 헬퍼를 쓰지 않습니다.
#   ● 확인 실패(네트워크/프록시/API 호출 한도/버전 파싱 실패)는 업데이트를 건너뛰고 설치를 계속합니다.
#     최신 유지는 부가 기능이지 설치의 필수 조건이 아닙니다.
#   ● 데이터 안전: wsl --update 는 WSL 서비스·커널·WSLg 만 교체하며, 배포판(ext4.vhdx)·계정·/etc/wsl.conf·
#     %USERPROFILE%\.wslconfig 는 건드리지 않습니다. 이미 최신이면 아무것도 하지 않습니다(멱등).
#   ● 단, 업데이트 중 실행 중인 모든 WSL 배포판이 종료됩니다(작업 중인 Neovim/빌드/터미널 세션 끊김).
#     실행 중인 배포판이 있거나 확인할 수 없으면 경고 후 동의를 받습니다. 없으면 바로 진행합니다.
#     (마지막 프로세스 종료 후 잠시 남아 있는 유휴 VM 도 실행 중으로 보일 수 있습니다)
if ($isWslEngineInstalled -and -not $isUpdateRequired) {
    $latestWslVersion = $null
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/WSL/releases/latest" `
            -Headers @{ 'Accept' = 'application/vnd.github+json' } -TimeoutSec 10 -ErrorAction Stop
        $latestWslVersion = ConvertTo-WslVersion ([string]$release.tag_name)
    } catch {}

    if ($null -eq $installedWslVersion -or $null -eq $latestWslVersion) {
        Write-Skip "WSL 최신 버전을 확인할 수 없어 업데이트 확인을 건너뜁니다."
    }
    elseif ($installedWslVersion -ge $latestWslVersion) {
        Write-Skip "WSL 이(가) 이미 최신 버전입니다. ($installedWslVersion)"
    }
    else {
        Write-Info "WSL 최신 버전이 있습니다. ($installedWslVersion → $latestWslVersion)"

        # 실행 중인 배포판 확인 (5초 타임아웃 — 위 목록 확인과 같은 이유)
        # ExitCode 0 이면 실행 중인 배포판 이름 목록, 0 이 아니면 실행 중인 배포판 없음.
        # 시간 초과·종료 코드 확인 불가($null)는 "실행 중일 수 있음"으로 보고 동의를 받습니다(안전 측).
        $runningDistros = @()
        $runningCheckOk = $false
        $runProc = Start-Process wsl.exe -ArgumentList "--list --running --quiet" -PassThru -NoNewWindow `
            -RedirectStandardOutput "$env:TEMP\wsl_running_check.txt" `
            -RedirectStandardError "$env:TEMP\wsl_running_error.txt" `
            -ErrorAction SilentlyContinue
        if ($runProc) { $null = $runProc.Handle }

        Wait-WithSpinner -Message "실행 중인 WSL 배포판 확인 중" -Condition {
            return (-not $runProc) -or $runProc.HasExited
        } -MaxTimeoutSeconds 5 | Out-Null

        if ($runProc -and -not $runProc.HasExited) {
            try { $runProc | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
        }
        elseif ($runProc -and $null -ne $runProc.ExitCode) {
            $runningCheckOk = $true
            if ($runProc.ExitCode -eq 0 -and (Test-Path "$env:TEMP\wsl_running_check.txt")) {
                $runningDistros = @((Get-Content "$env:TEMP\wsl_running_check.txt" -Raw -ErrorAction SilentlyContinue) `
                    -replace "`0", "" -split "`r`n" |
                    Where-Object { $_.Trim() -ne "" } |
                    ForEach-Object { $_.Trim() })
            }
        }
        Remove-Item "$env:TEMP\wsl_running_check.txt", "$env:TEMP\wsl_running_error.txt" -Force -ErrorAction SilentlyContinue

        $doWslUpdate = $true
        if ($runningDistros.Count -gt 0 -or -not $runningCheckOk) {
            Write-Warn "WSL 업데이트 중 실행 중인 모든 WSL 배포판이 종료됩니다. (작업 중인 Neovim, 빌드, 터미널 세션 등이 끊깁니다)"
            if ($runningDistros.Count -gt 0) {
                Write-Info "  실행 중인 배포판: $($runningDistros -join ', ')"
            } else {
                Write-Info "  실행 중인 배포판을 확인하지 못했습니다."
            }
            Write-Info "  배포판 데이터와 계정은 그대로 유지됩니다. 작업 중인 내용이 있으면 먼저 저장해 주세요."
            Write-Info "  WSL 셸 안에서 이 스크립트를 실행했다면 스크립트도 함께 중단될 수 있습니다 — 그 경우 Windows PowerShell 에서 다시 실행해 주세요."
            $doWslUpdate = Prompt-Confirm "👉 지금 WSL 을 $latestWslVersion 버전으로 업데이트하시겠습니까?" "Y"
        }

        if ($doWslUpdate) {
            if (Invoke-WslUpdate) {
                Write-Success "WSL 업데이트 완료 ($installedWslVersion → $latestWslVersion)"
            }
        } else {
            Write-Skip "WSL 업데이트를 건너뜁니다. 나중에 'wsl --update' 로 직접 업데이트할 수 있습니다."
        }
    }
}

# 등록된 배포판을 HKCU Lxss 레지스트리로도 확인해 목록에 합칩니다.
#   ● wsl --list 는 5초(업데이트 뒤 3초) 안에 끝나지 않으면 빈 목록이 되어, devtools2 가 있는데도 "새 설치"로 판정하고
#     경로·비밀번호·내려받기까지 진행한 뒤 wsl --import 에서야 실패했습니다. WSL 은 등록한 배포판을 이 키에 기록하므로
#     출력 인코딩·타임아웃과 무관하게 판정할 수 있습니다(오프라인 가져오기와 같은 방식).
#   ● 레지스트리에만 있고 실제로는 응답하지 않는 경우는 아래 "확인 불가" 분기가 삭제 없이 중단시킵니다.
try {
    $lxssNames = @(Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss" -ErrorAction SilentlyContinue |
        ForEach-Object { [string](Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DistributionName } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($lxssName in $lxssNames) {
        if (-not ($registeredDistros -contains $lxssName)) { $registeredDistros += $lxssName }
    }
} catch {}

# 4. 'devtools2'가 이미 등록되어 있다면 신규 설치를 건너뛰고 계속 진행
if ($registeredDistros -contains $wslName) {
    # 기존 배포판에 Step 3-5(사용자 계정 및 wsl.conf [user] default 설정)가 완료되었는지 확인
    # ⚠️ 판정이 "확인 불가"(WSL 일시 오류로 명령 자체가 실패)인 경우를 "미완성"과 구분합니다.
    #    확인하지 못했다는 이유만으로 배포판을 지우면 안의 데이터가 전부 사라지기 때문입니다.
    $hasDefaultUser = $false
    $confReadOk = $false
    try {
        $wslConfContent = [string](@(wsl.exe -d $wslName -u root -- bash -c "cat /etc/wsl.conf 2>/dev/null; echo __DT2_OK__" 2>$null) | Out-String)
        $confReadOk = ($wslConfContent -match "__DT2_OK__")
        if ($wslConfContent -match "\[user\][\s\S]*?default\s*=") {
            $hasDefaultUser = $true
        }
    } catch {}

    if ($hasDefaultUser) {
        Write-Success "기존에 설치된 WSL2 배포판 '$wslName'이 이미 존재하여 이를 그대로 사용합니다."
        Write-Warn "---------------------------------------------------------------------------"
        Write-Warn " [새로운 배포판으로 깨끗하게 다시 설치하고 싶으신가요?]"
        Write-Warn " 아래 명령어를 실행하여 기존 배포판을 완전히 삭제한 뒤, 이 스크립트를 다시 실행해 주세요."
        Write-Host ""
        Write-Host "   wsl --unregister $wslName" -ForegroundColor Red
        Write-Warn "   (※ 주의: 기존 배포판 내의 모든 파일과 설정이 영구적으로 지워집니다.)"
        Write-Warn "---------------------------------------------------------------------------"
        Write-Host ""
        Write-Success "기존 배포판 사용 준비 완료. 다음 단계로 진행합니다."
    } elseif (-not $confReadOk) {
        Write-Fail "기존 배포판 '$wslName'의 상태(/etc/wsl.conf)를 확인하지 못했습니다(WSL 일시 오류일 수 있음)."
        Write-Warn "데이터 보호를 위해 배포판을 삭제하지 않고 중단합니다. 잠시 후 다시 실행하거나 아래 명령으로 상태를 확인해 주세요:"
        Write-Host "    wsl --shutdown" -ForegroundColor Gray
        Write-Host "    wsl -d $wslName -u root -- cat /etc/wsl.conf" -ForegroundColor Gray
        Pause-Script
        Exit-WslSetup 1
    } else {
        Write-Warn "기존 배포판 '$wslName'이 등록되어 있으나, 이전 실행 중단으로 인해 사용자 계정 및 환경 설정(Step 3-5)이 완료되지 않았습니다."
        Write-Warn "초기화(unregister)하면 이 배포판 안의 모든 파일이 영구적으로 삭제됩니다."
        if (Prompt-Confirm "미완성 배포판 '$wslName'을 삭제하고 새로 설치하시겠습니까?" "N") {
            Write-Info "미완성 배포판을 초기화(unregister)하고 설치를 다시 시작합니다..."
            wsl.exe --unregister $wslName 2>$null
            Start-Sleep -Seconds 1
            $registeredDistros = @()
        } else {
            Write-Info "배포판을 그대로 두고 중단합니다. 필요한 파일을 백업한 뒤 다시 실행하거나, 직접 정리해 주세요:"
            Write-Host "    wsl --export $wslName <백업파일.tar>" -ForegroundColor Gray
            Write-Host "    wsl --unregister $wslName" -ForegroundColor Gray
            Pause-Script
            Exit-WslSetup 1
        }
    }
}

# 배포판을 새로 만드는 경우에만 Step 2~3-5(경로 선택·다운로드·import·계정 구성)를 실행합니다.
# [설계 원칙 / Rationale]
#   ● 이 단계들은 Install-NewDevtools2Distro 함수로 묶고, 새 설치일 때만 아래에서 호출합니다.
#     예전에는 들여쓰기 없는 if 블록(약 480줄)이 스크립트 끝까지 이어져, 9(.wslconfig 네트워크)·9-1(메모리)·
#     10(배포판 정보 저장)까지 그 안에 들어가 재설치하면 메모리 상한 제안이 아예 나오지 않았습니다(실측 확인).
#     함수로 경계를 분명히 하고 테스트 6-7 이 9~10 단계가 함수·호출 블록 밖에 있는지 검사합니다.
#   ● dot-source(. Install-NewDevtools2Distro)로 호출해 함수 안에서 만든 변수($wslInstallPath, $installedDistroDesc,
#     $createdUsername 등)가 예전 인라인 코드와 똑같이 스크립트 범위에 남습니다(아래 완료 요약에서 사용).
#   ● 함수 안의 exit 는 예전과 같이 스크립트 전체를 끝냅니다. 함수 본문에 최상위 return 은 두지 않습니다
#     (인라인일 때는 스크립트 종료였지만 함수에서는 함수만 빠져나와 의미가 달라지기 때문).
#   ● here-string(@' … '@) 본문과 닫는 줄은 들여쓰지 않습니다(닫는 '@ 는 줄 맨 앞이어야 하고, 본문 Python 코드는 들여쓰기가 의미).
$isNewDistroInstall = -not ($registeredDistros -contains $wslName)
function Install-NewDevtools2Distro {

    # ==============================================================================
    # [Step 2] 설치 경로 결정 - 개발자 드라이브(Dev Drive / ReFS) 자동 감지 및 사용자 선택
    # ------------------------------------------------------------------------------
    # 같은 PC의 여러 Windows 사용자가 드라이브를 공유할 수 있으므로,
    # 파일 충돌 방지를 위해 경로에 Windows 계정명($env:USERNAME)을 포함합니다.
    # (배포판 이름 'devtools2'는 고정 유지 - WSL 등록은 사용자별로 독립적)
    # ==============================================================================
    Write-Step "[Step 2] WSL2 가상 머신 설치 경로 결정"

    $windowsUser = $env:USERNAME.ToLower()

    # 모든 드라이브를 순회하여 개발자 드라이브(ReFS 포맷) 자동 감지
    # Win32_Volume WMI 쿼리: FileSystem=ReFS 이면서 실제 접근 가능한 드라이브만 수집
    $devDrives = @()
    try {
        $volumes = Get-CimInstance -ClassName Win32_Volume -Filter "DriveType=3" -ErrorAction SilentlyContinue |
            Where-Object { $_.FileSystem -eq 'ReFS' -and -not [string]::IsNullOrEmpty($_.DriveLetter) } |
            Sort-Object DriveLetter
        foreach ($vol in $volumes) {
            $letter = $vol.DriveLetter.TrimEnd('\')   # "Z:" 형태로 정규화
            if (Test-Path "$letter\") {
                $devDrives += $letter
            }
        }
    } catch {
        $devDrives = @()
    }

    $cDriveDefault = Join-Path $env:USERPROFILE "AppData\Local\WSL\$wslName"

    Write-Host ""
    Write-Host "===========================================================================" -ForegroundColor DarkCyan
    Write-Host "  📂 WSL2 가상 머신 설치 드라이브 선택" -ForegroundColor DarkCyan
    Write-Host "===========================================================================" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  💡 개발자 드라이브(Dev Drive / ReFS)에 설치하면 WSL2 파일 I/O 성능이" -ForegroundColor Yellow
    Write-Host "     크게 향상됩니다. 가능하다면 개발자 드라이브를 선택하는 것을 권장합니다." -ForegroundColor Yellow
    Write-Host ""

    $choices = @()

    if ($devDrives.Count -gt 0) {
        Write-Host "  ✅ 감지된 개발자 드라이브 (권장):" -ForegroundColor Green
        foreach ($drv in $devDrives) {
            $installPath = "$drv\wsl\devtools2\$windowsUser"
            $idx = $choices.Count + 1
            Write-Host ("  {0}) ★ {1}  →  {2}" -f $idx, $drv, $installPath) -ForegroundColor Cyan
            $choices += @{ Label = "$drv (개발자 드라이브)"; Path = $installPath }
        }
        Write-Host ""
    }

    # C: 폴백 옵션 (항상 마지막 번호로 추가)
    $cIdx = $choices.Count + 1
    Write-Host ("  {0}) C: (일반 드라이브)  →  {1}" -f $cIdx, $cDriveDefault) -ForegroundColor Gray
    $choices += @{ Label = "C: (일반 드라이브)"; Path = $cDriveDefault }

    Write-Host ""
    Write-Host "---------------------------------------------------------------------------" -ForegroundColor DarkGray

    $driveIdx = Prompt-Choice "👉 설치할 드라이브 번호를 입력하세요" ($choices | ForEach-Object { $_.Label }) 1
    $wslInstallPath = $choices[$driveIdx - 1].Path
    $selectedLabel  = $choices[$driveIdx - 1].Label

    Write-Host ""
    Write-Success "선택 완료: $selectedLabel"
    Write-Info    "WSL2 가상 머신 설치 경로: $wslInstallPath"
    Write-Host ""

    # ==============================================================================
    # [Step 3] 가상 머신 존재 확인 또는 공식 RootFS 직접 Import 생성
    # ------------------------------------------------------------------------------
    # ⚠️ [보안 및 안정성 원칙]
    # - 기존에 PC에 설치되어 있던 다른 Ubuntu 배포판(Ubuntu, Ubuntu-22.04 등)을
    #   절대 조회하거나 해제(unregister)하지 않습니다.
    # - Canonical 공식 Ubuntu WSL 경량 rootfs 이미지를 다운로드하여 지정된 경로에
    #   'wsl --import'로 직접 단번에 배포판을 생성합니다.
    # ==============================================================================
    $existingVhdx = Join-Path $wslInstallPath "ext4.vhdx"
    $skipDownload = $false
    $installedDistroDesc = "Ubuntu"

    if (Test-Path $existingVhdx) {
        Write-Host ""
        Write-Success "지정된 경로에 기존 WSL2 가상 디스크(ext4.vhdx)가 발견되었습니다:"
        Write-Host "   $existingVhdx" -ForegroundColor Cyan
        Write-Host ""
        $useExisting = Prompt-Confirm "기존 가상 디스크를 '$wslName' 배포판으로 즉시 재등록하여 사용하시겠습니까?" "Y"
        if ($useExisting) {
            Write-Info "기존 가상 디스크를 '$wslName'으로 등록 중..."
            # ⚠️ "wsl --import ... --vhd" 는 vhdx 를 설치 위치로 "복사"하므로, 원본이 이미 설치 위치
            #    ($wslInstallPath\ext4.vhdx)에 있으면 같은 경로로 복사하려다 실패합니다.
            #    이미 있는 가상 디스크를 그 자리에서 등록하는 명령은 --import-in-place 입니다.
            wsl --import-in-place $wslName $existingVhdx
            if ($LASTEXITCODE -eq 0) {
                Write-Success "기존 가상 디스크 재등록 완료!"
                $skipDownload = $true
                $installedDistroDesc = "Ubuntu (기존 가상 디스크 재등록)"
            } else {
                Write-Warn "기존 가상 디스크 재등록에 실패했습니다. 새로운 배포판 설치를 진행합니다."
            }
        }

        # 기존 가상 디스크를 쓰지 않으면(거절·재등록 실패) 같은 폴더에는 새로 import 할 수 없습니다
        # (ext4.vhdx 가 이미 있어 wsl --import 가 실패 — 그것도 버전 선택·비밀번호·내려받기를 다 한 뒤에).
        # 기존 디스크(안의 데이터)는 지우지 않고 옆의 새 폴더에 설치합니다.
        if (-not $skipDownload) {
            $altInstallPath = "$wslInstallPath-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Write-Warn "이 폴더에는 기존 가상 디스크가 있어 새 배포판을 만들 수 없습니다: $wslInstallPath"
            Write-Info "기존 ext4.vhdx 는 그대로 두고, 새 배포판은 다른 폴더에 설치할 수 있습니다: $altInstallPath"
            if (Prompt-Confirm "새 폴더에 설치하시겠습니까? (N: 중단 — 기존 파일을 정리한 뒤 다시 실행)" "Y") {
                $wslInstallPath = $altInstallPath
                Write-Info "WSL2 가상 머신 설치 경로: $wslInstallPath"
            } else {
                Write-Info "중단합니다. 기존 가상 디스크가 필요 없다면 백업·삭제한 뒤 다시 실행해 주세요:"
                Write-Host "    $existingVhdx" -ForegroundColor Gray
                Pause-Script
                Exit-WslSetup 1
            }
        }
    }

    if (-not $skipDownload) {
        # ── 1. Ubuntu 배포판 버전 선택 (동적 탐지) ─────────────────────────────
        # [1순위] Microsoft 공식 WSL 배포판 목록(DistributionInfo.json)에서 LTS 버전을 가져옵니다.
        #   ● wsl --install / wsl --list --online 이 쓰는 것과 같은 목록이라 새 LTS 가 나오면 자동으로 보입니다.
        #   ● Canonical 은 26.04 부터 WSL 이미지를 cloud-images.ubuntu.com/wsl 이 아니라 releases.ubuntu.com 에
        #     새 형식(.wsl — 내용은 일반 rootfs tar.gz)으로만 올립니다. 예전처럼 cloud-images 만 보면 26.04 가
        #     목록에 없어 24.04 가 "최신 LTS"로 잘못 표시됐습니다(2026-10 확인).
        #   ● 각 이미지의 다운로드 URL 과 SHA256 이 함께 들어 있어 아래 무결성 검증에 그대로 씁니다.
        #   ● LTS(짝수 연도 .04)만, 최신 LTS 부터 3개($ltsKeep)만 보여 주며 1번(최신 LTS)이 기본값입니다.
        #     설치 후 문제가 있으면 이전 LTS 를 골라 다시 설치하면 됩니다.
        # [2순위 폴백] 공식 목록 조회에 실패하면 아래의 기존 방식(cloud-images 탐지)을 그대로 씁니다:
        # cloud-images.ubuntu.com/wsl/releases/ 에서 사용 가능한 LTS 버전을
        # 런타임에 자동 탐지합니다. 각 버전의 /current/ 디렉터리에서 rootfs
        # 파일명을 파싱하여 codename(noble, jammy 등)을 추출합니다.
        # --------------------------------------------------------------------------
        Write-Step "[Step 3-1] Ubuntu 배포판 버전 선택"
        Write-Info "설치 가능한 Ubuntu LTS 버전을 확인하는 중..."

        $ltsKeep = 3
        # 아키텍처는 버전 목록(이미지 URL)부터 필요하므로 여기서 먼저 정합니다 (Step 3-3 에서 그대로 사용)
        $isArm64 = ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64)
        $arch = if ($isArm64) { "arm64" } else { "amd64" }

        # 버전("26.04") → @{ Ver; Url; Sha256 } (Microsoft 공식 목록에서 찾은 이미지)
        $msDistros = [ordered]@{}
        try {
            $distInfo = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json" -TimeoutSec 15 -ErrorAction Stop
            $found = @()
            foreach ($d in @($distInfo.ModernDistributions.Ubuntu)) {
                # "Ubuntu"(= 최신 LTS 별칭) 은 버전이 붙은 항목과 중복이라 건너뛰고 "Ubuntu-NN.04" 만 봅니다
                $vm = [regex]::Match([string]$d.Name, '^Ubuntu-(\d+)\.04$')
                if (-not $vm.Success) { continue }
                if (([int]$vm.Groups[1].Value % 2) -ne 0) { continue }   # 짝수 연도 .04 = LTS
                $urlObj = if ($isArm64) { $d.Arm64Url } else { $d.Amd64Url }
                if ($null -eq $urlObj -or [string]::IsNullOrWhiteSpace([string]$urlObj.Url)) { continue }
                $sha = [string]$urlObj.Sha256
                if (-not [string]::IsNullOrWhiteSpace($sha)) { $sha = ($sha.Trim().ToLower() -replace '^0x', '') }
                $found += [pscustomobject]@{ Ver = "$($vm.Groups[1].Value).04"; Url = [string]$urlObj.Url; Sha256 = $sha }
            }
            foreach ($f in @($found | Sort-Object { [System.Version]($_.Ver + ".0") } -Descending | Select-Object -First $ltsKeep)) {
                $msDistros[$f.Ver] = $f
            }
        } catch {
            Write-Warn "Microsoft 공식 WSL 배포판 목록 조회에 실패했습니다. Canonical cloud-images 목록으로 확인합니다."
        }

        if ($msDistros.Count -gt 0) {
            $availableVersions = @($msDistros.Keys)
        } else {
            $availableVersions = @()
            try {
                $releasesHtml = Invoke-RestMethod -Uri "https://cloud-images.ubuntu.com/wsl/releases/" -TimeoutSec 15 -ErrorAction Stop
                # HTML 디렉터리 목록에서 "22.04/", "24.04/" 같은 버전 링크 추출
                # Apache 버전(2.4, 3.2 등)을 제외하기 위해 >= 20.00 필터 적용
                $versionMatches = [regex]::Matches($releasesHtml, 'href="(\d+\.\d+)/"')
                foreach ($m in $versionMatches) {
                    $ver = $m.Groups[1].Value
                    if ([double]$ver -ge 20.0) {
                        $availableVersions += $ver
                    }
                }
                # 최신 버전이 맨 앞에 오도록 내림차순 정렬
                $availableVersions = $availableVersions | Sort-Object { [System.Version]($_ + ".0") } -Descending
            } catch {
                Write-Warn "온라인 버전 목록 조회에 실패했습니다. 기본 버전(24.04, 22.04)을 사용합니다."
                $availableVersions = @("24.04", "22.04")
            }

            if ($availableVersions.Count -eq 0) {
                Write-Warn "사용 가능한 Ubuntu 버전을 찾을 수 없습니다. 기본 버전(24.04, 22.04)을 사용합니다."
                $availableVersions = @("24.04", "22.04")
            }
            # 폴백 목록도 최신 LTS 부터 3개만
            $availableVersions = @($availableVersions | Select-Object -First $ltsKeep)
        }

        # 각 버전의 codename 을 rootfs 파일명에서 동적으로 추출
        # 예: ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz → "noble"
        $versionMap = [ordered]@{}
        foreach ($ver in $availableVersions) {
            $codename = $null
            # 공식 목록에서 찾은 버전은 이미지 URL 을 이미 알므로 cloud-images 조회를 건너뜁니다(표시는 아래 알려진 코드명)
            if (-not $msDistros.Contains($ver)) { try {
                $currentHtml = Invoke-RestMethod -Uri "https://cloud-images.ubuntu.com/wsl/releases/$ver/current/" -TimeoutSec 10 -ErrorAction Stop
                $codenameMatch = [regex]::Match($currentHtml, 'ubuntu-([a-z]+)-wsl-')
                if ($codenameMatch.Success) {
                    $codename = $codenameMatch.Groups[1].Value
                }
            } catch {
                # codename 조회 실패 시 무시 — 아래에서 폴백 처리
            } }
            # 잘 알려진 LTS codename 폴백 매핑
            if ([string]::IsNullOrEmpty($codename)) {
                $knownCodenames = @{
                    "24.04" = "noble"; "22.04" = "jammy"; "20.04" = "focal"
                    # 26.04 정식 코드명은 Resolute Raccoon (예전 값 "euphoric" 은 잘못된 추정이었음)
                    "26.04" = "resolute"; "28.04" = "unknown"
                }
                if ($knownCodenames.ContainsKey($ver)) {
                    $codename = $knownCodenames[$ver]
                } else {
                    $codename = "unknown"
                }
            }
            $versionMap[$ver] = $codename
        }

        # 사용자에게 선택지 제시 (최신 버전 = 1번 = 기본 선택)
        Write-Host "  설치할 Ubuntu 버전을 선택하세요:" -ForegroundColor White
        $versionChoices = @()
        $vIdx = 1
        foreach ($ver in $versionMap.Keys) {
            $cn = $versionMap[$ver]
            $cnCapital = (Get-Culture).TextInfo.ToTitleCase($cn)
            # 코드명을 모르는 새 LTS(unknown)는 괄호 안에 버전 설명만 표시
            $cnPart = if ($cn -eq "unknown") { "" } else { "$cnCapital - " }
            $label = if ($vIdx -eq 1) {
                "Ubuntu $ver LTS (${cnPart}최신 LTS 권장)"
            } elseif ($cn -eq "unknown") {
                "Ubuntu $ver LTS"
            } else {
                "Ubuntu $ver LTS ($cnCapital)"
            }
            $color = if ($vIdx -eq 1) { "Cyan" } else { "White" }
            Write-Host ("    {0}) {1}" -f $vIdx, $label) -ForegroundColor $color
            $versionChoices += $label
            $vIdx++
        }
        Write-Host ""
        $versionIdx = Prompt-Choice "👉 번호를 입력하세요" $versionChoices 1

        $selectedVer = @($versionMap.Keys)[$versionIdx - 1]
        $ubuntuVer = $selectedVer
        $ubuntuCodename = $versionMap[$selectedVer]
        $installedDistroDesc = "Ubuntu $ubuntuVer LTS ($ubuntuCodename)"
        Write-Info "선택된 Ubuntu 버전: $installedDistroDesc"

        # ── 2. WSL2 내부 기본 사용자 계정 및 비밀번호 설정 ─────────────────────
        Write-Step "[Step 3-2] WSL2 기본 사용자 계정 설정"
        Write-Host "  WSL2 내부에서 사용할 기본 사용자 계정과 비밀번호를 설정합니다." -ForegroundColor White
        $createdUsername = ""
        while ([string]::IsNullOrEmpty($createdUsername)) {
            Write-Host "👉 사용자 이름(Username) 입력 [기본값: $windowsUser]: " -ForegroundColor Yellow -NoNewline
            $inputUser = Read-Dt2Input
            $candidate = if ([string]::IsNullOrWhiteSpace($inputUser)) { $windowsUser } else { $inputUser.Trim() }
            $candidate = $candidate.Trim([char]0xFEFF).Trim().ToLower()

            # 리눅스 계정명 규칙 검증: 영문 소문자, 숫자, 하이픈(-), 밑줄(_), 32자 이하
            #   ● 배포판에 이미 있는 시스템 계정(root·daemon·nobody 등)은 받지 않습니다 — useradd 를 건너뛰고
            #     그 계정의 비밀번호를 바꾼 뒤 기본 사용자로 지정해, root 로 일상 작업을 하게 되거나 시스템 계정이 로그인 계정이 됩니다.
            #     ubuntu 는 일부 Ubuntu 이미지에 기본 계정으로 들어 있어(sudo 그룹이 아닐 수 있음) 함께 막습니다.
            $reservedUsers = @('root', 'daemon', 'bin', 'sys', 'sync', 'games', 'man', 'lp', 'mail', 'news', 'uucp', 'proxy',
                'www-data', 'backup', 'list', 'irc', 'gnats', 'nobody', '_apt', 'messagebus', 'syslog', 'ubuntu')
            if ($candidate -match '^[a-z_][a-z0-9_-]{0,31}$' -and $reservedUsers -notcontains $candidate -and $candidate -notlike 'systemd-*') {
                $createdUsername = $candidate
            } elseif ($candidate -match '^[a-z_][a-z0-9_-]{0,31}$') {
                Write-Warn "'$candidate' 은(는) 배포판에 이미 있는 시스템 계정 이름이라 사용할 수 없습니다. 다른 이름을 입력해 주세요."
                Write-Host ""
            } else {
                Write-Warn "사용자 계정명은 영문 소문자, 숫자, 하이픈(-), 밑줄(_)만, 32자 이하로 사용할 수 있습니다. (입력값: '$candidate')"
                Write-Host ""
            }
        }
        Write-Success "사용자 계정명: $createdUsername"

        $plainPassword = ""
        while ([string]::IsNullOrEmpty($plainPassword)) {
            $pw1 = Prompt-Password "👉 비밀번호(Password) 입력: "
            $bstr1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw1)
            $plain1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr1)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr1)

            $pw2 = Prompt-Password "👉 비밀번호(Password) 확인: "
            $bstr2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw2)
            $plain2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr2)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2)

            if ($plain1 -eq $plain2 -and -not [string]::IsNullOrEmpty($plain1)) {
                $plainPassword = $plain1
                Write-Success "비밀번호 설정 확인 완료"
            } else {
                Write-Fail "비밀번호가 일치하지 않거나 비어있습니다. 다시 입력해 주세요."
                Write-Host ""
            }
        }

        # ── 3. Canonical 공식 Ubuntu WSL RootFS 다운로드 (미러 및 원본 폴백 지원) ──
        Write-Step "[Step 3-3] Ubuntu WSL RootFS 다운로드"
        # ($isArm64 / $arch 는 Step 3-1 에서 이미 정했습니다)
        $rootfsFileName = "ubuntu-$ubuntuCodename-wsl-$arch-wsl.rootfs.tar.gz"

        # 우선순위 미러 및 공식 CDN URL 목록 (다중 URL 자동 폴백 지원)
        $rootfsUrls = @(
            "https://cloud-images.ubuntu.com/wsl/releases/$ubuntuVer/current/$rootfsFileName",
            "https://cloud-images.ubuntu.com/wsl/$ubuntuCodename/current/$rootfsFileName"
        )
        # Microsoft 공식 목록에서 고른 버전: releases.ubuntu.com 의 .wsl 이미지(내용은 rootfs tar.gz)를 사용
        # (wsl --import 는 gzip 압축을 내용으로 판별하므로 임시 파일 이름은 기존과 같은 .tar.gz 로 둡니다)
        $msImage = $null
        if ($msDistros.Contains($ubuntuVer)) {
            $msImage = $msDistros[$ubuntuVer]
            $rootfsUrls = @($msImage.Url)
        }

        $tempTarPath = Join-Path $env:TEMP "ubuntu-$ubuntuCodename-wsl-$arch.rootfs.tar.gz"
        $downloadOk = Download-WithProgress -Urls $rootfsUrls -DestinationPath $tempTarPath -Description "Ubuntu $ubuntuVer LTS ($arch)"

        if (-not $downloadOk -or -not (Test-Path $tempTarPath)) {
            Write-Fail "Ubuntu RootFS 다운로드에 실패했습니다. 네트워크 연결 상태를 확인해 주세요."
            Pause-Script
            Exit-WslSetup 1
        }

        # ── RootFS SHA256 무결성 검증 (같은 폴더의 공식 SHA256SUMS 기준) ──
        # 불일치하면 손상·변조된 이미지로 배포판을 만들지 않도록 중단합니다.
        # SHA256SUMS 자체를 받지 못한 경우에만 경고 후 계속합니다.
        # (Microsoft 공식 목록 이미지는 목록에 들어 있는 SHA256 을 그대로 기준값으로 씁니다)
        $expectedSha = $null
        if ($msImage -and -not [string]::IsNullOrWhiteSpace($msImage.Sha256)) { $expectedSha = $msImage.Sha256 }
        if (-not $expectedSha) { foreach ($u in $rootfsUrls) {
            $sumsUrl = ($u -replace '/[^/]+$', '') + '/SHA256SUMS'
            try {
                $sums = [string](Invoke-RestMethod -Uri $sumsUrl -TimeoutSec 15 -ErrorAction Stop)
                foreach ($line in ($sums -split "`n")) {
                    $parts = $line.Trim() -split '\s+'
                    if ($parts.Count -ge 2 -and $parts[1].TrimStart('*') -eq $rootfsFileName) { $expectedSha = $parts[0].ToLower(); break }
                }
            } catch {}
            if ($expectedSha) { break }
        } }
        if ($expectedSha) {
            $actualSha = (Get-FileHash -Path $tempTarPath -Algorithm SHA256).Hash.ToLower()
            if ($actualSha -ne $expectedSha) {
                Write-Fail "Ubuntu RootFS SHA256 불일치 — 손상되었거나 변조된 파일일 수 있어 설치를 중단합니다."
                Write-Host "    예상: $expectedSha" -ForegroundColor Gray
                Write-Host "    실제: $actualSha" -ForegroundColor Gray
                Remove-Item $tempTarPath -Force -ErrorAction SilentlyContinue
                Pause-Script
                Exit-WslSetup 1
            }
            Write-Success "Ubuntu RootFS SHA256 무결성 검증 통과"
        } else {
            Write-Warn "SHA256SUMS 를 받지 못해 RootFS 체크섬 검증 없이 계속합니다."
        }

        # ── 4. 지정 경로에 WSL2 배포판 직접 Import ─────────────────────────────
        Write-Step "[Step 3-4] WSL2 배포판 직접 생성 (wsl --import)"
        if (-not (Test-Path $wslInstallPath)) {
            New-Item -ItemType Directory -Path $wslInstallPath -Force | Out-Null
        }

        Write-Info "배포판을 '$wslName' 이름으로 생성 중... ($wslInstallPath)"

        # .NET Process API로 직접 백그라운드 프로세스 실행 (PS 5.1의 Start-Process 핸들 누락 버그 회피 - Rule 8)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "$env:SystemRoot\System32\wsl.exe"
        $psi.Arguments = "--import `"$wslName`" `"$wslInstallPath`" `"$tempTarPath`" --version 2"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardError = $true
        # wsl.exe 는 오류를 stderr 가 아니라 stdout 으로(UTF-16LE) 냅니다(실측) → stdout 도 받아 오류 상세에 씁니다.
        #   파이프 버퍼가 가득 차 wsl.exe 가 멈추지 않도록 두 스트림을 시작 직후부터 비동기로 끝까지 읽어 둡니다.
        $psi.RedirectStandardOutput = $true

        $importProc = [System.Diagnostics.Process]::Start($psi)
        $importOutBuf = New-Object System.IO.MemoryStream
        $importErrBuf = New-Object System.IO.MemoryStream
        $importReadTasks = @()
        if ($importProc) {
            $importReadTasks += $importProc.StandardOutput.BaseStream.CopyToAsync($importOutBuf)
            $importReadTasks += $importProc.StandardError.BaseStream.CopyToAsync($importErrBuf)
        }
        $importWait = Wait-WithSpinner -Message "WSL2 배포판 가상 디스크 생성 및 Import 중" -Condition {
            return ($null -eq $importProc) -or $importProc.HasExited
        } -MaxTimeoutSeconds 600
        if (-not $importWait -and $importProc) {
            # 600초는 안내 기준일 뿐입니다 — 느린 디스크·백신 검사 중이면 더 걸릴 수 있습니다.
            #   예전에는 여기서 아무 표시 없이 WaitForExit() 로 기다렸다가, 끝내 성공해도 "시간 초과"라 실패로 판정했습니다.
            Write-Warn "배포판 가져오기가 600초를 넘겼지만 아직 진행 중입니다. 끝날 때까지 계속 기다립니다(멈춘 것 같으면 Ctrl+C 로 중단)."
            $importWait = Wait-WithSpinner -Message "WSL2 배포판 가져오기 계속 대기 중" -Condition {
                return $importProc.HasExited
            } -MaxTimeoutSeconds ([int]::MaxValue)
        }

        $jobExit = 1
        $errDetail = ""
        if ($importProc) {
            $importProc.WaitForExit()
            $jobExit = $importProc.ExitCode
            try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$importReadTasks, 5000) } catch {}
            $errDetail = ((ConvertFrom-WslOutputBytes $importErrBuf.ToArray()) + "`n" + (ConvertFrom-WslOutputBytes $importOutBuf.ToArray())).Trim()
            $importProc.Dispose()
        } else {
            $errDetail = "WSL 가져오기 프로세스를 시작할 수 없습니다."
        }
        Remove-Item $tempTarPath -Force -ErrorAction SilentlyContinue

        # 배포판 등록 여부 실제 확인 (Rule 8: 프로세스 종료코드 외에 실제 시스템 자원 상태 교차 검증)
        $distroExists = $false
        try {
            $rawList = @(wsl.exe --list --quiet 2>$null)
            $cleanDistros = $rawList | ForEach-Object { ([string]$_ -replace "`0", "").Trim() }
            $distroExists = [bool]($cleanDistros -contains $wslName)
        } catch {}

        # 최종 성공 여부 판정:
        # 1) 타임아웃 미발생
        # 2) 배포판이 실제로 정상 등록됨 (실측 검증)
        # 3) 명시적 실패(종료 코드 0이 아님)가 아님
        $isImportSuccess = $importWait -and $distroExists -and ($jobExit -eq 0)

        if (-not $isImportSuccess) {
            Write-Fail "배포판 가져오기(Import) 실패 (종료 코드: $jobExit)"
            if (-not [string]::IsNullOrWhiteSpace($errDetail)) { Write-Warn "오류 상세: $errDetail" }
            Pause-Script
            Exit-WslSetup 1
        }
        Write-Success "WSL2 배포판 '$wslName' 생성 완료!"

        # ── 5. 기본 계정 생성 및 시스템 설정 초기화 (root 권한 1회 설정) ─────────
        Write-Step "[Step 3-5] 기본 계정 및 시스템 환경 구성"
        Write-Info "사용자 계정($createdUsername) 생성 및 wsl.conf(systemd=true 포함) 구성 중..."

        # 1) 일반 사용자 계정 생성 (sudo, adm, users 그룹 등록)
        wsl -d $wslName -u root -- bash -c "id -u '$createdUsername' >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,adm,users '$createdUsername'"
        $userAddExit = $LASTEXITCODE
        if ($userAddExit -ne 0) {
            Write-Fail "사용자 계정($createdUsername) 생성 실패 (종료 코드: $userAddExit)"
            Pause-Script
            Exit-WslSetup 1
        }

        # 2) 사용자 비밀번호 설정 (NoBOM 인코딩 보장 및 chpasswd 표준입력 전달)
        #    ⚠️ PowerShell은 네이티브 프로그램(wsl.exe)으로 파이프할 때 줄 끝에 CRLF(\r\n)를 붙입니다(실측).
        #    chpasswd는 \n만 제거하므로 그대로 넘기면 비밀번호 끝에 \r이 포함되어 저장되고,
        #    설치 후 sudo 등에서 입력한 비밀번호가 맞지 않게 됩니다. → tr -d '\r' 로 CR을 제거한 뒤 전달합니다.
        $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        Write-Output "${createdUsername}:${plainPassword}" | wsl -d $wslName -u root -- bash -c "tr -d '\r' | chpasswd"
        $chpasswdExit = $LASTEXITCODE
        $plainPassword = $null
        if ($chpasswdExit -ne 0) {
            Write-Fail "사용자 비밀번호 설정(chpasswd) 실패 (종료 코드: $chpasswdExit)"
            Pause-Script
            Exit-WslSetup 1
        }

        # 2) hostname 및 /etc/wsl.conf 설정 (기존 설정 보존하며 default user, systemd=true, interop 섹션 병합)
        wsl -d $wslName -u root -- bash -c "echo '$wslName' > /etc/hostname"
        $mergeWslConfPy = @'
import configparser, sys

path = '/etc/wsl.conf'
username = sys.argv[1]
# optionxform=str: 기본값(str.lower)이면 appendWindowsPath 같은 키가 소문자로 바뀌어 기록됩니다.
# interpolation=None: 값에 '%' 가 있어도(automount options 등) 오류 없이 그대로 보존합니다.
c = configparser.ConfigParser(interpolation=None)
c.optionxform = str
c.read(path)

for sec in ['boot', 'user', 'interop']:
    if not c.has_section(sec):
        c.add_section(sec)

c.set('boot', 'systemd', 'true')
c.set('user', 'default', username)
c.set('interop', 'enabled', 'true')
c.set('interop', 'appendWindowsPath', 'true')

with open(path, 'w', encoding='utf-8') as f:
    c.write(f)
'@
        $mergeWslConfPy | wsl -d $wslName -u root -- python3 - "$createdUsername"
        if ($LASTEXITCODE -ne 0) {
            # Python 실패 시 bash 순수 heredoc 폴백으로 직접 기록
            $confFallback = @"
cat << 'EOF' > /etc/wsl.conf
[boot]
systemd=true

[user]
default=$createdUsername

[interop]
enabled=true
appendWindowsPath=true
EOF
"@
            # CRLF(파이프 줄 끝/로컬 CRLF 체크아웃)가 섞이면 heredoc 종료 줄(EOF\r)을 인식하지 못하므로 CR 제거 후 실행
            $confFallback | wsl -d $wslName -u root -- bash -c "tr -d '\r' | bash"
            # 폴백까지 실패하면 기본 사용자가 root 로 남고 systemd 도 꺼진 채 다음 단계가 진행되므로 여기서 멈춥니다.
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "/etc/wsl.conf 기록 실패 (종료 코드: $LASTEXITCODE) — 기본 사용자·systemd 설정이 적용되지 않았습니다."
                Write-Host "    확인: wsl -d $wslName -u root -- cat /etc/wsl.conf" -ForegroundColor Gray
                Pause-Script
                Exit-WslSetup 1
            }
        }

        # 3) Windows Interop 핸들러 등록
        Register-WslInterop $wslName

        Write-Success "WSL2 시스템 환경 및 사용자($createdUsername) 구성 완료!"

        # 4) /etc/wsl.conf 의 [user] default=$createdUsername 및 systemd 설정을 즉시 적용하기 위해 배포판 종료(terminate)
        wsl --terminate $wslName 2>$null
    }

}
# ── Install-NewDevtools2Distro 끝 ──

if ($isNewDistroInstall) {
    . Install-NewDevtools2Distro
}

# --------------------------------------------------------------------------
# [Step 4] 완료 — 설치 경로·배포판 정보는 새로 설치했을 때만 있으므로 그때만 요약을 보여 줍니다
# --------------------------------------------------------------------------
if ($isNewDistroInstall) {
Write-Host ""
Write-Host "===========================================================================" -ForegroundColor DarkCyan
Write-Host "🎉 WSL2 설치 및 환경 설정 완료!" -ForegroundColor Green
Write-Host ""
Write-Host "  설치된 배포판 : $installedDistroDesc" -ForegroundColor White
Write-Host "  인스턴스 이름 : $wslName" -ForegroundColor White
Write-Host "  설치 경로     : $wslInstallPath" -ForegroundColor White
Write-Host "===========================================================================" -ForegroundColor DarkCyan
Write-Host ""
}

# ==============================================================================
# 계정 사용 결정 → 배포판 안에서 install.sh (Bitwarden 로그인 → _devtools2 clone)
# ==============================================================================
# 계정은 WSL 안에 저장되므로 결정도 install.sh 가 합니다(저장된 계정이 저장소에 접근되면 묻지 않고 그대로,
# 접근이 안 되면 일회성/중단, 계정이 없으면 y/n). 정한 값(y/n)은 파일로 돌려받아 이어지는 설치 단계에 넘깁니다.
# DT2_KEEP_ACCOUNT=y|n 을 지정했으면 그대로 넘깁니다(묻지 않음).
$keepAccount = ''
if ($env:DT2_KEEP_ACCOUNT -match '^[YyNn]') {
    $keepAccount = $env:DT2_KEEP_ACCOUNT.Substring(0, 1).ToLower()
}
$keepOutFile = "/tmp/dt2-keep-account.$PID.$([Guid]::NewGuid().ToString('N').Substring(0, 8))"

Write-Step "[저장소] GitHub 계정 확인 및 DevTools2 저장소 받기 (WSL 안 install.sh)"
# --exec: 셸을 거치지 않고 인자를 그대로 넘깁니다. install.sh 는 clone(또는 최신으로 맞추기)까지만 하고 끝냅니다
# (그 뒤 리눅스 설치 단계는 아래 Windows 설치 스크립트가 임시 sudo 와 함께 순서대로 실행).
wsl.exe -d $wslName --exec env "DT2_KEEP_ACCOUNT=$keepAccount" "DT2_KEEP_ACCOUNT_OUT=$keepOutFile" "DT2_SETUP_REF=$($env:DT2_SETUP_REF)" DT2_SETUP_CLONE_ONLY=1 `
    bash -c "curl -fsSL '$SETUP_RAW/install.sh' | bash"
$syncExit = $LASTEXITCODE
# 1줄: 계정 사용(y/n), 2줄: 입력한 Bitwarden 항목 이름(없으면 빈 줄 — 이어지는 Step 3 의 기본 항목으로 넘김)
$keepLines = @((wsl.exe -d $wslName --exec cat $keepOutFile 2>$null | Out-String) -split "`r?`n")
$keepResult = ([string]$keepLines[0]).Trim()
$patItem = if ($keepLines.Count -gt 1) { ([string]$keepLines[1]).Trim() } else { '' }
if ($patItem) { $env:BW_DEFAULT_PAT_ITEM = $patItem }
wsl.exe -d $wslName --exec rm -f $keepOutFile 2>$null | Out-Null
if ($syncExit -eq 130) {
    Write-Info "설치를 중단했습니다."
    Pause-Script
    Exit-Devtools2Setup 1
}
if ($syncExit -ne 0) {
    Write-Fail "DevTools2 저장소를 준비하지 못했습니다 (종료 코드 $syncExit)."
    Pause-Script
    Exit-Devtools2Setup 1
}
if ($keepResult -match '^[yn]$') { $keepAccount = $keepResult }
if (-not $keepAccount) {
    # 결정을 돌려받지 못하면 계정을 저장하지 않는 쪽(일회성)으로 이어 갑니다
    Write-Warn "계정 사용 결정을 확인하지 못해 일회성 설치로 이어 갑니다 (설치 단계의 GitHub 로그인 저장을 건너뜀)."
    $keepAccount = 'n'
}
$env:DT2_KEEP_ACCOUNT = $keepAccount

# ==============================================================================
# clone 한 저장소의 Windows 설치 스크립트 실행
# ==============================================================================
$repoWin = Get-WslDevtools2Path $wslName
$masterPath = Join-Path $repoWin "scripts\windows\setup-devtools2-wsl.ps1"
if (-not (Test-Path -LiteralPath $masterPath)) {
    Write-Fail "Windows 설치 스크립트를 찾을 수 없습니다: $masterPath"
    Pause-Script
    Exit-Devtools2Setup 1
}
$env:DT2_REPO_WIN = $repoWin
Restore-ConsoleQuickEdit | Out-Null
Invoke-Dt2LocalScript -Path $masterPath
