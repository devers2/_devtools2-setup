#!/usr/bin/env bash
# ==============================================================================
# DevTools2 설치 시작 스크립트 (WSL·리눅스)
#   curl -fsSL https://raw.githubusercontent.com/devers2/_devtools2-setup/main/install.sh | bash
# ==============================================================================
# 하는 일
#   1) Bitwarden CLI(bw)를 임시 폴더에 받음 (GitHub 릴리스, SHA-256 확인)
#   2) Bitwarden 로그인 → GitHub 계정(PAT) 읽기
#   3) 비공개 저장소 _devtools2 를 /var/opt/_devtools2 로 clone (이미 있으면 최신으로 맞춤)
#   4) 그 안의 scripts/linux/setup-devtools2.sh 실행
#
# 계정 사용 (DT2_KEEP_ACCOUNT=y|n 로 묻지 않고 지정)
#   y: 이 PC 에 Bitwarden 로그인과 GitHub 계정 정보(git 자격 증명·gh 로그인)를 저장합니다.
#      이미 git 자격 증명이 있으면 Bitwarden 없이 그대로 씁니다(다시 실행해 업데이트할 때).
#   n: 일회성 설치 — bw 는 임시 데이터 폴더(BITWARDENCLI_APPDATA_DIR)에서만 쓰고, PAT 는 clone·fetch 에만
#      메모리(환경 변수)로 넘깁니다. ~/.git-credentials·gh·git user 설정과 이 PC 의 기존 Bitwarden 로그인은
#      건드리지 않고, 설치 단계로 넘어가기 전에 bw logout·임시 폴더 삭제로 모두 지웁니다.
#      남의 PC 에 설치해 주거나, 예전에 설치해 준 PC 를 업데이트할 때 씁니다.
#
# 환경 변수
#   DT2_KEEP_ACCOUNT=y|n      계정 사용 질문의 답
#   BW_DEFAULT_PAT_ITEM=이름  GitHub PAT 가 든 Bitwarden 항목 (기본 github.com-main, 사용자 지정 필드 "PAT")
#   DT2_SETUP_REF=브랜치      이 저장소의 다른 브랜치·커밋으로 시험할 때 (기본 main)
#   DT2_SETUP_CLONE_ONLY=1    저장소 준비까지만 하고 끝냄 (Windows install.ps1 이 씀 — 리눅스 설치 단계는
#                             Windows 쪽 설치 스크립트가 임시 sudo 와 함께 순서대로 실행)
#
# ⚠️ 이 저장소는 공개입니다. 회사·고객 정보, 접속 주소, 비밀값을 넣지 마십시오.
# ==============================================================================
set -uo pipefail

DT2_REPO_URL="https://github.com/devers2/_devtools2.git"
DT2_DIR="/var/opt/_devtools2"
SETUP_REPO="devers2/_devtools2-setup"
SETUP_REF="${DT2_SETUP_REF:-main}"

KEEP=""
WORK=""
_HAD_DT2_HOME=false

_die() { printf '[오류] %s\n' "$*" >&2; exit 1; }

# ── 임시 폴더: 로그아웃하면 비워지는 XDG_RUNTIME_DIR 를 먼저 씀 (강제 종료돼도 오래 남지 않게) ──
_make_work_dir() {
    local _base="${XDG_RUNTIME_DIR:-}"
    if [ -z "$_base" ] || [ ! -d "$_base" ] || [ ! -w "$_base" ]; then
        _base="${TMPDIR:-/tmp}"
    fi
    WORK=$(mktemp -d "$_base/dt2-setup.XXXXXX") || _die "임시 폴더를 만들지 못했습니다."
    chmod 700 "$WORK"
}

