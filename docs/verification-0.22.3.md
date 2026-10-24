# 0.22.3 환경변수·실패 복구 검증 범위

## 변경

- User PATH의 REG_EXPAND_SZ 원본을 읽어 실제 사용자 기준 확장 값을 공식 단계 실행 전에 리터럴 문자열로 고정합니다. 임시 프로필 격리·명령 경로·서명·Git provenance·launcher attestation 검사는 유지합니다.
- 원래 PATH·HERMES_HOME·HERMES_GIT_BASH_PATH의 값과 레지스트리 형식을 체크포인트에 남깁니다. 실패 시 현 값이 이 설치의 예상 쓰기와 정확히 일치할 때만 원래 값·형식으로 복구하고 환경변수 변경을 알립니다. 외부 동시 변경은 덮어쓰지 않습니다.
- 불일치 필드와 PATH 항목별 예상/실제 값을 표시합니다. Machine PATH는 수정하지 않습니다.
- 같은 실패 계획·소스·설치기 해시·단계 기록과 실제 공식 checkout을 검사한 후 정확한 실패 launcher 항목만 User PATH에서 제거합니다. 실행 중인 코드나 완료된 marker/attestation이 있으면 인수하지 않습니다. 미검증 코드는 기존 복구 격리로 보존하고 공식 단계를 재적용합니다.
- 이전 실패 체크포인트와 원래 PATH는 별도 JSON에 보존합니다. 기존 서버·봇·프로필·인증·모델·3+1 팀 payload는 수정하지 않습니다.

## 재현·검증 방법

`tests/Run-InstallEnvironmentRecoveryTests.ps1`은 HKCU의 실제 User Environment가 아니라 GUID로 제한한 `Software\NST.InstallRecovery.Tests\<id>`만 사용합니다. 파일도 고유 임시 폴더 아래에만 만듭니다.

공식 고정 commit의 `Set-PathVariable` 함수 원문을 SHA256으로 고정한 fixture를 자식 PowerShell에서 실행합니다. 테스트에서만 Environment API를 전용 레지스트리 키로 연결하며, 제품은 수정하지 않은 공식 설치기 전체를 실행합니다.

1. 기존 REG_EXPAND_SZ가 임시 USERPROFILE/LOCALAPPDATA로 풀려 공식 helper 성공 뒤 마법사 검증이 실패하는 현상을 재현.
2. 실패 기록과 실제 로컬 Git checkout 검사를 거쳐 정확한 PATH 항목만 정리하고 미검증 파일을 격리. 개인 프로필 fixture 해시 보존 확인.
3. 같은 expandable PATH를 보정하고 같은 공식 helper를 다시 실행. 기존 엄격 postcondition이 통과하며 stage-profile 경로가 새 PATH에 들어가지 않는지 확인.
4. 원래 값·형식 복구, 외부 변경 보존, source/hash/plan/완료 marker/attestation/사용 중인 프로세스/Machine PATH의 자동 복구 차단 확인.

전체 공식 설치기 SHA256과 fixture 원문 일치 검사는 `-OfficialInstallerPath`를 주어 추가 실행할 수 있습니다. fixture 테스트 성공을 새 PC 전체 설치나 실제 S1/S2/S3 성공으로 표시하지 않습니다.

## 한계와 보존

로컬 Windows PowerShell 5.1·PowerShell 7 전체 회귀는 각각 22개 묶음과 WPF smoke를 통과했습니다. 별도 최종 복구 검사는 각 셸에서 38개 assertion을 통과했으며 여기에는 전체 고정 공식 설치기 SHA256과 fixture 원문 대조 2개가 포함됩니다. CI의 기본 복구 검사는 네트워크 다운로드 없이 나머지 36개 assertion을 실행합니다. 배포 파일·추출 마법사와 원격 CI 결과는 커밋/릴리스에 별도 검증합니다.

다른 PC에서 제공된 로그만으로 기존 불일치의 정확한 원인을 확정한 것은 아닙니다. 이번 변경은 재현된 확장 오류를 방지하고 다른 불일치는 정확히 표시합니다. 구버전이 이미 다른 PATH 항목을 임시 경로로 바꿨고 원본 기록이 없다면 그 항목의 원래 값을 추측하지 않습니다. 정확한 실패 launcher 항목만 정리하며, 별도 환경변수 복원이 필요할 수 있습니다.

실제 Windows 새 PC 전체 설치, 실제 모델·Mattermost S1/S2/S3 재실행은 이번 검증 범위에 포함되지 않습니다. 정상 Git·공식 설치기 pin·70개 연구팀 payload와 기존 보드는 그대로입니다.
