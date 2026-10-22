# 기여하기

작은 변경도 Windows PowerShell 5.1에서 동작해야 합니다. 한국어가 들어간 `.ps1`, `.psm1`, `.xaml` 파일은 UTF-8 BOM을 유지하세요.

변경 전 다음 원칙을 지켜 주세요.

- 설치는 명시적 `-Apply` 없이는 시작하지 않습니다.
- GUI 승인 체크박스는 기본 해제 상태를 유지합니다.
- Hermes 사용자 데이터는 읽기·수집·삭제하지 않습니다.
- 네트워크 소스와 공식 manifest는 fail-closed로 검증합니다.
- 대화형 `configure`, `gateway` 단계는 자동화하지 않습니다.
- 로그와 오류는 UI, 상태 파일, 진단 ZIP에 쓰기 전에 정제합니다.
- 제거·초기화·강제 downgrade 기능을 추가하려면 별도의 데이터 보존 설계와 테스트가 필요합니다.

Pull Request 전에 다음을 실행하세요.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-PowerShellSyntax.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Run-GuiTests.ps1
```

소스 pin 변경은 일반 코드 변경과 분리하고 `docs/updating-the-pin.md`의 증거를 PR 설명에 남겨 주세요.
