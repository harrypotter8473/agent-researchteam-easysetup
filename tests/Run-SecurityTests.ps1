[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Loader.psm1') -Force

$script:passed = 0
$script:failed = 0
function Assert-SecurityTrue {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS $Name" -ForegroundColor Green; $script:passed++ }
    else { Write-Host "FAIL $Name" -ForegroundColor Red; $script:failed++ }
}
function Get-Check {
    param($Preflight, [string]$Name)
    return @($Preflight.Checks | Where-Object { [string]$_.Name -eq $Name } | Select-Object -First 1)[0]
}

$tempBase = [System.IO.Path]::GetTempPath()
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $tempBase ('hermes-easy-setup-security-' + [guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$encoding = New-Object System.Text.UTF8Encoding $false

try {
    $source = Get-HermesSourceConfig
    Assert-SecurityTrue ([string]$source.hermes.tagObjectSha -eq 'b05e680e63d39d5a8e3ec0f5842a41d1c4209c03') 'annotated tag object recorded separately'
    Assert-SecurityTrue ([string]$source.hermes.commitSha -eq 'fcbd1076a93841fa88855acce810e342a5b78101') 'peeled release commit is execution pin'
    Assert-SecurityTrue ([string]$source.hermes.tagObjectSha -ne [string]$source.hermes.commitSha) 'tag object cannot masquerade as commit'

    $tagAsCommit = $source | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $tagAsCommit.hermes.commitSha = [string]$tagAsCommit.hermes.tagObjectSha
    Assert-SecurityTrue (-not (Test-HermesSourceConfig -Config $tagAsCommit).Valid) 'tag object rejected in commit field'

    $planHermesHome = Join-Path $testRoot 'plan-home'
    $runtime = Join-Path $testRoot 'plan-runtime'
    $plan = New-HermesInstallPlan -HermesHome $planHermesHome -RuntimeRoot $runtime -SkipComputerUse
    $mutatedSource = $source | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $mutatedSource.installer.sha256 = ('A' * 64)
    $mutatedSourcePath = Join-Path $testRoot 'mutated-source.json'
    [System.IO.File]::WriteAllText($mutatedSourcePath, ($mutatedSource | ConvertTo-Json -Depth 12), $encoding)
    $mutatedPlan = New-HermesInstallPlan -HermesHome $planHermesHome -RuntimeRoot $runtime -SkipComputerUse -SourceConfigPath $mutatedSourcePath
    Assert-SecurityTrue ($plan.Fingerprint -ne $mutatedPlan.Fingerprint) 'installer digest changes plan fingerprint'

    $manifestCopy = Join-Path $testRoot 'manifest.json'
    $manifestText = [System.IO.File]::ReadAllText((Join-Path $projectRoot 'config\hermes-manifest.json'), [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($manifestCopy, $manifestText + [Environment]::NewLine, $encoding)
    $manifestPlan = New-HermesInstallPlan -HermesHome $planHermesHome -RuntimeRoot $runtime -SkipComputerUse -ManifestContractPath $manifestCopy
    Assert-SecurityTrue ($plan.Fingerprint -ne $manifestPlan.Fingerprint) 'manifest contract bytes change plan fingerprint'

    $approvalRejected = $false
    try {
        Invoke-HermesInstall -HermesHome $planHermesHome -RuntimeRoot $runtime -SkipComputerUse -ExpectedPlanFingerprint ('0' * 64) | Out-Null
    } catch {
        $approvalRejected = ($_.Exception.Data.Contains('ExitCode') -and [int]$_.Exception.Data['ExitCode'] -eq 2)
    }
    Assert-SecurityTrue $approvalRejected 'mismatched approved fingerprint rejected before install'
    Assert-SecurityTrue (-not (Test-Path -LiteralPath $runtime -PathType Container)) 'fingerprint rejection makes no runtime directory'

    $layoutHome = Join-Path $testRoot 'layout-home'
    $layoutRuntime = Join-Path $testRoot 'layout-runtime'
    $badLayout = Get-HermesPreflight -HermesHome $layoutHome -InstallDir (Join-Path $layoutHome 'other') -RuntimeRoot $layoutRuntime
    Assert-SecurityTrue ((Get-Check $badLayout 'InstallLayout').Status -eq 'Fail') 'non-contract InstallDir rejected'
    $badOverlap = Get-HermesPreflight -HermesHome $layoutHome -RuntimeRoot (Join-Path $layoutHome 'runtime')
    Assert-SecurityTrue ((Get-Check $badOverlap 'RuntimeIsolation').Status -eq 'Fail') 'runtime and Hermes data overlap rejected'

    $foreignHome = Join-Path $testRoot 'foreign-home'
    $foreignInstall = Join-Path $foreignHome 'hermes-agent'
    New-Item -ItemType Directory -Path $foreignInstall -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $foreignInstall 'unrelated.txt'), 'foreign')
    $foreign = Get-HermesPreflight -HermesHome $foreignHome -RuntimeRoot (Join-Path $testRoot 'foreign-runtime')
    Assert-SecurityTrue ((Get-Check $foreign 'InstallDirectory').Status -eq 'Fail') 'foreign nonempty install directory rejected'

    $officialHome = Join-Path $testRoot 'official-home'
    $officialGit = Join-Path $officialHome 'hermes-agent\.git'
    New-Item -ItemType Directory -Path $officialGit -Force | Out-Null
    $gitConfig = "[remote `"origin`"]`r`n`turl = git@github.com:NousResearch/hermes-agent.git`r`n"
    [System.IO.File]::WriteAllText((Join-Path $officialGit 'config'), $gitConfig, $encoding)
    $official = Get-HermesPreflight -HermesHome $officialHome -RuntimeRoot (Join-Path $testRoot 'official-runtime')
    Assert-SecurityTrue ((Get-Check $official 'GitOrigin').Status -eq 'Pass') 'exact official SSH origin accepted'

    $unofficialHome = Join-Path $testRoot 'unofficial-home'
    $unofficialGit = Join-Path $unofficialHome 'hermes-agent\.git'
    New-Item -ItemType Directory -Path $unofficialGit -Force | Out-Null
    $unofficialOrigin = 'https://origin-user:origin-secret@github.com/evil/example.git'
    $unofficialConfig = "[remote `"origin`"]`r`n`turl = $unofficialOrigin`r`n"
    [System.IO.File]::WriteAllText((Join-Path $unofficialGit 'config'), $unofficialConfig, $encoding)
    $unofficial = Get-HermesPreflight -HermesHome $unofficialHome -RuntimeRoot (Join-Path $testRoot 'unofficial-runtime')
    $unofficialDetails = @($unofficial.Checks | ForEach-Object { [string]$_.Detail }) -join ' '
    Assert-SecurityTrue ((Get-Check $unofficial 'GitOrigin').Status -eq 'Fail' -and $unofficialDetails -notmatch 'origin-user|origin-secret') 'preflight rejects and redacts non-official origin'
    Assert-SecurityTrue ([string]$unofficial.ExistingOrigin -eq '[NON-OFFICIAL-REDACTED]') 'preflight JSON redacts non-official origin'

    $trustedGit = Get-HermesVerificationGitPath -HermesHome $unofficialHome
    $verificationHome = Join-Path $testRoot 'verification-origin-home'
    $verificationRepo = Join-Path $verificationHome 'hermes-agent'
    New-Item -ItemType Directory -Path $verificationRepo -Force | Out-Null
    $initResult = Invoke-HermesProcess -FilePath $trustedGit -ArgumentList @('init', $verificationRepo) -TimeoutSeconds 30
    $remoteResult = Invoke-HermesProcess -FilePath $trustedGit -ArgumentList @('-C', $verificationRepo, 'remote', 'add', 'origin', $unofficialOrigin) -TimeoutSeconds 30
    Assert-SecurityTrue ($initResult.ExitCode -eq 0 -and $remoteResult.ExitCode -eq 0) 'non-official origin verification fixture created'
    0..21 | ForEach-Object { [System.IO.File]::WriteAllText((Join-Path $verificationRepo ('dirty-{0:D2}.txt' -f $_)), 'fixture', $encoding) }
    [System.IO.File]::WriteAllText((Join-Path $verificationRepo 'API_KEY=file-secret.txt'), 'fixture', $encoding)
    $originVerification = Test-HermesInstallation -HermesHome $verificationHome -InstallDir $verificationRepo -RuntimeRoot (Join-Path $testRoot 'verification-origin-runtime')
    Assert-SecurityTrue (-not $originVerification.OriginOfficial -and [string]$originVerification.Origin -eq '[NON-OFFICIAL-REDACTED]') 'verification JSON redacts non-official origin'
    Assert-SecurityTrue ([bool]$originVerification.CheckoutStatusTruncated -and ([string]$originVerification.CheckoutStatus).Length -le 4096) 'checkout diagnostics cap status lines and characters'
    Assert-SecurityTrue ([string]$originVerification.CheckoutStatus -notmatch 'file-secret|origin-secret' -and @($originVerification.FailedChecks) -contains 'CheckoutClean') 'checkout diagnostics redact secret filenames and name dirty failure'

    $fakeBin = Join-Path $testRoot 'fake-bin'
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $fakeBin 'hermes.cmd'), '@exit /b 0', $encoding)
    $oldPath = $env:PATH
    try {
        $env:PATH = $fakeBin + ';' + $oldPath
        $targetOnly = Get-HermesCommandPath -HermesHome (Join-Path $testRoot 'empty-home') -InstallDir (Join-Path $testRoot 'empty-home\hermes-agent')
        Assert-SecurityTrue ($null -eq $targetOnly) 'PATH Hermes cannot satisfy target verification'
    } finally { $env:PATH = $oldPath }

    $trustedPowerShell = Get-HermesPowerShellExecutable
    $expectedPowerShell = [System.IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    Assert-SecurityTrue ($trustedPowerShell.Equals($expectedPowerShell, [StringComparison]::OrdinalIgnoreCase)) 'only exact signed System32 PowerShell selected'
    $restrictedModulePath = Join-Path $testRoot 'nonexistent-module-path'
    $moduleProbePath = Join-Path $testRoot 'restricted-module-path-probe.ps1'
    $loaderPathForProbe = (Join-Path $projectRoot 'src\HermesEasySetup.Loader.psm1').Replace("'", "''")
    $expectedPowerShellForProbe = $expectedPowerShell.Replace("'", "''")
    $moduleProbeText = @"
`$ErrorActionPreference = 'Stop'
Import-Module '$loaderPathForProbe' -Force
`$resolved = Get-HermesPowerShellExecutable
if (-not `$resolved.Equals('$expectedPowerShellForProbe', [StringComparison]::OrdinalIgnoreCase)) { exit 1 }
"@
    [System.IO.File]::WriteAllText($moduleProbePath, $moduleProbeText, $encoding)
    $moduleProbe = Invoke-HermesProcess -FilePath $trustedPowerShell `
        -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $moduleProbePath) `
        -Environment @{ PSModulePath = $restrictedModulePath } -TimeoutSeconds 30
    Assert-SecurityTrue ($moduleProbe.ExitCode -eq 0) 'trusted Authenticode module loads with a restricted inherited PSModulePath'
    $timeoutResult = Invoke-HermesProcess -FilePath $trustedPowerShell -ArgumentList @('-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 10') -TimeoutSeconds 1
    Assert-SecurityTrue ($timeoutResult.TimedOut -and $timeoutResult.ExitCode -eq -1) 'hung process tree is bounded by timeout'

    $resumeManifest = [pscustomobject]@{ stages = @([pscustomobject]@{name='uv';title='uv';category='prereqs';needs_user_input=$false}) }
    $resumeState = New-HermesInstallState -Plan $plan -Manifest $resumeManifest
    Assert-SecurityTrue (Test-HermesStateCanResume -State $resumeState -Plan $plan -Manifest $resumeManifest) 'running matching state can resume'
    $resumeState.status = 'Completed'
    Assert-SecurityTrue (-not (Test-HermesStateCanResume -State $resumeState -Plan $plan -Manifest $resumeManifest)) 'completed state cannot masquerade as interrupted resume'
    $resumeState.status = 'Failed'
    $resumeState.stages[0].status = 'Bogus'
    Assert-SecurityTrue (-not (Test-HermesStateCanResume -State $resumeState -Plan $plan -Manifest $resumeManifest)) 'corrupt stage status rejected'
    $resumeState.stages[0].status = 'Succeeded'
    $resetState = Reset-HermesStateForSafeResume -State $resumeState
    Assert-SecurityTrue ($resetState.stages[0].status -eq 'Pending') 'safe resume reapplies automatic stages'

    $diagnosticPaths = Get-HermesDefaultPaths -HermesHome (Join-Path $testRoot 'private-home') -RuntimeRoot (Join-Path $testRoot 'private-runtime')
    $privateText = "$($diagnosticPaths.HermesHome) $([Environment]::GetFolderPath('UserProfile'))?token=secret-value https://diag-user:diag-password@example.com/path"
    $protectedText = Protect-HermesDiagnosticText -Text $privateText -Paths $diagnosticPaths
    Assert-SecurityTrue ($protectedText -notmatch [regex]::Escape($diagnosticPaths.HermesHome)) 'diagnostic text removes Hermes absolute path'
    Assert-SecurityTrue ($protectedText -notmatch [regex]::Escape([Environment]::GetFolderPath('UserProfile'))) 'diagnostic text removes user profile path'
    Assert-SecurityTrue ($protectedText -notmatch 'secret-value') 'diagnostic text removes URL query secret'
    Assert-SecurityTrue ($protectedText -notmatch 'diag-user|diag-password') 'diagnostic text removes URL userinfo secret'
} finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        $tempPrefix = [System.IO.Path]::GetFullPath($tempBase)
        if ($testRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $testRoot) -like 'hermes-easy-setup-security-*') {
            Remove-Item -LiteralPath $testRoot -Recurse -Force
        }
    }
}

Write-Host ''
Write-Host "Passed: $script:passed  Failed: $script:failed"
if ($script:failed -gt 0) { exit 1 }
exit 0
