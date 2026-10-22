[CmdletBinding()]
param([switch]$IncludeDistribution)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$shell = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$tests = @('Test-RepositoryHygiene.ps1','Test-PowerShellSyntax.ps1','Run-NstOnlyTests.ps1',
    'Run-Tests.ps1','Run-SecurityTests.ps1','Run-ExistingRuntimeTests.ps1','Run-CodexRuntimeTests.ps1',
    'Run-CliTests.ps1','Run-AdminTests.ps1','Run-AdminBotTests.ps1','Run-AdminNetworkTests.ps1',
    'Run-DockerTests.ps1','Run-DockerCliTests.ps1','Run-ResearchTests.ps1','Run-ResearchRuntimeTests.ps1',
    'Run-ResearchDefaultsTests.ps1','Run-ResearchMigrationTests.ps1','Run-ResearchPluginsTests.ps1')
if ($IncludeDistribution) { $tests += 'Run-DistributionTests.ps1' }
foreach ($test in $tests) {
    Write-Host ('Running NST regression: ' + $test)
    & $shell -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $test)
    if ($LASTEXITCODE -ne 0) { throw ('NST regression failed: ' + $test + ' (exit ' + $LASTEXITCODE + ')') }
}
& $shell -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $root 'HermesResearchSetup.Gui.ps1') -SmokeTest
if ($LASTEXITCODE -ne 0) { throw 'NST Research GUI smoke failed' }
Write-Host ('PASS NST regression: ' + $tests.Count + ' suites and unified Research GUI; no live models or installed services modified')
