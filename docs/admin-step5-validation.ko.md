# 5단계 검증 범위 — 0.8.0

2026-09-21, Windows x64 / Docker Desktop Linux AMD64 / Mattermost 11.11.0 / Bot Control 0.6.2.

## 이 PC에서 확인한 통합 경로

`tests/Run-AdminDockerE2E.ps1 -Apply -WithBotControl -WithBots -WithNetwork`:

- 별도 임시 Mattermost/DB 생성, 관리자·팀·채널·플러그인·봇 토큰 준비.
- 서버 공유를 실제 이 PC의 NetBird IPv4에 추가하고 localhost 유지. wildcard 바인딩 없음, SiteURL 변경 확인.
- 사용자 코드의 실제 봇 토큰·역할·채널 멤버십·Bot Control 접근 검사 통과.
- 사용자 등록 코드 → 실제 Mattermost 플러그인 → 인증된 Dashboard **테스트 모형** 왕복 확인.
- 이름·역할 SOUL 내용, 멘션 조건·답변 모드 환경값, 해당 프로필 활성 세션 정리, Gateway 재시작 API 요청 확인.
- 공유 해제 후 localhost 복구 및 원래 메시지·봇 토큰 유지.
- 임시 서버·volume·Dashboard 모형·인증 파일 정리. 기존 로컬/GB10/개인 Hermes에는 적용하지 않음.

## 자동 검사

- 기존 설치/보안/CLI/GUI/관리자/봇 테스트.
- 공유 주소 검증, compose 변조 거부, 두 승인된 상태에서 전환 복구, 공유 실패 롤백, 공유/해제 재시도.
- 사용자 연결의 사람/관리자 토큰 거부, 잘못된 채널과 누락된 Bot Control 조기 차단, 리디렉션 차단 및 원격 오류 비밀 반사 방지.
- 관리자/사용자 배포 ZIP의 역할별 실행 파일·해시·파일 허용 목록과 압축 해제 후 GUI 로드.

실행 결과(모두 통과): Windows PowerShell 5.1 기존 핵심 188, 보안 30, CLI 37, GUI 7, Dashboard 4, Desktop 45, 관리자 60, 봇 48, 네트워크 28, 사용자 연결 24, 배포 17개 검사. 별도로 33개 PowerShell 파일 구문·BOM 검사와 저장소 파일 위생 검사, 실제 Docker 준비 확인을 사용하는 관리자 GUI 검사를 통과했다. PowerShell 7에서는 관리자 60·봇 48·네트워크 28·사용자 연결 24개를 다시 확인했다.

CI에도 새 검사를 등록했다. 이는 로컬 실행 결과이며, 아직 GitHub에 올리거나 원격 CI 실행 결과를 확인한 것은 아니다. 배포 ZIP 두 번 생성 시 각각 동일한 SHA-256을 확인했다. 테스트가 만든 임시 서버·저장소만 제거했고 다운로드한 Docker 이미지는 캐시로 남겼다.

## 아직 실제로 확인하지 않은 항목

- 다른 Windows PC에서 처음부터 Hermes·Desktop을 설치하는 전체 실행.
- 실제 사용자 OAuth 승인과 그 PC의 UAC, 부팅 작업 동작.
- 실제 Hermes·LLM이 일반 채널/스레드/무멘션 메시지에 요구대로 응답하는지.
- 두 PC 재부팅 후 연결 유지, 실제 NetBird 접근 정책·방화벽 조합.

다른 PC 테스트는 사용자가 준비된 뒤 [체크리스트](two-pc-checklist.ko.md)로 진행한다. 같은 PC API 계약 통과를 원격 실사용 검증으로 간주하지 않는다. GitHub 게시, 기존 GB10 변경, 운영 Linux 배포, 자동 DB 백업·복원 UI는 이번 변경에 포함하지 않는다.