# ── 정리: 일회성 설치면 Bitwarden 로그아웃, PAT·세션 변수와 임시 폴더 삭제 (여러 번 불러도 됨) ──
_cleanup() {
    if [ "$KEEP" = n ] && [ -n "$WORK" ] && [ -d "$WORK/bw-data" ] && command -v bw >/dev/null 2>&1; then
        BITWARDENCLI_APPDATA_DIR="$WORK/bw-data" bw logout >/dev/null 2>&1 || true
    fi
    BW_GH_PAT="" BW_GH_USER="" BW_GH_EMAIL="" BW_SESSION=""
    unset BW_GH_PAT BW_SESSION BITWARDENCLI_APPDATA_DIR
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        rm -rf -- "$WORK"
    fi
    WORK=""
    # bw-lib 이 불러올 때 만드는 ~/.devtools2 가 원래 없었고 비어 있으면 지움
    if [ "$KEEP" = n ] && [ "$_HAD_DT2_HOME" = false ]; then
        rmdir "$HOME/.devtools2" 2>/dev/null || true
    fi
}

# ── 공용 라이브러리(ui-lib·bw-lib) 받기 ───────────────────────────────────────
# 받는 커밋을 먼저 정해(git ls-remote) install.sh 를 받은 직후 main 에 push 가 있어도 두 파일이 같은 커밋이 되게 합니다.
# 이 저장소를 clone 해서 직접 실행하면(시험용) 스크립트 옆의 lib/ 를 씁니다.
_load_libs() {
    local _here="" _ref="$SETUP_REF" _sha _f
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        _here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    fi
    for _f in ui-lib bw-lib; do
        if [ -n "$_here" ] && [ -f "$_here/lib/$_f" ]; then
            cp "$_here/lib/$_f" "$WORK/$_f" || _die "$_here/lib/$_f 를 복사하지 못했습니다."
            continue
        fi
        if [ "$_ref" = "$SETUP_REF" ]; then
            _sha=$(git ls-remote "https://github.com/${SETUP_REPO}.git" "refs/heads/${SETUP_REF}" 2>/dev/null | cut -f1)
            [ -n "$_sha" ] && _ref="$_sha"
        fi
        curl -fsSL --max-time 30 -H 'Cache-Control: no-cache' \
            "https://raw.githubusercontent.com/${SETUP_REPO}/${_ref}/lib/${_f}" -o "$WORK/$_f" \
            || _die "공용 라이브러리($_f)를 받지 못했습니다. 인터넷 연결을 확인하세요."
    done
    [ -d "$HOME/.devtools2" ] && _HAD_DT2_HOME=true
    # shellcheck source=lib/ui-lib
    source "$WORK/ui-lib"
    # shellcheck source=lib/bw-lib
    source "$WORK/bw-lib"
    declare -F prompt_read >/dev/null && declare -F bw_get_github_account >/dev/null \
        || _die "공용 라이브러리를 불러오지 못했습니다."
}

# ── 필요한 명령 확인 (git·python3 이 없으면 apt 로 설치) ─────────────────────
_need_commands() {
    local _missing=() _c
    for _c in git python3; do
        command -v "$_c" >/dev/null 2>&1 || _missing+=("$_c")
    done
    [ "${#_missing[@]}" -eq 0 ] && return 0
    command -v apt-get >/dev/null 2>&1 || _die "${_missing[*]} 이(가) 필요합니다. 먼저 설치하세요."
    print_info "필요한 명령을 설치합니다: ${_missing[*]}"
    _sudo apt-get update -qq && _sudo apt-get install -y -qq "${_missing[@]}" >/dev/null \
        || _die "${_missing[*]} 설치에 실패했습니다."
}
_sudo() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# ── 계정 사용 질문 ───────────────────────────────────────────────────────────
_ask_keep_account() {
    case "${DT2_KEEP_ACCOUNT:-}" in
        [Yy]*) KEEP=y; return 0 ;;
        [Nn]*) KEEP=n; return 0 ;;
        "") ;;
        *) _die "DT2_KEEP_ACCOUNT 는 y 또는 n 입니다: ${DT2_KEEP_ACCOUNT}" ;;
    esac
    dt2_is_noninteractive && _die "질문할 터미널이 없습니다. DT2_KEEP_ACCOUNT=y 또는 n 으로 지정하세요."
    local _ans=""
    echo ""
    printf '%s\n' "${_C_YELLOW}${_C_BOLD}👉 설치에 사용할 Bitwarden/GitHub 계정을 현재 PC 에서 사용하시겠습니까? [y/n]${_C_RESET}"
    echo "   y: 이 PC 에 Bitwarden 로그인과 GitHub 계정 정보(PAT·gh 로그인)를 저장합니다."
    echo "   n: 일회성 설치 — 설치에만 사용하고, 끝나면 이 PC 에 계정 정보를 남기지 않습니다."
    # 기본값 없음: Enter 만 누르면 다시 묻습니다. 한글 입력 상태의 y·n 키(ㅛ·ㅜ)도 받습니다.
    while true; do
        prompt_read _ans "   선택 [y/n]:"
        _ans="${_ans//[[:space:]]/}"
        case "${_ans,,}" in
            y | yes | ㅛ) KEEP=y; return 0 ;;
            n | no | ㅜ) KEEP=n; return 0 ;;
        esac
        print_warn "y 또는 n 을 입력해 주세요."
    done
}

