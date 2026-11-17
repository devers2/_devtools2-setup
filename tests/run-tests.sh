#!/usr/bin/env bash
# ==============================================================================
# _devtools2-setup 시험 — sudo·Bitwarden 계정 없이 돌립니다.
#   bash tests/run-tests.sh                  기본 시험
#   DT2_TEST_NETWORK=1 bash tests/run-tests.sh   + Bitwarden CLI 실제 다운로드·SHA-256 확인
# ==============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '        %s\n' "${2//$'\n'/$'\n'        }"; }
check() { if eval "$2"; then ok "$1"; else no "$1" "${3:-}"; fi; }

echo "▶ 1. 문법"
for f in install.sh lib/ui-lib lib/bw-lib; do
    check "bash -n $f" "bash -n '$ROOT/$f'"
done
if command -v shellcheck >/dev/null 2>&1; then
    out=$(cd "$ROOT" && shellcheck -x -S warning install.sh lib/ui-lib 2>&1)
    check "shellcheck (install.sh·ui-lib)" '[ -z "$out" ]' "$out"
else
    echo "  SKIP  shellcheck 없음"
fi

# PowerShell 문법·정의 없는 함수 호출 검사 (pwsh 가 있을 때 — GitHub Actions ubuntu 에는 기본 포함, WSL 은 pwsh.exe)
PS_BIN="" PS_ROOT="$ROOT"
if command -v pwsh >/dev/null 2>&1; then
    PS_BIN=pwsh
elif command -v pwsh.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
    PS_BIN=pwsh.exe PS_ROOT="$(wslpath -w "$ROOT")"
