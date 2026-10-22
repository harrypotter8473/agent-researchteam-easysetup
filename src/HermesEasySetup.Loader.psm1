Set-StrictMode -Version 2.0

$modules = @(
    'HermesEasySetup.Core.psm1',
    'HermesEasySetup.Preflight.psm1',
    'HermesEasySetup.StateStore.psm1',
    'HermesEasySetup.Execution.psm1',
    'HermesEasySetup.Protocol.psm1',
    'HermesEasySetup.InstallEngine.psm1',
    'HermesEasySetup.Existing.psm1',
    'HermesEasySetup.Codex.psm1',
    'HermesEasySetup.Input.psm1',
    'HermesEasySetup.Docker.psm1',
    'HermesEasySetup.Admin.psm1',
    'HermesEasySetup.Research.psm1',
    'HermesEasySetup.ResearchRuntime.psm1',
    'HermesEasySetup.Bundle.psm1'
)
foreach ($module in $modules) {
    Import-Module (Join-Path $PSScriptRoot $module) -Force -Global -DisableNameChecking
}

Export-ModuleMember -Function @()