# ── Bitwarden CLI 준비 ──────────────────────────────────────────────────────
# 이미 DevTools2 가 설치한 bw 가 있으면(다시 실행) 그것을 쓰고, 없으면 GitHub 릴리스에서 임시 폴더로 받습니다.
# 받은 파일은 GitHub 가 알려 주는 SHA-256(digest)과 맞을 때만 씁니다. 정식 설치는 설치 Step 3 이 맡습니다.
_prepare_bw() {
    if [ -x "$DT2_DIR/modules/bitwarden/bw" ]; then
        export PATH="$DT2_DIR/modules/bitwarden:$PATH"
        return 0
    fi
    local _suffix _info _url _digest _got
    case "$(uname -m)" in
        x86_64 | amd64) _suffix="" ;;
        aarch64 | arm64) _suffix="-arm64" ;;
        *) _die "지원하지 않는 CPU 입니다: $(uname -m)" ;;
    esac
    print_info "Bitwarden CLI 를 받습니다..."
    # GITHUB_TOKEN 이 있으면(CI 등) API 호출 한도를 넉넉하게 씀
    local _auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && _auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    _info=$(curl -fsSL --max-time 30 "${_auth[@]}" "https://api.github.com/repos/bitwarden/clients/releases?per_page=50" | python3 -c '
import json, sys
suffix = sys.argv[1]
for r in json.load(sys.stdin):
    tag = r.get("tag_name", "")
    if r.get("draft") or r.get("prerelease") or not tag.startswith("cli-v"):
        continue
    want = "bw-linux%s-%s.zip" % (suffix, tag[len("cli-v"):])
    for a in r.get("assets", []):
        if a.get("name") == want:
            print(a.get("browser_download_url", ""), (a.get("digest") or "").replace("sha256:", ""))
            sys.exit(0)
' "$_suffix") || true
    read -r _url _digest <<<"$_info"
    [ -n "${_url:-}" ] || _die "Bitwarden CLI 릴리스를 찾지 못했습니다."
    [ -n "${_digest:-}" ] || _die "Bitwarden CLI 의 SHA-256 을 확인할 수 없어 설치하지 않습니다: $_url"
    curl -fsSL --max-time 300 "$_url" -o "$WORK/bw.zip" || _die "Bitwarden CLI 를 받지 못했습니다: $_url"
    _got=$(sha256sum "$WORK/bw.zip" | cut -d' ' -f1)
    [ "$_got" = "$_digest" ] || _die "Bitwarden CLI 파일의 SHA-256 이 맞지 않습니다 (받은 값 $_got, 기대 값 $_digest)."
    mkdir -p "$WORK/bin"
    python3 - "$WORK/bw.zip" "$WORK/bin/bw" <<'PY' || _die "Bitwarden CLI 압축을 풀지 못했습니다."
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z, z.open("bw") as src, open(sys.argv[2], "wb") as dst:
    dst.write(src.read())
PY
    chmod 700 "$WORK/bin/bw"
    rm -f "$WORK/bw.zip"
    export PATH="$WORK/bin:$PATH"
}

