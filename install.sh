#!/usr/bin/env bash
# ==============================================================================
# DevTools2 설치 시작 스크립트 (WSL·리눅스)
#   curl -fsSL https://raw.githubusercontent.com/devershq/_devtools2-setup/main/install.sh | bash
# ==============================================================================
# 하는 일
#   1) Bitwarden CLI(bw)를 임시 폴더에 받음 (GitHub 릴리스, SHA-256 확인)
#   2) Bitwarden 로그인 → GitHub 계정(PAT) 읽기
#   3) 비공개 저장소 _devtools2 를 /var/opt/_devtools2 로 clone (이미 있으면 최신으로 맞춤)
#   4) 그 안의 scripts/linux/setup-devtools2.sh 실행
#
# --ai: AI 로 고치기 위한 최소 준비만 (전체 설치는 하지 않음)
#   curl -fsSL https://raw.githubusercontent.com/devershq/_devtools2-setup/main/install.sh | bash -s -- --ai
#   설치 스크립트가 중간에 실패한 내 PC 에서 AI 로 바로 고치기 위한 모드입니다.
#   계정 확인 → _devtools2 받기(있으면 최신으로) → AI 에이전트 CLI 설치(tool.setup-agents.sh)
#   → AI 공통 설정(tool.setup-agent-notes.sh — agent-notes 받기·규칙 적용) 까지만 하고 끝냅니다.
#   비공개 작업 노트를 받으므로 내 계정일 때만 동작합니다(일회성·다른 사람의 계정이면 아무것도 하지 않고 끝남).
#
# 계정 사용 (DT2_KEEP_ACCOUNT=y|n 로 묻지 않고 지정)
#   (지정하지 않으면) 이 PC 에 저장된 GitHub 계정이 DevTools2 저장소에 접근되면 묻지 않고 그대로 씁니다.
#      계정은 있는데 접근이 안 되면 GitHub API 로 까닭을 나눕니다: 다른 사람의 계정(PAT 유효·권한 없음)이면 일회성/중단,
#      PAT 만료·폐기(401)면 PAT 갱신/일회성/중단. 계정이 없으면 y/n 을 묻습니다.
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
#   DT2_KEEP_ACCOUNT_OUT=파일 정한 계정 사용(y/n)과 입력한 Bitwarden 항목 이름을 이 파일에 씀 (Windows install.ps1 이 씀)
#   DT2_SETUP_CLONE_ONLY=1    저장소 준비까지만 하고 끝냄 (Windows install.ps1 이 씀 — 리눅스 설치 단계는
#                             Windows 쪽 설치 스크립트가 임시 sudo 와 함께 순서대로 실행)
#
# ⚠️ 이 저장소는 공개입니다. 회사·고객 정보, 접속 주소, 비밀값을 넣지 마십시오.
# ==============================================================================
set -uo pipefail

DT2_REPO_URL="https://github.com/devershq/_devtools2.git"
DT2_DIR="/var/opt/_devtools2"
SETUP_REPO="devershq/_devtools2-setup"
SETUP_REF="${DT2_SETUP_REF:-main}"

KEEP=""
WORK=""
AI_ONLY=0   # --ai: AI 로 고치기 위한 최소 준비만
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
    BW_GH_PAT="" BW_GH_OWNER_PATS="" BW_GH_USER="" BW_GH_EMAIL="" BW_SESSION=""
    unset BW_GH_PAT BW_GH_OWNER_PATS BW_SESSION BITWARDENCLI_APPDATA_DIR
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
    [ "$(id -u)" -eq 0 ] && { "$@"; return; }
    # 비밀번호를 물을 때 어느 계정의 것인지 알리도록 공용 dt2_sudo_auth 를 거칩니다.
    # 라이브러리를 받기 전(git 설치)에는 그 함수가 없어 같은 뜻의 안내만 직접 출력합니다.
    if declare -F dt2_sudo_auth >/dev/null; then
        dt2_sudo_auth || return 1
    elif ! sudo -n true 2>/dev/null; then
        echo "[정보] sudo 권한이 필요합니다. 계정 '$(id -un)' 의 비밀번호를 입력하세요 (WSL 이면 배포판을 만들 때 정한 비밀번호)."
        sudo -v || return 1
    fi
    sudo "$@"
}

