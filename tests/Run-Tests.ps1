[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Loader.psm1') -Force

$script:passed = 0
$script:failed = 0
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        Write-Host "PASS $Name" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "FAIL $Name" -ForegroundColor Red
        $script:failed++
    }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    Assert-True -Condition ($Expected -eq $Actual) -Name "$Name (expected=$Expected, actual=$Actual)"
}

function New-TestPortableExecutableBytes {
    param([Parameter(Mandatory = $true)][string]$Seed)

    $payload = [System.Text.Encoding]::ASCII.GetBytes($Seed)
    $bytes = New-Object byte[] (512 + $payload.Length)
    $bytes[0] = 0x4D
    $bytes[1] = 0x5A
    [BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3C)
    $bytes[0x80] = 0x50
    $bytes[0x81] = 0x45
    $bytes[0x82] = 0
    $bytes[0x83] = 0
    [BitConverter]::GetBytes([uint16]0x8664).CopyTo($bytes, 0x84)
    [BitConverter]::GetBytes([uint16]1).CopyTo($bytes, 0x86)
    [BitConverter]::GetBytes([uint16]0xF0).CopyTo($bytes, 0x94)
    [BitConverter]::GetBytes([uint16]0x22).CopyTo($bytes, 0x96)
    [BitConverter]::GetBytes([uint16]0x20B).CopyTo($bytes, 0x98)
    $payload.CopyTo($bytes, 0x1A0)
    return ,$bytes
}

$tempBase = [System.IO.Path]::GetTempPath()
$testRoot = Join-Path $tempBase ('hermes-easy-setup-tests-' + [guid]::NewGuid().ToString('N'))
$testRootFull = [System.IO.Path]::GetFullPath($testRoot)
New-Item -ItemType Directory -Path $testRootFull -Force | Out-Null

