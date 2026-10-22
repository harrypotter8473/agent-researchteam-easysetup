# 보안 정책 — NST 0.20.0

## NST 연구팀과 데이터

- 단일 NST 연구 마법사는 loopback 연구 서버만 구성합니다. 개인 Hermes·인증·다른 서버를 삭제하거나 인수하지 않습니다.
- 네 활성 일반 봇·채널 멤버십·요청자와 Hermes/모델 연결을 검사합니다. 재설정은 현재 Windows 사용자가 소유한 마법사 프로필·예약 작업에만 허용합니다.
- 입력과 발급 토큰은 DPAPI CurrentUser를 사용합니다. 기존 암호화 계약을 유지합니다. 프로필 .env, 서비스의 비공개 설정과 실행 중 메모리는 같은 사용자/PC 관리자가 읽을 수 있으므로 공유 폴더에 두지 않습니다.
- Git 작업 보드가 버전별 중간·최종 감사, 변경본 재감사·근거·전달 검사를 강제합니다. 프롬프트만으로 승인하지 않습니다. 다만 같은 Windows 사용자로 실행되는 도구에 대한 악성 코드/OS 샌드박스 격리를 보장하지는 않습니다.
- 총괄과 역할 실행기는 로그인 시 예약 작업으로 실행됩니다. 로그인 전 실행과 Docker Desktop 자동 시작을 보장하지 않습니다.
- 실제 현재 설치의 S1/S2/S3, 독립 감사, 최종 파일과 실제 첨부 재다운로드 확인 전에는 사용 준비 완료로 표시하지 않습니다. 무료 모의 테스트는 실모델 성공 증거가 아닙니다.
- NST/한국어 보드 플러그인은 고정 크기·SHA-256으로 검사합니다. 로그인·허용 사람·연구 채널 권한을 확인하며 브라우저에 연결 비밀값·봇/모델 키를 보내지 않습니다. 적용 뒤 업로드를 잠그며 진행 중 연구가 있으면 서버를 재시작하지 않습니다.
- 구형 Bot Control, 개인 Dashboard의 공개 기본 암호, Mattermost Desktop 설치 기능은 이 버전에 없습니다. 기존 설치된 프로그램을 제거하는 작업도 하지 않습니다.

## 연구 서버·봇 구성

- Docker Desktop의 고정된 로컬 Linux named pipe와 공식 이미지 digest만 사용합니다. 외부 Docker context는 사용하지 않습니다.
- 웹 포트는 기본 loopback만 허용합니다. 명시적으로 NetBird 공유를 선택하면 공식 로컬 클라이언트 상태와 활성 인터페이스에서 확인한 NetBird IPv4 한 개에만 추가로 바인딩합니다. wildcard/LAN/공인 IP와 DB 포트는 공개하지 않습니다. 공개 가입·플러그인은 초기 비활성화합니다.
- 최초 계정을 생성한 후 서버가 부여한 `system_admin` 역할을 확인합니다. 기존 계정의 권한 승격은 하지 않습니다.
- 입력된 관리자 암호는 DPAPI 임시 전송 후 제거하며, CLI 인수·설정 JSON·로그에는 넣지 않습니다. 세션 토큰은 메모리에서만 사용하고 로그아웃합니다.
- DB 암호는 DPAPI 파일에 보관하지만 실행 중인 컨테이너 환경에는 존재합니다. Docker 관리 권한자는 해당 값과 데이터에 접근할 수 있습니다.
- 재실행은 저장된 배포 identity·입력·이미지 pin·리소스 라벨이 일치해야 합니다. 변경된 compose 파일이나 다른 배포의 데이터를 덮어쓰지 않습니다.
- 봇 발급은 기존 배포·리소스·관리자 ID를 검증한 뒤 수행합니다. 기존 사람/다른 봇을 인수하지 않고, 생성 마커·소유자·일반 역할을 확인합니다. 봇에게 시스템/팀/채널 관리자나 추가 역할을 주지 않습니다. 기본 공개 채널 등 Mattermost의 일반 멤버 접근 범위까지 제거하는 채널 격리 기능은 아닙니다.
- 봇 생성 기능은 요청 중에만 열고 `finally`에서 닫습니다. 강제 종료로 정리가 중단되면 다음 관리자 서버 설정/봇 발급 시 남은 기록을 닫습니다. 재실행 전까지 기능이 열려 있을 수 있으나 서버 권한 검사는 유지됩니다. 확인 대상은 이 마법사가 만든 기본 역할입니다. 임의의 커스텀 권한 체계를 전역 감사·강제 수정하지 않습니다.
- 토큰은 현재 Windows 사용자 DPAPI 파일에 원자적으로 저장하며 JSON 상태·CLI 인수·stdout/stderr·진행 로그에 포함하지 않습니다. 서버 발급 성공 후 저장 전에 중단되면 중복 토큰을 만들지 않고 관리자 확인을 요구합니다. 자동 폐기/재발급은 하지 않습니다.
- 토큰 복사는 사용자가 버튼을 눌러야 하며 원문을 화면에 표시하지 않습니다. 같은 클립보드 값은 60초 후 또는 종료 시 비우지만 OS/서드파티 클립보드 기록·동기화를 삭제하지는 못합니다. PC 사용자 권한을 가진 프로세스로부터 토큰을 격리하는 기능은 아닙니다.
- 공유 실패 시 알려진 이전 Compose/공개 범위로 롤백합니다. 중단된 전환은 두 승인된 상태와 일치할 때만 복구하며 NetBird ACL·Windows 방화벽은 변경하지 않습니다. 이 PC의 ping 성공이 다른 PC 접근 성공을 뜻하지 않습니다.
- 배포 ZIP은 파일 허용 목록으로 만들며 개인 상태·인증·로그·백업·Git 이력을 포함하지 않습니다. SHA-256은 파일 무결성 확인용이지 코드 서명이나 게시자 인증이 아닙니다.
- 운영 Linux/GB10 배포, TLS 인증서, 자동 DB 백업·데이터 복원·삭제 UI는 이 단계의 제공 범위가 아닙니다. Windows Docker Desktop 버전은 테스트·개발 배포입니다.