# ── 계정 사용 질문 ───────────────────────────────────────────────────────────
# ── 이 PC 에 저장된 GitHub 계정 확인 ─────────────────────────────────────────
# ACC_STATE: none     저장된 계정 없음
#            ok       DevTools2 저장소에 접근됨
#            expired  PAT 만료·폐기(GitHub 401) — 누구의 계정인지는 알 수 없음
#            other    PAT 는 유효하지만 저장소 권한 없음 → 다른 사람의 계정
#            offline  GitHub 에 연결해 확인할 수 없음(네트워크)
# ACC_USER: 저장된 이름, ACC_LOGIN: PAT 의 실제 GitHub 계정(유효할 때)
# ⚠️ 계정은 읽기만 합니다(bw_read_stored_github_credential 참고 — 저장된 도우미로 바로 접속하면 401 때 git 이 그 줄을 지움).
ACC_STATE="" ACC_USER="" ACC_LOGIN=""
_detect_account() {
    local _pw _rc=0
    ACC_LOGIN=""
    # 저장소 주소로 읽음 — 이 저장소 계정의 전용 PAT(PAT_<계정>, bw_save_owner_git_credentials)가 저장돼 있으면 그것을 확인
    if ! bw_read_stored_github_credential "$DT2_REPO_URL"; then
        ACC_STATE=none ACC_USER=""
        return 0
    fi
    ACC_USER="$BW_STORED_GH_USER" _pw="$BW_STORED_GH_PAT"
    BW_STORED_GH_PAT=""
    if _check_repo_access "$ACC_USER" "$_pw"; then
        ACC_STATE=ok
    else
        ACC_LOGIN=$(bw_github_token_check "$_pw") || _rc=$?
        case "$_rc" in
            0) ACC_STATE=other ;;
            1) ACC_STATE=expired ;;
            *) ACC_STATE=offline ;;
        esac
    fi
    _pw=""
}

# 계정으로 비공개 저장소를 읽을 수 있는지 (메모리 전용 도우미 — 저장·삭제 없음). 시험에서는 이 함수를 바꿔 끼웁니다.
_check_repo_access() {
    DT2_GH_USER="$1" DT2_GH_PAT="$2" GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never timeout 30 git \
        -c credential.helper= \
        -c 'credential.helper=!f() { [ "$1" = get ] || exit 0; printf "username=%s\npassword=%s\n" "$DT2_GH_USER" "$DT2_GH_PAT"; }; f' \
        ls-remote --heads "$DT2_REPO_URL" >/dev/null 2>&1
}

