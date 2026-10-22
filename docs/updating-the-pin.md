# 검증 릴리스 pin 갱신

상류 릴리스 갱신은 보안 변경입니다. 자동으로 최신 태그를 따라가지 않습니다.

## annotated tag 주의

`git ls-remote --tags`의 `refs/tags/<tag>` 값은 commit이 아니라 annotated tag 객체일 수 있습니다. 설치기의 `-Commit`에는 반드시 `refs/tags/<tag>^{}`의 peeled commit SHA를 사용해야 합니다.

`config/hermes-source.json`은 두 값을 별도로 기록합니다.

- `hermes.tagObjectSha`: annotated tag 객체
- `hermes.commitSha`: 실제 peeled commit이며 raw URL과 `-Commit`에 사용

두 값이 같은 설정이나 tag 객체를 commit 필드에 넣은 설정은 로컬 검증에서 거부합니다.

## 필요한 증거

1. 공식 `NousResearch/hermes-agent` release tag를 확인합니다.
2. tag ref의 객체 종류, tag object SHA와 peeled commit SHA를 각각 확인합니다.
3. peeled commit tree에서 `scripts/install.ps1`의 Git blob SHA와 크기를 확인합니다.
4. blob 원본 바이트의 SHA-256을 계산하고 PowerShell AST가 유효한지 확인합니다.
5. `-ProtocolVersion` 결과가 지원 버전인지 확인합니다.
6. 기본 설치와 Desktop 포함 설치의 `-Manifest`를 모두 저장해 비교합니다.
7. 단계 순서, category, `needs_user_input`, 새 매개변수와 네트워크 동작을 코드 리뷰합니다.
8. `config/hermes-source.json`과 필요하면 `config/hermes-manifest.json`을 같은 PR에서 갱신합니다.
9. 모든 로컬 테스트와 `Run-UpstreamContractSmoke.ps1` base/Desktop을 실행합니다.
10. pin 관련 PR의 `Upstream contract smoke`가 tag→commit→tree blob 연결을 통과해야 합니다.

## 리뷰 기준

- `configure`, `gateway` 외 단계가 새로 대화형이 되면 자동 실행하지 않습니다.
- 새 단계는 목적, timeout, 복구와 재개 의미를 검토하기 전 허용 목록에 추가하지 않습니다.
- 임의 branch, `main`, 단축 commit, 움직이는 raw URL은 금지합니다.
- 해시, tag peel 또는 manifest가 예상과 다르면 우회하지 않고 pin 갱신을 중단합니다.
- 상류 설치기의 새 하위 다운로드나 fallback은 README와 SECURITY의 공급망 경계에 반영합니다.
- 검토 완료 뒤 wizard 버전과 `SHA256SUMS`를 포함한 새 release를 만들고 이전 취약 release 처리 여부를 기록합니다.
