# 0.21.1 Python 경로 호환성 검증

0.21.0에서 새 PC의 Python 설치 직전 경로 검사가 중단되는 문제를 수정합니다.
대상은 `WindowsApps\python.exe` 및 `Local\Python\bin\python.exe`를 사용하는 Windows 구성입니다.

## 보안 경계

- 일반 파일을 Windows 별칭으로 취급하지 않습니다. 사용자별 정해진 별칭 위치·0바이트·AppExecLink 태그·패키지 가족·앱 ID·대상 패키지 경로를 대조합니다.
- 새 PythonManager의 두 공식 배포자 ID와 기존 Store Python 패키지를 구분합니다.
- Microsoft Store 안내 바로가기는 실제 인터프리터가 아닙니다. 고정 해시의 공식 설치기가 WindowsApps 실행을 건너뛰는 Python 단계에서만 제외하고, 일반 Python 실행 신뢰를 부여하지 않습니다.
- 사용자별 실제 Python은 허용된 루트·전체 상위 경로의 재분석 지점 부재·PE 헤더·유효한 Python Software Foundation 서명을 요구합니다.
- PythonManager bin 별칭은 위 검사에 더해 크기가 제한된 일반 `.__target__` 파일과 대상 Python을 검사합니다. 외부 경로·자기 참조·추가 인자·별도 `.__script__.py`는 거부합니다.
- Python이 없으면 사전 검사에서 미설치를 보고하고 기존 공식 uv 자동 설치로 진행합니다. 임의 PATH 프로그램이나 Python 관리자의 자동 최신 버전 설치 기능을 호출하지 않습니다.
- 차단 오류는 명령·실제 후보 경로·이유를 표시합니다. 자격증명 가림과 기존 다른 도구 검사는 유지합니다.

## 검증 방법

`tests/Run-PythonCompatibilityTests.ps1`은 패키지 메타데이터·사용자별 경로·서명 실패·별칭 대상 변조·안내 별칭·Python 미설치·차단 메시지를 검사합니다.
서명 성공을 모의하는 경로 단위 검사는 실제 배포 파일의 서명 인증을 의미하지 않습니다.
Windows PowerShell 5.1/7 전체 회귀와 새 ZIP의 파일 해시·추출본 마법사 GUI도 별도로 검사합니다.

실제 자동 설치 검증은 독립된 임시 HermesHome·RuntimeRoot에 기존 uv를 바이트 대조하여 복사한 뒤 고정 해시 공식 설치기의 Python 단계만 실행했습니다.
관리 Python이 없는 상태에서 3.11.16이 자동 설치됐고, 두 번째 실행에서 같은 인터프리터를 재사용했습니다. 실제 `-I -S` 실행으로 버전을 확인하고 영구 User/Machine PATH·HERMES_HOME 불변을 대조했습니다.
기존 Hermes·Mattermost·Docker·프로필·서비스·모델 인증은 설치·중지·수정하지 않으며 실모델 호출도 하지 않습니다.
새 PythonManager가 설치된 사용자 PC 자체의 전체 설치 성공은 해당 PC에서 수정된 마법사로 재개하여 확인해야 합니다.

공식 구현 근거: [Python Windows 설치 관리자](https://docs.python.org/3/using/windows.html),
[PythonManager 별칭 구현](https://github.com/python/pymanager/blob/main/src/manage/aliasutils.py).
