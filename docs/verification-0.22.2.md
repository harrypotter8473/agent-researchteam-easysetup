# 0.22.2 Git 경로 호환 검증

## 변경 범위

설치 전·단계별 Git 경로 판정과 진단, 사용자 PATH 최소 보정만 변경합니다. 공식 Hermes 릴리스·설치기 SHA256·stage protocol은 그대로입니다. 3+1·전체 페르소나·버전별 블라인드 감사·권한·근거 재사용·모델·실행 한도·연구팀 payload와 보드 플러그인은 변경하지 않습니다.

## 검증 항목

- 실제 서명된 Program Files Git cmd/bin의 독립 검증.
- 빈 User PATH·중복 구분자·정상 Git PATH 누락·앞선 미신뢰 Git 후보의 재현.
- 기존 User PATH 전체를 그대로 보존한 앞쪽 경로 추가, Machine PATH 불변, 두 번째 실행 시 중복 보정 없음.
- 쓰기 전 원본·예상 PATH의 독점 생성 복구 기록, 외부 PATH 변경 시 쓰기 중단.
- 상대·UNC·미확정 경로, Program Files 밖으로 복사한 정상 서명 Git, 별도 미신뢰 uv 명령의 차단 유지.
- 실제 격리 자식 PowerShell에서 빈 PATH 구분자가 작업 폴더의 git.cmd를 실행하지 않음 확인.
- Windows PowerShell 5.1·PowerShell 7 회귀, 공식 고정 설치기 protocol/manifest, 배포 ZIP 무결성·추출 마법사 검사.

레지스트리 쓰기 장애주입은 테스트용 어댑터로 수행하며 운영 PC의 PATH를 바꾸지 않습니다. 실제 공식 Git stage는 User 환경변수를 쓰므로 이번 검증에서 실행하지 않습니다. 공식 설치기 파일은 고정 SHA256과 크기를 확인한 원본으로 조회합니다.

## 로컬 확인 결과 (2026-10-24)

- Windows PowerShell 5.1·PowerShell 7: 각각 21개 회귀 묶음과 마법사 smoke 통과. 배포 묶음은 각각 106개 assertion 통과.
- Git PATH 전용 검사: 각 셸에서 34개 assertion 통과. 실제 자식 셸의 Git 실행과 PATH 쓰기·복구·충돌 장애주입을 구분해 검사했습니다.
- Python 연구팀 전체 185개, gateway 권한·라우팅 29개, Node 보드·플러그인 및 Go 서버 검사 통과. 실모델 호출은 없습니다.
- 공식 고정 설치기의 태그·commit·blob·SHA256·protocol 1·15개 stage manifest 확인. 설치 stage 실행 수는 0입니다.
- ZIP 내부 FILES 121개·연구 payload 70개·추출 WPF 마법사 확인. payload manifest는 이전 버전과 같은 `7e9e9fcfeec7e4ba9a0d4694bcb9e60c91ff9180213237efe49afce782231b61`입니다.

원격 CI·릴리스 결과는 해당 커밋의 GitHub Actions와 릴리스에 별도로 기록합니다. 로컬 통과만으로 원격 통과를 주장하지 않습니다.

## 경계

이번 변경은 새 PC 전체 설치 또는 새 실모델 S1/S2/S3 성공 인증이 아닙니다. 기존 서버·봇·프로필·문서·개인 인증을 변경하거나 중지하지 않습니다. 다른 PC에서 실제 차단된 Git 경로는 그 PC의 새 진단 결과로 확인해야 합니다. 모든 설치 오류가 해결됐다는 의미는 아닙니다.