## 지원 버전

| 버전 | 보안 수정 |
|---|---|
| `0.20.0` 프리릴리스 | 현재 검증 범위만 지원 |
| 이전 개발 버전 | 현 검증 범위 확인 후 갱신 |
| unreleased source snapshot | 보장 없음 |

검증된 Hermes pin에 문제가 확인되면 해당 wizard release를 철회하고 새 pin과 체크섬을 배포합니다. 자동 업데이트는 하지 않습니다.

## 보안 문제 제보

토큰, API 키, `.env`, 세션, 전체 로그를 공개 이슈에 올리지 마세요. 공개 후 [GitHub Private Vulnerability Reporting](https://github.com/harrypotter8473/agent-researchteam-easysetup/security/advisories/new)을 활성화해 기본 비공개 신고 채널로 사용합니다. 기능이 아직 열려 있지 않다면 비밀을 제외한 최소 정보만으로 공개 이슈를 만들고 비공개 전달 방법을 요청해 주세요.

진단 ZIP은 자동 업로드되지 않습니다. 공유하기 전 직접 내용을 확인하고, 전달이 끝나면 원본 ZIP을 삭제하세요.

## 신뢰하는 것

- release 체크섬과 일치하는 이 저장소의 PowerShell 코드 및 고정 설정
- 고정된 `NousResearch/hermes-agent` annotated tag 객체와 peeled commit
- 해당 commit tree의 `scripts/install.ps1` Git blob, 크기와 SHA-256
- 검토된 stage protocol v1 manifest
- 유효한 Microsoft Authenticode 서명의 정확한 System32 Windows PowerShell
- 유효한 Johannes Schindelin Authenticode 서명의 Program Files Git for Windows

## 신뢰하지 않고 검증하는 것

- 네트워크 응답과 리디렉션
- 기존 설치기 캐시와 상태 파일
- 기존 설치 디렉터리, Git origin, checkout과 reparse point
- 공식 설치기의 protocol/manifest 및 stage JSON 출력
- PATH의 `hermes`나 `powershell.exe`
- 사용자가 지정한 mutable 경로
- 새 clone의 사용자 global Git 줄바꿈 설정과 command parameter 주입
- 상류 설치기가 다시 읽는 User/Machine registry PATH의 명령 순서, ambient PATHEXT와 사용자 PowerShell module 경로
- 기존 launcher attestation과 RuntimeRoot 상태

검증 실패 시 설치는 계속 진행하지 않습니다. 사용자 승인 계획 지문은 첫 변경 직전에 다시 확인하고, 설치기는 protocol/manifest와 매 stage 실행 직전에 재해시합니다.

새 설치의 `repository` 단계는 RuntimeRoot 아래 예측 불가능한 UTF-8 no-BOM managed global 설정과 빈 attributes/excludes 파일을 `CreateNew`로 만들고 `core.autocrlf=false`를 clone 전에 적용합니다. fresh clone에서는 system Git 설정과 표준 네트워크 환경을 유지하지만 user global은 읽지 않습니다. 기존/재개 checkout의 모든 stage와 정적 검증은 managed global을 별도로 만들고 system 설정도 끕니다. 모든 모드에서 Git redirect/UI/trace 환경을 제거하고 `GIT_CONFIG_COUNT=2`로 `core.hooksPath=NUL`, `core.fsmonitor=false`를 고정하며, PATHEXT는 `.COM;.EXE;.BAT;.CMD`, PSModulePath는 System32 module로 제한합니다.

공식 설치기는 각 stage 시작 시 registry User+Machine PATH로 process PATH를 덮어씁니다. 따라서 설치 시작 전과 매 stage 직전에 그 PATH를 파일 I/O로 순서대로 해석해 첫 `git` 후보가 정확한 서명된 Program Files `git.exe`인지 확인합니다. 경쟁 `git.com/.bat/.cmd/.ps1`, 빈·잘못된 PATH 항목은 실패-폐쇄되며, 이 검사를 통과하지 못하면 상류 프로세스를 시작하지 않습니다.

fresh repository 직후에는 exact HEAD/origin, clean status, 빈 active local exclude와 non-reparse 경로를 in-memory proof로 묶습니다. path 직전에 proof와 launcher 원본을 다시 확인하고, 대응 `venv\Scripts` 파일과 길이·SHA-256이 같고 유효한 bounded PE 헤더를 가진 exact `bin/hermes.exe`/`hermes-acp.exe` 두 개만 `.git/info/exclude`에 CAS 방식으로 등록합니다.

그 직후 RuntimeRoot의 `state\launcher-attestation-v1.json`을 strict UTF-8 canonical JSON으로 한 번만 발행합니다. schema, contract, HermesHome/InstallDir/RuntimeRoot path binding SHA-256, peeled commit, 설치기 SHA-256, 두 launcher 이름·길이·SHA-256을 묶으며 기존 파일은 바이트가 완전히 같은 경우 외에는 교체하지 않습니다. 기존/재개 checkout은 이 attestation과 전체 정적 provenance가 이미 맞는 경우만 읽기 전용으로 허용합니다. 일반 caught failure는 이번 실행이 쓴 attestation을 제거하므로, 재개는 attestation과 동일 checkpoint가 남은 제한적 비정상 종료에만 가능합니다.

repository-aware Git 전에 raw `.git/config`의 exact allowlist(상류의 단일 `windows.appendAtomically=false` 포함)를 적용하고 `commondir`, `config.worktree`, active `.git/info/attributes`, object alternates를 거부합니다. 그 뒤에만 격리된 서명 Git으로 raw origin, top-level/absolute git-dir, expected HEAD/index tree, index flags, gitlink 부재와 clean status를 검사합니다. Hermes 실행 직전 launcher와 attestation을 다시 확인합니다.

path snapshot 뒤 후속 stage 또는 최종 Verify가 실패하면 PATH/HERMES_HOME 복구, launcher exclude CAS 복원, exact fresh launcher 삭제, 이번 실행 attestation 삭제를 서로 독립된 best-effort 작업으로 수행해 한 복구 실패가 나머지를 막지 않게 합니다. 이는 checkout, venv, dependencies와 실패 checkpoint 전체를 되돌리는 트랜잭션이나 제거 기능은 아닙니다.

## 보장 범위 밖

- v0.1.2의 선택적 Browser/TUI npm 의존성 설치, Computer Use 사전 설치와 Hermes Desktop 자동 빌드
- DOS 8.3 짧은 경로 표기 지원(긴 절대 경로를 사용해야 함)
- 공식 설치기가 받는 모든 전이 의존성의 완전한 고정·재현 빌드
- launcher attestation 바깥의 전체 venv·Python/Node 패키지 진위
- 같은 사용자 권한으로 동시에 실행되는 악성 프로세스가 만드는 모든 로컬 TOCTOU 공격
- 같은 사용자 권한으로 RuntimeRoot와 InstallDir을 함께 수정해 launcher와 서명/MAC 없는 attestation을 다시 쓰는 지속적 로컬 위조
- Windows 자체, GitHub, 패키지 registry 또는 upstream Hermes의 compromise
- 코드 서명되지 않은 이 마법사 소스의 publisher identity
- regex/best-effort 정제가 모든 종류의 새 비밀 형식을 제거한다는 보장
- 사용자가 공식 설정 화면에 직접 입력한 공급자 자격증명의 저장·검증·관리
- 공식 setup 프로세스의 종료 코드 0 또는 창 닫힘만으로 공급자 구성이 완료되었다고 증명하는 것
- repository clone 중 user-global에만 정의된 기업 프록시, 사설 CA 또는 credential helper
- Program Files에 공식 Git for Windows가 없는 환경의 자동 Git 부트스트랩

이 프로젝트는 검토된 공식 설치기를 감싸는 안전 장치이지 독립적인 Hermes 배포판이 아닙니다.

## 사용자 데이터와 진단

마법사는 개인 .env·인증·세션·메모리를 수집하거나 삭제하지 않습니다. 선택한 모델에는 사용자가 동의한 연구 자료가 전송될 수 있습니다.
봇/모델 키와 DPAPI 파일은 공개 이슈나 로그에 넣지 마세요. 진단 번들은 사전 점검·고정 소스 요약과 정제된 마법사 상태·로그만 허용 목록으로 포함하며 자동 업로드되지 않습니다.
같은 Windows 사용자나 Docker 관리자는 실행 중인 인증값과 서버 데이터에 접근할 수 있습니다.

## 소스 고정 및 대응

릴리스 태그만 바꾸는 변경은 허용하지 않습니다. annotated tag object, peeled commit, commit tree의 Git blob, 정확한 바이트 크기, SHA-256, protocol과 전체 manifest를 함께 검토해야 합니다.

보안 문제가 확인되면 다음 순서로 대응합니다.

1. 영향받은 wizard와 Hermes pin 범위를 판정합니다.
2. 필요하면 release 다운로드와 pin을 철회합니다.
3. 수정 pin/코드와 새 체크섬을 배포합니다.
4. 공개 advisory에 영향, 완화책과 업데이트 버전을 기록합니다.

세부 갱신 절차는 `docs/updating-the-pin.md`에 있습니다.
