# ==============================================================================
# ui.ps1 — DevTools2 Windows 공용 함수 (출력·질문·스피너·다운로드·빠른 편집·관리자 승격·WSL 경로)
# ==============================================================================
# 원본은 이 저장소(_devtools2-setup) 하나입니다.
#   - 시작 스크립트(install.ps1): 같은 커밋의 이 파일을 받아 씀
#   - _devtools2 의 scripts/windows/dev-env/_common.ps1: submodule(public/)의 이 파일을 불러 씀
# 사용법 (PS 5.1 은 NoBOM UTF-8 파일을 CP949 로 읽으므로, UTF-8 로 읽어 메모리에서 실행):
#   . ([scriptblock]::Create([System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false))))
# ⚠️ 공개 저장소입니다. 회사·고객 정보, 접속 주소, 비밀값을 넣지 마십시오.
# ==============================================================================

# ==============================================================================
# 전역 공통 점자 스피너 프레임 (Braille Spinner Frames)
# Linux _common.sh 의 _spinner_frames 와 100% 동일한 유니코드 점자 프레임을 공유합니다.
# ==============================================================================
$global:DT2_SPINNER_FRAMES = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "===========================================================================" -ForegroundColor DarkGray
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "===========================================================================" -ForegroundColor DarkGray
}

function Write-SubStep {
    param([string]$Message)
    Write-Host ""
    Write-Host "---------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[성공] $Message" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Message)
    Write-Host "[건너뜀] $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "[정보] $Message" -ForegroundColor White
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[경고] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[오류] $Message" -ForegroundColor Red
}

