# NST Research Team Setup 0.22.3

Windows PC에 Mattermost·Hermes·총괄/조사/분석/감사 3+1 연구팀을 구성하는 NST 전용 마법사입니다.
한국어 작업보드와 NST 브랜딩을 Mattermost 안에 연결합니다.

## 실행

[저장소](https://github.com/harrypotter8473/agent-researchteam-easysetup)의 NST 연구팀 ZIP 전체를 새 폴더에 풀고 `Start-HermesResearchSetup.cmd`를 실행합니다.
순서는 **로컬 서버 → Hermes·모델 연결 → 기본설정 자동 구성·실제 설치 검증**입니다.
모델·웹 전송과 실제 검증 동의는 사용자가 확인하며, 네 봇·토큰·페르소나·실행기·보드는 한 버튼으로 구성합니다.

Mattermost에는 중요한 보고와 결과만 남기고, 왼쪽 **연구 작업보드**에서 프로젝트·작업·문서·감사·확인 요청·실시간 행동 기록을 봅니다.
사용자는 원하는 결과물만 요청합니다. 역할 배정과 후속 판단은 총괄이, 권한·버전별 감사·전달 검사는 프로그램이 담당합니다.

프로젝트는 사람이 읽기 쉬운 이름으로 표시합니다. 작은 네모 작업 카드는 **대기 / 진행 중 / 확인 필요 / 완료** 칸 사이를 상태에 따라 이동합니다.
카드 앞면에는 **분석 보고서**처럼 짧은 제목만 표시합니다. 클릭하면 요약·담당·현재 상태·감사·결과 파일과 상세 기록을 확인합니다.
실제 총괄 조치도 카드로 보이고 실무 과제·감사 승인과 구분됩니다. 활동은 담당별 연속 묶음과 이전 기록 조회,
문서는 화면 아래의 검색 가능한 폴더형 목록으로 정리합니다. 요약·화면 표시를 위한 추가 모델 호출은 없습니다.

작업 카드가 모두 완료되어도 필수 검증이 빠지면 총괄을 자동으로 깨워 누락 검사·변경 파일·반려 사유를 전달합니다.
담당자 수정 → 독립 재감사 → 영향받은 후속 결과 재검증을 거치며, 최종감사로 중간감사를 대신하지 않습니다.
실제 사용자 입력이 필요한 경우와 반복해도 진전이 없는 경우는 구체적인 사유와 기록 위치를 남깁니다.

## 유지한 기능

- 기존 3+1 전체 페르소나, Git 작업 보드와 독립 역할 실행기, 중간 결과에 따른 총괄 후속 판단.
- 독립 블라인드 감사, 통과한 버전만 후속 사용, 수정본 재감사, 최종 첨부 재다운로드 검증.
- 파일 기반 근거 재사용, 현재 모델·작업 폴더·도구·한도 설정과 기록 보존.
- 기존 Hermes/Codex 연결 및 LiteLLM의 공개/비공개 모델 분리 선택.
- 원클릭 기본설정과 실제 S1·S2·S3 증거에 따른 설치 완료 판정.

## NST 전용 정리

별도 사용자·관리자 화면, Mattermost Desktop 클라이언트 설치, 구형 Bot Control·개인 Lab/Dashboard 연결을 제거했습니다.
연구 마법사가 쓰는 서버 생성·봇 발급·DPAPI·소유권·보안 검사는 유지합니다.
단일 NST 연구팀 ZIP만 배포하며, 현재 설치된 서버·프로필·인증·기록을 자동 삭제하거나 변경하지 않습니다.

## 검증과 배포

현재는 **프리릴리스**입니다. 무료 회귀와 실제 모델·새 PC 설치 검증은 다릅니다.
0.21.2는 별도 프로필·기존 Mattermost의 새 검증 채널에서 실제 S1→S2→S3와 중간/최종 감사·총괄 첨부 해시 검증을 통과했습니다.
0.22.0도 새 ZIP 추출본으로 격리 실제 S1·중간/최종 감사·총괄 Word 첨부 해시 검증을 통과했습니다.
0.22.1의 작은 네모 칸반 카드·클릭 상세·읽기 쉬운 S1/S2/S3 표시 이름을 유지합니다.
0.22.3은 정상 Git 인식과 보안 검사를 유지하면서 임시 프로필에 의한 환경변수 확장 불일치와 실패 후 재시도 차단을 보완합니다. 실패 기록·동일 계획·공식 소스가 검증된 경우에만 남은 실행 경로를 정리하고, 미검증 코드는 격리 후 공식 단계를 재적용합니다. 서버·프로필을 초기화하지 않습니다. [현재 검증 범위](docs/verification-0.22.3.md)를 확인하세요.
새 Windows PC 전체 설치나 Word 모든 페이지의 시각적 배치까지 인증한 결과는 아닙니다.

- PowerShell: `tests/Run-NstRegression.ps1 -IncludeDistribution` (Windows PowerShell 5.1 및 PowerShell 7).
- Python: `python -B team/build_manifest.py --check`, `python -B -m unittest discover -s tests -p 'test_*.py' -v`.
- 보드·플러그인: `node tests/test_board_ui.cjs`, `node tests/test_mattermost_plugin_webapp.cjs`, Go server tests.
- 배포: `Build-Distributions.ps1 -DestinationRoot <소스 밖 별도 폴더>` → `NST-Research-Team-Setup-0.22.3.zip`과 SHA256SUMS.txt.

[설치 안내](docs/research-guide.ko.md) · [연구팀 구조](docs/research-team.md) · [작업보드](docs/research-board.ko.md) ·
[플러그인](docs/mattermost-plugins.ko.md) · [복구](docs/recovery-guide.ko.md) · [검증 범위](docs/verification-0.22.3.md)