# ── 계정 사용 결정 ───────────────────────────────────────────────────────────
# KEEP=y: 이 PC 의 계정 사용(없으면 저장) / n: 일회성 / RENEW=1: 만료된 PAT 갱신(KEEP=y 와 함께)
#   ok      → 묻지 않고 그대로(안내 표시)
#   other   → 1) 일회성 2) 중단                (다른 사람의 계정 — 건드리지 않음)
#   expired → 1) PAT 갱신 2) 일회성 3) 중단     (내 PC 면 갱신)
#   offline → 중단(네트워크 확인 안내)
#   none    → y/n
RENEW=0
_ask_keep_account() {
    local _ans=""
    _detect_account
    [ "$ACC_STATE" = offline ] && _die "GitHub 에 연결할 수 없어 저장된 계정(${ACC_USER})을 확인하지 못했습니다. 네트워크를 확인한 뒤 다시 실행하세요."
    # --ai: 비공개 작업 노트를 받으므로 내 계정(y)으로만 진행합니다 — 묻지 않고 y 와 같게 처리
    #   (다른 사람의 계정이면 아래 y 처리에서 멈춤, PAT 만료면 갱신, 계정이 없으면 Bitwarden 에서 읽어 저장)
    if [ "$AI_ONLY" = 1 ]; then
        case "${DT2_KEEP_ACCOUNT:-}" in
            [Nn]*) _die "--ai 는 내 계정으로만 실행합니다(비공개 작업 노트를 받음). 일회성 설치(DT2_KEEP_ACCOUNT=n)와 함께 쓸 수 없습니다." ;;
        esac
        [ "$ACC_STATE" = other ] && _die "--ai 는 내 계정으로만 실행합니다. 이 PC 에 저장된 GitHub 계정(${ACC_LOGIN:-$ACC_USER})은 DevTools2 저장소 권한이 없습니다(다른 사람의 계정)."
        [ "$ACC_STATE" = none ] && print_info "--ai: 이 PC 에 저장된 GitHub 계정이 없어 Bitwarden 에서 내 계정을 읽어 저장합니다."
        DT2_KEEP_ACCOUNT=y
    fi
    case "${DT2_KEEP_ACCOUNT:-}" in
        [Yy]*)
            case "$ACC_STATE" in
                other) _die "저장된 GitHub 계정(${ACC_LOGIN:-$ACC_USER})은 DevTools2 저장소 권한이 없습니다(다른 사람의 계정). DT2_KEEP_ACCOUNT=n(일회성)으로 실행하세요." ;;
                expired) print_warn "저장된 GitHub 계정(${ACC_USER})의 PAT 가 만료되었거나 폐기되어 Bitwarden 의 새 PAT 로 갱신합니다."; RENEW=1 ;;
                ok) print_done "저장된 GitHub 계정(${ACC_USER})으로 진행합니다 — DevTools2 저장소 접근 확인됨." ;;
            esac
            KEEP=y; return 0 ;;
        [Nn]*) KEEP=n; return 0 ;;
        "") ;;
        *) _die "DT2_KEEP_ACCOUNT 는 y 또는 n 입니다: ${DT2_KEEP_ACCOUNT}" ;;
    esac
    if [ "$ACC_STATE" = ok ]; then
        echo ""
        print_done "이 PC 에 저장된 GitHub 계정(${ACC_USER})이 있고 DevTools2 저장소에 접근할 수 있습니다."
        print_info "이 계정으로 그대로 진행합니다 (계정 설정은 바꾸지 않음). 일회성 설치를 원하면 중단 후 DT2_KEEP_ACCOUNT=n 으로 다시 실행하세요."
        KEEP=y; return 0
    fi
    dt2_is_noninteractive && _die "질문할 터미널이 없습니다. DT2_KEEP_ACCOUNT=y 또는 n 으로 지정하세요."
    echo ""
    if [ "$ACC_STATE" = other ]; then
        printf '%s\n' "${_C_YELLOW}${_C_BOLD}👉 이 PC 에 저장된 GitHub 계정(${ACC_LOGIN:-$ACC_USER})은 DevTools2 저장소 권한이 없습니다 (다른 사람의 계정).${_C_RESET}"
        echo "   1) 일회성 설치 — Bitwarden 에 로그인해 설치에만 쓰고, 끝나면 지웁니다. 이 PC 의 계정은 그대로 둡니다."
        echo "   2) 중단"
        while true; do
            prompt_read _ans "   선택 [1/2]:"
            case "${_ans//[[:space:]]/}" in
                1) KEEP=n; return 0 ;;
                2) print_info "설치를 중단했습니다."; exit 130 ;;
            esac
            print_warn "1 또는 2 를 입력해 주세요."
        done
    fi
    if [ "$ACC_STATE" = expired ]; then
        printf '%s\n' "${_C_YELLOW}${_C_BOLD}👉 이 PC 에 저장된 GitHub 계정(${ACC_USER})의 PAT 가 만료되었거나 폐기되었습니다.${_C_RESET}"
        echo "   1) PAT 갱신 — 내 PC: Bitwarden 에 로그인해 새 PAT 를 이 PC 에 저장합니다 (기존 자격 증명은 백업)"
        echo "   2) 일회성 설치 — 설치에만 쓰고 끝나면 지웁니다. 이 PC 의 계정은 그대로 둡니다."
        echo "   3) 중단"
        while true; do
            prompt_read _ans "   선택 [1/2/3]:"
            case "${_ans//[[:space:]]/}" in
                1) KEEP=y RENEW=1; return 0 ;;
                2) KEEP=n; return 0 ;;
                3) print_info "설치를 중단했습니다."; exit 130 ;;
            esac
            print_warn "1, 2, 3 중에서 입력해 주세요."
        done
    fi
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
    ver = tag[len("cli-v"):]
    # 2026.11.0 부터 bw-linux-<ver>.zip → bw-bit-linux-<ver>.zip (같은 공식 판). 알려진 이름만 새 이름부터 확인합니다
    # — 넓은 패턴으로 맞추면 라이선스 기능을 뺀 bw-oss-* 등 다른 판이 조용히 골라질 수 있음.
    assets = {a.get("name"): a for a in r.get("assets", [])}
    for want in ("bw-bit-linux%s-%s.zip" % (suffix, ver), "bw-linux%s-%s.zip" % (suffix, ver)):
        a = assets.get(want)
        if a:
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
        # 저장된 계정이 있으면(_detect_account) 그대로 씁니다 — 접근이 안 되는 계정이면 _ask_keep_account 에서 이미 걸러짐
        [ "$ACC_STATE" = ok ] && return 0
        # 만료된 PAT 갱신: bw_setup_github_auth 가 401 을 확인하고 백업 후 교체(남의 계정일 수 있으면 한 번 더 확인)
        if [ "$RENEW" = 1 ]; then
            _prepare_bw
            bw_setup_github_auth || _die "PAT 를 갱신하지 못했습니다. 일회성 설치(DT2_KEEP_ACCOUNT=n)로 다시 실행할 수 있습니다."
            _detect_account
            [ "$ACC_STATE" = ok ] || _die "PAT 를 갱신했지만 DevTools2 저장소에 접근할 수 없습니다 (상태: $ACC_STATE)."
            print_done "PAT 를 갱신했습니다 — GitHub 계정(${ACC_USER})으로 진행합니다."
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
        # PAT: 이 저장소 계정의 PAT_<계정> 이 있으면 그것, 없으면 기본 PAT (bw_pick_pat)
        DT2_GH_USER="$BW_GH_USER" DT2_GH_PAT="$(bw_pick_pat "$DT2_REPO_URL" "$BW_GH_PAT" "${BW_GH_OWNER_PATS:-}")" GIT_TERMINAL_PROMPT=0 git \
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
        # submodule(setup/) 안의 작업 트리 변화(설치 Step 0 의 chmod 등)는 무시합니다 — submodule 은 아래 update 가 맞춥니다.
        if ! git -C "$DT2_DIR" diff --quiet --ignore-submodules=dirty 2>/dev/null \
            || ! git -C "$DT2_DIR" diff --staged --quiet --ignore-submodules=dirty 2>/dev/null; then
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
        dt2_sudo_auth "$DT2_DIR 을 만들려면" || _die "$DT2_DIR 을 만들려면 sudo 권한이 필요합니다."
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