# 질문 제목 줄 (바로 뒤에 Write-Info 로 설명, Prompt-Confirm 으로 답을 받는 형태) — bash 쪽 print_question 과 같은 청록색
# ⚠️ 예전에는 0.setup-wsl.ps1 이 이 함수를 부르기만 하고 정의가 없어, .wslconfig 미러링·WSL 메모리 상한 질문에서
#    "'Write-Question' 용어가 ... 인식되지 않습니다" 로 멈췄습니다(테스트 2-3 이 정의 없는 함수 호출을 검사).
function Write-Question {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Pause-Script {
    # 기본 메시지: 이 함수를 부르는 호출부는 대부분 곧이어 exit 하는 상황이라
    # "계속하려면"이 아니라 "종료합니다"가 정확합니다(0.setup-wsl.ps1에서 실측 확인 —
    # 8곳 호출부 전부 Pause-Script 바로 다음 줄이 exit였음). 정말로 스크립트를 계속
    # 진행해야 하는 드문 호출부가 있다면 그때만 -Message 로 다른 문구를 넘기면 됩니다.
    param([string]$Message = "엔터(Enter) 키를 누르면 종료합니다")
    Write-Host ""
    Write-Host "👉 ${Message}: " -ForegroundColor Yellow -NoNewline
    [void][System.Console]::ReadLine()
}

# Yes/No 대화형 확인 프롬프트 공용 헬퍼 (bash _common.sh 의 prompt_confirm 대응)
# 사용법: if (Prompt-Confirm "👉 AutoHotKey를 설치하시겠습니까?" "Y") { ... }
function Prompt-Confirm {
    param(
        [string]$Message,
        [string]$Default = "N"
    )
    if ($env:DT2_NONINTERACTIVE -eq "1") {
        Write-Info "비대화형 모드: $Message → 기본값($Default) 자동 선택"
        return ($Default -eq "Y" -or $Default -eq "y")
    }
    Write-Host ""
    if ($Default -eq "Y" -or $Default -eq "y") {
        Write-Host "$Message [" -ForegroundColor Yellow -NoNewline
        Write-Host "Y" -ForegroundColor Green -NoNewline
        Write-Host "/n]: " -ForegroundColor Yellow -NoNewline
        $ans = Read-Dt2Input
        if ([string]::IsNullOrWhiteSpace($ans)) { return $true }
        return (Test-YesAnswer $ans)
    } else {
        Write-Host "$Message [y/" -ForegroundColor Yellow -NoNewline
        Write-Host "N" -ForegroundColor Green -NoNewline
        Write-Host "]: " -ForegroundColor Yellow -NoNewline
        $ans = Read-Dt2Input
        if ([string]::IsNullOrWhiteSpace($ans)) { return $false }
        return (Test-YesAnswer $ans)
    }
}

# y/n 답이 "예"인지 판정합니다(Prompt-Confirm 등 공용).
#   ● 한글 입력 상태에서 y 키를 누르면 'ㅛ'(U+315B)가 입력되어 '^[Yy]' 에 맞지 않고 "아니요"로 처리됐습니다(실측).
#     같은 키 자리인 'ㅛ' 도 "예"로 봅니다(n 키 자리의 'ㅜ' 는 원래대로 "아니요"). 파일 인코딩과 무관하도록 코드값으로 씁니다.
function Test-YesAnswer {
    param([string]$Answer)
    if ([string]::IsNullOrWhiteSpace($Answer)) { return $false }
    $a = $Answer.Trim()
    return ($a -match '^[Yy]' -or $a.StartsWith([string][char]0x315B))
}

# 입력값 정리 — bash ui-lib 의 dt2_clean_input 과 같은 규칙
#   제어 문자(Esc 키 신호 포함)·폭 없는 공백(U+200B~200D)·BOM(U+FEFF)을 지우고 앞뒤 공백(전각 포함)을 자릅니다.
#   가운데 공백과 한글 등 정상 문자는 그대로 둡니다. 비밀번호는 Prompt-Password 가 따로 받습니다.
function ConvertTo-Dt2CleanInput {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $t = $Text -replace '\x1B\[[0-9;?]*[@-~]', '' -replace '\x1BO[@-~]', '' -replace '[\x00-\x1F\x7F]', '' -replace '[\u200B-\u200D\uFEFF]', ''
    return $t.Trim()
}

# Read-Host + 입력값 정리 (자유 입력은 Read-Host 대신 이 함수를 씁니다)
function Read-Dt2Input {
    param([string]$Prompt = '')
    $raw = if ($Prompt) { Read-Host $Prompt } else { Read-Host }
    return (ConvertTo-Dt2CleanInput $raw)
}

# 기본값 없는 y/n 질문 — y 면 $true, n 이면 $false. Enter 만 누르면 다시 묻습니다(한글 입력 상태의 ㅛ·ㅜ 도 받음).
function Read-Dt2YesNo {
    param([string]$Prompt = '선택 [y/n]')
    while ($true) {
        $a = (Read-Dt2Input $Prompt).ToLower()
        if ($a -match '^(y|yes)$' -or $a -eq [string][char]0x315B) { return $true }
        if ($a -match '^(n|no)$' -or $a -eq [string][char]0x315C) { return $false }
        Write-Warn "y 또는 n 을 입력해 주세요."
    }
}

# 번호 선택 대화형 프롬프트 공용 헬퍼 (Prompt-Confirm 의 숫자형 버전)
# - 기본값 번호는 Green, 나머지 번호와 구분자는 Yellow (Prompt-Confirm [Y/n] 패턴과 동일)
# - 유효하지 않은 번호 입력 시 재입력 요구 (빈 입력은 Default 로 처리)
# - 반환값: 선택된 1-based 인덱스 (int)
#
# 사용법:
#   $idx = Prompt-Choice "👉 버전을 선택하세요" @("Ubuntu (최신 LTS)", "Ubuntu-24.04", "Ubuntu-22.04") 1
#   switch ($idx) {
#       1 { $distroId = "Ubuntu" }
#       2 { $distroId = "Ubuntu-24.04" }
#       3 { $distroId = "Ubuntu-22.04" }
#   }
function Prompt-Choice {
    param(
        [string]  $Message,
        [string[]]$Options,
        [int]     $Default = 1   # 1-based 기본 선택 번호
    )
    if ($env:DT2_NONINTERACTIVE -eq "1") {
        Write-Info "비대화형 모드: $Message → 기본값($Default) 자동 선택"
        return $Default
    }
    $result = 0
    do {
        Write-Host ""
        Write-Host "$Message [" -ForegroundColor Yellow -NoNewline
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $num = $i + 1
            if ($num -eq $Default) {
                Write-Host "$num" -ForegroundColor Green -NoNewline
            } else {
                Write-Host "$num" -ForegroundColor Yellow -NoNewline
            }
            if ($i -lt $Options.Count - 1) {
                Write-Host "/" -ForegroundColor Yellow -NoNewline
            }
        }
        Write-Host "]: " -ForegroundColor Yellow -NoNewline
        $ans = Read-Dt2Input
        $ans = $ans.Trim()
        if ($ans -eq "") { $ans = "$Default" }
        [int]::TryParse($ans, [ref]$result) | Out-Null
    } while ($result -lt 1 -or $result -gt $Options.Count)
    return $result
}

# ==============================================================================
# 한글 키보드(IME) 감지 및 비밀번호 입력 공용 헬퍼
# ==============================================================================
# Windows Win32 IME API (ImmGetDefaultIMEWnd / IMC_GETCONVERSIONMODE) 를 통해
# 현재 포그라운드 콘솔 창의 키보드가 한글 입력 모드인지 실시간으로 검사합니다.
if (-not ([System.Management.Automation.PSTypeName]'DevTools2.ImeHelper').Type) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace DevTools2 {
    public class ImeHelper {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("imm32.dll")]
        public static extern IntPtr ImmGetDefaultIMEWnd(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

        private const uint WM_IME_CONTROL = 0x0283;
        private const uint IMC_GETCONVERSIONMODE = 0x0001;
        private const int IME_CMODE_HANGUL = 0x0001;

        public static bool IsHangulMode() {
            try {
                IntPtr hwnd = GetForegroundWindow();
                if (hwnd == IntPtr.Zero) return false;
                IntPtr imeWnd = ImmGetDefaultIMEWnd(hwnd);
                if (imeWnd == IntPtr.Zero) return false;
                IntPtr mode = SendMessage(imeWnd, WM_IME_CONTROL, (IntPtr)IMC_GETCONVERSIONMODE, IntPtr.Zero);
                return ((mode.ToInt32() & IME_CMODE_HANGUL) != 0);
            } catch {
                return false;
            }
        }
    }
}
'@ -ErrorAction SilentlyContinue
    } catch {}
}