# ── GitHub 계정 준비 ─────────────────────────────────────────────────────────
_prepare_account() {
    if [ "$KEEP" = y ]; then
        if bw_git_credentials_exist github.com; then
            print_info "저장된 GitHub 로그인(~/.git-credentials)을 씁니다."
            return 0
        fi
        _prepare_bw
        bw_setup_github_auth || _die "GitHub 로그인 설정에 실패했습니다."
        return 0
    fi
    # 일회성: 이 PC 의 Bitwarden 로그인·세션 파일과 섞이지 않도록 데이터 폴더와 세션 파일을 임시 폴더로 돌림
    _prepare_bw
    export BITWARDENCLI_APPDATA_DIR="$WORK/bw-data"
    _BW_SESSION_FILE="$WORK/bw_session"
    unset BW_SESSION
    bw_get_github_account || _die "Bitwarden 에서 GitHub 계정을 읽지 못했습니다."
    # PAT 를 읽었으면 Bitwarden 은 더 쓰지 않으므로 바로 로그아웃
    bw logout >/dev/null 2>&1 || true
    rm -rf -- "$WORK/bw-data" "$WORK/bw_session"
    unset BITWARDENCLI_APPDATA_DIR BW_SESSION
}

# git 실행: 일회성이면 PAT 를 환경 변수로만 넘기는 임시 자격 증명 도우미를 씁니다.
#   -c credential.helper= 로 이 PC 의 기존 도우미(store 등)를 끄므로 PAT 가 파일에 저장되지 않고,
#   git -c 값은 저장소 설정에 남지 않습니다. PAT 는 명령 인자에 나타나지 않습니다.
_git() {
    if [ "$KEEP" = n ]; then
        DT2_GH_USER="$BW_GH_USER" DT2_GH_PAT="$BW_GH_PAT" GIT_TERMINAL_PROMPT=0 git \
            -c credential.helper= \
            -c 'credential.helper=!f() { [ "$1" = get ] || exit 0; printf "username=%s\npassword=%s\n" "$DT2_GH_USER" "$DT2_GH_PAT"; }; f' \
            "$@"
    else
        GIT_TERMINAL_PROMPT=0 git "$@"
    fi
}

