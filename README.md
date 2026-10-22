# NST Research Team Setup 0.20.0

Windows PC에 Mattermost·Hermes·총괄/조사/분석/감사 3+1 연구팀을 구성하는 NST 전용 마법사입니다.
한국어 작업보드와 NST 브랜딩을 Mattermost 안에 연결합니다.

## 실행

[저장소](https://github.com/harrypotter8473/agent-researchteam-easysetup)의 NST 연구팀 ZIP 전체를 새 폴더에 풀고 `Start-HermesResearchSetup.cmd`를 실행합니다.
순서는 **로컬 서버 → Hermes·모델 연결 → 기본설정 자동 구성·실제 설치 검증**입니다.
모델·웹 전송과 실제 검증 동의는 사용자가 확인하며, 네 봇·토큰·페르소나·실행기·보드는 한 버튼으로 구성합니다.

Mattermost에는 중요한 보고와 결과만 남기고, 왼쪽 **연구 작업보드**에서 프로젝트·작업·문서·감사·확인 요청·실시간 행동 기록을 봅니다.
사용자는 원하는 결과물만 요청합니다. 역할 배정과 후속 판단은 총괄이, 권한·버전별 감사·전달 검사는 프로그램이 담당합니다.

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
0.20.0 정리를 위해 실모델 S1·S2·S3을 새로 실행하지 않았습니다. 마법사의 실제 검증 조건은 그대로입니다.

- PowerShell: `tests/Run-NstRegression.ps1 -IncludeDistribution` (Windows PowerShell 5.1 및 PowerShell 7).
- Python: `python -B team/build_manifest.py --check`, `python -B -m unittest discover -s tests -p 'test_*.py' -v`.
- 플러그인: `node tests/test_mattermost_plugin_webapp.cjs`, Go server tests.
- 배포: `Build-Distributions.ps1 -DestinationRoot <소스 밖 별도 폴더>` → `NST-Research-Team-Setup-0.20.0.zip`과 SHA256SUMS.txt.

[설치 안내](docs/research-guide.ko.md) · [연구팀 구조](docs/research-team.md) · [작업보드](docs/research-board.ko.md) ·
[플러그인](docs/mattermost-plugins.ko.md) · [복구](docs/recovery-guide.ko.md) · [검증 범위](docs/verification-0.20.0.md)