# 현재 활성 창의 키보드가 한글 입력 상태인지 여부 반환 ($true / $false)
function Test-IsHangulIme {
    try {
        if ([System.Management.Automation.PSTypeName]'DevTools2.ImeHelper'.Type) {
            return [DevTools2.ImeHelper]::IsHangulMode()
        }
    } catch {}
    return $false
}

# 비밀번호 입력 대화형 프롬프트 공용 헬퍼 (한글/다국어 IME 상태 감지 + 비영문 문자 입력 시 경고 및 재입력 유도)
# - 입력 전: 키보드가 한글/다국어 모드이면 주황색 경고 메시지 출력
# - 입력 후: 마스킹으로 인해 비영문(한글, 일어, 중문, 전각문자 등)이 들어간 경우 에러 경고 후 재입력
# - 반환값: SecureString
#
# 사용법:
#   $securePw = Prompt-Password "👉 비밀번호(password) 입력: "
function Prompt-Password {
    param(
        [string]$Message = "👉 비밀번호(password) 입력: "
    )
    while ($true) {
        # 1. 입력 직전 실시간 한글 IME 상태 확인 및 경고
        if (Test-IsHangulIme) {
            Write-Host ""
            Write-Host "  ⚠️  [주의] 현재 키보드가 '한글/다국어' 입력 모드입니다! [한/영] 키를 눌러 영문으로 전환해 주세요." -ForegroundColor Yellow
        }

        Write-Host $Message -ForegroundColor Yellow -NoNewline
        $securePw = Read-Host -AsSecureString

        # 평문으로 변환하여 유효성 및 비영문(Non-ASCII) 포함 여부 검증
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePw)
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

        if ([string]::IsNullOrEmpty($plain)) {
            Write-Warn "비밀번호가 입력되지 않았습니다. 다시 입력해 주세요."
            Write-Host ""
            continue
        }

        # 비영문/비ASCII 문자(한글, 일어, 중문, 전각 기호 등: ASCII 32~126 범위를 벗어나는 모든 유니코드) 검사
        if ($plain -match '[^\u0020-\u007E]') {
            Write-Host ""
            Write-Host "  ❌ [오류] 입력된 비밀번호에 '비영문(한글/다국어/전각)' 문자가 포함되어 있습니다." -ForegroundColor Red
            Write-Host "      키보드를 영문 입력 상태로 전환한 뒤 다시 입력해 주세요." -ForegroundColor Yellow
            Write-Host ""
            continue
        }

        return $securePw
    }
}

# 프로세스 종료 시까지 스피너를 표시해 대기 (타임아웃 없음 — 프로세스가 끝날 때까지 무조건 대기)
# 프로젝트 표준 유니코드 점자 회전 기호(Braille spinner) 사용
function Wait-ProcessWithSpinner {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Message
    )
    # Start-Process 가 실패하면(실행 파일 없음 등) $null 이 넘어오는데, 그대로 두면 $null.HasExited 가
    # 항상 비어 있어 아래 루프가 영원히 돕니다(실측) → 바로 돌아갑니다. 호출부는 ExitCode 로 실패를 판정합니다.
    if ($null -eq $Process) {
        Write-Host "`r  [실패] $Message - 프로세스를 시작하지 못했습니다.        " -ForegroundColor Yellow
        return
    }
    $spinner = $global:DT2_SPINNER_FRAMES
    $spinIdx = 0
    while (-not $Process.HasExited) {
        $char = $spinner[$spinIdx]
        Write-Host -NoNewline "`r  [$char] $Message...       " -ForegroundColor Cyan
        $spinIdx = ($spinIdx + 1) % $spinner.Count
        Start-Sleep -Milliseconds 150
    }
    Write-Host "`r  [완료] $Message 완료!        " -ForegroundColor Green
}

# 조건(scriptblock)이 참이 될 때까지 스피너를 표시해 대기 (타임아웃 지원, 초과 시 $false 반환)
# ⚠️ 호출부는 반드시 반환값을 확인해야 합니다 — 확인하지 않으면 타임아웃 후에도 마치
# 정상 완료된 것처럼 다음 단계로 조용히 넘어갈 수 있습니다(0.setup-wsl.ps1에서 실측 확인:
# PowerShell은 아직 안 끝난 프로세스의 .ExitCode를 읽어도 예외 없이 빈 값만 반환하므로
# "-eq 3010" 등의 비교가 조용히 false가 되어버림).
function Wait-WithSpinner {
    param(
        [string]$Message,
        [scriptblock]$Condition,
        [int]$MaxTimeoutSeconds = 300
    )
    $spinner = $global:DT2_SPINNER_FRAMES
    $spinIdx = 0
    $startTime = Get-Date
    while ($true) {
        $elapsed = (Get-Date) - $startTime
        if ($elapsed.TotalSeconds -gt $MaxTimeoutSeconds) {
            Write-Host "`r  [시간 초과] $Message (제한 시간 초과)        " -ForegroundColor Red
            return $false
        }
        $done = [bool](& $Condition)
        if ($done) {
            Write-Host "`r  [완료] $Message 완료!        " -ForegroundColor Green
            return $true
        }
        $char = $spinner[$spinIdx % $spinner.Count]
        Write-Host -NoNewline "`r  [$char] $Message...       " -ForegroundColor Cyan
        Start-Sleep -Milliseconds 150
        $spinIdx++
    }
}

