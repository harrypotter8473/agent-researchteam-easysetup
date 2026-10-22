[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = New-Object Text.UTF8Encoding($false)
$projectRoot = Split-Path -Parent $PSScriptRoot
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixture = Join-Path $tempParent ('hermes-docker-cli-test-' + [guid]::NewGuid().ToString('N'))
$systemPowerShell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:passed = 0
function Assert {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw $Name }
    $script:passed++; Write-Host "PASS $Name"
}

# This Loader has no import, discovery, download, process, service, or network path.
# The child-only log helper lets the unchanged CLI catch report guard errors.
$fakeLoader = @'
Set-StrictMode -Version 2.0
function global:Protect-HermesLogText { param([string]$Text) return $Text }
function Get-HermesEasySetupExitCodes {
    return [pscustomobject]@{ Success = 0; InvalidArguments = 2; InstallStageFailed = 40; UnexpectedFailure = 70 }
}
function Get-HermesDefaultPaths {
    param([string]$RuntimeRoot)
    return [pscustomobject]@{ RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot) }
}
function Get-HermesDockerDesktopStatus {
    return [pscustomobject]@{
        Installed = $false; Ready = $false; StatusCode = 'Missing'; Summary = 'Fixture Docker status'
        CanInstall = $true; CanOpen = $false; Prerequisites = @(); Alternatives = @()
    }
}
function Install-HermesDockerDesktop {
    param([string]$RuntimeRoot, [switch]$Apply, [scriptblock]$ProgressCallback)
    if (-not $Apply) { throw 'Fixture installer requires Apply' }
    $scenario = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixture-scenario.txt')).Trim()
    if (@('EngineStopped','RebootRequired','InstallFailed','Cancelled','InstallerStillRunning','InstallNotDetected') -cnotcontains $scenario) {
        throw 'Unexpected fixture scenario'
    }
    if ($ProgressCallback) {
        & $ProgressCallback ([pscustomobject]@{ type = 'stage'; percent = 50; state = 'running'; message = 'Fixture installer only' })
    }
    return [pscustomobject]@{
        Installed = ($scenario -cnotin @('Cancelled','InstallNotDetected'))
        Ready = $false; CanInstall = $false; CanOpen = ($scenario -cnotin @('Cancelled','InstallNotDetected'))
        RebootRequired = ($scenario -ceq 'RebootRequired'); StatusCode = $scenario
        Summary = 'Fixture installation result'; Prerequisites = @(); Alternatives = @()
        FixtureMarker = 'retained-result-data'
    }
}
Export-ModuleMember -Function @(
    'Get-HermesEasySetupExitCodes','Get-HermesDefaultPaths',
    'Get-HermesDockerDesktopStatus','Install-HermesDockerDesktop'
)
'@

function Invoke-FixtureCli {
    param([string]$Action, [switch]$Apply, [switch]$JsonEvents)
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$cli,
        '-Action',$Action,'-RuntimeRoot',$runtimeRoot)
    if ($Apply) { $arguments += '-Apply' }
    $arguments += $(if ($JsonEvents) { '-JsonEvents' } else { '-Json' })
    $lines = @(& $systemPowerShell @arguments)
    $code = $LASTEXITCODE
    $events = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) { $events.Add(($line | ConvertFrom-Json -ErrorAction Stop)) }
    }
    return [pscustomobject]@{ ExitCode = $code; Events = $events.ToArray() }
}

try {
    $signature = Get-AuthenticodeSignature -LiteralPath $systemPowerShell
    Assert ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'Microsoft Corporation') 'Use signed Windows System32 PowerShell'
    $src = Join-Path $fixture 'src'
    New-Item -ItemType Directory -Path $src | Out-Null
    $cli = Join-Path $fixture 'HermesEasySetup.ps1'
    Copy-Item -LiteralPath (Join-Path $projectRoot 'HermesEasySetup.ps1') -Destination $cli
    $loaderPath = Join-Path $src 'HermesEasySetup.Loader.psm1'
    [IO.File]::WriteAllText($loaderPath, $fakeLoader, (New-Object Text.UTF8Encoding($true)))
    $scenarioPath = Join-Path $src 'fixture-scenario.txt'
    $runtimeRoot = Join-Path $fixture 'runtime-must-not-exist'
    Assert (@(Get-ChildItem -LiteralPath $src -File).Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $src 'HermesEasySetup.Docker.psm1'))) 'Fixture cannot load the real Docker implementation'

    $status = Invoke-FixtureCli -Action 'DockerStatus'
    Assert ($status.ExitCode -eq 0 -and $status.Events.Count -eq 1 -and $status.Events[0].StatusCode -ceq 'Missing' -and $status.Events[0].Ready -is [bool] -and -not $status.Events[0].Ready) 'Docker status returns read-only JSON with exit zero'
    Assert (-not (Test-Path -LiteralPath $runtimeRoot)) 'Docker status creates no runtime directory'

    $guard = Invoke-FixtureCli -Action 'DockerInstall' -JsonEvents
    Assert ($guard.ExitCode -eq 2 -and $guard.Events.Count -eq 1 -and $guard.Events[0].type -ceq 'error' -and $guard.Events[0].exit_code -eq 2 -and $guard.Events[0].message -like '*-Apply*') 'Docker install without Apply returns default-deny exit two'
    Assert (-not (Test-Path -LiteralPath $runtimeRoot)) 'Apply rejection creates no runtime directory'

    foreach ($scenario in @('EngineStopped','RebootRequired','InstallFailed','Cancelled','InstallerStillRunning','InstallNotDetected')) {
        [IO.File]::WriteAllText($scenarioPath, $scenario, (New-Object Text.UTF8Encoding($false)))
        $result = Invoke-FixtureCli -Action 'DockerInstall' -Apply -JsonEvents
        $completions = @($result.Events | Where-Object { $_.type -ceq 'complete' })
        $failure = @('InstallFailed','Cancelled','InstallerStillRunning','InstallNotDetected') -ccontains $scenario
        $expectedExit = $(if ($failure) { 40 } else { 0 })
        $expectedState = $(if ($failure) { 'failed' } else { 'closed' })
        Assert ($result.ExitCode -eq $expectedExit) ("$scenario has the correct CLI exit code")
        Assert ($completions.Count -eq 1 -and $completions[0].state -ceq $expectedState) ("$scenario keeps its complete event and state")
        Assert ($completions[0].data.StatusCode -ceq $scenario -and $completions[0].data.FixtureMarker -ceq 'retained-result-data' -and $completions[0].data.Ready -is [bool] -and -not $completions[0].data.Ready) ("$scenario retains result data without claiming engine readiness")
        if ($scenario -ceq 'RebootRequired') { Assert ($completions[0].data.RebootRequired -eq $true -and $completions[0].data.Installed -eq $true) 'Reboot result preserves installed and restart-required flags' }
        if ($scenario -ceq 'EngineStopped') { Assert ($completions[0].data.Installed -eq $true) 'Installed engine-stopped outcome remains a successful install' }
        Assert (-not (Test-Path -LiteralPath $runtimeRoot)) ("$scenario invokes only the fixture installer")
    }
    Write-Host ('Docker CLI tests passed: ' + $script:passed)
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -cne $tempParent -or [IO.Path]::GetFileName($resolved) -cnotmatch '^hermes-docker-cli-test-[a-f0-9]{32}$') {
        throw 'Unsafe Docker CLI fixture cleanup path'
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
