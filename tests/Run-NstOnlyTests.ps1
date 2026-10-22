[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Loader.psm1') -Force
$passed = 0
function Assert { param($Ok,[string]$Name) if (-not $Ok) { throw $Name }; $script:passed++; Write-Host "PASS $Name" }
$retired = @('Start-HermesEasySetup.cmd','Start-HermesAdminSetup.cmd','HermesEasySetup.Gui.ps1','HermesAdminSetup.Gui.ps1',
    'ui/MainWindow.xaml','ui/AdminWindow.xaml','src/HermesEasySetup.Lab.psm1','src/HermesEasySetup.Mattermost.psm1',
    'config/bot-control.json','config/mattermost-desktop.json','assets/bot-control/com.infonet.bot-control-0.6.2.tar.gz')
foreach ($file in $retired) { Assert (-not (Test-Path -LiteralPath (Join-Path $projectRoot $file))) ('Retired standalone feature absent: ' + $file) }
Assert (@(Get-ChildItem -LiteralPath $projectRoot -Filter 'Start-*.cmd' -File).Count -eq 1) 'Only one shipped wizard entry point'
Assert (@(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'ui') -Filter '*.xaml' -File).Count -eq 1) 'Only the unified NST research UI remains'
foreach ($name in @('Invoke-HermesAdminSetup','Invoke-HermesAdminBotSetup','Read-HermesAdminBotCredential','Invoke-HermesResearchPluginsSetup')) {
    Assert ((Get-Module HermesEasySetup.Admin).ExportedCommands.ContainsKey($name)) ('Research wizard shared server dependency retained: ' + $name)
}
Assert (-not (Get-Command Invoke-HermesAdminSetup).Parameters.ContainsKey('InstallBotControl')) 'Server backend no longer installs legacy Bot Control'
$tokens = $null; $errors = $null
$cli = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'HermesEasySetup.ps1'),[ref]$tokens,[ref]$errors)
Assert (@($errors).Count -eq 0) 'NST CLI parses'
$action = @($cli.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'Action' })[0]
$allowed = @($action.Attributes | Where-Object { $_.TypeName.Name -ceq 'ValidateSet' })[0].PositionalArguments.Value
Assert (@($allowed | Where-Object { $_ -cin @('LabSetup','MattermostSetup') }).Count -eq 0) 'Removed standalone actions cannot be invoked through CLI'
foreach ($name in @('AdminSetup','AdminBotSetup','ResearchTeamSetup','ResearchPluginsSetup','CodexStatus','CodexAuth','Bundle')) {
    Assert ($allowed -ccontains $name) ('Required NST worker action remains: ' + $name)
}
$payload = Get-HermesResearchTeamPayload
Assert ($payload.Files.Count -ge 50) 'Full pinned 3+1 team payload remains'
Assert (@(Get-HermesResearchTeamDefinition).Count -eq 4) 'Four research roles remain'
& (Get-Module HermesEasySetup.Admin) {
    if ((Get-HermesResearchPluginPackages).packages.Count -ne 2) { throw 'NST and board plugins required' }
    if (-not (Test-HermesNetBirdIPv4 '100.64.1.2') -or (Test-HermesNetBirdIPv4 '192.168.1.2')) { throw 'Owned server scope validation missing' }
}
Assert $true 'NST plugins and owned-server network validation retained'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('nst-input-compat-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    Add-Type -AssemblyName System.Security
    $entropy = [Text.Encoding]::UTF8.GetBytes('HermesEasySetup.LabInput.v1')
    $value = [pscustomobject]@{ Token = 'offline-compat-fixture'; DisplayName = '총괄' }
    $plain = [Text.Encoding]::UTF8.GetBytes(($value | ConvertTo-Json -Compress))
    $legacyPath = Join-Path $fixture 'legacy.bin'
    [IO.File]::WriteAllBytes($legacyPath,[Security.Cryptography.ProtectedData]::Protect($plain,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser))
    $read = Unprotect-HermesLabInput $legacyPath
    Assert ($read.Token -ceq $value.Token -and $read.DisplayName -ceq $value.DisplayName) 'Existing DPAPI bot/server credentials remain readable'
    $newPath = Join-Path $fixture 'new.bin'
    Protect-HermesLabInput $value $newPath | Out-Null
    $decoded = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($newPath),$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    Assert (([Text.Encoding]::UTF8.GetString($decoded) | ConvertFrom-Json).Token -ceq $value.Token) 'NST encrypted input preserves the original credential contract'
    Assert (-not [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($newPath)).Contains($value.Token)) 'NST transport contains no plaintext token'
    [Array]::Clear($plain,0,$plain.Length); [Array]::Clear($decoded,0,$decoded.Length)
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ([IO.Path]::GetDirectoryName($resolved) -cne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -cnotmatch '^nst-input-compat-[a-f0-9]{32}$') { throw 'Unsafe compatibility fixture cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host "$passed NST-only checks passed"
