[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('hermes-distribution-test-' + [Guid]::NewGuid().ToString('N'))
$passed = 0
function Assert { param($Condition,[string]$Name) if (-not $Condition) { throw $Name }; $script:passed++; Write-Host "PASS $Name" }
try {
    $one = & (Join-Path $projectRoot 'Build-Distributions.ps1') -DestinationRoot (Join-Path $fixture 'one')
    $two = & (Join-Path $projectRoot 'Build-Distributions.ps1') -DestinationRoot (Join-Path $fixture 'two')
    Assert (@($one.Packages).Count -eq 1 -and -not $one.Published -and -not $one.Signed) 'Single NST Research unsigned local distribution'
    Assert (Test-Path -LiteralPath $one.Checksums) 'ZIP checksums provided'
    foreach ($package in $one.Packages) {
        $other = @($two.Packages | Where-Object Kind -eq $package.Kind)[0]
        Assert ($other.SHA256 -ceq $package.SHA256) ('Reproducible ZIP: ' + $package.Kind)
        $archive = [IO.Compression.ZipFile]::OpenRead($package.Path)
        try {
            $entries = @($archive.Entries | ForEach-Object FullName)
            $name = [IO.Path]::GetFileNameWithoutExtension($package.Path)
            Assert (@($entries | Where-Object { -not $_.StartsWith($name + '/') -or $_ -match '\.\.|\\' }).Count -eq 0) 'Archive entries stay within a single relative root'
            Assert (@($entries | Where-Object { $_ -match '(?i)(^|/)(\.git|\.env|auth\.json|config\.yaml|ui-transport|runtime|tests)(/|$)|\.(bin|bak|log)$' }).Count -eq 0) 'No personal runtime, authentication, backups, or tests packaged'
            Assert (@($entries | Where-Object { $_ -match '(?i)\.exe$' }).Count -eq 0) 'Docker installer is downloaded only after consent, never bundled'
        } finally { $archive.Dispose() }
        $extract = Join-Path $fixture ('unpacked-' + $package.Kind)
        [IO.Compression.ZipFile]::ExtractToDirectory($package.Path,$extract)
        $root = Join-Path $extract $name
        Assert (Test-Path -LiteralPath (Join-Path $root $package.EntryPoint)) 'Role-specific launcher exists'
        Assert ((Test-Path -LiteralPath (Join-Path $root 'src/HermesEasySetup.Docker.psm1')) -and (Test-Path -LiteralPath (Join-Path $root 'config/docker-desktop.json'))) 'Docker discovery and verified-download pin included'

            $pluginPin=Get-Content -LiteralPath (Join-Path $root 'config/mattermost-plugins.json') -Raw -Encoding UTF8|ConvertFrom-Json
            foreach($plugin in $pluginPin.packages){
                $pluginFile=Join-Path $root ('assets/mattermost-plugins/'+$plugin.file)
                Assert ((Get-FileHash -LiteralPath $pluginFile -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $plugin.sha256) ('Pinned Mattermost plugin in '+$package.Kind+': '+$plugin.id)
            }
            Assert ((Get-FileHash -LiteralPath (Join-Path $root $pluginPin.bridge.path) -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $pluginPin.bridge.sha256) ('Pinned read-only bridge in '+$package.Kind)
        $hashes = [IO.File]::ReadAllLines((Join-Path $root 'FILES.sha256'))
        foreach ($line in $hashes) {
            if ($line -notmatch '^([a-f0-9]{64})  ([^\r\n]+)$') { throw 'Malformed file manifest' }
            $expected = $Matches[1]; $relative = $Matches[2]
            if ($relative.Contains('..') -or [IO.Path]::IsPathRooted($relative)) { throw 'Unsafe file manifest path' }
            if ((Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected) { throw "File checksum mismatch: $relative" }
        }
        Assert ($hashes.Count -gt 20 -and @($entries).Count -eq $hashes.Count + 2) 'Every source file checksum matches; only manifest and readme are generated'
        foreach ($retired in @('HermesEasySetup.Gui.ps1','HermesAdminSetup.Gui.ps1','Start-HermesEasySetup.cmd','Start-HermesAdminSetup.cmd','ui/MainWindow.xaml','ui/AdminWindow.xaml','src/HermesEasySetup.Lab.psm1','src/HermesEasySetup.Mattermost.psm1','config/bot-control.json','config/mattermost-desktop.json')) {
            Assert (-not (Test-Path -LiteralPath (Join-Path $root $retired))) ('NST ZIP omits retired feature: ' + $retired)
        }
        Assert ((Test-Path -LiteralPath (Join-Path $root 'src/HermesEasySetup.Input.psm1')) -and (Test-Path -LiteralPath (Join-Path $root 'src/HermesEasySetup.Admin.psm1'))) 'NST ZIP retains encrypted-input and research-server internals'

            Assert (-not (Test-Path -LiteralPath (Join-Path $root 'assets/bot-control')) -and (Test-Path -LiteralPath (Join-Path $root 'ui/ResearchWindow.xaml'))) 'Research ZIP includes unified local UI without optional server plugin'
            Assert ((Test-Path -LiteralPath (Join-Path $root 'team/manifest.json')) -and (Test-Path -LiteralPath (Join-Path $root 'team/shared/research_board.py')) -and -not (Test-Path -LiteralPath (Join-Path $root 'engine'))) 'Research ZIP includes the research team payload and no broker engine'
            $teamManifest = [IO.File]::ReadAllText((Join-Path $root 'team/manifest.json')) | ConvertFrom-Json
            foreach ($relative in @($teamManifest.files.PSObject.Properties.Name)) { Assert ((Get-FileHash -LiteralPath (Join-Path $root ('team/' + $relative)) -Algorithm SHA256).Hash.ToLowerInvariant() -ceq [string]$teamManifest.files.$relative) ('Research ZIP team file matches its pinned hash: ' + $relative) }
            Assert ((Test-Path -LiteralPath (Join-Path $root 'src/HermesEasySetup.ResearchDefaults.ps1')) -and (Test-Path -LiteralPath (Join-Path $root 'src/HermesEasySetup.ResearchMigration.ps1')) -and (Test-Path -LiteralPath (Join-Path $root 'src/HermesEasySetup.ResearchGateway.ps1'))) 'Research ZIP includes wizard choices and record-preserving migration'
            $gui = 'HermesResearchSetup.Gui.ps1'

        $ps = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $ps -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $root $gui) -SmokeTest
        Assert ($LASTEXITCODE -eq 0) ('Extracted ' + $package.Kind + ' GUI loads without installing anything')
        $guardRoot = Join-Path $fixture 'worker-guards'
        $guardHome = Join-Path $guardRoot 'hermes'
        $guardRuntime = Join-Path $guardRoot 'runtime'
        foreach ($action in @('AdminSetup','AdminBotSetup','ResearchTeamSetup','ResearchPluginsSetup')) {
            $guard = @(& $ps -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'HermesEasySetup.ps1') -Action $action -HermesHome $guardHome -InstallDir (Join-Path $guardHome 'hermes-agent') -RuntimeRoot $guardRuntime -Json)
            $guardExit = $LASTEXITCODE
            $errorFrame = $guard[-1] | ConvertFrom-Json
            Assert ($guardExit -ne 0 -and $errorFrame.type -ceq 'error' -and $errorFrame.message -like '*-Apply*') ('Extracted NST worker remains default-deny: ' + $action)
            Assert (-not (Test-Path -LiteralPath $guardHome) -and -not (Test-Path -LiteralPath $guardRuntime)) 'Extracted worker guards leave install and runtime paths untouched'
        }
    }
    $rejected = $false
    try { & (Join-Path $projectRoot 'Build-Distributions.ps1') -DestinationRoot (Join-Path $fixture 'one') | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Existing distributions are not silently overwritten'
    Write-Host "$passed distribution tests passed"
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolvedFixture) -cne $expectedParent -or [IO.Path]::GetFileName($resolvedFixture) -cnotmatch '^hermes-distribution-test-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup path' }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