# 시간이 걸리는 작업(scriptblock)을 같은 프로세스의 별도 실행 공간(runspace)에서 돌리고, 끝날 때까지 스피너 표시
# - 예: WSL 을 깨우는 wsl.exe 호출, \\wsl$ 경로 확인·복사처럼 화면에 아무것도 안 나오고 몇 초씩 멈춘 것처럼 보이는 작업
# - Start-Job 은 새 PowerShell 프로세스를 띄워 1~2초가 더 걸리므로 runspace 를 씁니다(PS 5.1 / PS 7 공통).
# - scriptblock 안에서는 이 파일의 함수(Write-Info 등)를 쓸 수 없으니 필요한 값은 -ArgumentList 로 넘기세요.
# - scriptblock 의 오류는 호출부로 전달되지 않으므로, 성공 여부는 반환값이나 결과물(파일 존재 등)로 확인하세요.
# 반환: scriptblock 출력 (시간 초과 시 작업을 멈추고 $null)
function Invoke-WithSpinner {
    param(
        [string]$Message,
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [int]$MaxTimeoutSeconds = 600
    )
    $ps = [powershell]::Create()
    [void]$ps.AddScript($ScriptBlock.ToString())
    foreach ($arg in $ArgumentList) { [void]$ps.AddArgument($arg) }
    $handle = $ps.BeginInvoke()
    $cond = { $handle.IsCompleted }.GetNewClosure()
    $null = Wait-WithSpinner -Message $Message -Condition $cond -MaxTimeoutSeconds $MaxTimeoutSeconds
    $result = $null
    try {
        if ($handle.IsCompleted) {
            $result = $ps.EndInvoke($handle)
        } else {
            $ps.Stop()
        }
    } catch {
        Write-Warn "$Message 중 오류: $($_.Exception.Message)"
    }
    $ps.Dispose()
    return $result
}

# ==============================================================================
# WSL 디스트로 상태 확인 / 안전 종료 대기 공용 헬퍼
# ==============================================================================
# wsl -l -v 출력에서 null 바이트를 제거한 뒤 파싱하는 방식으로 구현한다.
# (wsl.exe는 UTF-16LE로 출력하므로 PowerShell이 null 바이트를 포함하는 경우가 있음)

# 지정한 WSL 디스트로가 현재 Running 상태인지 여부를 반환한다.
# 사용법: $isRunning = Test-WslDistroRunning "devtools2"
function Test-WslDistroRunning {
    param([string]$Distro)
    $raw   = wsl.exe -l -v 2>$null
    $lines = $raw -split "`r?`n" | ForEach-Object { $_ -replace "`0", "" }
    # 배포판 이름은 단어 단위로 정확히 비교합니다("devtools2" 가 "devtools2-old" 에 매치되지 않도록).
    $namePattern = '(^|\s)\*?\s*' + [regex]::Escape($Distro) + '\s'
    return [bool]($lines | Where-Object { $_ -match $namePattern -and $_ -match 'Running' })
}

# wsl --shutdown 을 실행한 뒤 지정한 디스트로가 완전히 Stopped 될 때까지 스피너로 대기한다.
# - 타임아웃(기본 60초) 초과 시 오류 메시지 출력 후 $false 반환
# - 성공 시 $true 반환
#
# 사용법:
#   if (-not (Invoke-WslShutdown -Distro "devtools2")) {
#       Write-Fail "WSL 종료 실패"
#       Pause-Script; exit 1
#   }
function Invoke-WslShutdown {
    param(
        [string]$Distro          = "devtools2",
        [int]   $TimeoutSeconds  = 60,
        [string]$ShutdownMessage = "WSL 가상 머신 완전 종료 대기 중"
    )

    Write-Info "wsl --shutdown 실행 중..."
    wsl --shutdown 2>$null
    # 종료 명령 자체가 실패하면(WSL 서비스 오류 등) 아래 대기는 시간 초과로만 끝나 원인을 알 수 없으므로 종료 코드를 함께 알립니다.
    $shutdownExit = $LASTEXITCODE
    if ($shutdownExit -ne 0) {
        Write-Warn "wsl --shutdown 이 실패했습니다(종료 코드: $shutdownExit). 배포판이 멈췄는지 계속 확인합니다."
    }

    # 디스트로가 이미 Stopped 상태이면 즉시 성공 반환
    if (-not (Test-WslDistroRunning -Distro $Distro)) {
        Write-Host "  [완료] $Distro 이미 종료됨 — 즉시 계속합니다." -ForegroundColor Green
        return $true
    }

    $spinner   = $global:DT2_SPINNER_FRAMES
    $spinIdx   = 0
    $startTime = Get-Date

    while ($true) {
        $elapsed = (Get-Date) - $startTime

        # 타임아웃 초과 시 실패
        if ($elapsed.TotalSeconds -gt $TimeoutSeconds) {
            Write-Host ""
            Write-Fail "WSL 종료 대기 시간 초과 (${TimeoutSeconds}초 초과)"
            Write-Info "  → PC를 재부팅한 후 다시 실행해 주세요."
            return $false
        }

        # 디스트로가 멈췄으면 성공
        if (-not (Test-WslDistroRunning -Distro $Distro)) {
            $sec = [int]$elapsed.TotalSeconds
            Write-Host "`r  [완료] $ShutdownMessage 완료! (${sec}초 소요)   " -ForegroundColor Green
            return $true
        }

        $remaining = [int]($TimeoutSeconds - $elapsed.TotalSeconds)
        $char      = $spinner[$spinIdx % $spinner.Count]
        Write-Host -NoNewline "`r  [$char] $ShutdownMessage... (제한 ${TimeoutSeconds}초 / 남은 ${remaining}초)   " -ForegroundColor Cyan
        Start-Sleep -Milliseconds 500
        $spinIdx++
    }
}

