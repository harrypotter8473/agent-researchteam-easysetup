[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$errors = New-Object System.Collections.Generic.List[string]

$expectedModules = @(
    'HermesEasySetup.Admin.psm1',
    'HermesEasySetup.Bundle.psm1',
    'HermesEasySetup.Codex.psm1',
    'HermesEasySetup.Core.psm1',
    'HermesEasySetup.Docker.psm1',
    'HermesEasySetup.Execution.psm1',
    'HermesEasySetup.Existing.psm1',
    'HermesEasySetup.InstallEngine.psm1',
    'HermesEasySetup.Input.psm1',
    'HermesEasySetup.Loader.psm1',
    'HermesEasySetup.Preflight.psm1',
    'HermesEasySetup.Protocol.psm1',
    'HermesEasySetup.Research.psm1',
    'HermesEasySetup.ResearchRuntime.psm1',
    'HermesEasySetup.StateStore.psm1'
) | Sort-Object
$actualModules = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'src') -Filter '*.psm1' -File | ForEach-Object { $_.Name } | Sort-Object)
if (($expectedModules -join "`n") -cne ($actualModules -join "`n")) {
    $errors.Add("src module allowlist mismatch. Expected: $($expectedModules -join ', '); Actual: $($actualModules -join ', ')")
}

$forbiddenNamePatterns = @(
    '(?i)(?:^|[._-])(initial|backup|old|temp|tmp|v1)(?:[._-]|$)',
    '(?i)^\.env(?:\..*)?$',
    '(?i)^config\.ya?ml$',
    '(?i)\.(?:pem|p12|pfx|key|cer|crt|log|zip)$',
    '(?i)ui-transport'
)
foreach ($file in @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Force)) {
    $relative = $file.FullName.Substring($projectRoot.Length).TrimStart('\')
    foreach ($pattern in $forbiddenNamePatterns) {
        if ($file.Name -match $pattern -or $relative -match $pattern) { $errors.Add("forbidden repository file: $relative"); break }
    }
    if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $errors.Add("reparse-point file is not allowed: $relative") }
}
foreach ($directory in @(Get-ChildItem -LiteralPath $projectRoot -Recurse -Directory -Force)) {
    if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        $errors.Add("reparse-point directory is not allowed: $($directory.FullName.Substring($projectRoot.Length).TrimStart('\'))")
    }
}

$configFiles = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'config') -File | ForEach-Object { $_.Name } | Sort-Object)
$expectedConfig = @('docker-desktop.json', 'hermes-manifest.json', 'hermes-source.json', 'mattermost-plugins.json', 'mattermost-server.json')
if (($configFiles -join "`n") -cne ($expectedConfig -join "`n")) { $errors.Add("config allowlist mismatch: $($configFiles -join ', ')") }

if ($errors.Count -gt 0) {
    $errors.ToArray() | ForEach-Object { Write-Host "FAIL $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'PASS repository packaging allowlist and hygiene' -ForegroundColor Green
exit 0
