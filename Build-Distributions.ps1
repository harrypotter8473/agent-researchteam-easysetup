[CmdletBinding()]
param([string]$DestinationRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'nst-research-team-dist'))
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\HermesEasySetup.Loader.psm1') -Force
function Assert-DistributionPath { param([string]$Path) & (Get-Module HermesEasySetup.Admin) { param($Value) Assert-HermesAdminPath $Value } $Path }
$DestinationRoot = [IO.Path]::GetFullPath($DestinationRoot)
Assert-DistributionPath $DestinationRoot
if ($DestinationRoot.TrimEnd('\') -eq [IO.Path]::GetPathRoot($DestinationRoot).TrimEnd('\') -or $DestinationRoot.StartsWith('\\') -or
    $DestinationRoot -eq $PSScriptRoot -or (Test-HermesPathContains -ParentPath $PSScriptRoot -ChildPath $DestinationRoot)) { throw '배포 출력은 소스 폴더 밖의 별도 로컬 폴더를 선택하세요.' }
$version = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VERSION')).Trim()
if ($version -cnotmatch '^\d+\.\d+\.\d+$') { throw 'Invalid distribution version' }
# Explicit allowlist, never archive the worktree, runtime, .git, backups, or personal notes.
$common = @('HermesEasySetup.ps1','VERSION','LICENSE','README.md','SECURITY.md',
    'config/hermes-manifest.json','config/hermes-source.json','config/mattermost-server.json','config/docker-desktop.json',
    'src/HermesEasySetup.Loader.psm1','src/HermesEasySetup.Core.psm1','src/HermesEasySetup.Preflight.psm1','src/HermesEasySetup.StateStore.psm1',
    'src/HermesEasySetup.Execution.psm1','src/HermesEasySetup.Protocol.psm1','src/HermesEasySetup.InstallEngine.psm1','src/HermesEasySetup.Existing.psm1','src/HermesEasySetup.Codex.psm1',
    'src/HermesEasySetup.Input.psm1','src/HermesEasySetup.Docker.psm1','src/HermesEasySetup.Admin.psm1','src/HermesEasySetup.AdminBots.ps1','src/HermesEasySetup.AdminNetwork.ps1','src/HermesEasySetup.Research.psm1','src/HermesEasySetup.ResearchRuntime.psm1','src/HermesEasySetup.ResearchGovernance.ps1','src/HermesEasySetup.Bundle.psm1',
    'src/HermesEasySetup.ResearchDefaults.ps1','src/HermesEasySetup.ResearchMigration.ps1','src/HermesEasySetup.ResearchGateway.ps1','src/HermesEasySetup.ResearchPlugins.ps1',
    'docs/research-guide.ko.md','docs/research-team.md','docs/research-board.ko.md','docs/recovery-guide.ko.md','docs/verification-0.19.0.md','docs/verification-0.20.0.md')
$null = Get-HermesResearchTeamPayload
# The research team payload is exactly what team/manifest.json lists (the installer re-checks every hash).
$teamManifest = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'team\manifest.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$teamFiles = @('team/manifest.json') + @($teamManifest.files.PSObject.Properties.Name | ForEach-Object { 'team/' + $_ })
$researchPluginPin = & (Get-Module HermesEasySetup.Admin) { Get-HermesResearchPluginPackages }
$researchPluginFiles = @('config/mattermost-plugins.json','plugins/research-board/bridge.py','docs/mattermost-plugins.ko.md') + @($researchPluginPin.packages | ForEach-Object {'assets/mattermost-plugins/' + $_.file})
$roles = @(
    @{ Name = 'Research'; Entry = 'Start-HermesResearchSetup.cmd'; Files = @('Start-HermesResearchSetup.cmd','HermesResearchSetup.Gui.ps1','ui/ResearchWindow.xaml') + $teamFiles + $researchPluginFiles }
)
$plans = @()
foreach ($role in $roles) {
    $files = @($common + $role.Files | Sort-Object -Unique)
    foreach ($file in $files) {
        $path = Join-Path $PSScriptRoot $file
        Assert-DistributionPath $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('배포 파일이 없습니다: ' + $file) }
    }
    $name = 'NST-Research-Team-Setup-' + $version
    $path = Join-Path $DestinationRoot ($name + '.zip')
    if (Test-Path -LiteralPath $path) { throw '같은 이름의 배포 ZIP이 있습니다. 다른 출력 폴더를 선택하세요. 덮어쓰지 않습니다.' }
    $plans += [pscustomobject]@{ Name = $name; Role = $role.Name; Entry = $role.Entry; Files = $files; Path = $path }
}
$checksumPath = Join-Path $DestinationRoot 'SHA256SUMS.txt'
if (Test-Path -LiteralPath $checksumPath) { throw '기존 체크섬 파일은 덮어쓰지 않습니다.' }
New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$encoding = New-Object Text.UTF8Encoding $false
$stamp = [DateTimeOffset]::Parse('2026-01-01T00:00:00+00:00')
function Add-ZipText {
    param($Archive,[string]$Name,[string]$Content)
    $entry = $Archive.CreateEntry($Name,[IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = $stamp
    $stream = $entry.Open()
    try { $bytes = $encoding.GetBytes($Content); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
}
$outputs = @()
foreach ($plan in $plans) {
    $fileStream = [IO.File]::Open($plan.Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $archive = New-Object IO.Compression.ZipArchive($fileStream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try {
        $manifest = @()
        foreach ($file in $plan.Files) {
            $source = Join-Path $PSScriptRoot $file
            $entry = $archive.CreateEntry($plan.Name + '/' + $file,[IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $stamp
            $inputStream = [IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            $outputStream = $entry.Open()
            try {
                $hash = [Security.Cryptography.SHA256]::Create()
                try { $digest = ([BitConverter]::ToString($hash.ComputeHash($inputStream))).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
                $inputStream.Position = 0; $inputStream.CopyTo($outputStream)
                $manifest += ($digest + '  ' + $file)
            } finally { $outputStream.Dispose(); $inputStream.Dispose() }
        }
        Add-ZipText $archive ($plan.Name + '/FILES.sha256') (($manifest -join "`n") + "`n")
        $purpose = "NST 연구팀용입니다. 현재 Windows PC에 로컬 서버·Hermes·3+1 연구팀을 구성합니다.`n안내: docs/research-guide.ko.md`n실제 S1·S2·S3 결과·독립 감사·첨부 검증 전에는 사용 준비 완료로 표시하지 않습니다.`n"
        $note = "NST Research Team Setup $version`n`n압축을 모두 푼 뒤 $($plan.Entry)를 더블클릭하세요.`n" +
            "현재 패키지는 미서명 로컬 후보 빌드입니다. 실제 모델 S1·S2·S3 완주를 인증한 배포본이 아닙니다. Windows x64용입니다.`n" + $purpose +
            "실패 시: docs/recovery-guide.ko.md`n개인 인증값·설치 상태·기존 Hermes 프로필은 포함하지 않았습니다.`n" +
            "기존 프로그램·프로필을 제거하지 말고 먼저 안내를 읽으세요.`n"
        Add-ZipText $archive ($plan.Name + '/먼저읽기.txt') $note
    } finally { $archive.Dispose(); $fileStream.Dispose() }
    $outputs += [pscustomobject]@{ Kind = $plan.Role; Path = $plan.Path; SHA256 = (Get-FileHash -LiteralPath $plan.Path -Algorithm SHA256).Hash.ToLowerInvariant(); EntryPoint = $plan.Entry }
}
[IO.File]::WriteAllText($checksumPath,(($outputs | ForEach-Object { $_.SHA256 + '  ' + (Split-Path -Leaf $_.Path) }) -join "`n") + "`n",$encoding)
[pscustomobject]@{ Version = $version; Packages = $outputs; Checksums = $checksumPath; Published = $false; Signed = $false }
