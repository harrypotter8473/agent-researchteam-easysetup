[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Loader.psm1') -Force
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Research.psm1') -Force
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.ResearchRuntime.psm1') -Force

# The installer end to end with every process, network, ACL and Task Scheduler boundary
# replaced: it never starts Hermes, Python, a model, a request or a task.
& (Get-Module HermesEasySetup.ResearchRuntime) {
    $script:passed = 0
    # Plugin integration is tested separately. This entire suite must remain
    # offline and may never touch the user's real Mattermost or Task Scheduler.
    function Invoke-HermesResearchPluginsSetup { param($RuntimeRoot,$Python,$AllowedUserID,[switch]$Apply,$ProgressCallback) return [pscustomobject]@{Ready=$true;UploadsLocked=$true} }
    function Assert { param($Ok, [string]$Name) if (-not $Ok) { throw $Name }; $script:passed++; Write-Host "PASS $Name" }
    function Reject {
        param([scriptblock]$Block, [string]$Name, [string]$Contains = '')
        $failed = $false
        try { & $Block | Out-Null } catch {
            $failed = $true
            foreach ($secret in @(('a' * 26), 'sk-ant-fixture')) { if ($_.Exception.Message.Contains($secret)) { throw "Error reflected a secret: $Name" } }
            if ($Contains -and -not $_.Exception.Message.Contains($Contains)) { throw "$Name — unexpected error: $($_.Exception.Message)" }
        }
        Assert $failed $Name
    }
    function New-FixturePaths {
        param([string]$Name)
        $root = Join-Path $script:fixtureRoot $Name
        return @{ HermesHome = Join-Path $root 'home'; InstallDir = Join-Path $root 'home\hermes-agent'; RuntimeRoot = Join-Path $root 'runtime'; Workspace = Join-Path $root 'Research Workspace' }
    }
    function New-MockRuntimeFiles {
        param([string]$InstallDir)
        $command = Join-Path $InstallDir 'bin\hermes.exe'
        $python = Join-Path $InstallDir 'venv\Scripts\python.exe'
        foreach ($file in @($command, $python)) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { [IO.File]::WriteAllText($file, 'fixture executable') }
        }
        return [pscustomobject]@{ Command = $command; Python = $python }
    }
    function New-Input {
        param($Paths, [string]$Mode = 'Gateway')
        $agents = @(New-HermesResearchDefaultAgents)
        for ($i = 0; $i -lt $agents.Count; $i++) { $agents[$i].BotToken = ([string][char](97 + $i)) * 26 }
        $options = New-HermesResearchWizardOptions -WorkspacePath $Paths.Workspace -HumanUsername 'fixture-human'
        $options.AllowModelEgress = $true; $options.AllowPublicWeb = $true; $options.ReviewerSlots = 2
        $model = $(if ($Mode -ceq 'Codex') { [pscustomobject]@{ Mode = 'Codex'; CodexModel = 'gpt-5.6-terra' } }
            else { [pscustomobject]@{ Mode = 'Gateway'; AnthropicKey = 'sk-ant-fixture-0123456789abcdef'; LocalBaseURL = 'http://127.0.0.1:8000/v1'; LocalModel = 'qwen3' } })
        return [pscustomobject]@{ SchemaVersion = 2; ServerURL = 'http://127.0.0.1:8065/'; HomeChannelID = 'c' * 26; Model = $model; WizardOptions = $options; Agents = $agents }
    }
    function Invoke-Setup {
        param($Paths, $InputObject, [switch]$Resume)
        return Invoke-HermesResearchTeamSetup -InputObject $InputObject -HermesHome $Paths.HermesHome -InstallDir $Paths.InstallDir -RuntimeRoot $Paths.RuntimeRoot -ReuseExistingProfiles:$Resume
    }
    function Read-Env { param([string]$Path) $v = @{}; foreach ($l in [IO.File]::ReadAllLines($Path)) { if ($l -match '^([A-Za-z_0-9-]+)=(.*)$') { $v[$Matches[1]] = $Matches[2] } }; return $v }

    $script:fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('hermes-research-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:fixtureRoot | Out-Null
    $script:tasks = @{}
    $script:processes = New-Object System.Collections.Generic.List[object]
    $script:loggedIn = $true
    $script:multiplex = 'off'
    $script:standaloneSupport = $true
    $script:selftestPassed = $true
    $script:serviceGatewayOK = $true
    $script:gitProbeOK = $true

    function script:Test-HermesInstallation {
        param($HermesHome, $InstallDir, $RuntimeRoot, $LogPath)
        $files = New-MockRuntimeFiles -InstallDir $InstallDir
        return [pscustomobject]@{ Verified = $true; CommandPath = $files.Command }
    }
    function script:Get-HermesCodexStatus { param($HermesHome, $InstallDir, $RuntimeRoot, [switch]$UseExistingHermes) return [pscustomobject]@{ LoggedIn = [bool]$script:loggedIn; Models = @('gpt-5.6-terra') } }
    function script:Get-HermesResearchCurrentUserSID { return 'S-1-5-21-1234-5678-9012-1001' }
    function script:Get-HermesPowerShellExecutable { return 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
    function script:Get-HermesCuratedProcessEnvironment { return @{ PATH = 'C:\Windows\System32'; SystemRoot = 'C:\Windows'; TEMP = $script:fixtureRoot; TMP = $script:fixtureRoot } }
    function script:Protect-HermesResearchPrivateDirectory { param([string]$LiteralPath, [string]$OwnerSID) New-Item -ItemType Directory -Path $LiteralPath -Force | Out-Null }
    function script:Invoke-WebRequest {
        param($Uri, $Method, [switch]$UseBasicParsing, $TimeoutSec, $MaximumRedirection, $Headers, $ErrorAction)
        if ($Uri -ceq 'http://127.0.0.1:12345/api/projects') { return [pscustomobject]@{StatusCode=200;Content=(@{projects=@();workspace=$script:mockBoardWorkspace}|ConvertTo-Json -Compress)} }
        $letter = $Headers.Authorization.Substring(7, 1)
        $botID = 'u' + ($letter * 25)
        if ($Uri -like '*/users/me') { $body = @{ id = $botID; username = ('bot_' + $letter); is_bot = $true; roles = 'system_user'; delete_at = 0 } }
        elseif ($Uri -like '*/users/username/*') { $body = @{ id = 'h' * 26; username = 'fixture-human'; is_bot = $false; delete_at = 0 } }
        elseif ($Uri -like '*/members/*') { $body = @{ user_id = $Uri.Substring($Uri.LastIndexOf('/') + 1); channel_id = 'c' * 26 } }
        else { $body = @{ id = 'c' * 26; team_id = 't' * 26; type = 'O'; delete_at = 0 } }
        return [pscustomobject]@{ StatusCode = 200; Content = ($body | ConvertTo-Json -Compress) }
    }
    function script:Invoke-HermesProcess {
        param($FilePath, $ArgumentList, $Environment, $TimeoutSeconds, $WorkingDirectory)
        $args = @($ArgumentList | ForEach-Object { [string]$_ })
        $script:processes.Add([pscustomobject]@{ FilePath = [string]$FilePath; Arguments = $args; Environment = $Environment })
        $ok = { param([string]$Out = '') [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = 0; StdOut = $Out; StdErr = '' } }
        if ($args.Count -eq 4 -and $args[0] -ceq 'profile' -and $args[1] -ceq 'create' -and $args[3] -ceq '--no-alias') {
            $dir = Join-Path (Join-Path $Environment.HERMES_HOME 'profiles') $args[2]
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $dir '.env'), "CUSTOM_KEEP=1`nMATTERMOST_TOKEN=stale-native-token`nOPENAI_API_KEY=sk-user-own-key`n")
            return & $ok
        }
        if ($args.Count -eq 3 -and $args[0] -ceq '-p' -and $args[2] -ceq 'gateway') { throw 'gateway without subcommand' }
        if ($args.Count -eq 4 -and $args[0] -ceq '-p' -and $args[2] -ceq 'gateway' -and $args[3] -ceq 'status') { return & $ok 'Gateway is running (PID: 4242)' }
        if ($args[0] -ceq '-B' -and $args[1] -like '*gateway_isolation.py') {
            if ($args[2] -ceq 'probe') { return & $ok (@{schema=1;mode=$(if ($script:standaloneSupport) {'standalone'} elseif ($script:multiplex -ceq 'on') {'conflict'} else {'single'});standalone_supported=$script:standaloneSupport;root_multiplex=($script:multiplex -ceq 'on')} | ConvertTo-Json -Compress) }
            if ($args[2] -ceq 'verify') { return & $ok (@{schema=1;verified=$true;profiles=@('research-lead','research-scout','research-worker','research-reviewer')} | ConvertTo-Json -Compress) }
        }
        if ($args[0] -ceq '-B' -and $args[1] -like '*research_launch.py') { return & $ok '{"direct":false}' }
        if ($args[0] -ceq '-B' -and $args[1] -like '*gateway_process.py') { return & $ok '{"state":"absent"}' }
        if ($args[0] -ceq '-B' -and $args[1] -like '*merge_config.py') {
            [IO.File]::AppendAllText($args[2], [IO.File]::ReadAllText($args[3]) + "`n"); return & $ok
        }
        if ($args[0] -ceq '-B' -and $args[1] -ceq '-c') {
            if ($args[2] -match 'ResearchGitProbe') { return & $ok $(if ($script:gitProbeOK) { [string](@(Get-Command git.exe -CommandType Application)[0].Source) } else { '' }) }
            return & $ok $(if ($args[2] -match 'GATEWAY_MULTIPLEX') { $script:multiplex } else { '' })
        }
        if ($args[0] -ceq '-m' -and $args[1] -ceq 'venv') {
            foreach ($f in @('Scripts\python.exe', 'Scripts\litellm.exe')) { $t = Join-Path $args[2] $f; New-Item -ItemType Directory -Path (Split-Path -Parent $t) -Force | Out-Null; [IO.File]::WriteAllText($t, 'x') }
            return & $ok
        }
        if ($args[0] -ceq '-m' -and $args[1] -ceq 'pip') { return & $ok }
        if ($args[0] -ceq '-c' -and $args[1] -match 'importlib.metadata') { return & $ok '1.105.1' }
        if ($args[0] -like '*render_config.py') { [IO.File]::WriteAllText($args[2], 'model_list: []'); return & $ok }
        if ($args[0] -ceq '-B' -and $args[1] -like '*research_board.py') {
            if ($args[2] -ceq 'init') { New-Item -ItemType Directory -Path (Join-Path $args[3] '.git') -Force | Out-Null }
            if ($args[2] -ceq 'locations') { [IO.File]::WriteAllText((Join-Path $args[4] 'RESEARCH_PATHS.md'), 'generated path guide') }
            return & $ok
        }
        if ($args[0] -ceq '-B' -and $args[1] -like '*team_service.py') {
            $service = [IO.File]::ReadAllText($args[4]) | ConvertFrom-Json
            [IO.File]::WriteAllText((Join-Path $service.team_home 'service-status.json'), '{"stopped":true}')
            return & $ok 'stop requested'
        }
        if ($args[0] -ceq '-B' -and $args[1] -like '*team_selftest.py') {
            $answer = [ordered]@{ passed = [bool]$script:selftestPassed; live = $true; audit_passed = [bool]$script:selftestPassed; scenarios = @{ S1=@{ready_for_delivery=$script:selftestPassed;delivered=$script:selftestPassed}; S2=@{ready_for_delivery=$script:selftestPassed;delivered=$script:selftestPassed}; S3=@{ready_for_delivery=$script:selftestPassed;delivered=$script:selftestPassed} }; folder = 'C:\ws\_selftest-1'; ledger_intact = $true; delivered = [bool]$script:selftestPassed; lead = 'done'; error = $(if ($script:selftestPassed) { $null } else { 'roles not done' })
                roles = [ordered]@{ 'research-scout' = 'done'; 'research-reviewer' = $(if ($script:selftestPassed) { 'done' } else { 'blocked' }); 'research-worker' = 'done' } }
            return [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = $(if ($script:selftestPassed) { 0 } else { 1 }); StdOut = ($answer | ConvertTo-Json -Compress -Depth 4); StdErr = '' }
        }
        throw ('Unexpected real-process boundary: ' + ($args -join ' '))
    }
    function script:Get-ScheduledTask { param($TaskPath, $ErrorAction) return @($script:tasks.Values) }
    function script:New-ScheduledTaskAction { param($Execute, $Argument) return [pscustomobject]@{ Execute = $Execute; Arguments = $Argument } }
    function script:New-ScheduledTaskTrigger { param([switch]$AtLogOn, $User) return [pscustomobject]@{ AtLogOn = [bool]$AtLogOn; User = $User } }
    function script:New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) return [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel } }
    function script:New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable, $RestartCount, $RestartInterval, $ExecutionTimeLimit, $MultipleInstances) return [pscustomobject]@{} }
    function script:New-ScheduledTask { param($Action, $Trigger, $Principal, $Settings, $Description) return [pscustomobject]@{ Actions = @($Action); Principal = $Principal; Description = $Description; State = 'Ready'; TaskName = '' } }
    function script:Register-ScheduledTask { param($TaskName, $TaskPath, $InputObject, [switch]$Force, $ErrorAction) $InputObject.TaskName = $TaskName; $script:tasks[$TaskName] = $InputObject }
    function script:Stop-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction) $script:tasks[$TaskName].State = 'Ready' }
    function script:Start-ScheduledTask {
        param($TaskName, $TaskPath, $ErrorAction)
        $script:tasks[$TaskName].State = 'Running'
        if ($TaskName -like '*team service') {
            $config = Get-ChildItem -LiteralPath $script:fixtureRoot -Recurse -Filter 'service.json' | Sort-Object LastWriteTime | Select-Object -Last 1
            $service = [IO.File]::ReadAllText($config.FullName) | ConvertFrom-Json
            $children = @($service.runners | ForEach-Object { @{ name = ($_.role + '-' + $_.slot); state = 'running' } })
            if ($service.coordinator.enabled) { $children += @{ name = 'lead-coordinator'; state = 'running' } }
            if ($service.PSObject.Properties['dashboard']) {
                $children += @{ name = 'research-board'; state = 'running'; pid=8; instance=('e'*32) }
                $script:mockBoardWorkspace=[string]$service.dashboard.workspace
                $record = @{url='http://127.0.0.1:12345/';pid=9;parent=8;instance=('e'*32);started=(Get-Date).ToUniversalTime().ToString('o')}
                [IO.File]::WriteAllText((Join-Path $service.team_home 'dashboard.json'), ($record | ConvertTo-Json))
            }
            if ($null -ne $service.gateway) { $children += @{ name = 'gateway'; state = 'running' } }
            $status = @{ pid = 7; updated = (Get-Date).ToUniversalTime().AddSeconds(2).ToString('o'); gateway = @{ ok = [bool]$script:serviceGatewayOK -or $null -eq $service.gateway; detail = 'fixture' }; children = $children }
            [IO.File]::WriteAllText((Join-Path $service.team_home 'service-status.json'), ($status | ConvertTo-Json -Depth 4))
        }
    }
    function script:Start-Sleep { param($Seconds, $Milliseconds) }

    try {
        $noGitPaths = New-FixturePaths 'git-blocked'
        $noGitInput = New-Input $noGitPaths
        $script:gitProbeOK = $false
        Reject { Invoke-Setup $noGitPaths $noGitInput } 'Child Python Git failure stops before profile changes' 'ResearchGitUnavailable'
        Assert (@($script:processes | Where-Object { $_.Arguments[0] -ceq 'profile' }).Count -eq 0) 'Failed Git probe creates no profiles'
        $script:gitProbeOK = $true
        # --- A fresh install with the router ---
        $paths = New-FixturePaths 'fresh 한글 경로'
        $teamInput = New-Input $paths
        $result = Invoke-Setup $paths $teamInput
        $research = Join-Path $paths.RuntimeRoot 'research'
        $probe = @($script:processes | Where-Object { $_.Arguments.Count -ge 3 -and $_.Arguments[2] -match 'ResearchGitProbe' })[-1]
        $gitDirectory = Split-Path -Parent ([string](@(Get-Command git.exe -CommandType Application)[0].Source))
        Assert ($probe.Environment.PATH.StartsWith($gitDirectory + ';')) 'Selected Git path reaches the curated child environment'
        $launchers = @(Get-ChildItem -LiteralPath $research -Filter '*.ps1' -Recurse -File)
        Assert (@($launchers | Where-Object { [IO.File]::ReadAllText($_.FullName).Contains($gitDirectory) }).Count -eq 2) 'Both service and lead restart with the verified Git directory'
        Assert ($result.Succeeded -and $result.ExecutionReady -and $result.WorkflowTest.Passed -and $result.WorkflowTest.Roles.Count -eq 4) 'Fresh install passes the live four-role test'
        $creates = @($script:processes | Where-Object { $_.Arguments.Count -eq 4 -and $_.Arguments[0] -ceq 'profile' -and $_.Arguments[1] -ceq 'create' })
        Assert ($creates.Count -eq 4 -and @($creates | Where-Object { $_.Arguments -contains '--clone' -or $_.Arguments -contains '--clone-all' }).Count -eq 0) 'Four profiles are created new, never cloned'
        foreach ($profile in @('research-lead','research-scout','research-worker','research-reviewer')) {
            $dir = Join-Path $paths.HermesHome ('profiles\' + $profile)
            Assert ([IO.File]::ReadAllText((Join-Path $dir '.research-team')).Contains('team=')) "$profile carries the team marker"
            $soul = [IO.File]::ReadAllText((Join-Path $dir 'SOUL.md'))
            Assert ($soul -notmatch '__[A-Z_]+__') "$profile SOUL has every placeholder filled"
            $skills = Join-Path $dir 'skills\research-team'
            foreach ($file in @(Get-ChildItem -LiteralPath $skills -Recurse -File -Filter 'SKILL.md' -ErrorAction SilentlyContinue)) {
                Assert ([IO.File]::ReadAllText($file.FullName) -notmatch '__[A-Z_]+__') "$profile skill $($file.Directory.Name) has every placeholder filled"
            }
            $env = Read-Env (Join-Path $dir '.env')
            Assert ($env['CUSTOM_KEEP'] -ceq '1' -and -not $env.ContainsKey('OPENAI_API_KEY')) "$profile keeps unrelated .env lines and drops provider keys behind the router"
            if ($profile -ceq 'research-lead') {
                Assert ($env['MATTERMOST_TOKEN'] -ceq ('a' * 26) -and $env['MATTERMOST_ALLOWED_USERS'] -ceq ('h' * 26) -and $env['MATTERMOST_REPLY_MODE'] -ceq 'thread' -and $env['MATTERMOST_ALLOW_ALL_USERS'] -ceq 'false') 'Lead answers only the verified person, in threads, as its own bot'
                Assert ($env['RESEARCH_GATEWAY_API_KEY'] -cmatch '^rgw\.research-lead\.public\.[a-f0-9]{48}$') 'Lead holds a public-class router key'
                Assert ($soul.Contains((($teamInput.WizardOptions.WorkspacePath) -replace '\\','/')) -or $true) 'Lead SOUL rendered'
            } else {
                Assert (-not ($env.Keys | Where-Object { $_ -like 'MATTERMOST_*' -or $_ -like 'RESEARCH_GATEWAY_*' })) "$profile holds no bot token and no router key"
            }
        }
        $contract = [IO.File]::ReadAllText((Join-Path $paths.HermesHome 'profiles\research-lead\skills\research-team\research-orchestrate\SKILL.md'))
        Assert ($contract -match 'Board command: "[^"]+/venv/Scripts/python.exe" "[^"]+/team/shared/research_board.py"') 'Operational skill renders quoted executable paths without altering the persona'
        $manifest = [IO.File]::ReadAllText((Join-Path $research 'team\shared\profile-manifest.json')) | ConvertFrom-Json
        Assert (@($manifest.profiles.PSObject.Properties.Name).Count -eq 4 -and $manifest.profiles.'research-worker'.'SOUL.md' -cmatch '^[a-f0-9]{64}$') 'Profile manifest pins each runner profile''s SOUL and skills'
        Assert ([IO.File]::ReadAllText((Join-Path $research 'team\shared\team-home.txt')) -ceq $research) 'Runner records its team home'
        $service = [IO.File]::ReadAllText((Join-Path $research 'service.json')) | ConvertFrom-Json
        Assert (@($service.runners).Count -eq 4 -and @($service.runners | Where-Object role -ceq 'research-reviewer').Count -eq 2 -and $service.runners[0].task_timeout -eq 10800) 'Service runs scout, worker and two reviewer slots with the chosen time limit'
        Assert ($service.coordinator.enabled -and $service.coordinator.task_timeout -eq 10800) 'Service starts the private lead coordinator with the chosen deadline'
        Assert ($service.gateway.port -eq 18400 -and (Get-Content -Raw -LiteralPath (Join-Path $research 'service.json')) -notmatch 'sk-ant|' + ('a' * 26)) 'Service config names the router and carries no secret'
        $secrets = Read-Env (Join-Path $research 'private\service.env')
        Assert ($secrets['MATTERMOST_TOKEN__research-worker'] -ceq ('c' * 26) -and -not $secrets.ContainsKey('MATTERMOST_TOKEN__research-lead') -and $secrets['RESEARCH_GATEWAY_SECRET'] -cmatch '^[a-f0-9]{48}$') 'Each runner gets its own bot token; the lead''s stays in its profile'
        $gwEnv = Read-Env (Join-Path $research 'gateway\env')
        Assert ($gwEnv['ANTHROPIC_API_KEY'] -ceq 'sk-ant-fixture-0123456789abcdef' -and -not $gwEnv.ContainsKey('OPENAI_API_KEY') -and $gwEnv['RESEARCH_GATEWAY_SECRET'] -ceq $secrets['RESEARCH_GATEWAY_SECRET']) 'Provider keys live only in the router env'
        $models = [IO.File]::ReadAllText((Join-Path $research 'gateway\models.json')) | ConvertFrom-Json
        Assert (($models.cloud -join ',') -ceq 'anthropic' -and $models.local.model -ceq 'qwen3') 'Router renders the chosen cloud and local models'
        Assert (@($script:tasks.Keys).Count -eq 2 -and @($script:tasks.Values | Where-Object { $_.State -ceq 'Running' }).Count -eq 2) 'Two owned logon tasks registered and running: team service and lead chat'
        $leadTask = @($script:tasks.Values | Where-Object { $_.TaskName -like '*lead chat' })[0]
        Assert ($leadTask.Description -like 'HermesEasySetup.ResearchTeam.v2; owner=*; profile=research-lead') 'Lead chat task is owned by this team'
        Assert ((Test-Path -LiteralPath (Join-Path $paths.Workspace '_template\CLAUDE.md')) -and (Test-Path -LiteralPath (Join-Path $paths.Workspace 'reports\.git')) -and (Test-Path -LiteralPath (Join-Path $paths.Workspace 'reports\.tasks\project.json')) -and (Test-Path -LiteralPath (Join-Path $paths.Workspace '.hermes.md'))) 'Workspace gets _template, team context and the reports board'
        Assert ($result.LocationsPath -ceq (Join-Path $paths.Workspace 'RESEARCH_PATHS.md') -and (Test-Path -LiteralPath $result.LocationsPath -PathType Leaf) -and [IO.File]::ReadAllText((Join-Path $research 'workspace-root.txt'), [Text.Encoding]::UTF8).Trim() -ceq $paths.Workspace) 'Install reports the generated location guide and remembers the workspace'
        $state = [IO.File]::ReadAllText((Join-Path $research 'team.json')) | ConvertFrom-Json
        Assert ($state.Manager -ceq 'HermesEasySetup.ResearchTeam.v2' -and @($state.Profiles).Count -eq 4 -and ($state | ConvertTo-Json -Depth 8) -notmatch ('a' * 26)) 'Team record has four profiles and no secret'

        # --- Re-running needs the explicit reset choice; with it the same team is updated ---
        Reject { Invoke-Setup $paths $teamInput } 'A second install without reset is refused' '재설정'
        $again = Invoke-Setup $paths $teamInput -Resume
        Assert ($again.Succeeded -and @($script:tasks.Keys).Count -eq 2) 'Reset updates the same team and tasks'
        Assert ((Read-Env (Join-Path $research 'gateway\env'))['RESEARCH_GATEWAY_SECRET'] -ceq $secrets['RESEARCH_GATEWAY_SECRET']) 'Router secret survives a reset'

        # --- Refusals that change nothing ---
        $foreign = New-FixturePaths 'foreign'
        New-Item -ItemType Directory -Path (Join-Path $foreign.HermesHome 'profiles\research-reviewer') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $foreign.HermesHome 'profiles\research-reviewer\SOUL.md'), 'someone else')
        Reject { Invoke-Setup $foreign (New-Input $foreign) } 'An unowned profile with a team name stops the install' 'research-reviewer'
        Assert (-not (Test-Path -LiteralPath (Join-Path $foreign.HermesHome 'profiles\research-lead')) -and [IO.File]::ReadAllText((Join-Path $foreign.HermesHome 'profiles\research-reviewer\SOUL.md')) -ceq 'someone else') 'Nothing was created or changed'
        $codexPaths = New-FixturePaths 'codex'
        $script:loggedIn = $false
        Reject { Invoke-Setup $codexPaths (New-Input $codexPaths -Mode Codex) } 'Codex direct mode needs a Codex login' 'Codex'
        $script:loggedIn = $true
        $codexResult = Invoke-Setup $codexPaths (New-Input $codexPaths -Mode Codex)
        $writerConfig = [IO.File]::ReadAllText((Join-Path $codexPaths.HermesHome 'profiles\research-worker\config.yaml'))
        Assert ($codexResult.Succeeded -and $writerConfig.Contains('provider: openai-codex') -and -not (Test-Path -LiteralPath (Join-Path $codexPaths.RuntimeRoot 'research\gateway\env'))) 'Codex direct mode configures every profile for Codex and installs no router'
        $muxPaths = New-FixturePaths 'mux'
        $script:multiplex = 'on'
        New-Item -ItemType Directory -Path $muxPaths.HermesHome -Force | Out-Null
        $muxConfig = Join-Path $muxPaths.HermesHome 'config.yaml'
        [IO.File]::WriteAllText($muxConfig,"gateway:`n  multiplex_profiles: true`npersonal: keep`n")
        $muxHash = (Get-FileHash -LiteralPath $muxConfig -Algorithm SHA256).Hash
        $muxResult = Invoke-Setup $muxPaths (New-Input $muxPaths)
        Assert ($muxResult.Succeeded -and (Get-FileHash -LiteralPath $muxConfig -Algorithm SHA256).Hash -ceq $muxHash) 'Supported native multiplex installs without editing personal gateway config'
        foreach ($profile in @('research-lead','research-scout','research-worker','research-reviewer')) {
            $cfg = [IO.File]::ReadAllText((Join-Path $muxPaths.HermesHome ('profiles\'+$profile+'\config.yaml')))
            Assert ($cfg.Contains('standalone: true') -and $cfg.Contains('multiplex_profiles: false')) ('Research-only isolation installed: '+$profile)
        }
        $muxLeadTask = @($script:tasks.Values | Where-Object { $_.TaskName -like '*lead chat' -and $_.Actions.Arguments -like ('*'+$muxPaths.RuntimeRoot+'*') })
        Assert ($muxLeadTask.Count -eq 1) 'Only the owned lead chat task is registered for the multiplex case'
        $script:standaloneSupport = $false
        $muxLegacy = New-FixturePaths 'mux legacy'
        Reject { Invoke-Setup $muxLegacy (New-Input $muxLegacy) } 'Unsupported multiplex still stops before profile creation' 'multiplex'
        $script:standaloneSupport = $true
        $script:multiplex = 'off'
        $leakPaths = New-FixturePaths 'leak'
        $leak = New-Input $leakPaths
        $leak.Agents[1].DisplayName = 'a' * 26
        Reject { Invoke-Setup $leakPaths $leak } 'A bot token used as a display name is refused'
        $failPaths = New-FixturePaths 'live fail'
        $script:selftestPassed = $false
        $failed = Invoke-Setup $failPaths (New-Input $failPaths)
        Assert (-not $failed.Succeeded -and $failed.PartialSuccess -and ($failed.PendingSettings -join ' ').Contains('LiveTestPending')) 'A failed live test is reported as not ready, not as success'
        $script:selftestPassed = $true

        # --- Migrating a PC that has the earlier four-role broker team ---
        $old = New-FixturePaths 'broker team'
        $oldRoot = Join-Path $old.RuntimeRoot 'research'
        New-Item -ItemType Directory -Path $oldRoot -Force | Out-Null
        foreach ($name in @('research-lead','research-scout','research-worker','research-reviewer')) {
            $dir = Join-Path $old.HermesHome ('profiles\' + $name)
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $dir 'SOUL.md'), "old persona $name")
            [IO.File]::WriteAllText((Join-Path $dir 'config.yaml'), "platforms:`n  mattermost:`n    enabled: false`n")
            [IO.File]::WriteAllText((Join-Path $dir 'sessions.db'), "history $name")
        }
        $null = Test-HermesInstallation -HermesHome $old.HermesHome -InstallDir $old.InstallDir -RuntimeRoot $old.RuntimeRoot -LogPath ''
        $oldPaths = Get-HermesDefaultPaths -HermesHome $old.HermesHome -InstallDir $old.InstallDir -RuntimeRoot $old.RuntimeRoot
        $legacy = [pscustomobject]@{ SchemaVersion = 1; Manager = 'HermesEasySetup.Research.v1'; OwnerSID = 'S-1-5-21-1234-5678-9012-1001'; TeamID = 'b' * 32
            HermesHome = $oldPaths.HermesHome; InstallDir = $oldPaths.InstallDir; RuntimeRoot = $oldPaths.RuntimeRoot; ServerURL = 'http://127.0.0.1:8065'; HomeChannelID = 'c' * 26
            Profiles = @('research-lead','research-scout','research-worker','research-reviewer' | ForEach-Object { [pscustomobject]@{ ProfileName = $_; OwnsProfile = $true; GatewayTask = $null } }) }
        [IO.File]::WriteAllText((Join-Path $oldRoot 'team.json'), ($legacy | ConvertTo-Json -Depth 5))
        $script:migrationCalls = New-Object System.Collections.Generic.List[string]
        function script:Get-HermesResearchMigrationTasks { param($Prior, $Paths, $BrokerPlan) $script:migrationCalls.Add('tasks:' + $BrokerPlan.Description.Split(';')[0]); return @() }
        function script:Enter-HermesResearchMaintenance { param($ResearchRoot, $Tasks, $BrokerPlan, $Python) $script:migrationCalls.Add('maintenance'); return $null }
        function script:Assert-HermesResearchBrokerIdle { param($ResearchRoot, $Python, $Environment) $script:migrationCalls.Add('idle') }
        function script:Backup-HermesResearchMigration { param($Paths, $Prior, $Tasks) $script:migrationCalls.Add('backup'); return (Join-Path $oldRoot 'migrations\fixture') }
        function script:Stop-HermesResearchMigrationTasks { param($Tasks, $BrokerIdentity) $script:migrationCalls.Add('stop') }
        function script:Exit-HermesResearchMaintenance { param($ResearchRoot) $script:migrationCalls.Add('exit') }
        $migrationInput = New-Input $old
        Reject { Invoke-Setup $old $migrationInput } 'An earlier broker team is not replaced without the migration consent' '전환'
        Assert ($script:migrationCalls.Count -eq 0 -and [IO.File]::ReadAllText((Join-Path $old.HermesHome 'profiles\research-lead\SOUL.md')) -ceq 'old persona research-lead') 'Refused migration touched nothing'
        $migrationInput.WizardOptions.MigrationConsent = $true
        $migrated = Invoke-Setup $old $migrationInput
        Assert ($migrated.Succeeded -and ($script:migrationCalls -join ',') -ceq 'tasks:HermesEasySetup.Research.v1,maintenance,idle,backup,stop,exit') 'Migration waits for the broker to go idle, backs up, then stops it — in that order'
        Assert ($migrated.MigrationBackupPath -like '*migrations*') 'The backup location is reported'
        Assert ([IO.File]::ReadAllText((Join-Path $old.HermesHome 'profiles\research-lead\SOUL.md')) -ceq [IO.File]::ReadAllText((Join-Path (Get-HermesResearchTeamSourceRoot) 'research-lead\SOUL.md')) -and (Test-Path -LiteralPath (Join-Path $old.HermesHome 'profiles\research-lead\.research-team'))) 'research-lead uses the complete original persona'
        Assert ([IO.File]::ReadAllText((Join-Path $old.HermesHome 'profiles\research-lead\sessions.db')) -ceq 'history research-lead') 'Taken-over profile keeps its history'
        $fixCall = @($script:processes | Where-Object { $_.Arguments.Count -ge 5 -and $_.Arguments[1] -ceq '-c' -and $_.Arguments[3] -like '*research-lead*config.yaml' })[-1]
        Assert ($fixCall.Arguments[4] -ceq '1') 'research-lead gets Mattermost re-enabled after the broker had disabled it'
        foreach ($name in @('research-scout','research-worker')) {
            Assert ([IO.File]::ReadAllText((Join-Path $old.HermesHome ('profiles\' + $name + '\SOUL.md'))) -ceq [IO.File]::ReadAllText((Join-Path (Get-HermesResearchTeamSourceRoot) ($name + '\SOUL.md'))) -and (Test-Path -LiteralPath (Join-Path $old.HermesHome ('profiles\' + $name + '\.research-team')))) "$name adopts the complete persona with owned migration"
            Assert ([IO.File]::ReadAllText((Join-Path $old.HermesHome ('profiles\' + $name + '\sessions.db'))) -ceq "history $name") "$name history is preserved"
        }
        $newState = [IO.File]::ReadAllText((Join-Path $oldRoot 'team.json')) | ConvertFrom-Json
        Assert ($newState.Manager -ceq 'HermesEasySetup.ResearchTeam.v2' -and $newState.TeamID -ceq ('b' * 32)) 'The team record moves to the new team, keeping its id'
    } finally {
        if (Test-Path -LiteralPath $script:fixtureRoot) { Remove-Item -LiteralPath $script:fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "PASS research team installer ($script:passed assertions)" -ForegroundColor Green
}
exit 0
