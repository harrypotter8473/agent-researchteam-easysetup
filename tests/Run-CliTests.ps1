[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$projectRoot = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $projectRoot 'HermesEasySetup.ps1'
$systemPowerShell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tempBase = [System.IO.Path]::GetTempPath()
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $tempBase ('Hermes 테스트 공간 ' + [guid]::NewGuid().ToString('N'))))
$hermesHome = Join-Path $testRoot 'hermes home'
$installDir = Join-Path $hermesHome 'hermes-agent'
$runtimeRoot = Join-Path $testRoot 'wizard runtime'
$script:passed = 0
$script:failed = 0

function Assert-CliTrue {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS $Name" -ForegroundColor Green; $script:passed++ }
    else { Write-Host "FAIL $Name" -ForegroundColor Red; $script:failed++ }
}

try {
    $planOutput = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action Plan -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -SkipComputerUse -SetupMode Later -Json)
    $planExit = $LASTEXITCODE
    $plan = $planOutput[-1] | ConvertFrom-Json
    Assert-CliTrue ($planExit -eq 0 -and [string]$plan.Fingerprint -match '^[0-9A-F]{64}$') 'Plan JSON contract and exit code'
    Assert-CliTrue ([string]$plan.SourceCommit -eq 'fcbd1076a93841fa88855acce810e342a5b78101') 'Plan exposes peeled commit pin'
    Assert-CliTrue ([string]$plan.InstallDir -eq $installDir) 'Unicode and space path round-trips through CLI'

    $diagnoseOutput = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action Diagnose -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -Json)
    $diagnoseExit = $LASTEXITCODE
    $diagnosis = $diagnoseOutput[-1] | ConvertFrom-Json
    Assert-CliTrue ($diagnoseExit -eq 0 -and [bool]$diagnosis.Ready) 'Diagnose is read-only and ready on safe temp paths'

    $guardOutput = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action Install -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -SkipComputerUse -SetupMode Later -Json)
    $guardExit = $LASTEXITCODE
    $guardError = $guardOutput[-1] | ConvertFrom-Json
    Assert-CliTrue ($guardExit -eq 2 -and [int]$guardError.exit_code -eq 2 -and [string]$guardError.message -like '*-Apply*') 'Install without Apply is default-deny'
    Assert-CliTrue (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) 'Apply guard creates no runtime state'

    foreach ($blockedAction in @('Install', 'CodexAuth')) {
        $existingGuard = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action $blockedAction -UseExistingHermes -Apply -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -Json)
        $existingError = $existingGuard[-1] | ConvertFrom-Json
        Assert-CliTrue ($LASTEXITCODE -ne 0 -and $existingError.message -like '*새 로그인은 실행하지 않습니다*') ('Existing runtime mode rejects ' + $blockedAction)
        Assert-CliTrue (-not (Test-Path -LiteralPath $runtimeRoot) -and -not (Test-Path -LiteralPath $hermesHome)) 'Existing runtime guard creates no install, auth, or state files'
    }

    $dockerGuard = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action DockerInstall -RuntimeRoot $runtimeRoot -Json)
    Assert-CliTrue ($LASTEXITCODE -eq 2 -and ($dockerGuard[-1] | ConvertFrom-Json).message -like '*-Apply*') 'Docker download and install require explicit Apply'
    Assert-CliTrue (-not (Test-Path -LiteralPath $runtimeRoot)) 'Docker consent guard creates no runtime or download cache'

    $adminGuard = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action AdminSetup -RuntimeRoot $runtimeRoot -Json)
    Assert-CliTrue ($LASTEXITCODE -eq 2 -and ($adminGuard[-1] | ConvertFrom-Json).message -like '*-Apply*') 'Admin setup without Apply is default-deny'
    Assert-CliTrue (-not (Test-Path -LiteralPath $runtimeRoot)) 'Admin consent guard creates no runtime state'
    $adminMissing = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action AdminSetup -Apply -RuntimeRoot $runtimeRoot -Json)
    Assert-CliTrue ($LASTEXITCODE -ne 0 -and ($adminMissing[-1] | ConvertFrom-Json).message -like '*암호화*') 'Admin setup requires encrypted input'
    $adminForeign = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action AdminSetup -Apply -RuntimeRoot $runtimeRoot -AdminInputPath (Join-Path $testRoot 'foreign.bin') -Json)
    Assert-CliTrue ($LASTEXITCODE -ne 0 -and ($adminForeign[-1] | ConvertFrom-Json).message -like '*transport*') 'Admin setup rejects foreign transport path before reading or deleting it'

    $botGuard = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action AdminBotSetup -RuntimeRoot $runtimeRoot -Json)
    Assert-CliTrue ($LASTEXITCODE -eq 2 -and ($botGuard[-1] | ConvertFrom-Json).message -like '*-Apply*') 'Admin bot issuance requires explicit Apply'
    $botMissing = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action AdminBotSetup -Apply -RuntimeRoot $runtimeRoot -Json)
    Assert-CliTrue ($LASTEXITCODE -ne 0 -and ($botMissing[-1] | ConvertFrom-Json).message -like '*암호화*') 'Admin bot issuance requires encrypted input'
    $botForeign = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action AdminBotSetup -Apply -RuntimeRoot $runtimeRoot -AdminInputPath (Join-Path $testRoot 'foreign.bin') -Json)
    Assert-CliTrue ($LASTEXITCODE -ne 0 -and ($botForeign[-1] | ConvertFrom-Json).message -like '*transport*') 'Admin bot issuance rejects foreign input file'
    Assert-CliTrue (-not (Test-Path -LiteralPath $runtimeRoot)) 'Bot guards do not create state'

    $researchGuard = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action ResearchTeamSetup -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -Json)
    $researchGuardExit = $LASTEXITCODE
    $researchGuardError = $researchGuard[-1] | ConvertFrom-Json
    Assert-CliTrue ($researchGuardExit -eq 2 -and [int]$researchGuardError.exit_code -eq 2 -and [string]$researchGuardError.message -like '*-Apply*') 'Research team setup without Apply is default-deny'
    Assert-CliTrue (-not (Test-Path -LiteralPath $runtimeRoot)) 'Research consent guard creates no runtime state'
    $researchMissing = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action ResearchTeamSetup -Apply -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -Json)
    Assert-CliTrue ($LASTEXITCODE -ne 0 -and ($researchMissing[-1] | ConvertFrom-Json).message -like '*암호화*') 'Research team setup requires encrypted input'
    Assert-CliTrue (-not (Test-Path -LiteralPath $runtimeRoot)) 'Research missing input guard creates no runtime state'
    if (-not (Test-Path -LiteralPath $testRoot -PathType Container)) { New-Item -ItemType Directory -Path $testRoot | Out-Null }
    $researchForeignPath = Join-Path $testRoot 'research-foreign.bin'
    $researchForeignBytes = [byte[]]@(0, 1, 2, 13, 10, 255)
    [IO.File]::WriteAllBytes($researchForeignPath, $researchForeignBytes)
    $researchForeign = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action ResearchTeamSetup -Apply -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -ResearchInputPath $researchForeignPath -Json)
    Assert-CliTrue ($LASTEXITCODE -ne 0 -and ($researchForeign[-1] | ConvertFrom-Json).message -like '*transport*') 'Research team setup rejects foreign transport path before decrypting it'
    Assert-CliTrue ((Test-Path -LiteralPath $researchForeignPath -PathType Leaf) -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($researchForeignPath)) -ceq [Convert]::ToBase64String($researchForeignBytes)) 'Research foreign input remains byte-equivalent after rejection'
    Assert-CliTrue (-not (Test-Path -LiteralPath $runtimeRoot)) 'Research foreign path guard creates no runtime state'

    $codexGuardOutput = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action CodexAuth -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -Json)
    $codexGuardExit = $LASTEXITCODE
    $codexGuardError = $codexGuardOutput[-1] | ConvertFrom-Json
    Assert-CliTrue ($codexGuardExit -eq 2 -and [int]$codexGuardError.exit_code -eq 2 -and [string]$codexGuardError.message -like '*-Apply*') 'Codex OAuth without Apply is default-deny'
    Assert-CliTrue (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) 'Codex OAuth guard creates no runtime state'

    $codexStatusOutput = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action CodexStatus -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -Json)
    $codexStatusExit = $LASTEXITCODE
    $codexStatusError = $codexStatusOutput[-1] | ConvertFrom-Json
    Assert-CliTrue ($codexStatusExit -ne 0 -and [string]$codexStatusError.message -like '*검증된 Hermes 설치*') 'Codex status fails closed when Hermes is absent'
    Assert-CliTrue (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) 'Codex status remains read-only when Hermes is absent'

    $computerUseOutput = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action Install -Apply -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -SetupMode Later -Json)
    $computerUseExit = $LASTEXITCODE
    $computerUseError = $computerUseOutput[-1] | ConvertFrom-Json
    Assert-CliTrue ($computerUseExit -eq 10 -and [int]$computerUseError.exit_code -eq 10 -and [string]$computerUseError.message -like '*Computer Use*') 'v0.1.2 fails closed before automatic Computer Use bootstrap'
    Assert-CliTrue (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) 'Computer Use policy rejection precedes runtime mutation'

    $desktopOutput = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action Install -Apply -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -SkipComputerUse -IncludeDesktop -SetupMode Later -Json)
    $desktopExit = $LASTEXITCODE
    $desktopError = $desktopOutput[-1] | ConvertFrom-Json
    Assert-CliTrue ($desktopExit -eq 10 -and [int]$desktopError.exit_code -eq 10 -and [string]$desktopError.message -like '*Desktop*') 'v0.1.2 scope is limited to the base Hermes CLI install'
    Assert-CliTrue (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) 'Desktop policy rejection precedes runtime mutation'

    $mismatchOutput = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action Install -Apply -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -SkipComputerUse -SetupMode Later -ExpectedPlanFingerprint ('0' * 64) -Json)
    $mismatchExit = $LASTEXITCODE
    $mismatchError = $mismatchOutput[-1] | ConvertFrom-Json
    Assert-CliTrue ($mismatchExit -eq 2 -and [string]$mismatchError.message -like '*계획*') 'CLI worker rejects stale approval fingerprint'
    Assert-CliTrue (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) 'stale approval rejection precedes mutation'

    $verifyOutput = @(& $systemPowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cli -Action Verify -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -Json)
    $verifyExit = $LASTEXITCODE
    $verification = $verifyOutput[-1] | ConvertFrom-Json
    Assert-CliTrue ($verifyExit -eq 50 -and -not [bool]$verification.Verified) 'Verify fails closed when target installation is absent'
    Assert-CliTrue (@($verification.FailedChecks) -contains 'CommandWorks' -and @($verification.FailedChecks) -contains 'CheckoutPresent') 'Verify names failed Boolean properties without exposing ambient data'
    Assert-CliTrue (@($verification.FailedChecks) -contains 'ManagedLaunchersValid' -and @($verification.FailedChecks) -contains 'ManagedLauncherExclusionsValid') 'Verify fails closed when managed launcher invariants are absent'
    Assert-CliTrue (@($verification.FailedChecks) -contains 'RepositoryMetadataSafe' -and @($verification.FailedChecks) -contains 'LauncherAttestationValid') 'Verify names metadata and launcher attestation failures'
    Assert-CliTrue ($verification.PSObject.Properties.Name -contains 'CheckoutStatus' -and $verification.PSObject.Properties.Name -contains 'GitStatusExitCode') 'Verify exposes bounded checkout diagnostics'
    Assert-CliTrue ($verification.PSObject.Properties.Name -contains 'ManagedLaunchersValid' -and $verification.PSObject.Properties.Name -contains 'ManagedLauncherExclusionsValid' -and $verification.PSObject.Properties.Name -contains 'LauncherAttestationValid') 'Verify exposes managed launcher integrity and attestation results'
    Assert-CliTrue ($verification.PSObject.Properties.Name -contains 'GitExcludesIsolated' -and $verification.PSObject.Properties.Name -contains 'LocalExcludeOverrideAbsent') 'Verify exposes Git exclude isolation results'
    Assert-CliTrue ($verification.PSObject.Properties.Name -contains 'CheckoutLayoutValid' -and $verification.PSObject.Properties.Name -contains 'IndexMatchesExpectedTree' -and $verification.PSObject.Properties.Name -contains 'IndexFlagsClean' -and $verification.PSObject.Properties.Name -contains 'LocalGitConfigSafe' -and $verification.PSObject.Properties.Name -contains 'RepositoryMetadataSafe' -and $verification.PSObject.Properties.Name -contains 'NoGitLinks') 'Verify exposes static Git metadata, layout, and index attestation'
    Assert-CliTrue ($verification.PSObject.Properties.Name -contains 'StaticProvenanceValid' -and -not [bool]$verification.StaticProvenanceValid -and $verification.PSObject.Properties.Name -contains 'VersionStartFailed') 'Verify exposes static provenance and process-start diagnostics'
    Assert-CliTrue ($verification.PSObject.Properties.Name -contains 'CheckoutStatusTruncated' -and ([string]$verification.CheckoutStatus).Length -le 4096) 'Verify hard-caps checkout diagnostics'
    Assert-CliTrue ([string]::IsNullOrWhiteSpace([string]$verification.Origin) -or [string]$verification.Origin -eq '[NON-OFFICIAL-REDACTED]' -or [bool]$verification.OriginOfficial) 'Verify never exposes a raw non-official origin'
} finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        $tempPrefix = [System.IO.Path]::GetFullPath($tempBase)
        if ($testRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $testRoot) -like 'Hermes 테스트 공간 *') {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }
}

Write-Host ''
Write-Host "Passed: $script:passed  Failed: $script:failed"
if ($script:failed -gt 0) { exit 1 }
exit 0