# ==============================================================================
# 다운로드 게이지 프로그레스 바 공용 헬퍼 (스트림 기반 실시간 프로그레스 바)
# ==============================================================================
# Bash 환경(_common.sh 의 download_with_progress)과 100% 동일한 게이지 바로 렌더링합니다.
# 사용법:
#   # 단일 URL:
#   $ok = Download-WithProgress -Url "https://example.com/file.zip" -DestinationPath "$env:TEMP\file.zip" -Description "AutoHotkey v2"
#   # 다중 URL 폴백:
#   $ok = Download-WithProgress -Urls @("http://mirror1/f.zip", "http://mirror2/f.zip") -DestinationPath "$env:TEMP\file.zip"
function Download-WithProgress {
    param(
        [string]  $Url,
        [string[]]$Urls,
        [string]  $DestinationPath,
        [string]  $Description = "파일"
    )

    $targetUrls = @()
    if ($Urls -and $Urls.Count -gt 0) {
        $targetUrls = $Urls
    } elseif ($Url) {
        $targetUrls = @($Url)
    }

    if ($targetUrls.Count -eq 0) {
        return $false
    }

    $destDir = Split-Path $DestinationPath -Parent
    if (-not [string]::IsNullOrEmpty($destDir) -and -not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $finalSuccess = $false

    for ($i = 0; $i -lt $targetUrls.Count; $i++) {
        $currentUrl = $targetUrls[$i]
        $domain = $currentUrl
        try {
            $domain = ([System.Uri]$currentUrl).Host
        } catch {}

        if ($targetUrls.Count -gt 1) {
            Write-Host "   📥 $Description 다운로드 시도 [$($i + 1)/$($targetUrls.Count)] ($domain)..." -ForegroundColor Cyan
        } else {
            Write-Host "   📥 $Description 다운로드 중..." -ForegroundColor Cyan
        }

        Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue

        $downloadSuccess = $false
        $getResp = $null
        $inStream = $null
        $outStream = $null

        try {
            $getReq = [System.Net.HttpWebRequest]::Create($currentUrl)
            $getReq.Timeout = 10000
            $getReq.ReadWriteTimeout = 60000
            $getReq.AllowAutoRedirect = $true
            $getReq.Headers.Add('Cache-Control', 'no-cache, no-store, must-revalidate')
            $getReq.Headers.Add('Pragma', 'no-cache')

            $getResp = $getReq.GetResponse()
            $totalBytes = $getResp.ContentLength
            $inStream = $getResp.GetResponseStream()

            $outStream = [System.IO.File]::Create($DestinationPath)
            $buffer = New-Object byte[] 65536
            $downloadedBytes = 0
            $barLen = 50
            $lastUpdate = [DateTime]::MinValue

            while (($bytesRead = $inStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $outStream.Write($buffer, 0, $bytesRead)
                $downloadedBytes += $bytesRead

                $now = [DateTime]::UtcNow
                if (($now - $lastUpdate).TotalMilliseconds -ge 80 -or ($totalBytes -gt 0 -and $downloadedBytes -eq $totalBytes)) {
                    $lastUpdate = $now
                    if ($totalBytes -gt 0) {
                        $pct = ($downloadedBytes / $totalBytes) * 100
                        $filled = [int]($barLen * ($pct / 100))
                        $pctStr = (" {0:N1}% " -f $pct)
                        $leftLen = [int](($barLen - $pctStr.Length) / 2)

                        $barChars = New-Object char[] $barLen
                        for ($k = 0; $k -lt $barLen; $k++) {
                            if ($k -ge $leftLen -and $k -lt ($leftLen + $pctStr.Length)) {
                                $barChars[$k] = $pctStr[$k - $leftLen]
                            } elseif ($k -lt $filled) {
                                $barChars[$k] = '='
                            } else {
                                $barChars[$k] = ' '
                            }
                        }
                        $bar = -join $barChars
                        Write-Host -NoNewline "`r   [$bar]"
                    } else {
                        $mb = [math]::Round($downloadedBytes / 1MB, 1)
                        Write-Host -NoNewline "`r   [ 다운로드 중... ${mb} MB ]"
                    }
                }
            }

            # 다운로드 완료 후 게이지 바 라인 지우기
            Write-Host -NoNewline ("`r   " + (" " * ($barLen + 4)) + "`r")
            # 연결이 중간에 끊겨도 Read() 가 0 을 돌려주면 루프가 정상 종료되므로,
            # 서버가 알려준 크기(Content-Length)보다 적게 받았으면 실패로 처리합니다.
            if ($totalBytes -gt 0 -and $downloadedBytes -ne $totalBytes) {
                throw "다운로드가 중간에 끊겼습니다 ($downloadedBytes / $totalBytes bytes)"
            }
            $downloadSuccess = $true
        } catch {
            $downloadSuccess = $false
        } finally {
            if ($outStream) { try { $outStream.Close() } catch {} }
            if ($inStream) { try { $inStream.Close() } catch {} }
            if ($getResp) { try { $getResp.Close() } catch {} }
        }

        if ($downloadSuccess -and (Test-Path $DestinationPath) -and (Get-Item $DestinationPath).Length -gt 0) {
            $finalSuccess = $true
            break
        } else {
            if ($targetUrls.Count -gt 1) {
                Write-Warn "   → 미러 [$($i + 1)] ($domain) 다운로드 실패. 다음 미러로 전환합니다..."
            }
            Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
        }
    }

    return $finalSuccess
}

# ==============================================================================
# 콘솔 빠른 편집(QuickEdit) 모드 세션 한정 안전 제어 헬퍼
# ==============================================================================
# Windows 터미널에서 마우스 클릭 시 콘솔 출력이 일시 중단(프리징)되는 현상을 방지합니다.
# - Windows 전체/레지스트리 설정을 건드리지 않고 '현재 PowerShell 세션 핸들'에만 메모리 상에서 적용
# - 스크립트 정상 종료, 예외 발생, Ctrl+C 중단(Console.CancelKeyPress) 시 원래 모드로 100% 자동 복원
# ==============================================================================
if (-not ([System.Management.Automation.PSTypeName]'DevTools2.ConsoleHelper').Type) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace DevTools2 {
    public static class ConsoleHelper {
        private const int STD_INPUT_HANDLE = -10;
        private const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
        private const uint ENABLE_EXTENDED_FLAGS = 0x0080;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

        private static uint originalMode = 0;
        private static bool isModified = false;
        private static ConsoleCancelEventHandler cancelHandler = null;

        public static bool DisableQuickEdit() {
            try {
                IntPtr hStdin = GetStdHandle(STD_INPUT_HANDLE);
                if (hStdin == IntPtr.Zero || hStdin == (IntPtr)(-1)) return false;

                if (!GetConsoleMode(hStdin, out originalMode)) return false;

                // 이미 수정된 상태라면 중복 등록 방지
                if (!isModified) {
                    // Ctrl+C 이벤트 발생 시 안전 복원 핸들러 등록
                    cancelHandler = new ConsoleCancelEventHandler((sender, args) => {
                        RestoreQuickEdit();
                    });
                    Console.CancelKeyPress += cancelHandler;
                }

                uint newMode = (originalMode & ~ENABLE_QUICK_EDIT_MODE) | ENABLE_EXTENDED_FLAGS;
                bool result = SetConsoleMode(hStdin, newMode);
                if (result) isModified = true;
                return result;
            } catch {
                return false;
            }
        }

        public static bool RestoreQuickEdit() {
            try {
                if (!isModified) return true;

                IntPtr hStdin = GetStdHandle(STD_INPUT_HANDLE);
                if (hStdin == IntPtr.Zero || hStdin == (IntPtr)(-1)) return false;

                bool result = SetConsoleMode(hStdin, originalMode | ENABLE_EXTENDED_FLAGS);
                if (result) {
                    isModified = false;
                    if (cancelHandler != null) {
                        try { Console.CancelKeyPress -= cancelHandler; } catch {}
                        cancelHandler = null;
                    }
                }
                return result;
            } catch {
                return false;
            }
        }
    }
}
'@ -ErrorAction SilentlyContinue
    } catch {}
}