# ── _devtools2 저장소 준비 ───────────────────────────────────────────────────
# 이미 있으면: 고친 파일이 없고 main 에 있을 때만 최신으로 fast-forward (설치 Step 0 의 규칙과 같음)
# 없으면: 폴더를 만들어 현재 사용자 소유로 두고 clone (Git 저장소가 아닌 폴더는 .bak.<시각> 으로 옮김)
_sync_repo() {
    if [ -d "$DT2_DIR/.git" ]; then
        local _branch
        _branch=$(git -C "$DT2_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
        if ! git -C "$DT2_DIR" diff --quiet 2>/dev/null || ! git -C "$DT2_DIR" diff --staged --quiet 2>/dev/null; then
            print_warn "$DT2_DIR 에 커밋하지 않은 변경이 있어 최신으로 맞추지 않고 그대로 진행합니다."
        elif [ "$_branch" != main ]; then
            print_warn "$DT2_DIR 이 main 이 아닌 '${_branch:-분리된 HEAD}' 에 있어 최신으로 맞추지 않고 그대로 진행합니다."
        elif _git -C "$DT2_DIR" fetch --quiet origin && git -C "$DT2_DIR" merge --ff-only --quiet origin/main; then
            print_done "$DT2_DIR 을 최신으로 맞췄습니다: $(git -C "$DT2_DIR" rev-parse --short HEAD)"
        else
            print_warn "$DT2_DIR 을 최신으로 맞추지 못했습니다 (받기 실패 또는 로컬 커밋이 갈라짐). 기존 버전으로 진행합니다."
        fi
        _git -C "$DT2_DIR" submodule update --init --recursive --quiet \
            || print_warn "submodule 을 맞추지 못했습니다."
        return 0
    fi
    if [ "$(id -u)" -ne 0 ]; then
        dt2_sudo_auth || _die "$DT2_DIR 을 만들려면 sudo 권한이 필요합니다."
    fi
    if [ -e "$DT2_DIR" ] && [ -n "$(ls -A "$DT2_DIR" 2>/dev/null)" ]; then
        local _bak
        _bak="${DT2_DIR}.bak.$(date +%Y%m%d%H%M%S)"
        print_warn "Git 저장소가 아닌 $DT2_DIR 을 $_bak 로 옮깁니다."
        _sudo mv "$DT2_DIR" "$_bak" || _die "$DT2_DIR 을 옮기지 못했습니다."
    fi
    _sudo install -d -o "$(id -un)" -g "$(id -gn)" "$DT2_DIR" || _die "$DT2_DIR 을 만들지 못했습니다."
    print_info "_devtools2 저장소를 받습니다..."
    _git clone --quiet --recurse-submodules "$DT2_REPO_URL" "$DT2_DIR" \
        || _die "_devtools2 저장소를 받지 못했습니다. GitHub 계정에 저장소 읽기 권한이 있는지 확인하세요."
    print_done "$DT2_DIR 에 받았습니다: $(git -C "$DT2_DIR" rev-parse --short HEAD)"
}

main() {
    # curl … | bash 로 실행하면 표준 입력이 이 스크립트라 질문에 답할 수 없으므로, 터미널이 있으면 입력을 터미널로 돌림
    # (스크립트 전체가 main 함수 안에 있고 마지막 줄에서 부르므로, bash 가 남은 줄을 터미널에서 읽는 일은 없음)
    if [ ! -t 0 ] && { : </dev/tty; } 2>/dev/null; then
        exec </dev/tty
    fi
    command -v curl >/dev/null 2>&1 || _die "curl 이 필요합니다."
    _make_work_dir
    trap _cleanup EXIT
    trap 'echo ""; echo "⛔ 설치를 중단했습니다."; exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    command -v git >/dev/null 2>&1 || {
        # ls-remote 전에 git 이 필요하므로, 라이브러리를 받기 전에는 apt 로만 설치 (질문 함수 없이)
        command -v apt-get >/dev/null 2>&1 || _die "git 이 필요합니다. 먼저 설치하세요."
        echo "[정보] git 을 설치합니다..."
        _sudo apt-get update -qq && _sudo apt-get install -y -qq git >/dev/null || _die "git 설치에 실패했습니다."
    }
    _load_libs
    print_banner "DevTools2 설치 시작"
    _need_commands
    _ask_keep_account
    _prepare_account
    _sync_repo

    local _setup="$DT2_DIR/scripts/linux/setup-devtools2.sh"
    [ -f "$_setup" ] || _die "$_setup 이 없습니다."
    _cleanup
    trap - EXIT INT TERM HUP
    if [ "${DT2_SETUP_CLONE_ONLY:-0}" = 1 ]; then
        print_done "DevTools2 저장소 준비를 마쳤습니다 (설치 단계는 이어서 Windows 쪽에서 진행)."
        return 0
    fi
    export DT2_KEEP_ACCOUNT="$KEEP"
    if [ "$KEEP" = n ]; then
        # 설치 Step 3 의 GitHub 로그인 연결(Bitwarden PAT 저장)을 건너뜀
        export DT2_GITHUB_AUTH=n
        print_info "일회성 설치: 계정 정보를 지웠습니다. 이 PC 의 GitHub 로그인은 사용자 본인 계정으로 'gh auth login' 하세요."
    fi
    exec bash "$_setup" "$@"
}

# 시험(tests/run-tests.sh)은 이 파일을 source 해서 함수만 씁니다 — source 하면 여기서 돌아가고 main 은 실행하지 않음
if (return 0 2>/dev/null); then return 0; fi
main "$@"; exit $?
