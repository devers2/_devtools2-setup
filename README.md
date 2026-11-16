# _devtools2-setup

개인 개발 환경 [DevTools2](https://github.com/devers2/_devtools2)(비공개)를 설치하는 **공개 시작 저장소**입니다.
Bitwarden 에 저장한 GitHub 계정으로 비공개 저장소를 받은 뒤, 그 안의 설치 스크립트를 실행합니다.

## 설치

WSL·리눅스:

```bash
curl -fsSL https://raw.githubusercontent.com/devers2/_devtools2-setup/main/install.sh | bash
```

설치 중 한 번 묻습니다.

```
👉 설치에 사용할 Bitwarden/GitHub 계정을 현재 PC 에서 사용하시겠습니까? [y/n]
   y: 이 PC 에 Bitwarden 로그인과 GitHub 계정 정보(PAT·gh 로그인)를 저장합니다.
   n: 일회성 설치 — 설치에만 사용하고, 끝나면 이 PC 에 계정 정보를 남기지 않습니다.
```

- **y**: 본인 PC. 이미 GitHub 로그인(`~/.git-credentials`)이 있으면 Bitwarden 없이 그대로 씁니다.
- **n**: 남의 PC 에 설치해 주거나, 예전에 설치해 준 PC 를 업데이트할 때. Bitwarden 은 임시 폴더에서만 쓰고
  GitHub PAT 는 저장소를 받는 데만 메모리로 쓴 뒤 지웁니다. 이 PC 의 기존 Bitwarden·GitHub 로그인은 건드리지 않습니다.
- 묻지 않으려면 `DT2_KEEP_ACCOUNT=y` 또는 `n` 을 지정합니다.

## 구성

| 경로 | 내용 |
|---|---|
| `install.sh` | 시작 스크립트 (WSL·리눅스) |
| `lib/ui-lib` | 색·출력·질문 공용 함수 — _devtools2 의 `_common.sh` 도 이 파일을 씀 |
| `lib/bw-lib` | Bitwarden 공용 라이브러리 — _devtools2 의 `scripts/fzf/bw-lib` 이 이 파일을 가리킴 |
| `tests/run-tests.sh` | 시험 (sudo·Bitwarden 계정 없이 실행) |

`lib/` 의 원본은 이 저장소 하나입니다. _devtools2 는 이 저장소를 submodule 로 불러 씁니다.