function Disable-ConsoleQuickEdit {
    try {
        if ([System.Management.Automation.PSTypeName]'DevTools2.ConsoleHelper'.Type) {
            return [DevTools2.ConsoleHelper]::DisableQuickEdit()
        }
    } catch {}
    return $false
}

function Restore-ConsoleQuickEdit {
    try {
        if ([System.Management.Automation.PSTypeName]'DevTools2.ConsoleHelper'.Type) {
            return [DevTools2.ConsoleHelper]::RestoreQuickEdit()
        }
    } catch {}
    return $false
}

# ==============================================================================
# 승격 계정 확인 헬퍼 (UAC 에 다른 관리자 계정을 입력한 경우)
# ==============================================================================
# 표준 사용자 계정에서 UAC 창에 다른 관리자 계정의 자격 증명을 넣으면, 승격된 창은 그 관리자 계정으로 돌아
# %USERPROFILE%·HKCU·WSL 배포판 등록·작업 스케줄러 UserId 가 모두 관리자 계정 기준이 됩니다.
# 승격 창은 같은 로그온 세션에서 뜨므로, 같은 세션의 탐색기(explorer.exe) 소유자 = 실제로 쓰는 사용자로 보고 비교합니다.
#   ● 인자로 원래 사용자를 넘기지 않아도 되어 irm | iex·-File·마스터 경유 실행 모두 같은 방식으로 확인합니다.
#   ● 판단할 수 없으면(탐색기 없음·여러 소유자·조회 실패) 막지 않습니다.
#   ● 한 프로세스에서 한 번만 확인합니다(마스터가 확인했으면 하위 스크립트는 다시 묻지 않음).
# 반환: 계속 진행하면 $true, 중단해야 하면 $false
function Confirm-ElevatedUserMatchesDesktop {
    if ($env:DT2_ELEVATED_USER_OK -eq '1') { return $true }
    $owners = @()
    $me = ""
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $sessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
        $owners = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
            Where-Object { $_.SessionId -eq $sessionId } |
            ForEach-Object {
                $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue
                if ($o -and $o.ReturnValue -eq 0 -and -not [string]::IsNullOrWhiteSpace($o.User)) { "$($o.Domain)\$($o.User)" }
            } | Select-Object -Unique)
    } catch {
        return $true
    }
    if ($owners.Count -ne 1 -or [string]::IsNullOrWhiteSpace($me) -or ($owners[0] -ieq $me)) {
        $env:DT2_ELEVATED_USER_OK = '1'
        return $true
    }
    Write-Warn "관리자 권한 창이 지금 로그인한 사용자($($owners[0]))가 아니라 다른 계정($me)으로 실행되었습니다."
    Write-Warn "  UAC 창에 다른 관리자 계정을 입력한 경우로 보입니다. 이대로 진행하면 사용자 폴더·HKCU 설정·WSL 배포판·"
    Write-Warn "  로그온 작업이 모두 '$me' 계정에 만들어져, 로그인한 사용자는 쓸 수 없습니다."
    Write-Warn "  DevTools2 를 쓸 사용자 계정에 관리자 권한을 준 뒤 그 계정으로 다시 실행하는 것을 권장합니다."
    if (Prompt-Confirm "그래도 '$me' 계정 기준으로 계속 진행하시겠습니까?" "N") {
        $env:DT2_ELEVATED_USER_OK = '1'
        return $true
    }
    return $false
}

