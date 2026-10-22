# NST 연구팀 구조 (0.20.0)

진입점은 Start-HermesResearchSetup.cmd 하나입니다. 별도 사용자·관리자 GUI는 없습니다.

1. 로컬 서버: 공식 Docker Desktop과 고정 Mattermost/PostgreSQL 이미지, 배포 소유권, 최초 관리자·팀·채널을 검사·구성합니다.
2. Hermes·모델: 고정 공식 설치 또는 기존 신뢰 설치를 확인하고 Codex 인증/모델을 선택합니다.
3. 연구팀: 한 버튼으로 네 봇·토큰, 전체 페르소나, 전용 프로필/실행기, 한국어 보드·NST를 구성하고 실제 S1/S2/S3을 검사합니다.

GUI는 명시적 동의를 받은 뒤 별도 PowerShell CLI worker를 실행합니다. 관리자 비밀번호·토큰·키는 DPAPI 입력 파일로 전달하며 로그에 넣지 않습니다.
Admin.psm1/AdminBots.ps1은 별도 제품 화면이 아니라 이 연구 마법사의 서버·봇 공용 백엔드입니다.
Input.psm1은 기존 DPAPI 계약만 유지하며, 제거된 개인 Lab 프로필·Dashboard·주간 업데이트를 실행하지 않습니다.

## 연구 실행

- 사용자의 멘션을 총괄이 받고 Git 작업 보드에 작업·요구·의존성을 기록합니다.
- 조사·분석·감사 실행기가 역할 작업을 가져갑니다. 총괄은 결과 이벤트를 보고 후속 조사·수정·감사와 사용자 질문을 결정합니다.
- 감사자는 Git 이력과 작성자 작업환경이 없는 별도 사본을 검수합니다. 현재 파일·요구·근거 버전의 통과만 후속 사용/최종 전달을 허용합니다.
- 봇 간 Mattermost 대화로 작업을 넘기지 않습니다. 서비스가 역할 토큰을 보관하고 주요 보고만 같은 스레드에 게시합니다.
- 보드는 실제 저장 문서와 행동 기록을 보여 주는 읽기 전용 화면입니다. 승인이나 감사 판정을 우회하지 않습니다.
- Codex 직접 연결은 공개 자료용이며, LiteLLM은 설정된 공개 등급에 따라 클라우드/로컬을 분리합니다.

소스 team/ 전체·해시·페르소나·실행 한도와 두 NST/보드 플러그인 패키지는 이번 코드 정리에서 바꾸지 않았습니다.
소스 복사본을 검사하는 동안 현재 설치된 연구팀은 교체하거나 재시작하지 않습니다.

## 모듈

| 구성 | 책임 |
| --- | --- |
| HermesResearchSetup.Gui.ps1 / ui/ResearchWindow.xaml | 단일 3단계 NST 마법사, 원클릭 기본 구성, 동의·상태·실제 검증 결과 |
| HermesEasySetup.ps1 / Loader.psm1 | 명시된 연구·설치·진단 worker와 모듈 로딩 |
| Admin.psm1 / AdminBots.ps1 / AdminNetwork.ps1 | 소유 서버·관리자·일반 봇/토큰, 안전한 Compose 및 기존 공개 범위 기록 검증 |
| Input.psm1 | 기존 서버/봇/마법사 입력의 DPAPI CurrentUser 호환 |
| Research*.psm1 / Research*.ps1 | 네 역할·모델 계약·프로필 격리·설치·마이그레이션·준비 판정·NST 플러그인 |
| Core / Preflight / StateStore / Execution / Protocol / InstallEngine / Existing / Codex | 공식 설치 무결성·승인·기존 설치·인증·복구 안전 경계 |
| Docker.psm1 / Bundle.psm1 | 검증된 Docker 준비·승인된 다운로드와 비밀값을 제외한 진단 ZIP |
| team/ | Git 작업 보드·독립 실행기·총괄 후속 판단·강제 감사·근거·모델 라우터·실제 설치 테스트 |
| plugins/ / assets/mattermost-plugins/ | 읽기 전용 Mattermost 한국어 작업보드·NST 브랜딩과 검증 패키지 |