try {
    $source = Get-HermesSourceConfig
    Assert-Equal 'NousResearch/hermes-agent' $source.hermes.repository 'official repository pin'
    Assert-Equal 64 ([string]$source.installer.sha256).Length 'installer SHA-256 length'
    Assert-True (Test-HermesSourceConfig -Config $source).Valid 'source config validates'

    $evil = ($source | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    $evil.installer.uri = 'https://evil.example/install.ps1'
    Assert-True (-not (Test-HermesSourceConfig -Config $evil).Valid) 'unapproved source host rejected'
    $badCommit = ($source | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    $badCommit.hermes.commitSha = 'main'
    Assert-True (-not (Test-HermesSourceConfig -Config $badCommit).Valid) 'non-immutable commit rejected'

    $redacted = Protect-HermesLogText 'Authorization: Bearer abc.def API_KEY=supersecret sk-abcdefghijklmnop https://url-user:url-secret@example.com/path'
    Assert-True ($redacted -notmatch 'abc\.def|supersecret|sk-abcdefghijklmnop|url-secret') 'log secrets redacted'
    Assert-True ($redacted -match 'https://\[REDACTED\]@example\.com/path') 'URL userinfo redacted'
    Assert-True ($redacted -match '\[REDACTED') 'redaction marker retained'

    Assert-True (-not (Test-HermesSafeTargetPath -LiteralPath 'C:\' -Label 'test').Safe) 'drive root target rejected'
    Assert-True (-not (Test-HermesSafeTargetPath -LiteralPath 'C:\Users\FIRSTL~1\AppData\Local\hermes' -Label 'test').Safe) 'DOS 8.3 target spelling rejected before upstream path expansion'
    Assert-True (Test-HermesSafeTargetPath -LiteralPath (Join-Path $testRootFull 'home') -Label 'test').Safe 'nested target accepted'

    $shortDefaultPathRejected = $false
    try {
        Get-HermesDefaultPaths -HermesHome 'C:\Users\FIRSTL~1\AppData\Local\hermes' -RuntimeRoot (Join-Path $testRootFull 'short-path-runtime') | Out-Null
    } catch {
        $shortDefaultPathRejected = ([int]$_.Exception.Data['ExitCode'] -eq 10)
    }
    Assert-True $shortDefaultPathRejected 'default path normalization rejects raw DOS 8.3 spelling with preflight exit code'

    $planA = New-HermesInstallPlan -HermesHome (Join-Path $testRootFull 'home') -RuntimeRoot (Join-Path $testRootFull 'runtime')
    $planB = New-HermesInstallPlan -HermesHome (Join-Path $testRootFull 'home') -RuntimeRoot (Join-Path $testRootFull 'runtime')
    $planC = New-HermesInstallPlan -HermesHome (Join-Path $testRootFull 'home') -RuntimeRoot (Join-Path $testRootFull 'runtime') -IncludeDesktop
    $trailingPaths = Get-HermesDefaultPaths -HermesHome ($planA.HermesHome + '\') -InstallDir ($planA.InstallDir + '\') -RuntimeRoot ($planA.RuntimeRoot + '\')
    $rootPaths = Get-HermesDefaultPaths -HermesHome 'C:\' -InstallDir 'C:\' -RuntimeRoot 'C:\'
    Assert-True ($trailingPaths.HermesHome -ceq $planA.HermesHome -and $trailingPaths.InstallDir -ceq $planA.InstallDir -and $trailingPaths.RuntimeRoot -ceq $planA.RuntimeRoot -and $rootPaths.HermesHome -ceq 'C:\') 'directory paths remove trailing separators without corrupting drive roots'
    Assert-Equal $planA.Fingerprint $planB.Fingerprint 'plan fingerprint deterministic'
    Assert-True ($planA.Fingerprint -ne $planC.Fingerprint) 'material option changes fingerprint'
    $resolvedPlanOptions = Find-HermesInstallPlanOptionsByFingerprint -Fingerprint $planA.Fingerprint -HermesHome $planA.HermesHome -InstallDir $planA.InstallDir -RuntimeRoot $planA.RuntimeRoot
    $unresolvedPlanOptions = Find-HermesInstallPlanOptionsByFingerprint -Fingerprint ('F' * 64) -HermesHome $planA.HermesHome -InstallDir $planA.InstallDir -RuntimeRoot $planA.RuntimeRoot
    $invalidPlanOptions = Find-HermesInstallPlanOptionsByFingerprint -Fingerprint 'not-a-fingerprint' -HermesHome $planA.HermesHome -InstallDir $planA.InstallDir -RuntimeRoot $planA.RuntimeRoot
    Assert-True ($null -ne $resolvedPlanOptions -and -not $resolvedPlanOptions.IncludeDesktop -and -not $resolvedPlanOptions.SkipComputerUse -and [string]$resolvedPlanOptions.SetupMode -ceq 'Portal') 'failed plan fingerprint resolves to its exact material option selection'
    Assert-True ($null -eq $unresolvedPlanOptions -and $null -eq $invalidPlanOptions) 'unknown or malformed plan fingerprints do not resolve'
    $existingSetupPaths = [pscustomobject]@{
        HermesHome = $planA.HermesHome
        InstallDir = $planA.InstallDir
        RuntimeRoot = $planA.RuntimeRoot
    }
    $eligibleDiagnosis = [pscustomobject]@{
        Ready = $true
        ExistingCheckout = $true
        ExistingCommand = (Join-Path $planA.InstallDir 'bin\hermes.exe')
        ExistingOrigin = 'https://github.com/NousResearch/hermes-agent.git'
        Paths = $existingSetupPaths
    }
    $eligibleState = [pscustomobject]@{
        schema_version = 2
        status = 'Completed'
        source_commit = $planA.SourceCommit
        hermes_home = $planA.HermesHome
        install_dir = $planA.InstallDir
        runtime_root = $planA.RuntimeRoot
        verification = [pscustomobject]@{ verified = $true; failed_checks = @() }
    }
    $eligibleExistingSetup = Test-HermesCompletedInstallForSetup -Diagnosis $eligibleDiagnosis -State $eligibleState -Paths $existingSetupPaths -ExpectedCommit $planA.SourceCommit
    Assert-True ($eligibleExistingSetup.Eligible -and [string]$eligibleExistingSetup.Reason -ceq 'Eligible') 'completed wizard install is eligible for the setup-only route'

    $notReadyDiagnosis = ($eligibleDiagnosis | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $notReadyDiagnosis.Ready = $false
    $noCheckoutDiagnosis = ($eligibleDiagnosis | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $noCheckoutDiagnosis.ExistingCheckout = $false
    $missingCommandDiagnosis = ($eligibleDiagnosis | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $missingCommandDiagnosis.ExistingCommand = $null
    $foreignOriginDiagnosis = ($eligibleDiagnosis | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $foreignOriginDiagnosis.ExistingOrigin = 'https://evil.example/hermes-agent.git'
    $wrongCommandDiagnosis = ($eligibleDiagnosis | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $wrongCommandDiagnosis.ExistingCommand = (Join-Path $planA.InstallDir 'venv\Scripts\hermes.exe')
    $wrongDiagnosisPath = ($eligibleDiagnosis | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $wrongDiagnosisPath.Paths.RuntimeRoot = (Join-Path $testRootFull 'other-diagnosis-runtime')
    $diagnosisRejects = @(
        (Test-HermesCompletedInstallForSetup -Diagnosis $notReadyDiagnosis -State $eligibleState -Paths $existingSetupPaths -ExpectedCommit $planA.SourceCommit),
        (Test-HermesCompletedInstallForSetup -Diagnosis $noCheckoutDiagnosis -State $eligibleState -Paths $existingSetupPaths -ExpectedCommit $planA.SourceCommit),
        (Test-HermesCompletedInstallForSetup -Diagnosis $missingCommandDiagnosis -State $eligibleState -Paths $existingSetupPaths -ExpectedCommit $planA.SourceCommit),
        (Test-HermesCompletedInstallForSetup -Diagnosis $foreignOriginDiagnosis -State $eligibleState -Paths $existingSetupPaths -ExpectedCommit $planA.SourceCommit),
        (Test-HermesCompletedInstallForSetup -Diagnosis $wrongCommandDiagnosis -State $eligibleState -Paths $existingSetupPaths -ExpectedCommit $planA.SourceCommit),
        (Test-HermesCompletedInstallForSetup -Diagnosis $wrongDiagnosisPath -State $eligibleState -Paths $existingSetupPaths -ExpectedCommit $planA.SourceCommit)
    )
    Assert-True (@($diagnosisRejects | Where-Object { $_.Eligible }).Count -eq 0) 'setup-only route rejects unready, foreign, missing, or path-mismatched diagnosis evidence'

    $wrongSchemaState = ($eligibleState | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $wrongSchemaState.schema_version = 3
    $runningState = ($eligibleState | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $runningState.status = 'Running'
    $wrongCaseState = ($eligibleState | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $wrongCaseState.status = 'completed'
    $wrongSourceState = ($eligibleState | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $wrongSourceState.source_commit = ('0' * 40)
    $wrongStatePath = ($eligibleState | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $wrongStatePath.install_dir = (Join-Path $testRootFull 'other-install')
    $unverifiedState = ($eligibleState | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $unverifiedState.verification.verified = $false
    $failedChecksState = ($eligibleState | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $failedChecksState.verification.failed_checks = @('CommandWorks')
    $stateRejects = @(
        (Test-HermesCompletedInstallForSetup -Diagnosis $eligibleDiagnosis -State $null -Paths $existingSetupPaths -ExpectedCommit $planA.SourceCommit),
        (Test-HermesCompletedInstallForSetup -Diagnosis $eligibleDiagnosis -State $wrongSchemaState -Paths $existingSetupPaths -ExpectedCommit $planA.SourceCommit),
        (Test-HermesCompletedInstallForSetup -Diagnosis $eligibleDiagnosis -State $runningState -Paths $existingSetupPaths -ExpectedCommit $planA.SourceCommit),
        (Test-HermesCompletedInstallForSetup -Diagnosis $eligibleDiagnosis -State $wrongCaseState -Paths $existingSetupPaths -ExpectedCommit $planA.SourceCommit),
        (Test-HermesCompletedInstallForSetup -Diagnosis $eligibleDiagnosis -State $wrongSourceState -Paths $existingSetupPaths -ExpectedCommit $planA.SourceCommit),
        (Test-HermesCompletedInstallForSetup -Diagnosis $eligibleDiagnosis -State $wrongStatePath -Paths $existingSetupPaths -ExpectedCommit $planA.SourceCommit),
        (Test-HermesCompletedInstallForSetup -Diagnosis $eligibleDiagnosis -State $unverifiedState -Paths $existingSetupPaths -ExpectedCommit $planA.SourceCommit),
        (Test-HermesCompletedInstallForSetup -Diagnosis $eligibleDiagnosis -State $failedChecksState -Paths $existingSetupPaths -ExpectedCommit $planA.SourceCommit)
    )
    Assert-True (@($stateRejects | Where-Object { $_.Eligible }).Count -eq 0) 'setup-only route rejects null, stale, malformed, unverified, or path-mismatched completed state'
    $resumeEnvelope = ($eligibleState | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $resumeEnvelope.status = 'Failed'
    $resumeEnvelope | Add-Member -NotePropertyName plan_fingerprint -NotePropertyValue $planA.Fingerprint
    $resumeWrongPath = ($resumeEnvelope | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    $resumeWrongPath.runtime_root = (Join-Path $testRootFull 'wrong-resume-runtime')
    Assert-True (Test-HermesStateMatchesResumeEnvelope -State $resumeEnvelope -Plan $planA) 'resume envelope accepts the exact failed plan, source, and paths'
    Assert-True (-not (Test-HermesStateMatchesResumeEnvelope -State $resumeWrongPath -Plan $planA)) 'resume envelope rejects a path-mismatched checkpoint'


    $validWorkerCompletion = [pscustomobject]@{
        Installed = $true
        Verified = $true
        FailedChecks = @()
    }
    $validWorkerState = [pscustomobject]@{
        schema_version = 2
        status = 'Completed'
        plan_fingerprint = $planA.Fingerprint
        verification = [pscustomobject]@{
            verified = $true
            failed_checks = @()
        }
    }
    $knownZeroOutcome = Resolve-HermesInstallWorkerOutcome -ExitCode 0 -ExitCodeAvailable $true -CompletionData $validWorkerCompletion -State $validWorkerState -ExpectedPlanFingerprint $planA.Fingerprint
    $missingExitOutcome = Resolve-HermesInstallWorkerOutcome -ExitCode $null -ExitCodeAvailable $false -CompletionData $validWorkerCompletion -State $validWorkerState -ExpectedPlanFingerprint $planA.Fingerprint
    $nullAvailableOutcome = Resolve-HermesInstallWorkerOutcome -ExitCode $null -ExitCodeAvailable $true -CompletionData $validWorkerCompletion -State $validWorkerState -ExpectedPlanFingerprint $planA.Fingerprint
    $knownFailureOutcome = Resolve-HermesInstallWorkerOutcome -ExitCode 40 -ExitCodeAvailable $true -CompletionData $validWorkerCompletion -State $validWorkerState -ExpectedPlanFingerprint $planA.Fingerprint
    Assert-True ($knownZeroOutcome.Succeeded -and -not $knownZeroOutcome.UsedFallback -and [string]$knownZeroOutcome.Reason -ceq 'VerifiedCompletionAndState') 'worker outcome accepts zero exit only with matching complete event and state'
    Assert-True ($missingExitOutcome.Succeeded -and $missingExitOutcome.UsedFallback -and $null -eq $missingExitOutcome.ExitCode) 'worker outcome safely falls back when Windows exit code is unavailable'
    Assert-True ($nullAvailableOutcome.Succeeded -and $nullAvailableOutcome.UsedFallback -and $null -eq $nullAvailableOutcome.ExitCode) 'worker outcome falls back when an available exit-code property has no value'
    Assert-True (-not $knownFailureOutcome.Succeeded -and [string]$knownFailureOutcome.Reason -ceq 'KnownNonZeroExit') 'known nonzero worker exit cannot be overridden by completion artifacts'

    $badWorkerCompletion = [pscustomobject]@{ Installed = $true; Verified = $true; FailedChecks = @('CheckoutClean') }
    $badCompletionOutcome = Resolve-HermesInstallWorkerOutcome -ExitCode $null -ExitCodeAvailable $false -CompletionData $badWorkerCompletion -State $validWorkerState -ExpectedPlanFingerprint $planA.Fingerprint
    $wrongFingerprintState = [pscustomobject]@{
        schema_version = 2
        status = 'Completed'
        plan_fingerprint = $planC.Fingerprint
        verification = [pscustomobject]@{ verified = $true; failed_checks = @() }
    }
    $wrongFingerprintOutcome = Resolve-HermesInstallWorkerOutcome -ExitCode 0 -ExitCodeAvailable $true -CompletionData $validWorkerCompletion -State $wrongFingerprintState -ExpectedPlanFingerprint $planA.Fingerprint
    $badVerificationState = [pscustomobject]@{
        schema_version = 2
        status = 'Completed'
        plan_fingerprint = $planA.Fingerprint
        verification = [pscustomobject]@{ verified = $true; failed_checks = @('CommandWorks') }
    }
    $badVerificationOutcome = Resolve-HermesInstallWorkerOutcome -ExitCode 0 -ExitCodeAvailable $true -CompletionData $validWorkerCompletion -State $badVerificationState -ExpectedPlanFingerprint $planA.Fingerprint
    Assert-True (-not $badCompletionOutcome.Succeeded -and [string]$badCompletionOutcome.Reason -ceq 'InvalidCompletionData') 'worker outcome rejects a complete event with failed checks'
    Assert-True (-not $wrongFingerprintOutcome.Succeeded -and [string]$wrongFingerprintOutcome.Reason -ceq 'InvalidState') 'worker outcome rejects a stale completed state from another plan'
    Assert-True (-not $badVerificationOutcome.Succeeded -and [string]$badVerificationOutcome.Reason -ceq 'InvalidState') 'worker outcome rejects state verification failures'

    $laterSetupResult = Start-HermesOfficialSetup -HermesHome $planA.HermesHome -InstallDir $planA.InstallDir -RuntimeRoot $planA.RuntimeRoot -Mode Later -Wait
    Assert-True (-not $laterSetupResult.Started -and -not $laterSetupResult.Exited -and $null -eq $laterSetupResult.ExitCode -and $null -eq $laterSetupResult.ProcessId -and [string]$laterSetupResult.Mode -ceq 'Later' -and $null -eq $laterSetupResult.Command) 'Later setup returns the fixed no-process outcome without verification or launch'

    $systemPowerShellForSetupTest = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $setupEventOut = Join-Path $testRootFull 'setup-events.out'
    $setupEventErr = Join-Path $testRootFull 'setup-events.err'
    $setupArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $projectRoot 'HermesEasySetup.ps1'),
        '-Action', 'Setup', '-HermesHome', $planA.HermesHome, '-InstallDir', $planA.InstallDir,
        '-RuntimeRoot', $planA.RuntimeRoot, '-SetupMode', 'Later', '-WaitForSetup', '-JsonEvents'
    )
    $setupArgumentLine = ($setupArguments | ForEach-Object { ConvertTo-WindowsProcessArgument -Argument ([string]$_) }) -join ' '
    $setupProcess = Start-Process -FilePath $systemPowerShellForSetupTest -ArgumentList $setupArgumentLine -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $setupEventOut -RedirectStandardError $setupEventErr
    $setupEventExit = [int]$setupProcess.ExitCode
    $setupProcess.Dispose()
    $setupEventLines = @([System.IO.File]::ReadAllLines($setupEventOut, [System.Text.Encoding]::UTF8))
    $setupEvents = @($setupEventLines | ForEach-Object { $_ | ConvertFrom-Json })
    $startingSetupEventValid = $false
    $closedSetupEventValid = $false
    if ($setupEvents.Count -eq 2) {
        $eventFields = @('type', 'timestamp', 'state', 'message', 'data')
        $startingFields = @($setupEvents[0].PSObject.Properties.Name)
        $closedFields = @($setupEvents[1].PSObject.Properties.Name)
        $closedDataFields = @($setupEvents[1].data.PSObject.Properties.Name)
        $startingSetupEventValid = (
            $startingFields.Count -eq $eventFields.Count -and
            @($startingFields | Where-Object { $eventFields -notcontains $_ }).Count -eq 0 -and
            [string]$setupEvents[0].type -ceq 'setup' -and
            [string]$setupEvents[0].state -ceq 'starting' -and
            [string]$setupEvents[0].message -ceq '현재 Hermes 설치를 검증하고 공식 설정 창을 여는 중입니다.' -and
            $null -eq $setupEvents[0].data
        )
        $closedSetupEventValid = (
            $closedFields.Count -eq $eventFields.Count -and
            @($closedFields | Where-Object { $eventFields -notcontains $_ }).Count -eq 0 -and
            [string]$setupEvents[1].type -ceq 'setup' -and
            [string]$setupEvents[1].state -ceq 'closed' -and
            [string]$setupEvents[1].message -ceq '공식 Hermes 설정 창이 닫혔습니다. 설정 완료 여부는 이 마법사에서 확인하지 않았습니다.' -and
            $closedDataFields.Count -eq 5 -and
            $closedDataFields -contains 'Started' -and
            $closedDataFields -contains 'Exited' -and
            $closedDataFields -contains 'ExitCode' -and
            $closedDataFields -contains 'Mode' -and
            $closedDataFields -contains 'ProcessId' -and
            $closedDataFields -notcontains 'Command' -and
            -not [bool]$setupEvents[1].data.Started -and
            -not [bool]$setupEvents[1].data.Exited -and
            $null -eq $setupEvents[1].data.ExitCode -and
            [string]$setupEvents[1].data.Mode -ceq 'Later' -and
            $null -eq $setupEvents[1].data.ProcessId
        )
    }
    Assert-True ($setupEventExit -eq 0 -and $setupEventLines.Count -eq 2 -and $startingSetupEventValid) 'Setup JsonEvents emits one fixed pre-launch event without raw child output'
    Assert-True $closedSetupEventValid 'Setup JsonEvents emits one sanitized post-wait event with fixed result fields only'

    $systemGitHome = Join-Path $testRootFull 'system-git-probe-home'
    $signedSystemGit = Get-HermesVerificationGitPath -HermesHome $systemGitHome
    Assert-True (-not [string]::IsNullOrWhiteSpace($signedSystemGit)) 'signed Program Files Git is available for verification tests'

    $planManagedGit = Join-Path $planA.HermesHome 'git\cmd\git.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $planManagedGit) -Force | Out-Null
    Copy-Item -LiteralPath $signedSystemGit -Destination $planManagedGit
    $installEngineModulePath = (Resolve-Path -LiteralPath (Join-Path $projectRoot 'src\HermesEasySetup.InstallEngine.psm1')).Path
    $installEngineModule = Get-Module | Where-Object { [string]::Equals([string]$_.Path, $installEngineModulePath, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    Assert-True ($null -ne $installEngineModule) 'InstallEngine module context is available for private resolver tests'
    $earlyInstallFailure = & $installEngineModule {
        param($root)

        $functionNames = @(
            'Get-HermesDefaultPaths', 'Get-HermesSourceConfig', 'New-HermesInstallPlan', 'Publish-HermesEvent',
            'Get-HermesPreflight', 'Get-HermesVerificationGitPath', 'Test-HermesRegistryGitResolution',
            'Get-HermesTrustedGitBashPath', 'Test-HermesTrustedGitBashCompatibility',
            'Assert-HermesFreshManagedCommandSeed', 'Get-HermesPathStageEnvironmentSnapshot',
            'Write-HermesEasySetupLog', 'Enter-HermesInstallLock', 'Read-HermesInstallState',
            'Invoke-HermesExposureRollback', 'Exit-HermesInstallLock'
        )
        $originalFunctions = @{}
        foreach ($functionName in $functionNames) {
            $originalFunctions[$functionName] = (Get-Command $functionName -CommandType Function).ScriptBlock
        }

        $script:HermesTestEarlyPaths = [pscustomobject]@{
            HermesHome = (Join-Path $root 'early-failure-home')
            InstallDir = (Join-Path $root 'early-failure-home\hermes-agent')
            RuntimeRoot = (Join-Path $root 'early-failure-runtime')
            LogDir = (Join-Path $root 'early-failure-runtime\logs')
            StateDir = (Join-Path $root 'early-failure-runtime\state')
            StateFile = (Join-Path $root 'early-failure-runtime\state\install-state.json')
        }
        $script:HermesTestEarlyPlan = [pscustomobject]@{
            Fingerprint = ('A' * 64)
            SourceTag = 'v-test'
            SourceCommit = ('b' * 40)
            HermesHome = $script:HermesTestEarlyPaths.HermesHome
            InstallDir = $script:HermesTestEarlyPaths.InstallDir
            RuntimeRoot = $script:HermesTestEarlyPaths.RuntimeRoot
        }
        $script:HermesTestEarlyRollbackPlan = $null

        try {
            Set-Item -Path 'Function:script:Get-HermesDefaultPaths' -Value { param($HermesHome, $InstallDir, $RuntimeRoot) return $script:HermesTestEarlyPaths }
            Set-Item -Path 'Function:script:Get-HermesSourceConfig' -Value { param($LiteralPath) return [pscustomobject]@{ hermes = [pscustomobject]@{ commitSha = ('b' * 40) }; installer = [pscustomobject]@{ sha256 = ('c' * 64) } } }
            Set-Item -Path 'Function:script:New-HermesInstallPlan' -Value { param($HermesHome, $InstallDir, $RuntimeRoot, $IncludeDesktop, $SkipComputerUse, $SetupMode, $SourceConfigPath) return $script:HermesTestEarlyPlan }
            Set-Item -Path 'Function:script:Publish-HermesEvent' -Value { param($Callback, $Type, $Stage, $State, $Message, $Percent, $Data) }
            Set-Item -Path 'Function:script:Get-HermesPreflight' -Value { param($HermesHome, $InstallDir, $RuntimeRoot, $IncludeDesktop) return [pscustomobject]@{ Ready = $true; ExistingCheckout = $true } }
            Set-Item -Path 'Function:script:Get-HermesVerificationGitPath' -Value { param($HermesHome) return 'C:\Program Files\Git\cmd\git.exe' }
            Set-Item -Path 'Function:script:Test-HermesRegistryGitResolution' -Value { param($TrustedGitPath, $PathValues) return [pscustomobject]@{ Valid = $true; ResolvedPath = $TrustedGitPath } }
            Set-Item -Path 'Function:script:Get-HermesTrustedGitBashPath' -Value { param($TrustedGitPath) return 'C:\Program Files\Git\bin\bash.exe' }
            Set-Item -Path 'Function:script:Test-HermesTrustedGitBashCompatibility' -Value { param($BashPath) return $true }
            Set-Item -Path 'Function:script:Assert-HermesFreshManagedCommandSeed' -Value { param($Plan, $PathValues) }
            Set-Item -Path 'Function:script:Get-HermesPathStageEnvironmentSnapshot' -Value { param($Plan, $TrustedGitBashPath) return [pscustomobject]@{ Captured = $true } }
            Set-Item -Path 'Function:script:Write-HermesEasySetupLog' -Value { param($LiteralPath, $Message, $Level) }
            Set-Item -Path 'Function:script:Enter-HermesInstallLock' -Value { param($RuntimeRoot) return [pscustomobject]@{ TestLock = $true } }
            Set-Item -Path 'Function:script:Read-HermesInstallState' -Value { param($LiteralPath) return $null }
            Set-Item -Path 'Function:script:Invoke-HermesExposureRollback' -Value {
                param($Snapshot, $Plan, $FreshRepositoryProof, $LauncherExcludeWrite, $LauncherAttestationWrite, $Paths, $LogPath, $Context)
                $script:HermesTestEarlyRollbackPlan = $Plan
            }
            Set-Item -Path 'Function:script:Exit-HermesInstallLock' -Value { param($Lock) }

            $caughtMessage = $null
            try {
                Invoke-HermesInstall -HermesHome $script:HermesTestEarlyPaths.HermesHome -InstallDir $script:HermesTestEarlyPaths.InstallDir -RuntimeRoot $script:HermesTestEarlyPaths.RuntimeRoot -SkipComputerUse | Out-Null
            } catch {
                $caughtMessage = $_.Exception.Message
            }
            return [pscustomobject]@{
                Message = $caughtMessage
                RollbackReceivedInitialPlan = ($script:HermesTestEarlyRollbackPlan -eq $script:HermesTestEarlyPlan)
            }
        } finally {
            foreach ($functionName in $functionNames) {
                Set-Item -Path ('Function:script:' + $functionName) -Value $originalFunctions[$functionName]
            }
            Remove-Variable -Scope Script -Name HermesTestEarlyPaths -ErrorAction SilentlyContinue
            Remove-Variable -Scope Script -Name HermesTestEarlyPlan -ErrorAction SilentlyContinue
            Remove-Variable -Scope Script -Name HermesTestEarlyRollbackPlan -ErrorAction SilentlyContinue
        }
    } $testRootFull
    Assert-True ([string]$earlyInstallFailure.Message -ceq '기존 checkout은 launcher attestation v1이 있는 실패 상태의 -Resume만 허용합니다. 새 빈 InstallDir에서 다시 설치하세요.' -and [bool]$earlyInstallFailure.RollbackReceivedInitialPlan) 'existing checkout rejection preserves its original error and rolls back with the approved initial plan'
    $signedManagedCandidate = & $installEngineModule { param($path) Test-HermesGitCandidate -LiteralPath $path -RequireValidSignature } $planManagedGit
    Assert-Equal ([System.IO.Path]::GetFullPath($planManagedGit)) $signedManagedCandidate 'signed Git candidate passes leaf validation'

    $trustedRegistryGitDirectory = [System.IO.Path]::GetDirectoryName($signedSystemGit)
    $hostileRegistryGitDirectory = Join-Path $testRootFull 'hostile-registry-git'
    New-Item -ItemType Directory -Path $hostileRegistryGitDirectory -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $hostileRegistryGitDirectory 'git.cmd'), '@exit /b 97', (New-Object System.Text.ASCIIEncoding))
    $safeRegistryGit = & $installEngineModule {
        param($trusted, $directory)
        Test-HermesRegistryGitResolution -TrustedGitPath $trusted -PathValues @($directory)
    } $signedSystemGit $trustedRegistryGitDirectory
    $hostileRegistryGit = & $installEngineModule {
        param($trusted, $hostile, $trustedDirectory)
        Test-HermesRegistryGitResolution -TrustedGitPath $trusted -PathValues @($hostile, $trustedDirectory)
    } $signedSystemGit $hostileRegistryGitDirectory $trustedRegistryGitDirectory
    $laterHostileRegistryGit = & $installEngineModule {
        param($trusted, $trustedDirectory, $hostile)
        Test-HermesRegistryGitResolution -TrustedGitPath $trusted -PathValues @($trustedDirectory, $hostile)
    } $signedSystemGit $trustedRegistryGitDirectory $hostileRegistryGitDirectory
    Assert-True ($safeRegistryGit.Valid -and -not $hostileRegistryGit.Valid -and $laterHostileRegistryGit.Valid) 'registry PATH requires signed Program Files Git as the first git command'

    $commandShadowMarker = Join-Path $testRootFull 'command-shadow-executed.marker'
    $commandShadowCases = @(
        [pscustomobject]@{ Stage = 'uv'; File = 'uv.cmd' },
        [pscustomobject]@{ Stage = 'python'; File = 'python.exe' },
        [pscustomobject]@{ Stage = 'node'; File = 'node.ps1' },
        [pscustomobject]@{ Stage = 'system-packages'; File = 'rg.exe' },
        [pscustomobject]@{ Stage = 'system-packages'; File = 'ffmpeg.exe' },
        [pscustomobject]@{ Stage = 'system-packages'; File = 'winget.cmd' },
        [pscustomobject]@{ Stage = 'system-packages'; File = 'choco.cmd' },
        [pscustomobject]@{ Stage = 'system-packages'; File = 'scoop.ps1' },
        [pscustomobject]@{ Stage = 'venv'; File = 'taskkill.cmd' },
        [pscustomobject]@{ Stage = 'dependencies'; File = 'npm.ps1' },
        [pscustomobject]@{ Stage = 'dependencies'; File = 'npx.ps1' },
        [pscustomobject]@{ Stage = 'dependencies'; File = 'cua-driver.cmd' },
        [pscustomobject]@{ Stage = 'node-deps'; File = 'uv.ps1' },
        [pscustomobject]@{ Stage = 'repository'; File = 'ssh.cmd' },
        [pscustomobject]@{ Stage = 'desktop'; File = 'uv.ps1' },
        [pscustomobject]@{ Stage = 'desktop'; File = 'icacls.cmd' },
        [pscustomobject]@{ Stage = 'desktop'; File = 'ie4uinit.cmd' }
    )
    $commandShadowResults = @()
    for ($shadowIndex = 0; $shadowIndex -lt $commandShadowCases.Count; $shadowIndex++) {
        $shadowCase = $commandShadowCases[$shadowIndex]
        $shadowDirectory = Join-Path $testRootFull ("command-shadow-$shadowIndex")
        New-Item -ItemType Directory -Path $shadowDirectory -Force | Out-Null
        $shadowPath = Join-Path $shadowDirectory ([string]$shadowCase.File)
        $shadowText = "Set-Content -LiteralPath '$commandShadowMarker' -Value hostile"
        [System.IO.File]::WriteAllText($shadowPath, $shadowText, (New-Object System.Text.UTF8Encoding($false)))
        $shadowResult = & $installEngineModule {
            param($plan, $stage, $trustedGit, $shadow, $trustedDirectory)
            Test-HermesStageBareCommandResolution -Plan $plan -Stage $stage -TrustedGitPath $trustedGit -PathValues @($shadow, $trustedDirectory) -ManagedCommandProof @{}
        } $planA ([string]$shadowCase.Stage) $signedSystemGit $shadowDirectory $trustedRegistryGitDirectory
        $commandShadowResults += $shadowResult
    }
    Assert-True (@($commandShadowResults | Where-Object { [bool]$_.Valid }).Count -eq 0 -and -not (Test-Path -LiteralPath $commandShadowMarker)) 'reviewed stages reject hostile exe, cmd, and ps1 PATH candidates without execution'
    $optionalCommandsAbsent = & $installEngineModule {
        param($plan, $trustedGit, $trustedDirectory)
        Test-HermesStageBareCommandResolution -Plan $plan -Stage 'system-packages' -TrustedGitPath $trustedGit -PathValues @($trustedDirectory) -ManagedCommandProof @{}
    } $planA $signedSystemGit $trustedRegistryGitDirectory
    $unreviewedStage = & $installEngineModule {
        param($plan, $trustedGit, $trustedDirectory)
        Test-HermesStageBareCommandResolution -Plan $plan -Stage 'future-stage' -TrustedGitPath $trustedGit -PathValues @($trustedDirectory) -ManagedCommandProof @{}
    } $planA $signedSystemGit $trustedRegistryGitDirectory
    Assert-True ($optionalCommandsAbsent.Valid -and $optionalCommandsAbsent.MissingCommands -contains 'rg' -and $optionalCommandsAbsent.MissingCommands -contains 'ffmpeg' -and -not $unreviewedStage.Valid) 'optional absent commands are reported and unreviewed stages fail closed'

    $nullRegistryPathResult = & $installEngineModule {
        Get-HermesRegistryBareCommandCandidates -CommandName 'uv' -PathValues $null
    }
    $invalidRegistryPathValues = @(';', 'relative\bin', '\\server\share\bin', '%HERMES_EASY_SETUP_UNDEFINED_PATH%')
    $invalidRegistryPathResults = @($nullRegistryPathResult) + @($invalidRegistryPathValues | ForEach-Object {
        & $installEngineModule {
            param($value)
            Get-HermesRegistryBareCommandCandidates -CommandName 'uv' -PathValues @($value)
        } $_
    })
    $driveRootComparable = & $installEngineModule { ConvertTo-HermesComparablePathEntry -PathEntry 'C:\' }
    Assert-True (@($invalidRegistryPathResults | Where-Object { [bool]$_.Valid }).Count -eq 0 -and $driveRootComparable -ceq 'C:\') 'registry PATH rejects null, empty, relative, UNC, and unexpanded entries while preserving drive roots'

    New-Item -ItemType Directory -Path $planA.RuntimeRoot -Force | Out-Null

    $callerGitConfig = Join-Path $testRootFull 'caller.gitconfig'
    $callerGitConfigText = "[core]`n`tautocrlf = true`n"
    [System.IO.File]::WriteAllText($callerGitConfig, $callerGitConfigText, (New-Object System.Text.UTF8Encoding($false)))
    $previousGlobalConfig = [Environment]::GetEnvironmentVariable('GIT_CONFIG_GLOBAL', [EnvironmentVariableTarget]::Process)
    try {
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', $callerGitConfig, [EnvironmentVariableTarget]::Process)
        $repositoryEnvironment = New-HermesStageEnvironment -Plan $planA -Stage 'repository'
        $gitConfigPath = [string]$repositoryEnvironment['GIT_CONFIG_GLOBAL']
        $token = [System.IO.Path]::GetFileName($gitConfigPath).Substring(11, 32)
        $gitAttributesPath = Join-Path $planA.RuntimeRoot ("git-attributes-$token.txt")
        $gitExcludesPath = Join-Path $planA.RuntimeRoot ("git-excludes-$token.txt")
        $attributesConfigValue = ([System.IO.Path]::GetFullPath($gitAttributesPath)).Replace('\', '/').Replace('"', '\"')
        $excludesConfigValue = ([System.IO.Path]::GetFullPath($gitExcludesPath)).Replace('\', '/').Replace('"', '\"')
        $gitConfigText = "[core]`n`tautocrlf = false`n`tlongpaths = true`n`tattributesFile = `"$attributesConfigValue`"`n`texcludesFile = `"$excludesConfigValue`"`n`thooksPath = NUL`n`tfsmonitor = false`n"
        Assert-Equal $planA.HermesHome $repositoryEnvironment['HERMES_HOME'] 'stage environment preserves HERMES_HOME'
        Assert-True ($repositoryEnvironment.ContainsKey('GIT_CONFIG_GLOBAL')) 'fresh repository stage receives managed global Git config'
        Assert-True ($gitConfigPath.StartsWith(([System.IO.Path]::GetFullPath($planA.RuntimeRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) 'managed Git config stays inside RuntimeRoot'
        Assert-True ((Split-Path -Leaf $gitConfigPath) -match '^git-global-[0-9a-f]{32}\.config$') 'managed Git config uses an unpredictable filename'
        Assert-Equal $gitConfigText ([System.IO.File]::ReadAllText($gitConfigPath, [System.Text.Encoding]::UTF8)) 'managed Git config forces LF and empty global attributes'
        Assert-Equal 0 (Get-Item -LiteralPath $gitAttributesPath).Length 'managed global attributes file is empty'
        Assert-Equal 0 (Get-Item -LiteralPath $gitExcludesPath).Length 'managed external excludes file is empty'
        $coreRead = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('config', '--file', $gitConfigPath, '--bool', '--get', 'core.autocrlf') -Environment $repositoryEnvironment -TimeoutSeconds 30
        Assert-Equal 0 $coreRead.ExitCode 'managed Git config is accepted by Git'
        Assert-Equal 'false' $coreRead.StdOut.Trim() 'Git reads managed core.autocrlf as false'
        $upstreamGlobalWrite = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('config', '--global', 'windows.appendAtomically', 'false') -Environment $repositoryEnvironment -TimeoutSeconds 30
        Assert-Equal 0 $upstreamGlobalWrite.ExitCode 'upstream global Git write targets managed config'
        $coreAfterWrite = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('config', '--file', $gitConfigPath, '--bool', '--get', 'core.autocrlf') -Environment $repositoryEnvironment -TimeoutSeconds 30
        Assert-Equal 'false' $coreAfterWrite.StdOut.Trim() 'upstream global write preserves managed core.autocrlf'
        $attributesAfterWrite = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('config', '--file', $gitConfigPath, '--path', '--get', 'core.attributesFile') -Environment $repositoryEnvironment -TimeoutSeconds 30
        Assert-Equal ([System.IO.Path]::GetFullPath($gitAttributesPath)) ([System.IO.Path]::GetFullPath($attributesAfterWrite.StdOut.Trim())) 'upstream global write preserves managed attributes file'
        $excludesAfterWrite = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('config', '--file', $gitConfigPath, '--path', '--get', 'core.excludesFile') -Environment $repositoryEnvironment -TimeoutSeconds 30
        Assert-Equal ([System.IO.Path]::GetFullPath($gitExcludesPath)) ([System.IO.Path]::GetFullPath($excludesAfterWrite.StdOut.Trim())) 'upstream global write preserves empty external excludes file'
        $gitConfigBytes = [System.IO.File]::ReadAllBytes($gitConfigPath)
        Assert-True (-not ($gitConfigBytes[0] -eq 0xEF -and $gitConfigBytes[1] -eq 0xBB -and $gitConfigBytes[2] -eq 0xBF)) 'managed Git config has no UTF-8 BOM'

        $repositoryEnvironmentAgain = New-HermesStageEnvironment -Plan $planA -Stage 'repository'
        $gitConfigPathAgain = [string]$repositoryEnvironmentAgain['GIT_CONFIG_GLOBAL']
        Assert-True (-not $gitConfigPath.Equals($gitConfigPathAgain, [StringComparison]::OrdinalIgnoreCase)) 'managed Git config path is never reused'
        Assert-Equal $callerGitConfigText ([System.IO.File]::ReadAllText($callerGitConfig, [System.Text.Encoding]::UTF8)) 'caller global Git config is unchanged'
        Assert-True ($repositoryEnvironmentAgain.ContainsKey('GIT_CONFIG_PARAMETERS') -and $null -eq $repositoryEnvironmentAgain['GIT_CONFIG_PARAMETERS']) 'ambient Git command parameters are removed'
        Assert-True ($repositoryEnvironmentAgain.ContainsKey('GIT_CONFIG_SYSTEM') -and $null -eq $repositoryEnvironmentAgain['GIT_CONFIG_SYSTEM']) 'ambient Git system redirect is removed'
        Assert-True ($repositoryEnvironmentAgain.ContainsKey('GIT_EXEC_PATH') -and $null -eq $repositoryEnvironmentAgain['GIT_EXEC_PATH']) 'ambient Git executable redirect is removed'
        Assert-True ($repositoryEnvironmentAgain.ContainsKey('GIT_COMMON_DIR') -and $null -eq $repositoryEnvironmentAgain['GIT_COMMON_DIR']) 'ambient Git common directory redirect is removed'
        Assert-True ($repositoryEnvironmentAgain.ContainsKey('GIT_NAMESPACE') -and $null -eq $repositoryEnvironmentAgain['GIT_NAMESPACE']) 'ambient Git namespace redirect is removed'
        Assert-Equal '1' $repositoryEnvironmentAgain['GIT_CONFIG_NOSYSTEM'] 'Git system configuration is disabled for every stage'
        Assert-Equal '1' $repositoryEnvironmentAgain['GIT_ATTR_NOSYSTEM'] 'system Git attributes are disabled'
        Assert-Equal '1' $repositoryEnvironmentAgain['GIT_NO_REPLACE_OBJECTS'] 'Git replace objects are disabled'
        Assert-Equal '2' $repositoryEnvironmentAgain['GIT_CONFIG_COUNT'] 'two safe Git command overrides are installed'
        Assert-Equal 'core.hooksPath' $repositoryEnvironmentAgain['GIT_CONFIG_KEY_0'] 'Git hooks override key is fixed'
        Assert-Equal 'NUL' $repositoryEnvironmentAgain['GIT_CONFIG_VALUE_0'] 'Git hooks are disabled'
        Assert-Equal 'core.fsmonitor' $repositoryEnvironmentAgain['GIT_CONFIG_KEY_1'] 'Git fsmonitor override key is fixed'
        Assert-Equal 'false' $repositoryEnvironmentAgain['GIT_CONFIG_VALUE_1'] 'Git fsmonitor is disabled'
        Assert-Equal '.COM;.EXE;.BAT;.CMD' $repositoryEnvironmentAgain['PATHEXT'] 'stage command extensions are fixed'
        $expectedSystemModulePath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)) 'System32\WindowsPowerShell\v1.0\Modules'
        Assert-Equal ([System.IO.Path]::GetFullPath($expectedSystemModulePath)) $repositoryEnvironmentAgain['PSModulePath'] 'stage PowerShell module path is system-only'
        $expectedWindowsDirectory = [System.IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows))
        $expectedCmdPath = Join-Path $expectedWindowsDirectory 'System32\cmd.exe'
        $expectedGitSshPath = Join-Path (Split-Path -Parent (Split-Path -Parent $signedSystemGit)) 'usr\bin\ssh.exe'
        Assert-True ([string]::Equals([string]$repositoryEnvironmentAgain['ComSpec'], [System.IO.Path]::GetFullPath($expectedCmdPath), [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$repositoryEnvironmentAgain['SystemRoot'], $expectedWindowsDirectory, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$repositoryEnvironmentAgain['WINDIR'], $expectedWindowsDirectory, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$repositoryEnvironmentAgain['GIT_SSH'], [System.IO.Path]::GetFullPath($expectedGitSshPath), [StringComparison]::OrdinalIgnoreCase)) 'stage environment pins cmd, Windows roots, and bundled Git SSH'
        $trustedWindowsCommandPaths = & $installEngineModule {
            @('cmd', 'schtasks', 'taskkill', 'icacls', 'ie4uinit') | ForEach-Object {
                Get-HermesTrustedWindowsCommandPath -CommandName $_
            }
        }
        Assert-True (@($trustedWindowsCommandPaths).Count -eq 5 -and @($trustedWindowsCommandPaths | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) 'signed System32 command canaries pass trust validation'
        $appExecutionAliasChecks = & $installEngineModule {
            param($plan, $trustedGit)
            $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
            @('winget.exe', 'python.exe') | ForEach-Object {
                $path = Join-Path $localAppData (Join-Path 'Microsoft\WindowsApps' $_)
                $exists = Test-Path -LiteralPath $path -PathType Leaf
                $commandName = [System.IO.Path]::GetFileNameWithoutExtension($_)
                [pscustomobject]@{
                    Name = $_
                    Exists = $exists
                    Trusted = $(if ($exists) { Test-HermesWindowsAppExecutionAlias -LiteralPath $path -ExpectedName $_ } else { $false })
                    Accepted = $(if ($exists) { Test-HermesTrustedBareCommandCandidate -Plan $plan -CommandName $commandName -LiteralPath $path -TrustedGitPath $trustedGit -ManagedCommandProof @{} } else { $false })
                }
            }
        } $planA $signedSystemGit
        Assert-True (@($appExecutionAliasChecks | Where-Object { [bool]$_.Exists -and [bool]$_.Accepted -ne [bool]$_.Trusted }).Count -eq 0) 'only package-bound winget and Python AppExecLink aliases are accepted'
        $vbsOnlyGitDirectory = Join-Path $testRootFull 'vbs-only-registry-git'
        New-Item -ItemType Directory -Path $vbsOnlyGitDirectory -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $vbsOnlyGitDirectory 'git.vbs'), 'WScript.Echo "hostile"', (New-Object System.Text.ASCIIEncoding))
        $previousProbePath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Process)
        $previousProbePathExt = [Environment]::GetEnvironmentVariable('PATHEXT', [EnvironmentVariableTarget]::Process)
        try {
            [Environment]::SetEnvironmentVariable('Path', $vbsOnlyGitDirectory + [System.IO.Path]::PathSeparator + $trustedRegistryGitDirectory, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('PATHEXT', [string]$repositoryEnvironmentAgain['PATHEXT'], [EnvironmentVariableTarget]::Process)
            $resolvedVbsProbeGit = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        } finally {
            [Environment]::SetEnvironmentVariable('Path', $previousProbePath, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable('PATHEXT', $previousProbePathExt, [EnvironmentVariableTarget]::Process)
        }
        Assert-True ([string]::Equals([string]$resolvedVbsProbeGit.Source, $signedSystemGit, [System.StringComparison]::OrdinalIgnoreCase)) 'fixed PATHEXT prevents a registry PATH git.vbs from shadowing trusted Git'

        Remove-HermesStageEnvironmentArtifacts -Environment $repositoryEnvironment -Plan $planA
        Remove-HermesStageEnvironmentArtifacts -Environment $repositoryEnvironmentAgain -Plan $planA
        Assert-True (-not (Test-Path -LiteralPath $gitConfigPath)) 'first managed Git config is removed after stage'
        Assert-True (-not (Test-Path -LiteralPath $gitConfigPathAgain)) 'second managed Git config is removed after stage'
        Assert-True (-not (Test-Path -LiteralPath $gitAttributesPath)) 'managed Git attributes are removed after stage'
        Assert-True (-not (Test-Path -LiteralPath $gitExcludesPath)) 'managed Git excludes are removed after stage'
    } finally {
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', $previousGlobalConfig, [EnvironmentVariableTarget]::Process)
    }

    $existingRepositoryEnvironment = New-HermesStageEnvironment -Plan $planA -Stage 'repository' -ExistingCheckout
    $existingGitConfigPath = [string]$existingRepositoryEnvironment['GIT_CONFIG_GLOBAL']
    Assert-True (-not [string]::IsNullOrWhiteSpace($existingGitConfigPath)) 'existing checkout receives isolated managed Git config'
    Assert-Equal '1' $existingRepositoryEnvironment['GIT_CONFIG_NOSYSTEM'] 'existing checkout disables system Git config'
    Assert-True ($existingRepositoryEnvironment.ContainsKey('GIT_COMMON_DIR') -and $null -eq $existingRepositoryEnvironment['GIT_COMMON_DIR']) 'existing checkout removes ambient common directory'
    $trustedGitPathPrefix = [System.IO.Path]::GetDirectoryName($signedSystemGit) + [System.IO.Path]::PathSeparator
    Assert-True ([string]$existingRepositoryEnvironment['PATH'] -like "$trustedGitPathPrefix*") 'repository stage PATH starts with Program Files Git'
    Remove-HermesStageEnvironmentArtifacts -Environment $existingRepositoryEnvironment -Plan $planA
    Assert-True (-not (Test-Path -LiteralPath $existingGitConfigPath)) 'existing checkout managed Git config is removed'
    $gitStageEnvironment = New-HermesStageEnvironment -Plan $planA -Stage 'git'
    Assert-True ([string]$gitStageEnvironment['PATH'] -like "$trustedGitPathPrefix*") 'official Git stage PATH starts with Program Files Git'
    Assert-True ($gitStageEnvironment.ContainsKey('GIT_CONFIG_GLOBAL') -and (Test-Path -LiteralPath ([string]$gitStageEnvironment['GIT_CONFIG_GLOBAL']) -PathType Leaf)) 'official Git stage receives managed global config'
    $uvEnvironment = New-HermesStageEnvironment -Plan $planA -Stage 'uv'
    Assert-True ([string]$uvEnvironment['PATH'] -like "$trustedGitPathPrefix*") 'later automatic stage PATH starts with Program Files Git'
    Assert-True ($uvEnvironment.ContainsKey('GIT_CONFIG_GLOBAL') -and (Test-Path -LiteralPath ([string]$uvEnvironment['GIT_CONFIG_GLOBAL']) -PathType Leaf)) 'later automatic stage receives managed global config'
    Assert-True ($uvEnvironment.ContainsKey('GIT_COMMON_DIR') -and $null -eq $uvEnvironment['GIT_COMMON_DIR']) 'later automatic stage removes ambient common directory'
    Assert-True ((Get-Content -LiteralPath ([string]$uvEnvironment['GIT_CONFIG_GLOBAL']) -Raw) -cmatch '(?m)^\s*longpaths = true$') 'managed Git config enables long Windows checkout paths'
    $stageProfilePrefix = [System.IO.Path]::GetFullPath($planA.RuntimeRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar + 'stage-profile-'
    Assert-True ([string]$uvEnvironment['USERPROFILE'] -like "$stageProfilePrefix*" -and
        [string]::Equals([string]$uvEnvironment['HOME'], [string]$uvEnvironment['USERPROFILE'], [StringComparison]::OrdinalIgnoreCase) -and
        [string]$uvEnvironment['LOCALAPPDATA'] -like "$stageProfilePrefix*" -and
        [string]$uvEnvironment['TEMP'] -like "$stageProfilePrefix*" -and
        (Get-Item -LiteralPath ([string]$uvEnvironment['NPM_CONFIG_USERCONFIG'])).Length -eq 0) 'automatic stage uses an isolated profile, TEMP, LocalAppData, and empty npm config'
    Assert-True ([string]$uvEnvironment['UV_NO_MODIFY_PATH'] -ceq '1' -and [string]$uvEnvironment['UV_MANAGED_PYTHON'] -ceq '1' -and [string]$uvEnvironment['UV_PYTHON_NO_REGISTRY'] -ceq '1' -and
        [string]$uvEnvironment['UV_TOOL_DIR'] -ceq [System.IO.Path]::GetFullPath((Join-Path $planA.HermesHome 'uv-tools')) -and
        [string]$uvEnvironment['UV_TOOL_BIN_DIR'] -ceq [System.IO.Path]::GetFullPath((Join-Path $planA.HermesHome 'bin')) -and
        [string]$uvEnvironment['PLAYWRIGHT_BROWSERS_PATH'] -ceq '0') 'uv cannot modify User PATH or discover registry Python, while tool and browser environments remain in stable managed locations'
    $pythonStageEnvironment = New-HermesStageEnvironment -Plan $planA -Stage 'python'
    Assert-True ([string]$pythonStageEnvironment['UV_NO_PROJECT'] -ceq '1' -and $null -eq $pythonStageEnvironment['VIRTUAL_ENV'] -and
        $null -eq $pythonStageEnvironment['UV_PROJECT'] -and $null -eq $pythonStageEnvironment['UV_PROJECT_ENVIRONMENT'] -and
        $null -eq $pythonStageEnvironment['CONDA_PREFIX']) 'Python bootstrap does not inherit an ambient project or virtual environment'
    $hostileEnvironmentNames = @('NODE_OPTIONS', 'NODE_PATH', 'PYTHONPATH', 'PYTHONHOME', 'VIRTUAL_ENV', 'UV_PROJECT', 'UV_PROJECT_ENVIRONMENT', 'UV_PYTHON', 'CONDA_PREFIX', 'CONDA_DEFAULT_ENV', 'PIPENV_ACTIVE', 'POETRY_ACTIVE', 'BASH_ENV', 'ENV', 'NPM_CONFIG_SCRIPT_SHELL', 'GIT_SSH_COMMAND')
    $hostileEnvironmentPrevious = @{}
    try {
        foreach ($name in $hostileEnvironmentNames) {
            $hostileEnvironmentPrevious[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable($name, (Join-Path $testRootFull ("hostile-$name")), [EnvironmentVariableTarget]::Process)
        }
        # Probe the actual child environment without PowerShell's first-run
        # module discovery under a fresh synthetic user profile. ComSpec was
        # pinned and signature-checked by New-HermesStageEnvironment.
        $isolationProbeCommand = 'for %V in (NODE_OPTIONS NODE_PATH PYTHONPATH PYTHONHOME VIRTUAL_ENV UV_PROJECT UV_PROJECT_ENVIRONMENT UV_PYTHON CONDA_PREFIX CONDA_DEFAULT_ENV PIPENV_ACTIVE POETRY_ACTIVE BASH_ENV ENV NPM_CONFIG_SCRIPT_SHELL GIT_SSH_COMMAND) do @if defined %V exit /b 1'
        $isolationProbeCommand = '(' + $isolationProbeCommand + ') & echo isolated'
        $inheritedProbe = Invoke-HermesProcess -FilePath ([string]$uvEnvironment['ComSpec']) -ArgumentList @('/d', '/c', $isolationProbeCommand) -TimeoutSeconds 30
        Assert-True ($inheritedProbe.ExitCode -eq 1 -and -not $inheritedProbe.TimedOut) 'environment probe detects inherited hostile variables'
        $isolationProbe = Invoke-HermesProcess -FilePath ([string]$uvEnvironment['ComSpec']) -ArgumentList @('/d', '/c', $isolationProbeCommand) -Environment $uvEnvironment -TimeoutSeconds 30
        Assert-True ($isolationProbe.ExitCode -eq 0 -and $isolationProbe.StdOut.Trim() -ceq 'isolated') 'replacement environment blocks inherited Node, Python, shell, npm, and Git injection variables'
    } finally {
        foreach ($name in $hostileEnvironmentNames) {
            [Environment]::SetEnvironmentVariable($name, $hostileEnvironmentPrevious[$name], [EnvironmentVariableTarget]::Process)
        }
    }
    Assert-Equal ([System.IO.Path]::GetFullPath($signedSystemGit)) (Get-HermesVerificationGitPath -HermesHome $planA.HermesHome) 'Program Files Git is selected'
    $gitStageConfigPath = [string]$gitStageEnvironment['GIT_CONFIG_GLOBAL']
    $uvStageConfigPath = [string]$uvEnvironment['GIT_CONFIG_GLOBAL']
    $gitStageProfilePath = [string]$gitStageEnvironment['HERMES_EASY_SETUP_STAGE_PROFILE']
    $uvStageProfilePath = [string]$uvEnvironment['HERMES_EASY_SETUP_STAGE_PROFILE']
    $pythonStageProfilePath = [string]$pythonStageEnvironment['HERMES_EASY_SETUP_STAGE_PROFILE']
    Remove-HermesStageEnvironmentArtifacts -Environment $gitStageEnvironment -Plan $planA
    Remove-HermesStageEnvironmentArtifacts -Environment $uvEnvironment -Plan $planA
    Remove-HermesStageEnvironmentArtifacts -Environment $pythonStageEnvironment -Plan $planA
    Assert-True (-not (Test-Path -LiteralPath $gitStageConfigPath) -and -not (Test-Path -LiteralPath $uvStageConfigPath) -and -not (Test-Path -LiteralPath $gitStageProfilePath) -and -not (Test-Path -LiteralPath $uvStageProfilePath) -and -not (Test-Path -LiteralPath $pythonStageProfilePath)) 'automatic stage Git files and isolated profiles are removed'

    $uvRepairRoot = Join-Path $testRootFull 'uv-junction-repair'
    $uvRepairHome = Join-Path $uvRepairRoot 'home'
    $uvRepairPythonRoot = Join-Path $uvRepairHome 'python'
    $uvRepairTarget = Join-Path $uvRepairPythonRoot 'cpython-3.11.16-windows-x86_64-none'
    $uvRepairLink = Join-Path $uvRepairPythonRoot 'cpython-3.11-windows-x86_64-none'
    New-Item -ItemType Directory -Path $uvRepairTarget -Force | Out-Null
    Copy-Item -LiteralPath $signedSystemGit -Destination (Join-Path $uvRepairTarget 'python.exe') -Force
    New-Item -ItemType Junction -Path $uvRepairLink -Target $uvRepairTarget | Out-Null
    $uvRepairPlan = [pscustomobject]@{ HermesHome = $uvRepairHome }
    $uvRepair = Convert-HermesBrokenUvPythonMinorJunction -Plan $uvRepairPlan -PythonVersion '3.11'
    Assert-True ($uvRepair.Changed -and (Test-Path -LiteralPath (Join-Path $uvRepairLink 'python.exe') -PathType Leaf) -and
        -not (Test-Path -LiteralPath $uvRepairTarget) -and ((Get-Item -LiteralPath $uvRepairLink -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) 'broken uv managed-Python junction is materialized as an ordinary verified directory'

    $freshGuardHome = Join-Path $testRootFull 'fresh-command-guard-home'
    $freshGuardRuntime = Join-Path $testRootFull 'fresh-command-guard-runtime'
    $freshGuardPlan = New-HermesInstallPlan -HermesHome $freshGuardHome -RuntimeRoot $freshGuardRuntime
    $freshPreplantPaths = @(
        (Join-Path $freshGuardHome 'bin\uv.exe'),
        (Join-Path $freshGuardHome 'bin\browser-use.exe'),
        (Join-Path $freshGuardHome 'node\node.exe'),
        (Join-Path $freshGuardHome 'node\npm.cmd'),
        (Join-Path $freshGuardHome 'node\npm.ps1'),
        (Join-Path $freshGuardHome 'node\npx.cmd'),
        (Join-Path $freshGuardHome 'node\npx.ps1'),
        (Join-Path $freshGuardHome 'python'),
        (Join-Path $freshGuardHome 'uv-tools'),
        (Join-Path $freshGuardHome 'git\bin\bash.exe'),
        (Join-Path $freshGuardHome 'git\usr\bin\bash.exe')
    )
    $freshPreplantRejected = 0
    foreach ($preplantPath in $freshPreplantPaths) {
        if ((Split-Path -Leaf $preplantPath) -eq 'python') {
            New-Item -ItemType Directory -Path $preplantPath -Force | Out-Null
        } else {
            New-Item -ItemType Directory -Path (Split-Path -Parent $preplantPath) -Force | Out-Null
            [System.IO.File]::WriteAllText($preplantPath, 'preplanted', (New-Object System.Text.UTF8Encoding($false)))
        }
        try {
            & $installEngineModule {
                param($plan, $path)
                Assert-HermesFreshManagedCommandSeed -Plan $plan -PathValues @($path)
            } $freshGuardPlan $trustedRegistryGitDirectory
        } catch {
            $freshPreplantRejected++
        } finally {
            if (Test-Path -LiteralPath $preplantPath -PathType Container) {
                Remove-Item -LiteralPath $preplantPath -Recurse -Force
            } elseif (Test-Path -LiteralPath $preplantPath) {
                Remove-Item -LiteralPath $preplantPath -Force
            }
        }
    }
    Assert-Equal $freshPreplantPaths.Count $freshPreplantRejected 'fresh install rejects every exact managed command, browser backend, and Python preplant'
    $resumeRecoveryHome = Join-Path $testRootFull 'resume-recovery-home'
    $resumeRecoveryRuntime = Join-Path $testRootFull 'resume-recovery-runtime'
    $resumeRecoveryPlan = New-HermesInstallPlan -HermesHome $resumeRecoveryHome -RuntimeRoot $resumeRecoveryRuntime -SkipComputerUse
    $resumeRecoveryState = [pscustomobject]@{
        schema_version = 2; status = 'Failed'; plan_fingerprint = $resumeRecoveryPlan.Fingerprint
        source_commit = $resumeRecoveryPlan.SourceCommit; hermes_home = $resumeRecoveryPlan.HermesHome
        install_dir = $resumeRecoveryPlan.InstallDir; runtime_root = $resumeRecoveryPlan.RuntimeRoot
    }
    New-Item -ItemType Directory -Path (Join-Path $resumeRecoveryHome 'bin') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $resumeRecoveryHome 'python') -Force | Out-Null
    New-Item -ItemType Directory -Path $resumeRecoveryPlan.InstallDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $resumeRecoveryRuntime 'state') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $resumeRecoveryHome 'bin\uv.exe'), 'managed uv', (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText((Join-Path $resumeRecoveryHome '.env'), 'PRESERVE=true', (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText((Join-Path $resumeRecoveryRuntime 'state\launcher-attestation-v1.json'), '{"stale":true}', (New-Object System.Text.UTF8Encoding $false))
    $resumeRecovery = & $installEngineModule { param($plan, $state) Move-HermesResumeManagedSeedToQuarantine -Plan $plan -State $state } $resumeRecoveryPlan $resumeRecoveryState
    $resumeRecoveryClean = $true
    try { & $installEngineModule { param($plan) Assert-HermesFreshManagedCommandSeed -Plan $plan -PathValues @() } $resumeRecoveryPlan } catch { $resumeRecoveryClean = $false }
    Assert-True ($resumeRecovery.Changed -and $resumeRecovery.Items.Count -eq 4 -and (Test-Path -LiteralPath (Join-Path $resumeRecovery.Root 'recovery.json') -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $resumeRecoveryRuntime 'state\launcher-attestation-v1.json'))) 'failed early install moves exact managed outputs and stale launcher attestation into a recoverable quarantine'
    Assert-True ($resumeRecoveryClean -and (Test-Path -LiteralPath (Join-Path $resumeRecoveryHome '.env') -PathType Leaf)) 'resume recovery restores the fresh command boundary while preserving user configuration'
    $ambientCuaDirectory = Join-Path $testRootFull 'ambient-cua-driver'
    New-Item -ItemType Directory -Path $ambientCuaDirectory -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ambientCuaDirectory 'cua-driver.cmd'), '@exit /b 0', (New-Object System.Text.ASCIIEncoding))
    $ambientCuaRejected = $false
    try {
        & $installEngineModule {
            param($plan, $path)
            Assert-HermesFreshManagedCommandSeed -Plan $plan -PathValues @($path)
        } $freshGuardPlan $ambientCuaDirectory
    } catch { $ambientCuaRejected = $true }
    $skipCuaPlan = New-HermesInstallPlan -HermesHome $freshGuardHome -RuntimeRoot $freshGuardRuntime -SkipComputerUse
    $skipCuaAccepted = $true
    try {
        & $installEngineModule {
            param($plan, $path)
            Assert-HermesFreshManagedCommandSeed -Plan $plan -PathValues @($path)
        } $skipCuaPlan $ambientCuaDirectory
    } catch { $skipCuaAccepted = $false }
    Assert-True ($ambientCuaRejected -and $skipCuaAccepted) 'fresh install rejects ambient cua-driver unless computer use is skipped'

    $launcherHome = Join-Path $testRootFull 'launcher-home'
    $launcherRepo = Join-Path $launcherHome 'hermes-agent'
    $launcherRuntime = Join-Path $testRootFull 'launcher-runtime'
    New-Item -ItemType Directory -Path $launcherRepo -Force | Out-Null
    New-Item -ItemType Directory -Path $launcherRuntime -Force | Out-Null
    $launcherPlan = [pscustomobject]@{ HermesHome = $launcherHome; InstallDir = $launcherRepo; RuntimeRoot = $launcherRuntime }
    $freshSeed = & $installEngineModule { param($path) Get-HermesFreshCheckoutSeed -InstallDir $path } $launcherRepo
    Assert-True ([bool]$freshSeed.Eligible) 'empty ordinary InstallDir is eligible for fresh proof'
    $launcherEnvironment = New-HermesStageEnvironment -Plan $launcherPlan -Stage 'repository'
    try {
        $launcherInit = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('init', $launcherRepo) -Environment $launcherEnvironment -TimeoutSeconds 30
        [System.IO.File]::WriteAllText((Join-Path $launcherRepo '.gitignore'), "/venv/`n", (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $launcherRepo 'tracked.txt'), "pinned`n", (New-Object System.Text.UTF8Encoding($false)))
        $launcherPackageLock = Join-Path $launcherRepo 'package-lock.json'
        [System.IO.File]::WriteAllText($launcherPackageLock, "{}`n", (New-Object System.Text.UTF8Encoding($false)))
        $launcherAdd = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'add', '--', '.gitignore', 'tracked.txt', 'package-lock.json') -Environment $launcherEnvironment -TimeoutSeconds 30
        $launcherCommit = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-c', 'user.name=Hermes Test', '-c', 'user.email=hermes-test@example.invalid', '-C', $launcherRepo, 'commit', '-m', 'fixture') -Environment $launcherEnvironment -TimeoutSeconds 30
        $launcherRemote = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'remote', 'add', 'origin', 'https://github.com/NousResearch/hermes-agent.git') -Environment $launcherEnvironment -TimeoutSeconds 30
        $launcherWindowsConfig = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'config', '--local', 'windows.appendAtomically', 'false') -Environment $launcherEnvironment -TimeoutSeconds 30
        Assert-True ($launcherInit.ExitCode -eq 0 -and $launcherAdd.ExitCode -eq 0 -and $launcherCommit.ExitCode -eq 0 -and $launcherRemote.ExitCode -eq 0 -and $launcherWindowsConfig.ExitCode -eq 0) 'managed launcher Git fixture created with pinned installer config'

        $launcherHeadResult = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'rev-parse', 'HEAD') -Environment $launcherEnvironment -TimeoutSeconds 30
        $launcherHead = $launcherHeadResult.StdOut.Trim()
        $freshProof = & $installEngineModule { param($seed, $plan, $commit) New-HermesFreshRepositoryProof -Seed $seed -Plan $plan -ExpectedCommit $commit } $freshSeed $launcherPlan $launcherHead
        Assert-True ([string]$freshProof.ExpectedCommit -eq $launcherHead.ToLowerInvariant()) 'clean repository receives a same-run fresh proof'
        $nonEmptySeed = & $installEngineModule { param($path) Get-HermesFreshCheckoutSeed -InstallDir $path } $launcherRepo
        Assert-True (-not [bool]$nonEmptySeed.Eligible) 'nonempty checkout cannot mint a new fresh seed'

        $proofDirtyPath = Join-Path $launcherRepo 'proof-dirty.tmp'
        [System.IO.File]::WriteAllText($proofDirtyPath, 'dirty', (New-Object System.Text.UTF8Encoding($false)))
        $dirtyProofRejected = $false
        try { & $installEngineModule { param($seed, $plan, $commit) New-HermesFreshRepositoryProof -Seed $seed -Plan $plan -ExpectedCommit $commit } $freshSeed $launcherPlan $launcherHead | Out-Null } catch { $dirtyProofRejected = $true }
        Remove-Item -LiteralPath $proofDirtyPath -Force
        Assert-True $dirtyProofRejected 'fresh proof rejects an untracked repository change'

        $launcherPackageLockBytes = [System.IO.File]::ReadAllBytes($launcherPackageLock)
        [System.IO.File]::WriteAllText($launcherPackageLock, '{"changed":true}', (New-Object System.Text.UTF8Encoding($false)))
        $dirtyLockfileProofRejected = $false
        try { & $installEngineModule { param($seed, $plan, $commit) New-HermesFreshRepositoryProof -Seed $seed -Plan $plan -ExpectedCommit $commit } $freshSeed $launcherPlan $launcherHead | Out-Null } catch { $dirtyLockfileProofRejected = $true }
        [System.IO.File]::WriteAllBytes($launcherPackageLock, $launcherPackageLockBytes)
        Assert-True $dirtyLockfileProofRejected 'fresh proof still rejects tracked package-lock churn'

        $launcherExcludePath = Join-Path $launcherRepo '.git\info\exclude'
        $excludeStateBeforeRace = & $installEngineModule { param($path) Get-HermesManagedLauncherExcludeState -InstallDir $path } $launcherRepo
        $excludeBytesBeforeRace = [byte[]]$excludeStateBeforeRace.OriginalBytes
        $concurrentText = ([string]$excludeStateBeforeRace.Text) + "# concurrent user comment`n"
        $concurrentBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($concurrentText)
        [System.IO.File]::WriteAllBytes($launcherExcludePath, $concurrentBytes)
        $concurrentWriteRejected = $false
        try {
            & $installEngineModule {
                param($state)
                Set-HermesManagedLauncherExcludeFile -State $state -MissingPatterns @('/bin/hermes.exe', '/bin/hermes-acp.exe')
            } $excludeStateBeforeRace | Out-Null
        } catch { $concurrentWriteRejected = $true }
        $concurrentBytesAfter = [System.IO.File]::ReadAllBytes($launcherExcludePath)
        Assert-True ($concurrentWriteRejected -and [Convert]::ToBase64String($concurrentBytesAfter) -ceq [Convert]::ToBase64String($concurrentBytes)) 'concurrent exclude edit is preserved and managed write is rejected'
        [System.IO.File]::WriteAllBytes($launcherExcludePath, $excludeBytesBeforeRace)

        $launcherSources = Join-Path $launcherRepo 'venv\Scripts'
        $launcherTargets = Join-Path $launcherRepo 'bin'
        New-Item -ItemType Directory -Path $launcherSources -Force | Out-Null
        New-Item -ItemType Directory -Path $launcherTargets -Force | Out-Null
        foreach ($name in @('hermes.exe', 'hermes-acp.exe')) {
            [byte[]]$bytes = New-TestPortableExecutableBytes -Seed "managed launcher $name"
            [System.IO.File]::WriteAllBytes((Join-Path $launcherSources $name), $bytes)
            [System.IO.File]::WriteAllBytes((Join-Path $launcherTargets $name), $bytes)
        }

        $validPeFixture = Join-Path $launcherRuntime 'valid-pe.exe'
        [System.IO.File]::WriteAllBytes($validPeFixture, [byte[]](New-TestPortableExecutableBytes -Seed 'valid direct PE fixture'))
        [byte[]]$mzOnlyBytes = New-Object byte[] 128
        $mzOnlyBytes[0] = 0x4D
        $mzOnlyBytes[1] = 0x5A
        $mzOnlyFixture = Join-Path $launcherRuntime 'mz-only.exe'
        [System.IO.File]::WriteAllBytes($mzOnlyFixture, $mzOnlyBytes)
        [byte[]]$badSignatureBytes = New-TestPortableExecutableBytes -Seed 'bad PE signature'
        $badSignatureBytes[0x80] = 0x51
        $badSignatureFixture = Join-Path $launcherRuntime 'bad-signature.exe'
        [System.IO.File]::WriteAllBytes($badSignatureFixture, $badSignatureBytes)
        $validPeHeader = & $installEngineModule { param($path) Test-HermesPortableExecutableHeader -LiteralPath $path } $validPeFixture
        $mzOnlyHeader = & $installEngineModule { param($path) Test-HermesPortableExecutableHeader -LiteralPath $path } $mzOnlyFixture
        $badSignatureHeader = & $installEngineModule { param($path) Test-HermesPortableExecutableHeader -LiteralPath $path } $badSignatureFixture
        Assert-True ($validPeHeader -and -not $mzOnlyHeader -and -not $badSignatureHeader) 'PE parser requires bounded e_lfanew and PE signature'

        $managedUvPath = Join-Path $launcherHome 'bin\uv.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $managedUvPath) -Force | Out-Null
        [byte[]]$managedUvBytes = New-TestPortableExecutableBytes -Seed 'same-run managed uv'
        [System.IO.File]::WriteAllBytes($managedUvPath, $managedUvBytes)
        $managedCommandProof = @{}
        & $installEngineModule {
            param($plan, $proof, $path)
            Update-HermesManagedCommandProofAfterStage -Plan $plan -ManagedCommandProof $proof -Stage 'uv' -PathValues @($path)
        } $launcherPlan $managedCommandProof $trustedRegistryGitDirectory
        $managedBoundary = & $installEngineModule {
            param($plan, $proof)
            Test-HermesManagedAbsoluteCommandBoundary -Plan $plan -ManagedCommandProof $proof
        } $launcherPlan $managedCommandProof
        [byte[]]$tamperedManagedUvBytes = [System.IO.File]::ReadAllBytes($managedUvPath)
        $tamperedManagedUvBytes[$tamperedManagedUvBytes.Length - 1] = $tamperedManagedUvBytes[$tamperedManagedUvBytes.Length - 1] -bxor 0x01
        [System.IO.File]::WriteAllBytes($managedUvPath, $tamperedManagedUvBytes)
        $tamperedManagedBoundary = & $installEngineModule {
            param($plan, $proof)
            Test-HermesManagedAbsoluteCommandBoundary -Plan $plan -ManagedCommandProof $proof
        } $launcherPlan $managedCommandProof
        [System.IO.File]::WriteAllBytes($managedUvPath, $managedUvBytes)
        Remove-Item -LiteralPath $managedUvPath -Force
        $missingManagedBoundary = & $installEngineModule {
            param($plan, $proof)
            Test-HermesManagedAbsoluteCommandBoundary -Plan $plan -ManagedCommandProof $proof
        } $launcherPlan $managedCommandProof
        [System.IO.File]::WriteAllBytes($managedUvPath, $managedUvBytes)
        $managedBrowserUsePath = Join-Path $launcherHome 'bin\browser-use.exe'
        New-Item -ItemType Directory -Path (Join-Path $launcherHome 'uv-tools') -Force | Out-Null
        [byte[]]$managedBrowserUseBytes = New-TestPortableExecutableBytes -Seed 'same-run managed browser use'
        [System.IO.File]::WriteAllBytes($managedBrowserUsePath, $managedBrowserUseBytes)
        & $installEngineModule {
            param($plan, $proof, $path)
            Update-HermesManagedCommandProofAfterStage -Plan $plan -ManagedCommandProof $proof -Stage 'node-deps' -PathValues @($path)
        } $launcherPlan $managedCommandProof $trustedRegistryGitDirectory
        $managedBashPath = Join-Path $launcherHome 'git\usr\bin\bash.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $managedBashPath) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($managedBashPath, [byte[]](New-TestPortableExecutableBytes -Seed 'untrusted managed bash'))
        $managedBashBoundary = & $installEngineModule {
            param($plan, $proof)
            Test-HermesManagedAbsoluteCommandBoundary -Plan $plan -ManagedCommandProof $proof
        } $launcherPlan $managedCommandProof
        Remove-Item -LiteralPath $managedBashPath -Force
        Assert-True ($managedCommandProof.Count -eq 2 -and $managedBoundary.Valid -and -not $tamperedManagedBoundary.Valid -and -not $missingManagedBoundary.Valid -and -not $managedBashBoundary.Valid) 'same-run managed command proof binds uv and browser-use and rejects tamper, deletion, and HermesHome Git Bash'

        $excludeFailureHandoff = & $installEngineModule {
            param($plan, $commit, $proof)
            $originalGetState = (Get-Command Get-HermesManagedLauncherExcludeState).ScriptBlock
            $originalRestoreExclude = (Get-Command Restore-HermesManagedLauncherExcludeFile).ScriptBlock
            $script:HermesTestOriginalGetExcludeState = $originalGetState
            $script:HermesTestExcludeStateCalls = 0
            try {
                Set-Item -Path 'Function:script:Get-HermesManagedLauncherExcludeState' -Value {
                    param([string]$InstallDir)
                    $script:HermesTestExcludeStateCalls++
                    $state = & $script:HermesTestOriginalGetExcludeState -InstallDir $InstallDir
                    if ($script:HermesTestExcludeStateCalls -ge 2) { $state.Complete = $false }
                    return $state
                }
                Set-Item -Path 'Function:script:Restore-HermesManagedLauncherExcludeFile' -Value {
                    param($State, [byte[]]$WrittenBytes)
                    return $false
                }
                try {
                    Initialize-HermesManagedLauncherExclusions -Plan $plan -ExpectedCommit $commit -FreshCheckoutProof $proof | Out-Null
                    return [pscustomobject]@{ Exception = $null; Pending = $null }
                } catch {
                    return [pscustomobject]@{ Exception = $_.Exception; Pending = $_.Exception.Data['HermesLauncherExcludeWrite'] }
                }
            } finally {
                Set-Item -Path 'Function:script:Get-HermesManagedLauncherExcludeState' -Value $originalGetState
                Set-Item -Path 'Function:script:Restore-HermesManagedLauncherExcludeFile' -Value $originalRestoreExclude
                Remove-Variable -Scope Script -Name HermesTestOriginalGetExcludeState -ErrorAction SilentlyContinue
                Remove-Variable -Scope Script -Name HermesTestExcludeStateCalls -ErrorAction SilentlyContinue
            }
        } $launcherPlan $launcherHead $freshProof
        $excludeHandoffRollback = & $installEngineModule {
            param($plan, $pending)
            Invoke-HermesExposureRollback -Snapshot $null -Plan $plan -FreshRepositoryProof $null -LauncherExcludeWrite $pending -LauncherAttestationWrite $null -Paths ([pscustomobject]@{}) -LogPath $null -Context 'exclude handoff test'
        } $launcherPlan $excludeFailureHandoff.Pending
        $excludeHandoffRestoredExactly = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($launcherExcludePath)) -ceq [Convert]::ToBase64String([byte[]]$freshProof.ExcludeBytes)
        Assert-True ($null -ne $excludeFailureHandoff.Exception -and $null -ne $excludeFailureHandoff.Pending -and $excludeHandoffRollback.ExcludeRestored -and $excludeHandoffRestoredExactly) 'post-write exclude failure hands state to independent outer CAS rollback'

        $launcherNormalization = & $installEngineModule {
            param($plan, $commit, $proof)
            Initialize-HermesManagedLauncherExclusions -Plan $plan -ExpectedCommit $commit -FreshCheckoutProof $proof
        } $launcherPlan $launcherHead $freshProof
        Assert-True ([bool]$launcherNormalization.Valid -and [bool]$launcherNormalization.Changed) 'exact managed launchers normalized from same-run fresh proof'
        $launcherExcludeText = [System.IO.File]::ReadAllText($launcherExcludePath, [System.Text.Encoding]::UTF8)
        $launcherActivePatterns = @($launcherExcludeText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith('#') })
        Assert-True ($launcherActivePatterns.Count -eq 2 -and $launcherActivePatterns -ccontains '/bin/hermes.exe' -and $launcherActivePatterns -ccontains '/bin/hermes-acp.exe') 'only exact launcher files are excluded'

        $launcherPaths = Get-HermesDefaultPaths -HermesHome $launcherHome -InstallDir $launcherRepo -RuntimeRoot $launcherRuntime
        New-Item -ItemType Directory -Path $launcherPaths.StateDir -Force | Out-Null
        $omittedManagedCommandRejected = $false
        try {
            & $installEngineModule {
                param($plan, $commit, $digest, $proof)
                New-HermesLauncherAttestation -Plan $plan -ExpectedCommit $commit -InstallerSha256 $digest -FreshCheckoutProof $proof
            } $launcherPlan $launcherHead ([string]$source.installer.sha256) $freshProof | Out-Null
        } catch { $omittedManagedCommandRejected = $true }
        $launcherAttestation = & $installEngineModule {
            param($plan, $commit, $digest, $proof, $commandProof)
            New-HermesLauncherAttestation -Plan $plan -ExpectedCommit $commit -InstallerSha256 $digest -FreshCheckoutProof $proof -ManagedCommandProof $commandProof
        } $launcherPlan $launcherHead ([string]$source.installer.sha256) $freshProof $managedCommandProof
        $launcherAttestationWrite = & $installEngineModule {
            param($paths, $attestation)
            Set-HermesLauncherAttestation -Paths $paths -Attestation $attestation
        } $launcherPaths $launcherAttestation
        $launcherAttestationCheck = & $installEngineModule {
            param($plan, $commit, $digest)
            Test-HermesLauncherAttestation -Plan $plan -ExpectedCommit $commit -InstallerSha256 $digest
        } $launcherPlan $launcherHead ([string]$source.installer.sha256)
        Assert-True ($omittedManagedCommandRejected -and $launcherAttestation.contract -ceq 'hermes-managed-launchers-and-commands-v1' -and @($launcherAttestation.managedCommands).Count -eq 2 -and $launcherAttestationWrite.Changed -and $launcherAttestationCheck.Valid -and $launcherAttestationCheck.ManagedCommandProof.Count -eq 2 -and (Test-Path -LiteralPath $launcherPaths.LauncherAttestationFile -PathType Leaf)) 'fresh proof publishes canonical nonempty managed command attestation'
        [byte[]]$attestedUvTamper = [System.IO.File]::ReadAllBytes($managedUvPath)
        $attestedUvTamper[0x1A0] = $attestedUvTamper[0x1A0] -bxor 0x01
        [System.IO.File]::WriteAllBytes($managedUvPath, $attestedUvTamper)
        $tamperedCommandAttestation = & $installEngineModule {
            param($plan, $commit, $digest)
            Test-HermesLauncherAttestation -Plan $plan -ExpectedCommit $commit -InstallerSha256 $digest
        } $launcherPlan $launcherHead ([string]$source.installer.sha256)
        [System.IO.File]::WriteAllBytes($managedUvPath, $managedUvBytes)
        $restoredCommandAttestation = & $installEngineModule {
            param($plan, $commit, $digest)
            Test-HermesLauncherAttestation -Plan $plan -ExpectedCommit $commit -InstallerSha256 $digest
        } $launcherPlan $launcherHead ([string]$source.installer.sha256)
        Assert-True (-not $tamperedCommandAttestation.Valid -and $restoredCommandAttestation.Valid) 'attested managed command tampering is rejected and exact bytes restore validity'

        $launcherStatus = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'status', '--porcelain=v1', '--untracked-files=all') -Environment $launcherEnvironment -TimeoutSeconds 30
        Assert-True ($launcherStatus.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($launcherStatus.StdOut)) 'launcher exclusions leave checkout clean'
        $unexpectedIgnore = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'check-ignore', '-q', '--no-index', '--', 'bin/unexpected.exe') -Environment $launcherEnvironment -TimeoutSeconds 30
        Assert-Equal 1 $unexpectedIgnore.ExitCode 'unexpected bin file is not ignored'

        $excludeBeforeRepeat = [System.IO.File]::ReadAllBytes($launcherExcludePath)
        $staleProofRejected = $false
        try {
            & $installEngineModule {
                param($plan, $commit, $proof)
                Initialize-HermesManagedLauncherExclusions -Plan $plan -ExpectedCommit $commit -FreshCheckoutProof $proof
            } $launcherPlan $launcherHead $freshProof | Out-Null
        } catch { $staleProofRejected = $true }
        $excludeAfterRepeat = [System.IO.File]::ReadAllBytes($launcherExcludePath)
        $readOnlyLaunchers = & $installEngineModule { param($path) Test-HermesManagedLaunchers -InstallDir $path } $launcherRepo
        $readOnlyExclusions = & $installEngineModule { param($path) Test-HermesManagedLauncherExclusions -InstallDir $path } $launcherRepo
        Assert-True ($staleProofRejected -and $readOnlyLaunchers.Valid -and $readOnlyExclusions.Valid -and [Convert]::ToBase64String($excludeBeforeRepeat) -ceq [Convert]::ToBase64String($excludeAfterRepeat)) 'stale proof cannot rewrite metadata while exact existing contract validates read-only'

        foreach ($name in @('hermes.exe', 'hermes-acp.exe')) {
            [byte[]]$swappedBytes = New-TestPortableExecutableBytes -Seed "swapped launcher $name"
            [System.IO.File]::WriteAllBytes((Join-Path $launcherSources $name), $swappedBytes)
            [System.IO.File]::WriteAllBytes((Join-Path $launcherTargets $name), $swappedBytes)
        }
        $swappedManagedPair = & $installEngineModule { param($path) Test-HermesManagedLaunchers -InstallDir $path } $launcherRepo
        $swappedAttestation = & $installEngineModule {
            param($plan, $commit, $digest)
            Test-HermesLauncherAttestation -Plan $plan -ExpectedCommit $commit -InstallerSha256 $digest
        } $launcherPlan $launcherHead ([string]$source.installer.sha256)
        Assert-True ($swappedManagedPair.Valid -and -not $swappedAttestation.Valid) 'matching source and target launcher swap is rejected by attestation'
        foreach ($name in @('hermes.exe', 'hermes-acp.exe')) {
            [byte[]]$originalBytes = New-TestPortableExecutableBytes -Seed "managed launcher $name"
            [System.IO.File]::WriteAllBytes((Join-Path $launcherSources $name), $originalBytes)
            [System.IO.File]::WriteAllBytes((Join-Path $launcherTargets $name), $originalBytes)
        }
        $restoredAttestation = & $installEngineModule {
            param($plan, $commit, $digest)
            Test-HermesLauncherAttestation -Plan $plan -ExpectedCommit $commit -InstallerSha256 $digest
        } $launcherPlan $launcherHead ([string]$source.installer.sha256)
        Assert-True $restoredAttestation.Valid 'original managed launchers restore the attested contract'

        $staticGateLog = Join-Path $launcherRuntime 'static-gate.log'
        $staticGate = Test-HermesInstallation -HermesHome $launcherHome -InstallDir $launcherRepo -RuntimeRoot $launcherRuntime -ExpectedCommit $launcherHead -LogPath $staticGateLog
        Assert-True (-not [bool]$staticGate.Verified -and $null -eq $staticGate.VersionExitCode -and [string]::IsNullOrWhiteSpace([string]$staticGate.CommandPath)) 'failed static provenance prevents launcher execution'
        Assert-True ($staticGate.CheckoutLayoutValid -and $staticGate.IndexMatchesExpectedTree -and $staticGate.IndexFlagsClean -and $staticGate.LocalGitConfigSafe -and $staticGate.RepositoryMetadataSafe -and $staticGate.NoGitLinks -and $staticGate.LauncherAttestationValid) 'static Git layout, metadata, index, and launcher attestation pass clean fixture'

        $addDuplicateWindowsConfig = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'config', '--local', '--add', 'windows.appendAtomically', 'false') -Environment $launcherEnvironment -TimeoutSeconds 30
        $duplicateWindowsMetadata = & $installEngineModule { param($path) Test-HermesRepositoryMetadataSafety -InstallDir $path } $launcherRepo
        $unsetWindowsConfig = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'config', '--local', '--unset-all', 'windows.appendAtomically') -Environment $launcherEnvironment -TimeoutSeconds 30
        $setTrueWindowsConfig = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'config', '--local', 'windows.appendAtomically', 'true') -Environment $launcherEnvironment -TimeoutSeconds 30
        $trueWindowsMetadata = & $installEngineModule { param($path) Test-HermesRepositoryMetadataSafety -InstallDir $path } $launcherRepo
        $restoreWindowsConfig = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'config', '--local', '--replace-all', 'windows.appendAtomically', 'false') -Environment $launcherEnvironment -TimeoutSeconds 30
        Assert-True ($addDuplicateWindowsConfig.ExitCode -eq 0 -and -not $duplicateWindowsMetadata.Valid -and $unsetWindowsConfig.ExitCode -eq 0 -and $setTrueWindowsConfig.ExitCode -eq 0 -and -not $trueWindowsMetadata.Valid -and $restoreWindowsConfig.ExitCode -eq 0) 'windows.appendAtomically allows one exact false value only'

        $filterMarker = Join-Path $launcherRuntime 'filter-executed.marker'
        $infoAttributesPath = Join-Path $launcherRepo '.git\info\attributes'
        $filterCommand = 'cmd.exe /d /c echo filter-executed>' + $filterMarker
        $setFilter = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'config', '--local', 'filter.pwn.clean', $filterCommand) -Environment $launcherEnvironment -TimeoutSeconds 30
        [System.IO.File]::WriteAllText($infoAttributesPath, ('tracked.txt filter=pwn' + [char]10), (New-Object System.Text.UTF8Encoding($false)))
        try {
            [System.IO.File]::WriteAllText((Join-Path $launcherRepo 'tracked.txt'), ('changed' + [char]10), (New-Object System.Text.UTF8Encoding($false)))
            $filterGate = Test-HermesInstallation -HermesHome $launcherHome -InstallDir $launcherRepo -RuntimeRoot $launcherRuntime -ExpectedCommit $launcherHead -LogPath $staticGateLog
            Assert-True ($setFilter.ExitCode -eq 0 -and -not $filterGate.RepositoryMetadataSafe -and $null -eq $filterGate.VersionExitCode -and -not (Test-Path -LiteralPath $filterMarker)) 'active info attributes and clean filter are rejected before Git execution'
        } finally {
            $removeFilter = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'config', '--local', '--remove-section', 'filter.pwn') -Environment $launcherEnvironment -TimeoutSeconds 30
            if (Test-Path -LiteralPath $infoAttributesPath -PathType Leaf) { Remove-Item -LiteralPath $infoAttributesPath -Force }
            [System.IO.File]::WriteAllText((Join-Path $launcherRepo 'tracked.txt'), ('pinned' + [char]10), (New-Object System.Text.UTF8Encoding($false)))
            if (Test-Path -LiteralPath $filterMarker -PathType Leaf) { Remove-Item -LiteralPath $filterMarker -Force }
        }
        Assert-Equal 0 $removeFilter.ExitCode 'malicious local filter fixture is removed'

        $localExcludeFixture = Join-Path $launcherRuntime 'local-excludes.txt'
        [System.IO.File]::WriteAllBytes($localExcludeFixture, [byte[]]@())
        $setLocalExclude = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'config', '--local', 'core.excludesFile', $localExcludeFixture) -Environment $launcherEnvironment -TimeoutSeconds 30
        $localGate = Test-HermesInstallation -HermesHome $launcherHome -InstallDir $launcherRepo -RuntimeRoot $launcherRuntime -ExpectedCommit $launcherHead -LogPath $staticGateLog
        $unsetLocalExclude = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'config', '--local', '--unset-all', 'core.excludesFile') -Environment $launcherEnvironment -TimeoutSeconds 30
        Assert-True ($setLocalExclude.ExitCode -eq 0 -and -not [bool]$localGate.LocalExcludeOverrideAbsent -and -not [bool]$localGate.LocalGitConfigSafe -and $null -eq $localGate.VersionExitCode -and $unsetLocalExclude.ExitCode -eq 0) 'local core.excludesFile override blocks execution'

        $setSkipWorktree = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'update-index', '--skip-worktree', 'tracked.txt') -Environment $launcherEnvironment -TimeoutSeconds 30
        $skipWorktreeGate = Test-HermesInstallation -HermesHome $launcherHome -InstallDir $launcherRepo -RuntimeRoot $launcherRuntime -ExpectedCommit $launcherHead -LogPath $staticGateLog
        $clearSkipWorktree = Invoke-HermesProcess -FilePath $signedSystemGit -ArgumentList @('-C', $launcherRepo, 'update-index', '--no-skip-worktree', 'tracked.txt') -Environment $launcherEnvironment -TimeoutSeconds 30
        Assert-True ($setSkipWorktree.ExitCode -eq 0 -and -not [bool]$skipWorktreeGate.IndexFlagsClean -and $null -eq $skipWorktreeGate.VersionExitCode -and $clearSkipWorktree.ExitCode -eq 0) 'skip-worktree index flag blocks execution'

        $unexpectedPath = Join-Path $launcherTargets 'unexpected.exe'
        [System.IO.File]::WriteAllText($unexpectedPath, 'unexpected', (New-Object System.Text.UTF8Encoding($false)))
        $excludeBeforeRejectedRun = [System.IO.File]::ReadAllBytes($launcherExcludePath)
        $unexpectedLaunchers = & $installEngineModule { param($path) Test-HermesManagedLaunchers -InstallDir $path } $launcherRepo
        $excludeAfterRejectedRun = [System.IO.File]::ReadAllBytes($launcherExcludePath)
        Assert-True (-not [bool]$unexpectedLaunchers.Valid -and [Convert]::ToBase64String($excludeBeforeRejectedRun) -ceq [Convert]::ToBase64String($excludeAfterRejectedRun)) 'unexpected bin file fails closed without metadata mutation'
        Remove-Item -LiteralPath $unexpectedPath -Force

        [System.IO.File]::WriteAllText((Join-Path $launcherTargets 'hermes.exe'), 'tampered', (New-Object System.Text.UTF8Encoding($false)))
        $tamperedLaunchers = & $installEngineModule { param($path) Test-HermesManagedLaunchers -InstallDir $path } $launcherRepo
        Assert-True (-not [bool]$tamperedLaunchers.Valid) 'launcher hash tampering rejected'
        Copy-Item -LiteralPath (Join-Path $launcherSources 'hermes.exe') -Destination (Join-Path $launcherTargets 'hermes.exe') -Force

        [System.IO.File]::WriteAllText($launcherExcludePath, ($launcherExcludeText + "/bin/`n"), (New-Object System.Text.UTF8Encoding($false)))
        $broadExclude = & $installEngineModule { param($path) Test-HermesManagedLauncherExclusions -InstallDir $path } $launcherRepo
        Assert-True (-not [bool]$broadExclude.Valid) 'broad launcher exclusion rejected'

        [System.IO.File]::WriteAllBytes($launcherExcludePath, [byte[]]$excludeBeforeRepeat)
        $rollbackIsolation = & $installEngineModule {
            param($snapshot, $plan, $proof, $excludeWrite, $attestationWrite, $paths, $log)
            Invoke-HermesExposureRollback -Snapshot $snapshot -Plan $plan -FreshRepositoryProof $proof -LauncherExcludeWrite $excludeWrite -LauncherAttestationWrite $attestationWrite -Paths $paths -LogPath $log -Context 'test rollback'
        } ([pscustomobject]@{}) $launcherPlan $freshProof $launcherNormalization.ExcludeWrite $launcherAttestationWrite $launcherPaths $staticGateLog
        $excludeRestoredExactly = $(if ([bool]$freshProof.ExcludeExists) {
            (Test-Path -LiteralPath $launcherExcludePath -PathType Leaf) -and
                [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($launcherExcludePath)) -ceq [Convert]::ToBase64String([byte[]]$freshProof.ExcludeBytes)
        } else {
            -not (Test-Path -LiteralPath $launcherExcludePath)
        })
        Assert-True ($rollbackIsolation.Errors.Count -ge 1 -and $rollbackIsolation.ExcludeRestored -and $rollbackIsolation.RemovedLaunchers.Count -eq 2 -and $rollbackIsolation.AttestationRemoved -and $excludeRestoredExactly -and -not (Test-Path -LiteralPath $launcherPaths.LauncherAttestationFile) -and -not (Test-Path -LiteralPath (Join-Path $launcherTargets 'hermes.exe')) -and -not (Test-Path -LiteralPath (Join-Path $launcherTargets 'hermes-acp.exe'))) 'rollback cleanup remains independent when PATH restoration throws'
    } finally {
        Remove-HermesStageEnvironmentArtifacts -Environment $launcherEnvironment -Plan $launcherPlan
    }

    $unsignedGitHome = Join-Path $testRootFull 'unsigned-git-home'
    $unsignedGitFixture = Join-Path $unsignedGitHome 'git\cmd\git.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $unsignedGitFixture) -Force | Out-Null
    [System.IO.File]::WriteAllText($unsignedGitFixture, 'fixture', (New-Object System.Text.UTF8Encoding($false)))
    $unsignedManagedCandidate = & $installEngineModule { param($path) Test-HermesGitCandidate -LiteralPath $path -RequireValidSignature } $unsignedGitFixture
    Assert-True ([string]::IsNullOrWhiteSpace($unsignedManagedCandidate)) 'unsigned managed Git is rejected'

    $competingGitHome = Join-Path $testRootFull 'competing-git-home'
    $competingGitExe = Join-Path $competingGitHome 'git\cmd\git.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $competingGitExe) -Force | Out-Null
    Copy-Item -LiteralPath $signedSystemGit -Destination $competingGitExe
    [System.IO.File]::WriteAllText((Join-Path (Split-Path -Parent $competingGitExe) 'git.cmd'), '@exit /b 0', (New-Object System.Text.ASCIIEncoding))
    $competingManagedCandidate = & $installEngineModule { param($path) Test-HermesGitCandidate -LiteralPath $path -RequireValidSignature } $competingGitExe
    Assert-True ([string]::IsNullOrWhiteSpace($competingManagedCandidate)) 'managed Git with competing git.cmd is rejected'

    Assert-Equal 'plain' (ConvertTo-WindowsProcessArgument -Argument 'plain') 'plain argv unchanged'
    Assert-Equal '"two words"' (ConvertTo-WindowsProcessArgument -Argument 'two words') 'space argv quoted'

    $pathProbeVariable = 'HERMES_EASY_SETUP_PATH_PROBE'
    $previousPathProbe = [Environment]::GetEnvironmentVariable($pathProbeVariable, [EnvironmentVariableTarget]::Process)
    $pathProbeTarget = Join-Path $testRootFull 'path-probe\bin'
    try {
        [Environment]::SetEnvironmentVariable($pathProbeVariable, $pathProbeTarget, [EnvironmentVariableTarget]::Process)
        $quotedPathProbe = '  ' + [char]34 + $pathProbeTarget + '\' + [char]34 + '  '
        $expandedPathProbe = '%' + $pathProbeVariable + '%'
        $quotedPathDetected = & $installEngineModule {
            param($value, $directory)
            Test-HermesPathContainsDirectory -PathValues @($value) -Directory $directory
        } $quotedPathProbe $pathProbeTarget
        $expandedPathDetected = & $installEngineModule {
            param($value, $directory)
            Test-HermesPathContainsDirectory -PathValues @($value) -Directory $directory
        } $expandedPathProbe $pathProbeTarget
        Assert-True ($quotedPathDetected -and $expandedPathDetected) 'PATH comparison canonicalizes quotes, trailing separators, and environment variables'

        $postconditionLauncher = [System.IO.Path]::GetFullPath((Join-Path $planA.InstallDir 'bin'))
        $postconditionSnapshot = [pscustomobject]@{
            ExpectedPath = "$postconditionLauncher;C:\Windows\System32"
            ExpectedHermesHome = [string]$planA.HermesHome
            LauncherDirectory = $postconditionLauncher
        }
        $validPathPostcondition = & $installEngineModule {
            param($plan, $snapshot, $path, $home)
            Test-HermesPathStagePostcondition -Plan $plan -Snapshot $snapshot -UserPath $path -UserHermesHome $home
        } $planA $postconditionSnapshot $postconditionSnapshot.ExpectedPath $planA.HermesHome
        $extraPathPostcondition = & $installEngineModule {
            param($plan, $snapshot, $path, $home)
            Test-HermesPathStagePostcondition -Plan $plan -Snapshot $snapshot -UserPath $path -UserHermesHome $home
        } $planA $postconditionSnapshot ($postconditionSnapshot.ExpectedPath + ';C:\extra') $planA.HermesHome
        $suffixPathPostcondition = & $installEngineModule {
            param($plan, $snapshot, $path, $home)
            Test-HermesPathStagePostcondition -Plan $plan -Snapshot $snapshot -UserPath $path -UserHermesHome $home
        } $planA $postconditionSnapshot (($postconditionSnapshot.ExpectedPath).Replace($postconditionLauncher, ($postconditionLauncher + '-suffix'))) $planA.HermesHome
        $wrongHomePostcondition = & $installEngineModule {
            param($plan, $snapshot, $path, $home)
            Test-HermesPathStagePostcondition -Plan $plan -Snapshot $snapshot -UserPath $path -UserHermesHome $home
        } $planA $postconditionSnapshot $postconditionSnapshot.ExpectedPath (Join-Path $testRootFull 'wrong-home')
        $canonicalHomePostcondition = & $installEngineModule {
            param($plan, $snapshot, $path, $home)
            Test-HermesPathStagePostcondition -Plan $plan -Snapshot $snapshot -UserPath $path -UserHermesHome $home
        } $planA $postconditionSnapshot $postconditionSnapshot.ExpectedPath ($planA.HermesHome.ToUpperInvariant() + '\')
        Assert-True ($validPathPostcondition.Valid -and -not $extraPathPostcondition.Valid -and -not $suffixPathPostcondition.Valid -and -not $wrongHomePostcondition.Valid -and $canonicalHomePostcondition.Valid) 'PATH stage requires the exact predicted PATH and canonical exact HERMES_HOME'

        $legacyDirectory = [System.IO.Path]::GetFullPath((Join-Path $planA.InstallDir 'venv\Scripts'))
        $rawPathCases = @(
            [pscustomobject]@{ Input = "C:\x;$legacyDirectory;"; Expected = "$postconditionLauncher;C:\x" },
            [pscustomobject]@{ Input = ('C:\x;"' + $legacyDirectory + '";'); Expected = ($postconditionLauncher + ';C:\x;"' + $legacyDirectory + '"') },
            [pscustomobject]@{ Input = "C:\x;$legacyDirectory\;"; Expected = "$postconditionLauncher;C:\x;$legacyDirectory\" },
            [pscustomobject]@{ Input = $null; Expected = "$postconditionLauncher;" },
            [pscustomobject]@{ Input = ($postconditionLauncher + '-suffix;C:\x'); Expected = ($postconditionLauncher + '-suffix;C:\x') }
        )
        $rawPathMatches = 0
        foreach ($rawCase in $rawPathCases) {
            $rawResult = & $installEngineModule {
                param($plan, $path)
                Get-HermesUpstreamPathStageValues -Plan $plan -UserPath $path -UserHermesHome $null
            } $planA $rawCase.Input
            if ([string]$rawResult.UserPath -ceq [string]$rawCase.Expected) { $rawPathMatches++ }
        }
        $suffixRawResult = & $installEngineModule {
            param($plan, $path)
            $values = Get-HermesUpstreamPathStageValues -Plan $plan -UserPath $path -UserHermesHome $null
            $snapshot = [pscustomobject]@{ ExpectedPath = $values.UserPath; ExpectedHermesHome = $values.UserHermesHome; LauncherDirectory = (Join-Path $plan.InstallDir 'bin') }
            Test-HermesPathStagePostcondition -Plan $plan -Snapshot $snapshot -UserPath $values.UserPath -UserHermesHome $values.UserHermesHome
        } $planA ($postconditionLauncher + '-suffix;C:\x')
        Assert-True ($rawPathMatches -eq $rawPathCases.Count -and -not $suffixRawResult.Valid) 'PATH snapshot models pinned upstream raw substring and empty-segment semantics byte-for-byte while requiring an exact launcher entry'

        $pathHomeRollbackIsolation = & $installEngineModule {
            param($plan)
            $originalPathRestore = (Get-Command Restore-HermesRejectedUserPathExposure).ScriptBlock
            $originalHomeRestore = (Get-Command Restore-HermesRejectedHermesHomeExposure).ScriptBlock
            $originalGitBashRestore = (Get-Command Restore-HermesRejectedGitBashExposure).ScriptBlock
            try {
                Set-Item -Path 'Function:script:Restore-HermesRejectedUserPathExposure' -Value { throw 'forced path restore failure' }
                Set-Item -Path 'Function:script:Restore-HermesRejectedHermesHomeExposure' -Value { return $true }
                Set-Item -Path 'Function:script:Restore-HermesRejectedGitBashExposure' -Value { return $true }
                Invoke-HermesExposureRollback -Snapshot ([pscustomobject]@{}) -Plan $plan -FreshRepositoryProof $null -LauncherExcludeWrite $null -LauncherAttestationWrite $null -Paths ([pscustomobject]@{}) -LogPath $null -Context 'path/home isolation test'
            } finally {
                Set-Item -Path 'Function:script:Restore-HermesRejectedUserPathExposure' -Value $originalPathRestore
                Set-Item -Path 'Function:script:Restore-HermesRejectedHermesHomeExposure' -Value $originalHomeRestore
                Set-Item -Path 'Function:script:Restore-HermesRejectedGitBashExposure' -Value $originalGitBashRestore
            }
        } $planA
        Assert-True (-not $pathHomeRollbackIsolation.PathRestored -and $pathHomeRollbackIsolation.HermesHomeRestored -and $pathHomeRollbackIsolation.GitBashPathRestored -and $pathHomeRollbackIsolation.Errors.Count -eq 1 -and [string]$pathHomeRollbackIsolation.Errors[0] -like 'path:*') 'HERMES_HOME and Git Bash rollback still run when PATH rollback throws'
    } finally {
        [Environment]::SetEnvironmentVariable($pathProbeVariable, $previousPathProbe, [EnvironmentVariableTarget]::Process)
    }
    $probeVariable = 'HERMES_EASY_SETUP_REMOVE_PROBE'
    $previousProbe = [Environment]::GetEnvironmentVariable($probeVariable, [EnvironmentVariableTarget]::Process)
    try {
        [Environment]::SetEnvironmentVariable($probeVariable, 'ambient', [EnvironmentVariableTarget]::Process)
        $probeCommand = "if (Test-Path Env:$probeVariable) { Write-Output present } else { Write-Output absent }"
        $probeResult = Invoke-HermesProcess -FilePath (Get-HermesPowerShellExecutable) -ArgumentList @('-NoLogo', '-NoProfile', '-Command', $probeCommand) -Environment @{ $probeVariable = $null } -TimeoutSeconds 30
        Assert-Equal 0 $probeResult.ExitCode 'child process environment removal succeeds'
        Assert-Equal 'absent' $probeResult.StdOut.Trim() 'null environment entry is not inherited by child process'
    } finally {
        [Environment]::SetEnvironmentVariable($probeVariable, $previousProbe, [EnvironmentVariableTarget]::Process)
    }

    $missingExecutable = Join-Path $testRootFull 'missing-process-start.exe'
    $startFailure = Invoke-HermesProcess -FilePath $missingExecutable -ArgumentList @('--version') -TimeoutSeconds 30
    Assert-True (-not $startFailure.Started -and $startFailure.ExitCode -eq -1 -and $startFailure.StartFailure -ceq 'ProcessStartFailed' -and -not $startFailure.TimedOut) 'Process.Start failure returns a structured diagnostic result'

    $streamLines = New-Object 'System.Collections.Generic.List[string]'
    $streamCallback = { param($streamName, $line); [void]$streamLines.Add(([string]$streamName + '|' + [string]$line)) }.GetNewClosure()
    $streamProbeCommand = '[Console]::Out.WriteLine("DEVICE-READY");[Console]::Out.Flush();Start-Sleep -Milliseconds 100;[Console]::Error.WriteLine("STREAM-DONE");exit 0'
    $streamResult = Invoke-HermesProcess -FilePath (Get-HermesPowerShellExecutable) -ArgumentList @('-NoLogo', '-NoProfile', '-Command', $streamProbeCommand) -TimeoutSeconds 30 -OutputLineCallback $streamCallback
    Assert-True ($streamResult.ExitCode -eq 0 -and $streamLines.Contains('StdOut|DEVICE-READY') -and $streamLines.Contains('StdErr|STREAM-DONE')) 'process output callback receives live stdout and stderr lines'
    Assert-True ($streamResult.StdOut.Trim() -ceq 'DEVICE-READY' -and $streamResult.StdErr.Trim() -ceq 'STREAM-DONE') 'streaming process result retains bounded captured output'

    $frameText = 'noise' + [Environment]::NewLine + '{"stage":"one","ok":true}' + [Environment]::NewLine + 'more'
    $frame = ConvertFrom-HermesJsonFrame -Text $frameText -RequiredProperty 'stage'
    Assert-Equal 'one' $frame.stage 'last valid JSON frame parsed'
    Assert-True (Test-HermesStageFrame -Frame ([pscustomobject]@{stage='uv';ok=$true;skipped=$false;reason=$null;duration_ms=1}) -ExpectedStage 'uv').Valid 'valid stage frame accepted'
    Assert-True (-not (Test-HermesStageFrame -Frame ([pscustomobject]@{stage='wrong';ok=$true;skipped=$false;reason=$null;duration_ms=1}) -ExpectedStage 'uv').Valid) 'wrong stage frame rejected'
    $nodeDepsPolicyReason = & $installEngineModule { Get-HermesMvpPolicyStageSkipReason -Stage 'node-deps' }
    $pathPolicyReason = & $installEngineModule { Get-HermesMvpPolicyStageSkipReason -Stage 'path' }
    Assert-True (-not [string]::IsNullOrWhiteSpace($nodeDepsPolicyReason) -and [string]::IsNullOrWhiteSpace($pathPolicyReason)) 'v0.1.2 policy skips only optional node-deps'

    $contract = Get-Content -Raw (Join-Path $projectRoot 'config\hermes-manifest.json') | ConvertFrom-Json
    function New-TestManifest([bool]$Desktop) {
        $stages = @()
        foreach ($name in @($contract.baseStages)) {
            $category = if (@('uv','python','git','node','system-packages') -contains $name) {
                'prereqs'
            } elseif (@('repository','venv','dependencies','node-deps') -contains $name) {
                'install'
            } elseif (@('path','config-templates','platform-sdks','bootstrap-marker') -contains $name) {
                'finalize'
            } else {
                'post-install'
            }
            $stages += [pscustomobject]@{
                name = [string]$name
                title = "Title $name"
                category = $category
                needs_user_input = (@('configure','gateway') -contains [string]$name)
            }
            if ($Desktop -and [string]$name -eq 'node-deps') {
                $stages += [pscustomobject]@{name='desktop';title='Desktop';category='install';needs_user_input=$false}
            }
        }
        return [pscustomobject]@{protocol_version=1;stages=$stages}
    }
    $baseManifest = New-TestManifest $false
    $desktopManifest = New-TestManifest $true
    Assert-True (Test-HermesInstallerManifest -Manifest $baseManifest -IncludeDesktop $false).Valid 'reviewed base manifest accepted'
    Assert-True (Test-HermesInstallerManifest -Manifest $desktopManifest -IncludeDesktop $true).Valid 'reviewed desktop manifest accepted'
    $baseManifest.stages[0].needs_user_input = $true
    Assert-True (-not (Test-HermesInstallerManifest -Manifest $baseManifest -IncludeDesktop $false).Valid) 'unexpected interactive stage rejected'
    $baseManifest = New-TestManifest $false

    $state = New-HermesInstallState -Plan $planA -Manifest $baseManifest
    $state = Set-HermesStageRecord -State $state -Name 'uv' -Status 'Succeeded' -DurationMs 5
    $statePath = Join-Path $testRootFull 'state\state.json'
    [void](Save-HermesInstallState -LiteralPath $statePath -State $state)
    $roundTrip = Read-HermesInstallState -LiteralPath $statePath
    Assert-True (Test-HermesStateCanResume -State $roundTrip -Plan $planA -Manifest $baseManifest) 'matching checkpoint resumes'
    Assert-True (-not (Test-HermesStateCanResume -State $roundTrip -Plan $planC -Manifest $baseManifest)) 'different plan checkpoint rejected'
    Assert-Equal 'Succeeded' (Get-HermesStageRecord -State $roundTrip -Name 'uv').status 'stage status persisted'

    $state.status = 'Failed'
    [void](Save-HermesInstallState -LiteralPath $statePath -State $state)
    $replacedState = Read-HermesInstallState -LiteralPath $statePath
    Assert-Equal 'Failed' $replacedState.status 'existing state file atomically replaced'
    $stateTemporaryFiles = @(Get-ChildItem -LiteralPath (Split-Path -Parent $statePath) -Filter '.state-*.tmp' -File -Force)
    Assert-Equal 0 $stateTemporaryFiles.Count 'state replacement leaves no temporary file'

    $fixture = Join-Path $testRootFull 'fixture-install.ps1'
    $fixtureScript = 'param([switch]$Manifest)' + [Environment]::NewLine + 'if($Manifest){''{"protocol_version":1,"stages":[]}''}'
    [System.IO.File]::WriteAllText($fixture, $fixtureScript, (New-Object System.Text.UTF8Encoding $false))
    $fixtureConfig = ($source | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    $fixtureConfig.installer.sha256 = ConvertTo-HermesSha256 -LiteralPath $fixture
    $fixtureConfig.installer.sizeBytes = (Get-Item -LiteralPath $fixture).Length
    $fixtureConfig.installer.maxBytes = 4096
    Assert-True (Test-HermesInstallerFile -LiteralPath $fixture -SourceConfig $fixtureConfig).Valid 'matching installer fixture accepted'
    [System.IO.File]::AppendAllText($fixture, '#tamper')
    Assert-True (-not (Test-HermesInstallerFile -LiteralPath $fixture -SourceConfig $fixtureConfig).Valid) 'tampered installer fixture rejected'

    [System.IO.File]::WriteAllText($fixture, "Write-Output 'fixture'", (New-Object System.Text.UTF8Encoding $false))
    $fixtureConfig.installer.sha256 = ConvertTo-HermesSha256 -LiteralPath $fixture
    $fixtureConfig.installer.sizeBytes = (Get-Item -LiteralPath $fixture).Length
    $fixtureConfig.installer.maxBytes = 4096
    $downloadRoot = Join-Path $testRootFull 'download'
    $downloadPaths = Get-HermesDefaultPaths -HermesHome (Join-Path $downloadRoot 'home') -RuntimeRoot $downloadRoot
    New-Item -ItemType Directory -Path $downloadPaths.LogDir -Force | Out-Null
    $downloader = { param($uri,$destination,$maximum); Copy-Item -LiteralPath $fixture -Destination $destination }.GetNewClosure()
    $verified = Get-HermesVerifiedInstaller -SourceConfig $fixtureConfig -Paths $downloadPaths -Downloader $downloader -LogPath (Join-Path $downloadPaths.LogDir 'test.log')
    Assert-Equal $fixtureConfig.installer.sha256 $verified.Sha256 'custom downloader content verified'

    $bundleRuntime = Join-Path $testRootFull 'bundle-runtime'
    $bundleHome = Join-Path $testRootFull 'bundle-home'
    New-Item -ItemType Directory -Path $bundleHome -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $bundleHome '.env'), 'API_KEY=must-not-ship')
    $bundle = Export-HermesDiagnosticBundle -HermesHome $bundleHome -RuntimeRoot $bundleRuntime
    $expanded = Join-Path $testRootFull 'expanded-bundle'
    Expand-Archive -LiteralPath $bundle.Path -DestinationPath $expanded
    $entries = @(Get-ChildItem -LiteralPath $expanded -Recurse -File | ForEach-Object { $_.Name })
    Assert-True ($entries -notcontains '.env') 'diagnostic bundle excludes .env'
    Assert-True ($entries -notcontains 'config.yaml') 'diagnostic bundle excludes config.yaml'
    Assert-True ($entries -contains 'preflight.json') 'diagnostic bundle includes preflight summary'

    [xml]$xaml = Get-Content -Raw (Join-Path $projectRoot 'ui\ResearchWindow.xaml')
    Assert-True ($null -ne $xaml.DocumentElement) 'GUI XAML is well-formed XML'
    $xamlText = Get-Content -Raw (Join-Path $projectRoot 'ui\ResearchWindow.xaml')
    Assert-True ($xamlText -match 'x:Name="HermesConsent"') 'GUI has explicit approval control'
    Assert-True ($xamlText -match 'x:Name="HermesInstallButton"[^>]*IsEnabled="False"') 'GUI install starts disabled'
    Assert-True ($xamlText -match 'x:Name="TeamTab"') 'GUI includes the 3+1 research team setup tab'
    Assert-True ($xamlText -match 'x:Name="ModelCombo"') 'GUI includes an in-wizard Codex model selector'
    Assert-True ($xamlText -match 'x:Name="AuthCode"' -and $xamlText -match 'x:Name="AuthOpenButton"') 'GUI displays the Codex device code and fixed browser action'
    Assert-True ($xamlText -notmatch 'Nous Portal|OpenRouter|Discord|Slack|Telegram|Spotify') 'GUI excludes unrelated provider and messaging setup choices'
    $codexModuleText = Get-Content -Raw (Join-Path $projectRoot 'src\HermesEasySetup.Codex.psm1')
    Assert-True ($codexModuleText -match "PYTHONUNBUFFERED.*=.*'1'" -and $codexModuleText -match "-Type 'oauth'") 'Codex OAuth streams its device code to a dedicated wizard event'
    Assert-True ($codexModuleText -match 'Test-HermesInstallation[^\r\n]+-StaticOnly' -and $codexModuleText -match '\$verification\.StaticProvenanceValid') 'Codex status refresh uses static provenance and never blocks on Hermes doctor'
    $inputModuleText = Get-Content -Raw (Join-Path $projectRoot 'src\HermesEasySetup.Input.psm1')
    Assert-True ($inputModuleText -match 'HermesEasySetup.LabInput.v1') 'NST input retains the original credential encryption contract'
    $labInputPath = Join-Path $testRootFull 'lab-input.bin'
    $labInput = [pscustomobject]@{ ProfileName = 'albus'; MattermostToken = 'lab-secret-token'; DashboardPassword = 'lab-secret-password' }
    Protect-HermesLabInput -Value $labInput -LiteralPath $labInputPath | Out-Null
    $labCipherText = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($labInputPath))
    Assert-True ($labCipherText -notmatch 'lab-secret-token|lab-secret-password') 'Lab worker input does not expose plaintext secrets'
    $labRoundTrip = Unprotect-HermesLabInput -LiteralPath $labInputPath
    Assert-Equal 'lab-secret-token' $labRoundTrip.MattermostToken 'Lab DPAPI input round-trips for the current user'
} finally {
    if (Test-Path -LiteralPath $testRootFull -PathType Container) {
        $resolved = [System.IO.Path]::GetFullPath($testRootFull)
        $tempPrefix = [System.IO.Path]::GetFullPath($tempBase)
        if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'hermes-easy-setup-tests-*') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

Write-Host ''
Write-Host "Passed: $script:passed  Failed: $script:failed"
if ($script:failed -gt 0) { exit 1 }
exit 0