# ==============================================================================
# 관리자 권한 승격 재실행 헬퍼 (비관리자 창에서 단독 실행했을 때)
# ==============================================================================
# 마스터 스크립트를 거치면 이미 관리자라 쓰이지 않고, 하위 스크립트를 단독 실행했을 때만 쓰입니다.
#   ● _devtools2 는 비공개 저장소라 원격(raw)에서 다시 받을 수 없으므로, 같은 저장소의 로컬 파일을 다시 실행합니다.
#     파일은 UTF-8 로 읽어 메모리에서 실행합니다(PS 5.1 이 NoBOM 한글 파일을 CP949 로 읽어 파싱이 깨지는 문제 회피).
#   ● 공개 저장소의 install.ps1 처럼 원격 주소로 다시 실행할 때는 -OnlineUrl 을 줍니다.
#   ● 끝나거나 오류로 멈춘 뒤에도 결과를 읽을 수 있도록 마지막에 엔터를 기다립니다(예전에는 끝나자마자 창이 닫혔습니다).
#     스크립트 안의 exit 로 끝나도 finally 가 실행됩니다(PS 5.1 실측).
#   ● 명령은 작은따옴표만 쓰는 한 줄로 만들어 -Command 로 넘깁니다(큰따옴표가 없어 명령줄 따옴표 처리와 겹치지 않음).
#     Base64 로 인코딩한 명령 전달 방식은 백신 오탐(Trojan:Win32/Commando.A!ml)을 일으켜 쓰지 않습니다(테스트 5-11).
# 사용법:
#   Start-ElevatedRelaunch -RepoScriptPath 'scripts/windows/dev-env/tool.setup-zed.ps1' -Parameters ([ordered]@{ WslDistro = $WslDistro })
#   RepoScriptPath 는 _devtools2 저장소 안의 경로(Get-Dt2RepoRoot 기준). -ScriptFilePath 로 파일을 직접 줄 수도 있습니다.
#   Parameters 값: 빈 문자열·$false 는 생략, $true(스위치)는 "-이름" 만, 그 밖은 "-이름 '값'".

# _devtools2 저장소의 Windows 경로(\\wsl.localhost\<배포판>\var\opt\_devtools2 등)
#   DT2_REPO_WIN(이번 설치가 정한 값) → DEVTOOLS2(사용자 환경 변수) → 기본 배포판 devtools2 순서로 찾습니다.
function Get-Dt2RepoRoot {
    foreach ($cand in @($env:DT2_REPO_WIN, $env:DEVTOOLS2)) {
        if (-not [string]::IsNullOrWhiteSpace($cand) -and (Test-Path -LiteralPath (Join-Path $cand "scripts\windows"))) {
            return $cand
        }
    }
    return Get-WslDevtools2Path "devtools2"
}

# 파일을 UTF-8 로 읽어 스크립트블록으로 실행합니다 (PS 5.1·7 공통, 인자는 해시테이블로 — 배열 스플래팅은 이름이 바인딩되지 않음)
function Invoke-Dt2LocalScript {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Arguments = @{}
    )
    $content = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
    & ([scriptblock]::Create($content)) @Arguments
}