fi
if [ -n "$PS_BIN" ]; then
    out=$(timeout 120 "$PS_BIN" -NoProfile -Command "
[Console]::OutputEncoding = [Text.UTF8Encoding]::new(\$false); \$root = '$PS_ROOT'; \$defs = @{}; \$bad = @()
foreach (\$f in 'install.ps1', 'lib/ui.ps1') {
    \$t = [IO.File]::ReadAllText((Join-Path \$root \$f), [Text.UTF8Encoding]::new(\$false)); \$e = \$null
    \$a = [System.Management.Automation.Language.Parser]::ParseInput(\$t, [ref]\$null, [ref]\$e)
    if (\$e) { \$bad += \$e | ForEach-Object { \"\$f L\$(\$_.Extent.StartLineNumber): \$(\$_.Message)\" } }
    \$a.FindAll({ \$args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, \$true) | ForEach-Object { \$defs[\$_.Name] = 1 }
}
\$t = [IO.File]::ReadAllText((Join-Path \$root 'install.ps1'), [Text.UTF8Encoding]::new(\$false))
\$a = [System.Management.Automation.Language.Parser]::ParseInput(\$t, [ref]\$null, [ref]\$null)
\$a.FindAll({ \$args[0] -is [System.Management.Automation.Language.CommandAst] }, \$true) | ForEach-Object { \$_.GetCommandName() } |
    Where-Object { \$_ -and -not \$defs[\$_] -and -not (Get-Command \$_ -ErrorAction SilentlyContinue) } | Sort-Object -Unique |
    ForEach-Object { \$bad += \"정의 없는 함수: \$_\" }
\$bad" 2>&1 | tr -d '\r')
    check "install.ps1·ui.ps1 문법과 함수 정의 ($PS_BIN)" '[ -z "$out" ]' "$out"
    # 입력값 정리(ConvertTo-Dt2CleanInput)가 bash 의 dt2_clean_input 과 같은 결과를 내는지
    out=$(timeout 60 "$PS_BIN" -NoProfile -Command "
[Console]::OutputEncoding = [Text.UTF8Encoding]::new(\$false)
. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path '$PS_ROOT' 'lib/ui.ps1'), [Text.UTF8Encoding]::new(\$false))))
@(([string][char]0x3000 + ' a b  '), ([string][char]27 + '[23;8~abc'), ([string][char]0x200B + 'x' + [string][char]0xFEFF + 'y')) | ForEach-Object { '[' + (ConvertTo-Dt2CleanInput \$_) + ']' }
" 2>&1 | tr -d '\r' | tr '\n' ' ')
    check "Windows 입력값 정리: 앞뒤·전각 공백, Esc 신호, 폭 없는 공백·BOM ($PS_BIN)" '[ "$out" = "[a b] [abc] [xy] " ]' "$out"
else
    echo "  SKIP  pwsh 없음 (PowerShell 검사)"
fi

# 함수만 불러오는 셸: HOME 을 임시 폴더로 바꿔 이 PC 의 설정을 건드리지 않음
run() {
    HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" GIT_CONFIG_NOSYSTEM=1 DT2_NONINTERACTIVE=1 bash -c "
set -uo pipefail
source '$ROOT/install.sh'
source '$ROOT/lib/ui-lib'
source '$ROOT/lib/bw-lib'
_sudo() { \"\$@\"; }; dt2_sudo_auth() { :; }
$1" 2>&1
}
mkdir -p "$T/home"

echo "▶ 2. 계정 사용 질문"
check "DT2_KEEP_ACCOUNT=y → y" '[ "$(run "DT2_KEEP_ACCOUNT=y; _ask_keep_account; echo \$KEEP")" = y ]'
check "DT2_KEEP_ACCOUNT=N → n" '[ "$(run "DT2_KEEP_ACCOUNT=N; _ask_keep_account; echo \$KEEP")" = n ]'
out=$(run "DT2_KEEP_ACCOUNT=x; _ask_keep_account; echo KEEP=\$KEEP")
check "잘못된 값 → 거부" 'grep -q "y 또는 n" <<<"$out" && ! grep -q "KEEP=" <<<"$out"' "$out"
out=$(run "unset DT2_KEEP_ACCOUNT; _ask_keep_account; echo KEEP=\$KEEP")
check "터미널 없음·값 없음 → 거부 (기본값 없음)" 'grep -q "DT2_KEEP_ACCOUNT=y 또는 n" <<<"$out" && ! grep -q "KEEP=" <<<"$out"' "$out"

echo "▶ 2-0. 저장된 계정 확인 (_detect_account — 접근되면 묻지 않음, 남의 계정·PAT 만료·네트워크 구분)"
git config --file "$T/home/.gitconfig" credential.helper store
printf 'https://tester:fake-pat-000@github.com\n' >"$T/home/.git-credentials"
cred_md5=$(md5sum <"$T/home/.git-credentials")
NOACC='_check_repo_access() { return 1; }'
OTHER="$NOACC; bw_github_token_check() { echo someone; return 0; }"
EXPIRED="$NOACC; bw_github_token_check() { return 1; }"
OFFLINE="$NOACC; bw_github_token_check() { return 2; }"
out=$(run "_check_repo_access() { return 0; }; unset DT2_KEEP_ACCOUNT; _ask_keep_account; echo KEEP=\$KEEP STATE=\$ACC_STATE")
check "접근되는 계정 → 묻지 않고 그대로(y), 계정 이름과 진행 안내 표시" 'grep -q "KEEP=y STATE=ok" <<<"$out" && grep -q "(tester)" <<<"$out" && grep -q "그대로 진행" <<<"$out" && ! grep -q "선택" <<<"$out"' "$out"
out=$(run "$OTHER; _detect_account; echo STATE=\$ACC_STATE LOGIN=\$ACC_LOGIN")
check "PAT 유효·권한 없음 → other(다른 사람의 계정)" 'grep -q "STATE=other LOGIN=someone" <<<"$out"' "$out"
out=$(run "$EXPIRED; _detect_account; echo STATE=\$ACC_STATE")
check "401 → expired(PAT 만료·폐기)" 'grep -q "STATE=expired" <<<"$out"' "$out"
out=$(run "$OFFLINE; unset DT2_KEEP_ACCOUNT; _ask_keep_account; echo KEEP=\$KEEP")
check "확인 불가(네트워크) → 진행하지 않고 네트워크 안내" 'grep -q "네트워크" <<<"$out" && ! grep -q "KEEP=" <<<"$out"' "$out"
out=$(run "$OTHER; unset DT2_KEEP_ACCOUNT; _ask_keep_account; echo KEEP=\$KEEP")
check "다른 사람의 계정·터미널 없음 → 진행하지 않음" '! grep -q "KEEP=" <<<"$out"' "$out"
out=$(run "$OTHER; DT2_KEEP_ACCOUNT=y; _ask_keep_account; echo KEEP=\$KEEP")
check "다른 사람의 계정 + DT2_KEEP_ACCOUNT=y → 거부하고 일회성 안내" 'grep -q "DT2_KEEP_ACCOUNT=n" <<<"$out" && ! grep -q "KEEP=" <<<"$out"' "$out"
out=$(run "$EXPIRED; DT2_KEEP_ACCOUNT=y; _ask_keep_account; echo KEEP=\$KEEP RENEW=\$RENEW")
check "PAT 만료 + DT2_KEEP_ACCOUNT=y → 갱신(RENEW=1)" 'grep -q "KEEP=y RENEW=1" <<<"$out"' "$out"
out=$(run "$EXPIRED; DT2_KEEP_ACCOUNT=n; _ask_keep_account; echo KEEP=\$KEEP RENEW=\$RENEW")
check "PAT 만료 + DT2_KEEP_ACCOUNT=n → 일회성" 'grep -q "KEEP=n RENEW=0" <<<"$out"' "$out"
if command -v script >/dev/null 2>&1; then
    # 실제 터미널에서 질문 답하기 (script 가 가상 터미널을 만듦)
    ask_tty() {
        printf '%s' "$2" | HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 timeout 20 script -qec "bash -c 'source \"$ROOT/install.sh\"; source \"$ROOT/lib/ui-lib\"; source \"$ROOT/lib/bw-lib\"; $1; unset DT2_KEEP_ACCOUNT; _ask_keep_account; echo KEEP=\$KEEP RENEW=\$RENEW'; echo rc=\$?" /dev/null 2>&1 | tr -d '\r'
    }
    out=$(ask_tty "$EXPIRED" $'1\n')
    check "PAT 만료 질문: 1 → 갱신" 'grep -q "만료되었거나 폐기" <<<"$out" && grep -q "KEEP=y RENEW=1" <<<"$out"' "$out"
    out=$(ask_tty "$EXPIRED" $'9\n2\n')
    check "PAT 만료 질문: 잘못된 값은 다시 묻고 2 → 일회성" 'grep -q "1, 2, 3 중에서" <<<"$out" && grep -q "KEEP=n RENEW=0" <<<"$out"' "$out"
    out=$(ask_tty "$EXPIRED" $'3\n')
    check "PAT 만료 질문: 3 → 중단(130)" 'grep -q "rc=130" <<<"$out"' "$out"
    out=$(ask_tty "$OTHER" $'1\n')
    check "다른 사람의 계정 질문: 1 → 일회성 (갱신 선택지 없음)" 'grep -q "권한이 없습니다" <<<"$out" && ! grep -q "PAT 갱신" <<<"$out" && grep -q "KEEP=n" <<<"$out"' "$out"
else
    echo "  SKIP  터미널 질문 시험 (script 없음)"
fi
if [ "${DT2_TEST_NETWORK:-0}" = 1 ]; then
    # 실제 GitHub: 가짜 PAT 는 401 → 저장된 도우미를 썼다면 git 이 reject 로 이 줄을 지웠을 것
    out=$(run "_detect_account; echo STATE=\$ACC_STATE USER=\$ACC_USER")
    check "실제 GitHub: 가짜 PAT → expired, ~/.git-credentials 그대로 (네트워크)" 'grep -q "STATE=expired USER=tester" <<<"$out" && [ "$(md5sum <"$T/home/.git-credentials")" = "$cred_md5" ]' "$out"
else
    echo "  SKIP  실제 GitHub 401 판정·자격 증명 보존 (DT2_TEST_NETWORK=1)"
fi
check "확인 중 ~/.git-credentials 를 바꾸지 않음" '[ "$(md5sum <"$T/home/.git-credentials")" = "$cred_md5" ]'

echo "▶ 2-0-1. 만료된 PAT 갱신 (bw_setup_github_auth — 백업 후 교체, 남의 계정일 수 있으면 확인)"
FAKE_BW='bw_get_github_account() { BW_GH_USER=tester BW_GH_EMAIL=t@t BW_GH_PAT=new-pat-111; }; bw_setup_git_config() { :; }; bw_setup_gh_auth() { :; }'
out=$(run "$FAKE_BW; bw_github_token_check() { [ \"\$1\" = new-pat-111 ] && { echo tester; return 0; }; return 1; }; bw_setup_github_auth; echo rc=\$?")
check "만료 → Bitwarden 새 PAT 로 교체, 기존 파일 백업" 'grep -q "rc=0" <<<"$out" && grep -q "new-pat-111@github.com" "$T/home/.git-credentials" && ! grep -q fake-pat-000 "$T/home/.git-credentials" && grep -qs fake-pat-000 "$T"/home/.git-credentials.bak.*' "$out"
rm -f "$T"/home/.git-credentials.bak.*
printf 'https://tester:still-good@github.com\n' >"$T/home/.git-credentials"
FAKE_BW2='bw_get_github_account() { echo BW-OPENED; BW_GH_USER=tester BW_GH_EMAIL=t@t BW_GH_PAT=new-pat-111; }; bw_setup_git_config() { :; }; bw_setup_gh_auth() { echo "GH-LOGIN:$1:${3:-}"; }'
out=$(run "$FAKE_BW2; bw_github_token_check() { echo tester; return 0; }; bw_setup_github_auth; echo rc=\$?")
check "PAT 있음(유효) → 계정 표시, 변경 기본 N → Bitwarden 없이 저장된 PAT 로 gh 만 로그인" 'grep -q "계정 tester (유효)" <<<"$out" && grep -q "변경하시겠습니까? (github.com-main)" <<<"$out" && ! grep -q BW-OPENED <<<"$out" && grep -q "GH-LOGIN:still-good:$" <<<"$out" && grep -q still-good "$T/home/.git-credentials"' "$out"
out=$(run "$FAKE_BW2; bw_github_token_check() { return 2; }; bw_setup_github_auth; echo rc=\$?")
check "PAT 있음(네트워크로 확인 불가) → 확인 못 했다고 표시, 기본 N 이면 그대로" 'grep -q "확인하지 못함" <<<"$out" && ! grep -q BW-OPENED <<<"$out" && grep -q still-good "$T/home/.git-credentials"' "$out"
if command -v script >/dev/null 2>&1; then
    out=$(printf 'y\n' | HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 timeout 20 script -qec "bash -c 'source \"$ROOT/lib/ui-lib\"; source \"$ROOT/lib/bw-lib\"; $FAKE_BW2; bw_github_token_check() { echo tester; return 0; }; bw_setup_github_auth; echo rc=\$?'" /dev/null 2>&1 | tr -d '\r')
    check "PAT 있음(유효) + 변경 y → Bitwarden 의 PAT 로 교체(백업), gh 도 다시 로그인" 'grep -q BW-OPENED <<<"$out" && grep -q "new-pat-111@github.com" "$T/home/.git-credentials" && grep -q "GH-LOGIN:new-pat-111:replace" <<<"$out" && grep -qs still-good "$T"/home/.git-credentials.bak.*' "$out"
    rm -f "$T"/home/.git-credentials.bak.*
fi
printf 'https://otherperson:old-pat@github.com\n' >"$T/home/.git-credentials"
out=$(run "$FAKE_BW; bw_github_token_check() { [ \"\$1\" = new-pat-111 ] && { echo tester; return 0; }; return 1; }; bw_setup_github_auth; echo rc=\$?")
check "저장된 이름이 Bitwarden·GitHub 계정과 모두 다르면 묻고, 기본(N)이면 바꾸지 않음" 'grep -q "계정(otherperson)과" <<<"$out" && grep -q "rc=1" <<<"$out" && grep -q old-pat "$T/home/.git-credentials"' "$out"
out=$(run "$FAKE_BW; bw_github_token_check() { return 1; }; bw_setup_github_auth; echo rc=\$?")
check "Bitwarden 의 PAT 도 만료면 바꾸지 않고 안내" 'grep -q "Bitwarden 의 PAT 도 만료" <<<"$out" && grep -q old-pat "$T/home/.git-credentials"' "$out"
if [ "${DT2_TEST_NETWORK:-0}" = 1 ]; then
    out=$(run "bw_github_token_check fake-pat-000; echo rc=\$?")
    check "실제 GitHub API: 가짜 PAT → 401(rc=1) (네트워크)" 'grep -q "rc=1" <<<"$out"' "$out"
fi
rm -f "$T/home/.git-credentials" "$T/home/.gitconfig" "$T"/home/.git-credentials.bak.*
out=$(run "unset DT2_KEEP_ACCOUNT; _detect_account; echo STATE=\$ACC_STATE")
check "저장된 계정 없음 → none (기존 y/n 질문으로)" 'grep -q "STATE=none" <<<"$out"' "$out"

echo "▶ 2-1. 입력값 정리 (dt2_clean_input — prompt_read 가 모든 입력에 적용)"
clean() { LANG=C.UTF-8 LC_ALL=C.UTF-8 bash -c 'source "$1"; v="$2"; dt2_clean_input v; printf "%s" "$v"' _ "$ROOT/lib/ui-lib" "$1"; }
check "앞뒤 공백·전각 공백 자름, 가운데 공백은 유지" '[ "$(clean $'"'"'\xe3\x80\x80 a b  '"'"')" = "a b" ]'
check "Esc 키 신호 제거" '[ "$(clean $'"'"'\e[23;8~abc'"'"')" = "abc" ]'
check "깨진 한글 조합 바이트 제거, 정상 한글은 유지" '[ "$(clean $'"'"'\xe3\x84한글'"'"')" = "한글" ]'
check "폭 없는 공백·BOM 제거" '[ "$(clean $'"'"'\xe2\x80\x8bx\xef\xbb\xbfy'"'"')" = "xy" ]'

# 설치 단계 스크립트는 set -euo pipefail 이라 정리 함수 안의 명령 하나만 실패해도 입력 직후 스크립트가 끝납니다
# (예전: shopt -p extglob 이 종료 코드 1 → npm 설치 방식 질문 직후 "핵심 도구 설치 실패").
strict_clean() { bash -c 'set -euo pipefail; source "$1"; v="$2"; dt2_clean_input v; printf "[%s]" "$v"' _ "$ROOT/lib/ui-lib" "$1" 2>&1; }
check "set -euo pipefail 에서도 끝나지 않음 (빈 입력)" '[ "$(strict_clean "")" = "[]" ]' "$(strict_clean "")"
check "set -euo pipefail 에서도 끝나지 않음 (보통 입력)" '[ "$(strict_clean " 1 ")" = "[1]" ]' "$(strict_clean " 1 ")"

echo "▶ 3. 일회성 git 자격 증명 (PAT 를 파일에 남기지 않음)"
git config --file "$T/home/.gitconfig" credential.helper store
out=$(run "KEEP=n; BW_GH_USER=tester; BW_GH_PAT=pat-secret-123
printf 'protocol=https\nhost=github.com\n\n' | _git credential fill")
check "도우미가 메모리의 계정을 돌려줌" 'grep -qx "username=tester" <<<"$out" && grep -qx "password=pat-secret-123" <<<"$out"' "$out"
run "KEEP=n; BW_GH_USER=tester; BW_GH_PAT=pat-secret-123
printf 'protocol=https\nhost=github.com\nusername=tester\npassword=pat-secret-123\n\n' | _git credential approve" >/dev/null
check "기존 store 도우미를 꺼서 ~/.git-credentials 에 저장 안 됨" '! grep -rqs "pat-secret-123" "$T/home"'
out=$(run "KEEP=y; printf 'protocol=https\nhost=github.com\nusername=me\npassword=kept\n\n' | _git credential approve; cat \"\$HOME/.git-credentials\"")
check "y 이면 이 PC 의 도우미를 그대로 씀 (대조)" 'grep -q "me:kept@github.com" <<<"$out"' "$out"
rm -f "$T/home/.git-credentials"

echo "▶ 4. 저장소 준비 (_sync_repo, 로컬 저장소로)"
src="$T/src"
git init -q -b main "$src" && git -C "$src" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
out=$(run "KEEP=n; BW_GH_USER=u; BW_GH_PAT=p; DT2_DIR='$T/dt2'; DT2_REPO_URL='$src'; _sync_repo")
check "없으면 clone" '[ -d "$T/dt2/.git" ]' "$out"
git -C "$src" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
out=$(run "KEEP=n; BW_GH_USER=u; BW_GH_PAT=p; DT2_DIR='$T/dt2'; DT2_REPO_URL='$src'; _sync_repo")
check "있으면 최신으로 fast-forward" '[ "$(git -C "$T/dt2" log -1 --format=%s)" = two ]' "$out"
echo x >"$T/dt2/local.txt" && git -C "$T/dt2" add local.txt
git -C "$src" -c user.name=t -c user.email=t@t commit -q --allow-empty -m three
out=$(run "KEEP=n; BW_GH_USER=u; BW_GH_PAT=p; DT2_DIR='$T/dt2'; DT2_REPO_URL='$src'; _sync_repo")
check "고친 파일이 있으면 맞추지 않음" '[ "$(git -C "$T/dt2" log -1 --format=%s)" = two ] && grep -q "커밋하지 않은 변경" <<<"$out"' "$out"
git -C "$T/dt2" reset -q --hard && git -C "$T/dt2" clean -qfd
sub="$T/sub"; git init -q -b main "$sub" && echo a >"$sub/a.sh" && git -C "$sub" add a.sh && git -C "$sub" -c user.name=t -c user.email=t@t commit -qm s
git -C "$src" -c protocol.file.allow=always submodule add -q "$sub" public >/dev/null 2>&1 && git -C "$src" -c user.name=t -c user.email=t@t commit -qm four
out=$(run "KEEP=n; BW_GH_USER=u; BW_GH_PAT=p; DT2_DIR='$T/dt2'; DT2_REPO_URL='$src'; git config --global protocol.file.allow always; _sync_repo")
chmod +x "$T/dt2/public/a.sh" 2>/dev/null
git -C "$src" -c user.name=t -c user.email=t@t commit -q --allow-empty -m five
out=$(run "KEEP=n; BW_GH_USER=u; BW_GH_PAT=p; DT2_DIR='$T/dt2'; DT2_REPO_URL='$src'; git config --global protocol.file.allow always; _sync_repo")
check "submodule 안 권한 변화는 무시하고 최신으로 맞춤" '[ "$(git -C "$T/dt2" log -1 --format=%s)" = five ]' "$out"
# submodule 폴더 이름이 바뀐 업데이트(_devtools2 2026-11-17: public/ → setup/)도 최신으로 맞추고 새 폴더를 채우는가
#   (옛 public/ 폴더는 남을 수 있음 — _devtools2 의 설치 Step 0 이 정리)
git -C "$src" -c protocol.file.allow=always submodule deinit -q -f public >/dev/null 2>&1
git -C "$src" rm -q -f public >/dev/null 2>&1 && rm -rf "$src/.git/modules/public"
git -C "$src" -c protocol.file.allow=always submodule add -q --name setup "$sub" setup >/dev/null 2>&1 \
    && git -C "$src" -c user.name=t -c user.email=t@t commit -qm six
out=$(run "KEEP=n; BW_GH_USER=u; BW_GH_PAT=p; DT2_DIR='$T/dt2'; DT2_REPO_URL='$src'; git config --global protocol.file.allow always; _sync_repo")
check "submodule 폴더 이름이 바뀐 업데이트도 최신으로 맞추고 새 폴더를 채움" '[ "$(git -C "$T/dt2" log -1 --format=%s)" = six ] && [ -f "$T/dt2/setup/a.sh" ]' "$out"
mkdir -p "$T/plain" && echo keep >"$T/plain/f"
out=$(run "KEEP=n; BW_GH_USER=u; BW_GH_PAT=p; DT2_DIR='$T/plain'; DT2_REPO_URL='$src'; _sync_repo")
check "Git 저장소가 아닌 폴더는 .bak 으로 옮기고 clone" '[ -d "$T/plain/.git" ] && ls -d "$T"/plain.bak.* >/dev/null 2>&1' "$out"

echo "▶ 5. 정리 (_cleanup)"
# _devtools2 의 설치 Step 0 이 *.sh 를 실행 가능으로 바꾸므로, git 에 실행 비트 없이 들어가면 submodule 이 "고친 파일"로 보입니다
nonexec=$(cd "$ROOT" && git ls-files -s -- '*.sh' 2>/dev/null | awk '$1 != "100755" {print $4}')
check "*.sh 가 git 에 실행 비트(100755)로 기록됨" '[ -z "$nonexec" ]' "$nonexec"

check "DT2_SETUP_CLONE_ONLY=1 이면 설치 스크립트를 실행하지 않고 끝냄 (Windows 용)" \
    'grep -q "DT2_SETUP_CLONE_ONLY:-0}\" = 1 ]; then" "$ROOT/install.sh" && awk "/DT2_SETUP_CLONE_ONLY:-0/{f=1} f&&/return 0/{print \"OK\"; exit} f&&/exec bash/{exit}" "$ROOT/install.sh" | grep -q OK'

out=$(run "KEEP=n; _HAD_DT2_HOME=false; _make_work_dir; w=\$WORK; BW_GH_PAT=secret; _cleanup
[ -d \"\$w\" ] && echo LEFT; echo \"PAT=\${BW_GH_PAT:-}\"")
check "임시 폴더·PAT 변수 삭제" '! grep -q LEFT <<<"$out" && grep -qx "PAT=" <<<"$out"' "$out"

if [ "${DT2_TEST_NETWORK:-0}" = 1 ]; then
    echo "▶ 6. Bitwarden CLI 받기 (네트워크)"
    out=$(run "DT2_DIR='$T/none'; _make_work_dir; _prepare_bw && bw --version; _cleanup")
    check "GitHub 릴리스에서 받아 SHA-256 확인 후 실행됨" 'grep -Eq "^[0-9]+\.[0-9]+\.[0-9]+" <<<"$(tail -1 <<<"$out")"' "$out"
fi

echo ""
echo "결과: 통과 $PASS, 실패 $FAIL"
[ "$FAIL" -eq 0 ]