# ── 이어지는 설치 단계에 계정 결정 넘기기 (리눅스: 환경 변수, Windows: DT2_KEEP_ACCOUNT_OUT 파일) ──
_hand_off_account() {
    # 여기서 입력한 Bitwarden 항목 이름을 이어지는 설치 단계(Step 3 GitHub 로그인 연결)의 기본값으로 넘김
    #   (기본값이 아닌 항목을 썼으면 "다른 계정 PAT 로 바꾸시겠습니까?" 다음의 항목 이름 질문 기본값도 그 이름이 되도록)
    [ -n "${BW_GH_ITEM:-}" ] && export BW_DEFAULT_PAT_ITEM="$BW_GH_ITEM"
    # Windows install.ps1 이 이어지는 설치 단계에 넘기도록 결정(1줄: y/n)과 항목 이름(2줄, 없으면 빈 줄)을 파일로 돌려줌
    if [ -n "${DT2_KEEP_ACCOUNT_OUT:-}" ]; then
        printf '%s\n%s\n' "$KEEP" "${BW_GH_ITEM:-}" >"$DT2_KEEP_ACCOUNT_OUT" 2>/dev/null || print_warn "계정 사용 결정을 기록하지 못했습니다: $DT2_KEEP_ACCOUNT_OUT"
    fi
    return 0
}

# ── --ai: AI 에이전트 CLI + AI 공통 설정만 실행 ──────────────────────────────────
# 받은 저장소의 설치 단계 스크립트 두 개를 그대로 씁니다(설치 때와 같은 코드 — 여기서 따로 구현하지 않음).
_run_ai_setup() {
    local _dev="$DT2_DIR/scripts/linux/dev-env" _f
    for _f in tool.setup-agents.sh tool.setup-agent-notes.sh; do
        [ -f "$_dev/$_f" ] || _die "$_dev/$_f 이 없습니다 (저장소가 예전 버전인지 확인하세요)."
    done
    DEVTOOLS2="$DT2_DIR" bash "$_dev/tool.setup-agents.sh" || print_warn "AI 에이전트 CLI 단계에서 오류가 있었습니다. 계속합니다."
    DEVTOOLS2="$DT2_DIR" bash "$_dev/tool.setup-agent-notes.sh" --now || _die "AI 공통 설정(agent-notes)에 실패했습니다."
    echo ""
    print_done "AI 로 고칠 준비를 마쳤습니다 (전체 설치는 실행하지 않음)."
    print_info "새 터미널(또는 'exec bash -l')에서: cd $DT2_DIR && claude   — 고친 뒤 설치를 다시 실행하세요."
}

main() {
    if [ "${1:-}" = "--ai" ]; then
        AI_ONLY=1
        shift
    fi
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
    if [ "$AI_ONLY" = 1 ]; then
        print_banner "DevTools2 — AI 로 고치기 위한 준비 (--ai)"
    else
        print_banner "DevTools2 설치 시작"
    fi
    _need_commands
    _ask_keep_account
    _prepare_account
    _sync_repo

    local _setup="$DT2_DIR/scripts/linux/setup-devtools2.sh"
    [ -f "$_setup" ] || _die "$_setup 이 없습니다."
    _cleanup
    trap - EXIT INT TERM HUP
    _hand_off_account
    if [ "$AI_ONLY" = 1 ]; then
        _run_ai_setup
        return 0
    fi
    if [ "${DT2_SETUP_CLONE_ONLY:-0}" = 1 ]; then
        print_done "DevTools2 저장소 준비를 마쳤습니다 (DT2_SETUP_CLONE_ONLY=1 — 설치 단계는 실행하지 않음)."
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