function Get-ElevatedRelaunchCommand {
    param(
        [string]$RepoScriptPath = '',
        [string]$ScriptFilePath = '',
        [System.Collections.IDictionary]$Parameters = $null,
        [string]$OnlineUrl = ''
    )
    $q = { param($s) "'" + ([string]$s -replace "'", "''") + "'" }
    $argText = ''
    if ($Parameters) {
        foreach ($k in $Parameters.Keys) {
            $v = $Parameters[$k]
            if ($v -is [bool] -or $v -is [System.Management.Automation.SwitchParameter]) {
                if ([bool]$v) { $argText += " -$k" }
            } elseif (-not [string]::IsNullOrEmpty([string]$v)) {
                $argText += " -$k " + (& $q $v)
            }
        }
    }
    if (-not [string]::IsNullOrEmpty($OnlineUrl)) {
        $invoke = "& ([scriptblock]::Create((Invoke-RestMethod -Uri $(& $q $OnlineUrl) -Headers @{ 'Cache-Control' = 'no-cache, no-store, must-revalidate'; 'Pragma' = 'no-cache' } -ErrorAction Stop)))$argText"
        $prefix = ''
    } else {
        if ([string]::IsNullOrEmpty($ScriptFilePath)) {
            $ScriptFilePath = Join-Path (Get-Dt2RepoRoot) ($RepoScriptPath -replace '/', '\')
        }
        $invoke = "& ([scriptblock]::Create([System.IO.File]::ReadAllText($(& $q $ScriptFilePath), [System.Text.UTF8Encoding]::new(`$false))))$argText"
        # 승격 창이 부모의 환경 변수를 물려받는다고 기대하지 않고 저장소 경로를 명령 안에서 다시 지정합니다.
        # 저장소 경로 = 파일 경로에서 \scripts\windows\ 앞부분 (dev-env·autohotkey·하위 폴더 모두 같은 규칙)
        $repoRoot = if ($ScriptFilePath -match '^(.*?)\\scripts\\windows\\') { $Matches[1] } else { Get-Dt2RepoRoot }
        $prefix = "`$env:DT2_REPO_WIN = $(& $q $repoRoot); "
    }
    return "$prefix" + "try { $invoke } finally { Write-Host ''; [void](Read-Host '엔터(Enter) 키를 누르면 이 관리자 창을 닫습니다') }"
}

function Start-ElevatedRelaunch {
    param(
        [string]$RepoScriptPath = '',
        [string]$ScriptFilePath = '',
        [System.Collections.IDictionary]$Parameters = $null,
        [string]$OnlineUrl = ''
    )
    $cmd = Get-ElevatedRelaunchCommand -RepoScriptPath $RepoScriptPath -ScriptFilePath $ScriptFilePath -Parameters $Parameters -OnlineUrl $OnlineUrl
    try {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`"" -Verb RunAs -ErrorAction Stop
    } catch {
        Write-Warn "관리자 권한으로 다시 실행하지 못했습니다(UAC 취소 등): $($_.Exception.Message)"
    }
}

# ==============================================================================
# WSL2 UNC 공유 경로 탐색 헬퍼 (\\wsl.localhost 및 \\wsl$ 호환)
# ==============================================================================
# Windows 11/10 관리자 권한 세션이나 환경에 따라 \\wsl.localhost 가 인식되지 않고
# \\wsl$ 만 인식되는 경우가 빈번합니다. 실제 접근 가능한 UNC 루트를 찾아 반환합니다.
function Get-WslUncRoot {
    param([string]$Distro)
    if ([string]::IsNullOrEmpty($Distro)) { return "" }
    $candidates = @("\\wsl$\$Distro", "\\wsl.localhost\$Distro")
    foreach ($cand in $candidates) {
        if (Test-Path $cand) {
            return $cand
        }
    }
    # 접근 확인이 안 되더라도 관리자 권한 호환성이 더 높은 \\wsl$ 를 기본값으로 반환
    return "\\wsl$\$Distro"
}

# WSL 내부의 _devtools2 디렉터리 경로 반환 (\\wsl$ 및 \\wsl.localhost 자동 탐지)
function Get-WslDevtools2Path {
    param([string]$Distro)
    if ($env:DEVTOOLS2 -and (Test-Path $env:DEVTOOLS2)) {
        return $env:DEVTOOLS2
    }
    if (-not [string]::IsNullOrEmpty($Distro)) {
        $candidates = @(
            "\\wsl$\$Distro\var\opt\_devtools2",
            "\\wsl.localhost\$Distro\var\opt\_devtools2"
        )
        foreach ($cand in $candidates) {
            if (Test-Path $cand) {
                return $cand
            }
        }
    }
    return "\\wsl$\$Distro\var\opt\_devtools2"
}

# ==============================================================================
# WSL2 Interop (binfmt_misc) 등록 헬퍼
# ==============================================================================
# Windows .exe 바이너리 실행 시 Exec format error 방지
function Register-WslInterop {
    param([string]$Distro)
    if ([string]::IsNullOrEmpty($Distro)) { return }
    wsl.exe -d $Distro -u root -- bash -c "mkdir -p /etc/binfmt.d /usr/lib/binfmt.d && echo ':WSLInterop:M::MZ::/init:PF' > /etc/binfmt.d/WSLInterop.conf && echo ':WSLInterop:M::MZ::/init:PF' > /usr/lib/binfmt.d/WSLInterop.conf && ([ -f /proc/sys/fs/binfmt_misc/register ] && echo ':WSLInterop:M::MZ::/init:PF' > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true)" 2>$null
}