## 승인과 freshness

`Plan`은 읽기 전용입니다. 지문에는 tag object, peeled commit, raw/API URL, blob과 SHA-256, protocol, manifest 파일 SHA-256, 세 mutable 경로와 모든 옵션이 들어갑니다.

CLI `Install`은 `-Apply`가 없으면 종료 코드 2로 중단됩니다. GUI는 기본 해제된 승인 체크박스를 사용하며 승인 지문을 worker에 전달합니다. worker는 첫 runtime mutation 전 지문을 확인하고, protocol/manifest를 읽은 뒤 첫 Hermes 변경 직전에 다시 계산합니다.

## 경로와 기존 설치

v1은 `InstallDir == HermesHome\hermes-agent`를 강제합니다. RuntimeRoot는 두 Hermes 경로와 서로 포함될 수 없습니다. drive root, 사용자 프로필 전체, Windows 폴더, UNC/device, wildcard, DOS 8.3 짧은 경로와 기존 reparse 경로를 거부합니다.

비어 있지 않은 InstallDir은 임의로 채택하지 않습니다. 오직 `-Resume`, 동일 계획/manifest의 resumable checkpoint, launcher attestation v1과 전체 `StaticProvenanceValid`가 모두 맞는 동일 wizard 실행 경계만 읽기 전용으로 받아들입니다. 그 밖의 legacy/foreign checkout은 공식 origin이어도 새 빈 InstallDir을 요구합니다. PATH의 다른 `hermes`는 진단·검증·설정에 사용하지 않습니다.

## 공급망 경계

`config/hermes-source.json`은 annotated tag object SHA와 peeled commit SHA를 구분합니다. 또한 raw URL, API blob URL, Git blob SHA, 정확한 크기, SHA-256과 protocol을 고정합니다. 네트워크 상류 스모크는 tag→commit→tree blob 연결까지 확인합니다.

다운로드 파일과 캐시는 크기·SHA와 PowerShell AST를 검사합니다. 같은 파일을 protocol/manifest 및 각 stage 실행 직전에 다시 검사합니다. 공식 manifest는 단계 순서, category와 `needs_user_input`을 포함해 `config/hermes-manifest.json`과 비교합니다.

## 단계 실행과 재개

각 자동 단계는 새 signed Windows PowerShell 프로세스에서 `-Stage`, `-Commit`, `-HermesHome`, `-InstallDir`, `-SkipSetup`, `-NonInteractive`, `-Json`으로 실행됩니다. stdout/stderr는 stream별 4 MiB로 제한하고 마지막 유효 JSON frame을 스키마 검증합니다.

설치 시작 전과 매 stage 직전에 registry User PATH 다음 Machine PATH를 순서대로 해석해 첫 `git` 명령이 서명된 Program Files `git.exe`와 정확히 일치하는지 확인합니다. 상류 `Sync-EnvPath`가 child process PATH prefix를 덮어쓰기 때문에 이 registry 검사가 필요합니다. child에는 `PATHEXT=.COM;.EXE;.BAT;.CMD`, System32-only PSModulePath, `core.hooksPath=NUL`, `core.fsmonitor=false`를 전달하고 Git redirect/UI/trace 환경을 제거합니다.

fresh `repository`는 RuntimeRoot의 예측 불가능한 managed global 설정과 빈 attributes/excludes를 `CreateNew`로 만들고 LF checkout을 선행합니다. fresh mode는 system Git 설정을 유지합니다. 기존/재개 stage와 정적 verification은 별도 managed global을 쓰고 system 설정까지 끕니다. 세 모드 모두 user global 파일을 읽거나 수정하지 않으며 일회성 파일은 stage 뒤 제거합니다.

