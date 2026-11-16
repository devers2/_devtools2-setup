# AGENTS.md — _devtools2-setup 작업 규칙

1. **공개 저장소입니다.** 회사·고객 이름, 서버 주소, 계정, 비밀값을 넣지 않습니다. 그런 값이 필요한 코드는 비공개 _devtools2 에 둡니다.
2. 이 저장소에는 **로그인하기 전이거나 내 계정이 없는 기기에서 받아야 하는 것만** 둡니다(시작 스크립트와 그것이 쓰는 공용 라이브러리).
   Windows 는 Bitwarden 로그인이 WSL 안에서 일어나므로 WSL 엔진 설치·devtools2 배포판 만들기까지가 이 저장소(install.ps1)에 있습니다.
   그 뒤의 WSL 설정(.wslconfig 등)과 도구 설치는 비공개 _devtools2 가 맡습니다 — 같은 코드를 두 곳에 두지 않습니다.
3. `lib/` 는 _devtools2 가 submodule 로 씁니다. 함수 이름·인수·전역 변수를 바꾸면 _devtools2 쪽 호출도 함께 고치고,
   _devtools2 에서 submodule 이 가리키는 커밋을 올립니다.
4. 수정한 뒤에는 `bash tests/run-tests.sh` 를 통과시킵니다(네트워크 확인까지: `DT2_TEST_NETWORK=1`).
   새 동작이나 버그 수정에는 시험을 함께 추가하고, 일부러 망가뜨린 사본으로 시험이 실패를 잡는지 확인합니다.
5. 일회성 설치(`DT2_KEEP_ACCOUNT=n`)에서는 이 PC 에 계정 정보를 남기지 않는 것이 원칙입니다.
   PAT·Bitwarden 세션을 파일·명령 인자·git 설정에 쓰는 코드를 넣지 않습니다.
6. PowerShell 은 5.1·7 모두에서 동작해야 합니다: `??` 금지, `param()` 은 맨 위, 파일은 UTF-8 NoBOM 이고
   PS 5.1 이 NoBOM 한글 파일을 CP949 로 읽으므로 파일을 직접 실행하지 않고 UTF-8 로 읽어 스크립트블록으로 실행합니다(`Invoke-Dt2LocalScript`).
7. `s2-office-converter/` 는 s2-docflow CI 만 씁니다(원본은 비공개 s2-docflow 의 `scripts/`). 여기서 고치면 다음 복사 때 덮어써지므로
   고칠 내용은 s2-docflow 에서 고칩니다.
8. 주석·문서·커밋 메시지는 한국어로 씁니다.
