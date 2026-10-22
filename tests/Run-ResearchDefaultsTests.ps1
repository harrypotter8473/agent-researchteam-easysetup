[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Loader.psm1') -Force
$script:passed = 0
function Assert { param($Ok, [string]$Name) if (-not $Ok) { throw $Name }; $script:passed++; Write-Host "PASS $Name" }
function Reject { param([scriptblock]$Action, [string]$Name) $failed = $false; try { & $Action | Out-Null } catch { $failed = $true }; Assert $failed $Name }

$runtime = 'C:\Users\Fixture\AppData\Local\HermesEasySetup'
$defaults = New-HermesResearchWizardOptions -WorkspacePath 'C:\Research'
Assert ($defaults.SchemaVersion -eq 2 -and $defaults.ReviewerSlots -eq 1 -and $defaults.TaskTimeoutMinutes -eq 180 -and $defaults.GatewayPort -eq 18400) 'Visible defaults: one referee, three hours per task, router on 18400'
Assert (-not $defaults.AllowModelEgress -and -not $defaults.AllowPublicWeb -and -not $defaults.MigrationConsent) 'No consent is preselected'
Assert ((New-HermesResearchWizardOptions).WorkspacePath.EndsWith('Hermes Research Workspace')) 'Default workspace is a separate Documents folder'
Reject { Assert-HermesResearchWizardOptions -Options $defaults -RuntimeRoot $runtime } 'Install refused without model and web consent'
$ok = New-HermesResearchWizardOptions -WorkspacePath 'C:\Research' -HumanUsername 'paul.song'
$ok.AllowModelEgress = $true; $ok.AllowPublicWeb = $true
$checked = Assert-HermesResearchWizardOptions -Options $ok -RuntimeRoot $runtime
Assert ($checked.WorkspacePath -ceq 'C:\Research' -and $checked.HumanUsername -ceq 'paul.song') 'Consented options validate'
foreach ($case in @(
    @{ Name = 'reviewer slots 0'; Key = 'ReviewerSlots'; Value = 0 }, @{ Name = 'reviewer slots 4'; Key = 'ReviewerSlots'; Value = 4 },
    @{ Name = 'timeout 10 minutes'; Key = 'TaskTimeoutMinutes'; Value = 10 }, @{ Name = 'timeout 13 hours'; Key = 'TaskTimeoutMinutes'; Value = 780 },
    @{ Name = 'privileged port'; Key = 'GatewayPort'; Value = 80 }, @{ Name = 'string number'; Key = 'ReviewerSlots'; Value = '2' },
    @{ Name = 'display-name user'; Key = 'HumanUsername'; Value = 'Paul Song' }, @{ Name = 'relative workspace'; Key = 'WorkspacePath'; Value = 'Research' },
    @{ Name = 'drive root'; Key = 'WorkspacePath'; Value = 'C:\' }, @{ Name = 'runtime folder'; Key = 'WorkspacePath'; Value = $runtime },
    @{ Name = 'inside runtime'; Key = 'WorkspacePath'; Value = ($runtime + '\research') }, @{ Name = 'string consent'; Key = 'AllowPublicWeb'; Value = 'true' }
)) {
    $bad = ($ok | ConvertTo-Json | ConvertFrom-Json)
    $bad.($case.Key) = $case.Value
    Reject { Assert-HermesResearchWizardOptions -Options $bad -RuntimeRoot $runtime } ('Options reject ' + $case.Name)
}
$extra = ($ok | ConvertTo-Json | ConvertFrom-Json); $extra | Add-Member NoteProperty Roles @{}
Reject { Assert-HermesResearchWizardOptions -Options $extra -RuntimeRoot $runtime } 'Options reject the old per-role policy grid'
$old = ($ok | ConvertTo-Json | ConvertFrom-Json); $old.SchemaVersion = 1
Reject { Assert-HermesResearchWizardOptions -Options $old -RuntimeRoot $runtime } 'Options reject schema 1'

Write-Host "PASS research wizard defaults ($script:passed assertions)" -ForegroundColor Green
exit 0
