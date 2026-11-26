# _devtools2-setup

개인 개발 환경 [DevTools2](https://github.com/devershq/_devtools2)(비공개)를 설치하는 **공개 시작 저장소**입니다.
Bitwarden 에 저장한 GitHub 계정으로 비공개 저장소를 받은 뒤, 그 안의 설치 스크립트를 실행합니다.

## 설치

Windows (WSL 까지 한 번에 — Windows PowerShell 에서):

```powershell
irm https://raw.githubusercontent.com/devershq/_devtools2-setup/main/install.ps1 | iex
```

WSL·리눅스:

```bash
curl -fsSL https://raw.githubusercontent.com/devershq/_devtools2-setup/main/install.sh | bash
```

설치 스크립트가 중간에 실패했을 때 (내 PC — AI 로 바로 고치기):

```bash
curl -fsSL https://raw.githubusercontent.com/devershq/_devtools2-setup/main/install.sh | bash -s -- --ai
```

전체 설치 대신 계정 확인 → DevTools2 받기 → AI 에이전트 CLI 설치 → AI 공통 설정(agent-notes 받기·규칙 적용)까지만 하고 끝냅니다.
그 뒤 `cd /var/opt/_devtools2 && claude` 로 고치고 설치를 다시 실행합니다. Windows 는 `wsl -d devtools2` 로 들어가 같은 명령을 실행합니다.
비공개 작업 노트를 받으므로 **내 계정일 때만** 동작합니다(일회성·다른 사람의 계정이면 아무것도 하지 않고 끝남).

다시 실행하면 이미 된 단계는 건너뛰고 DevTools2 를 최신으로 맞춘 뒤 설치를 이어 갑니다(업데이트).

설치를 시작하면 먼저 이 PC 에 저장된 GitHub 계정을 확인합니다.

- **계정이 있고 DevTools2 저장소에 접근되면**: 묻지 않고 그 계정으로 진행합니다(어떤 계정으로 진행하는지 화면에 표시, 계정 설정은 바꾸지 않음).
- **계정은 있는데 접근이 안 되면** GitHub 에 물어 까닭을 나눕니다.
  - 다른 사람의 계정(PAT 는 유효하지만 저장소 권한 없음): `1) 일회성 설치` / `2) 중단`. 이 PC 의 계정은 건드리지 않습니다.
  - PAT 만료·폐기: `1) PAT 갱신`(내 PC — Bitwarden 의 새 PAT 를 저장, 기존 `~/.git-credentials` 는 백업) / `2) 일회성 설치` / `3) 중단`.
    저장된 이름이 Bitwarden·GitHub 계정과 모두 다르면(남의 계정일 수 있음) 바꾸기 전에 한 번 더 묻습니다.
  - GitHub 에 연결할 수 없으면 중단하고 네트워크를 확인하라고 알립니다.
- **계정이 없으면** 묻습니다.

```
👉 설치에 사용할 Bitwarden/GitHub 계정을 현재 PC 에서 사용하시겠습니까? [y/n]
   y: 이 PC 에 Bitwarden 로그인과 GitHub 계정 정보(PAT·gh 로그인)를 저장합니다.
   n: 일회성 설치 — 설치에만 사용하고, 끝나면 이 PC 에 계정 정보를 남기지 않습니다.
```

- **y**: 본인 PC. Bitwarden 에서 GitHub PAT 를 읽어 이 PC 에 저장합니다.
- **일회성(n)**: 남의 PC 에 설치해 주거나, 예전에 설치해 준 PC 를 업데이트할 때. Bitwarden 은 임시 폴더에서만 쓰고
  GitHub PAT 는 저장소를 받는 데만 메모리로 쓴 뒤 지웁니다. 이 PC 의 기존 Bitwarden·GitHub 로그인은 건드리지 않습니다.
- 계정 확인은 저장된 값을 읽기만 합니다(접근 확인이 실패해도 저장된 계정을 지우지 않음).
- 묻지 않으려면 `DT2_KEEP_ACCOUNT=y` 또는 `n` 을 지정합니다(n 은 저장된 계정이 접근되더라도 일회성 설치, y 는 PAT 만료면 갱신).
- 설치 Step 3 의 GitHub 로그인 연결(`bw_setup_github_auth` — 명령 팔레트 PR 체크아웃 등도 같음)은 PAT 가 이미 저장되어 있으면
  계정과 유효 여부를 보여 주고 `Bitwarden 의 PAT 로 변경하시겠습니까? (github.com-main) [y/N]` 만 묻습니다(괄호는 Bitwarden 항목 이름 — 기본값 또는 BW_DEFAULT_PAT_ITEM). N 이면 Bitwarden 없이 저장된 PAT 로 gh 만 로그인하고,
  PAT 가 만료됐으면 묻지 않고 Bitwarden 의 새 PAT 로 갱신합니다.

## 구성

| 경로 | 내용 |
|---|---|
| `install.ps1` | 시작 스크립트 (Windows) — 관리자 승격, WSL 기능·엔진, devtools2 배포판 만들기, WSL 안에서 `install.sh`(clone 까지), 이어서 clone 한 저장소의 Windows 설치 스크립트 실행 |
| `install.sh` | 시작 스크립트 (WSL·리눅스) — Bitwarden 로그인, `_devtools2` clone, 설치 스크립트 실행 |
| `lib/ui.ps1` | Windows 출력·질문·스피너·다운로드·관리자 승격 공용 함수 — _devtools2 의 `_common.ps1` 도 이 파일을 씀 |
| `lib/ui-lib` | 색·출력·질문 공용 함수 — _devtools2 의 `_common.sh` 도 이 파일을 씀 |
| `lib/bw-lib` | Bitwarden 공용 라이브러리 — _devtools2 의 `scripts/fzf/bw-lib` 이 이 파일을 가리킴 |
| `tests/run-tests.sh` | 시험 (sudo·Bitwarden 계정 없이 실행) |
| `s2-office-converter/` | s2-docflow 변환기 서버 설치 스크립트 — **원본은 비공개 s2-docflow 의 `scripts/`**, main 에 push 되면 그쪽 CI 가 여기로 복사합니다(여기서 고치지 않음) |

`lib/` 의 원본은 이 저장소 하나입니다. _devtools2 는 이 저장소를 submodule 로 불러 씁니다.

## s2-office-converter (서버 설치)

```bash
curl -fsSL https://raw.githubusercontent.com/devershq/_devtools2-setup/main/s2-office-converter/setup-s2-office-converter.sh | bash
```

사용법은 [s2-office-converter/README.md](s2-office-converter/README.md) 를 보십시오.