v0.1.2는 core CLI stage만 실행하고 `-SkipComputerUse`를 강제합니다. 선택적 Browser/TUI npm 설치인 `node-deps`는 child process를 만들기 전에 정책상 `Skipped`로 기록하며, Computer Use 사전 설치와 Desktop stage는 후속 버전까지 설치 진입 전에 거부합니다. 실행되는 일반 stage 제한은 30분, dependencies/platform-sdks는 90분입니다. timeout이면 정확한 System32 `taskkill.exe /T /F`로 해당 프로세스 트리를 정리합니다. path snapshot 이후 caught failure는 PATH/HERMES_HOME, 이번 exclude write, exact launcher와 attestation을 독립적으로 compare/CAS 복구하지만 checkout·venv·dependencies·실패 state 전체를 원복하지는 않습니다.

`-Resume`은 schema, Running/Failed 상태, 계획 지문, manifest와 launcher attestation v1의 전체 정적 provenance가 모두 같은 경우만 허용됩니다. 이전 success 기록은 재개하지 않습니다. fresh in-memory proof는 상태 파일에 저장하지 않고 정상 caught failure는 새 attestation도 제거하므로, attestation 발급 뒤 비정상 종료로 두 기록이 함께 남은 제한된 경우만 모든 자동 단계를 Pending으로 되돌려 공식 idempotent stage를 다시 적용합니다. `configure`와 `gateway`는 별도 대화형 설정으로 넘깁니다.

## 최종 provenance 검증

성공에는 다음이 모두 필요합니다.

- `bin`에 exact `hermes.exe`/`hermes-acp.exe` 두 파일만 있고 대응 `venv\Scripts` launcher와 길이·SHA-256이 일치하며 DOS/PE 헤더가 구조적으로 유효
- `.git/info/exclude`의 active 패턴이 exact 두 launcher뿐이며 예상 밖 `bin` 파일은 숨기지 않음
- canonical `state\launcher-attestation-v1.json`의 path binding, peeled commit, installer digest와 두 launcher record가 현재 파일과 일치
- `venv\Scripts\python.exe`가 non-reparse 일반 PE 파일로 존재
- `.git` checkout과 서명된 Program Files Git 존재
- repository-aware Git 전에 raw `.git/config` exact allowlist, redirect 파일, active info attributes와 alternates 검사를 통과
- raw local origin이 정확히 하나의 공식 HTTPS/SSH 값이며 top-level과 absolute git-dir가 예상 경로와 일치
- HEAD와 index tree가 peeled pin tree와 일치하고 assume-unchanged/skip-worktree/gitlink가 없음
- 격리된 Git status가 clean
- bounded strict UTF-8 `.hermes-bootstrap-complete` schema 1과 pinnedCommit 일치
- 위 정적 조건과 launcher/attestation 즉시 재검사를 모두 통과한 뒤에만 절대경로 `bin\hermes.exe --version` 실행

attestation은 fresh same-run proof가 만든 연속성 기록이지만 서명/MAC은 아닙니다. 같은 사용자 권한이 RuntimeRoot와 InstallDir을 함께 수정하는 위조와 전체 venv·전이 dependency 진위는 이 모델 밖입니다.

`hermes doctor`는 공급자 설정 전 경고가 날 수 있어 기록하되, 위 provenance 검증과 분리합니다.

## 데이터와 진단

```text
%LOCALAPPDATA%\hermes                       Hermes 데이터와 설치
%LOCALAPPDATA%\HermesEasySetup\cache        검증된 설치기
%LOCALAPPDATA%\HermesEasySetup\logs         정제 로그
%LOCALAPPDATA%\HermesEasySetup\state        체크포인트
%LOCALAPPDATA%\HermesEasySetup\diagnostics  로컬 ZIP
```

진단 ZIP은 Hermes 홈을 순회하지 않습니다. 마법사가 생성한 허용 목록 파일만 복사하고 토큰과 알려진 로컬 경로를 다시 정제합니다.
