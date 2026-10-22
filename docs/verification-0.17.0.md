# 0.17.0 로컬 검증 기록

이 문서는 초기 스냅샷입니다. Git 차단 해소와 실제 모델 후속 비교는
[0.17.1 검증 기록](verification-0.17.1.md)을 참조하세요.

검사 날짜: 2026-10-21. 이 문서는 **모의·구성 검사 결과**이며 실제 모델 완주 인증이 아닙니다.

| 검사 | 결과 | 범위 |
|---|---|---|
| 감사·설치 판정·총괄 재시도 단위 검사 | 33 tests 통과 | 원문/산출물/작업 버전 변경 시 승인 무효화, 반려 차단, 중간/최종 구분, 한도/인증 오류 구분 |
| 모델 gateway 설정 검사 | 5 tests 통과 | 실제 모델 호출 없음 |
| 서비스 프로세스 검사 | 2 tests 통과 | 임시 모의 자식 실행기 시작·재시작·종료 |
| 팀 입력·배포 payload | 37 assertions 통과 | 4역할, 비밀값/잘못된 입력 차단, 해시 |
| 마법사 기본값 | 19 assertions 통과 | 시간/경로/동의/심사자 수 |
| 설치 경로 모의 검사 | 76 assertions 통과 | 외부 프로세스·모델·서버·예약 작업 모의 처리. Python→Git 경로와 재시작 스크립트 포함 |
| 이전 팀 전환·완료 판정 모의 검사 | 77 assertions 통과 | 소유권·기록 보존·미완료 결과 거부 |
| PowerShell 구문·BOM | 50 scripts 통과 | Windows PowerShell 5.1 |
| WPF smoke | 통과 | 실제 4봇 완료 이벤트 순서, 최종 설치 호출 1회, 중간 실패 시 토큰 보존. 외부 설치 없음 |
| 패키지 검사 | 91 assertions 통과 | 재현 가능한 ZIP, 허용 파일만 포함, 체크섬, 세 ZIP 추출 후 WPF smoke |
| 원본 페르소나 비교 | 4/4 동일 | donor TXT와 candidate SOUL.md의 SHA-256 동일 |
| 저장소 위생·팀 manifest | 통과 | 비밀값 파일/런타임 미포함, 59개 팀 파일의 해시 |

서로 다른 범위의 assertion과 test 수를 합쳐 '전체 실사용 테스트 통과'라고 표현하지 않습니다.
Run-ResearchRuntimeTests의 "live test passes" 출력은 경계값을 모의한 설치 판정 검사이지 실제 모델 실행이 아닙니다.

## 미완료 / 차단

- 실제 로컬 Git 작업 보드 통합: test_research_board.py의 22개 시험이 초기 로컬 push에서 Git sh.exe의
  NtCreateDirectoryObject / 0xC0000022 권한 오류에 막혔습니다. 모델 실행 전이며 시나리오 품질 실패가 아닙니다.
  보안 경계를 우회하지 않았습니다. 일반 Windows 실행 환경에서 재검증해야 합니다.
- 추가 pytest 기반 gateway/test_policy.py: 해당 테스트용 pytest가 로컬 인터프리터에 없어 미실행.
  기존 Hermes 가상환경에 새 패키지를 설치하지 않았습니다. 위 5개 unittest와 별도입니다.
- 실제 설치·실제 모델 S1/S2/S3, 사용자 Mattermost 멘션 종단간 시험, 원격 Windows CI: 미실행.
- 포크 대 후보의 실제 연구 품질·시간·사용량 우열: 미판정. fork-comparison.json은 감사 통제 모의 비교입니다.

## 보존 및 출처

이번 작업에서는 기존 서버·봇·프로필·인증·GitHub를 변경하거나 모델을 호출하지 않았습니다.
기존 Python 실행 파일을 테스트 인터프리터로만 이용했고, 임시 파일은 별도 codex/h17-tmp에 생성했습니다.
다운로드된 포크 폴더 152개 파일을 ZIP과 다시 비교했을 때 6개 설치/문서 파일에 별도 차이가 있었습니다.
비교에 사용한 team/shared/research_board.py 및 팀 설정은 ZIP과 일치했습니다.
그 6개 파일을 이 작업에서 수정하거나 되돌리지 않았습니다. 원격 저장소의 최신 상태를 확인했다는 뜻도 아닙니다.

Git 경로 사전 검사는 후보에 별도로 추가했습니다. 마법사 셸에서 Git이 보이는 것과
선택한 Hermes Python 하위 프로세스에서 Git이 보이는 것을 구분하고, 후자가 실패하면 프로필 변경 전에 중단합니다.
Git --version 통과만으로 push/pull 통합 검사를 통과했다고 간주하지 않습니다.

## 재현

소스 폴더에서 테스트 전용 Python(PyYAML 필요)으로:

```powershell
python -B team/build_manifest.py --check
python -B -m unittest discover -s tests -p 'test_research_*.py' -v
```

Windows PowerShell에서 tests/Run-ResearchTests.ps1, Run-ResearchDefaultsTests.ps1,
Run-ResearchRuntimeTests.ps1, Run-ResearchMigrationTests.ps1, Run-DistributionTests.ps1을 실행합니다.
이 스크립트들은 실제 모델 S1을 실행하는 명령이 아닙니다.
