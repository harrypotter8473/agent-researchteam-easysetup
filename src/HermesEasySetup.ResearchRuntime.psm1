Set-StrictMode -Version 2.0

# The research team installer (team/ in this repository): four Hermes profiles, a team service
# (model router + board runners), research-lead's Mattermost gateway, and a live test.
$script:ResearchManager = 'HermesEasySetup.ResearchTeam.v2'
$script:ResearchLegacyManager = 'HermesEasySetup.Research.v1'

. (Join-Path $PSScriptRoot 'HermesEasySetup.ResearchGovernance.ps1')
. (Join-Path $PSScriptRoot 'HermesEasySetup.ResearchDefaults.ps1')
. (Join-Path $PSScriptRoot 'HermesEasySetup.ResearchMigration.ps1')
. (Join-Path $PSScriptRoot 'HermesEasySetup.ResearchGateway.ps1')

function Publish-HermesResearchStage {
    param([AllowNull()][scriptblock]$Callback, [string]$Stage, [string]$Message, [int]$Percent, [string]$State = 'running')
    if ($null -ne $Callback) { [void](Publish-HermesEvent -Callback $Callback -Type 'stage' -Stage $Stage -State $State -Message $Message -Percent $Percent) }
}

function Invoke-HermesResearchMattermostAPI {
    param([string]$ServerURL, [string]$Path, [string]$Token)
    if ($Path -cnotmatch '^/api/v4/(users/me|users/username/[a-z0-9][a-z0-9._-]{0,63}|channels/[a-z0-9]{26}(/members/[a-z0-9]{26})?)$') { throw 'ResearchApiPathRejected' }
    try {
        $response = Invoke-WebRequest -Uri ($ServerURL.TrimEnd('/') + $Path) -Method GET -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 0 -Headers @{ Authorization = 'Bearer ' + $Token } -ErrorAction Stop
        if ([int]$response.StatusCode -ne 200) { throw 'UnexpectedStatus' }
        return ($response.Content | ConvertFrom-Json)
    } catch {
        # Remote errors and response bodies can reflect Authorization headers.
        throw '로컬 Mattermost 연결 검사에 실패했습니다. 서버·봇 토큰·채널 권한을 확인하세요.'
    }
}

function Test-HermesResearchTeamConnection {
    param([Parameter(Mandatory = $true)]$InputObject)
    $identities = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $seenNames = @{}
    foreach ($agent in @($InputObject.Agents)) {
        try {
            $me = Invoke-HermesResearchMattermostAPI -ServerURL $InputObject.ServerURL -Path '/api/v4/users/me' -Token $agent.BotToken
            if ($me.is_bot -isnot [bool] -or -not $me.is_bot -or $me.delete_at -ne 0 -or $me.roles -cne 'system_user' -or $me.id -cnotmatch '^[a-z0-9]{26}$') { throw 'InvalidBot' }
            if ($me.username -isnot [string] -or $me.username -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$') { throw 'InvalidBotUsername' }
            if ($seen.ContainsKey([string]$me.id)) { throw 'DuplicateBot' }
            if ($seenNames.ContainsKey([string]$me.username)) { throw 'DuplicateBotUsername' }
            $channel = Invoke-HermesResearchMattermostAPI -ServerURL $InputObject.ServerURL -Path ("/api/v4/channels/$($InputObject.HomeChannelID)") -Token $agent.BotToken
            if ($channel.id -cne $InputObject.HomeChannelID -or $channel.delete_at -ne 0 -or $channel.type -cnotin @('O', 'P') -or $channel.team_id -cnotmatch '^[a-z0-9]{26}$') { throw 'InvalidChannel' }
            $member = Invoke-HermesResearchMattermostAPI -ServerURL $InputObject.ServerURL -Path ("/api/v4/channels/$($InputObject.HomeChannelID)/members/$($me.id)") -Token $agent.BotToken
            if ($member.user_id -cne $me.id -or $member.channel_id -cne $InputObject.HomeChannelID) { throw 'InvalidMembership' }
            $seen[[string]$me.id] = $true
            $seenNames[[string]$me.username] = $true
            $identities.Add([pscustomobject]@{ ProfileName = [string]$agent.ProfileName; BotUserID = [string]$me.id; BotUsername = [string]$me.username })
        } catch {
            throw ('서로 다른 활성 일반 봇 {0}개와 홈 채널 접근·멤버십을 모두 확인해야 합니다. 확인하지 못한 프로필: {1}' -f @($InputObject.Agents).Count, $agent.ProfileName)
        }
    }
    return $identities.ToArray()
}


function Write-HermesResearchAtomicText {
    param([string]$LiteralPath, [AllowEmptyString()][string]$Text, [switch]$ByteOrderMark)
    $safe = Test-HermesSafeTargetPath -LiteralPath $LiteralPath -Label 'research file'
    if (-not $safe.Safe) { throw 'ResearchUnsafeFilePath' }
    $parent = Split-Path -Parent $LiteralPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
    $temporary = $LiteralPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, (New-Object System.Text.UTF8Encoding([bool]$ByteOrderMark)))
        if (Test-Path -LiteralPath $LiteralPath -PathType Leaf) { [System.IO.File]::Replace($temporary, $LiteralPath, [System.Management.Automation.Language.NullString]::Value, $true) }
        else { [System.IO.File]::Move($temporary, $LiteralPath) }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}
function New-HermesResearchEnvironment {
    param([string]$HermesHome, [string]$InstallDir)
    $environment = Get-HermesCuratedProcessEnvironment
    $environment['HERMES_HOME'] = $HermesHome
    $environment['VIRTUAL_ENV'] = Join-Path $InstallDir 'venv'
    foreach ($key in @('PYTHONHOME', 'PYTHONPATH', 'PYTHONUSERBASE', 'PYTHONSTARTUP', 'PYTHONINSPECT')) { $environment[$key] = $null }
    $environment['PYTHONNOUSERSITE'] = '1'
    $environment['PYTHONSAFEPATH'] = '1'
    return $environment
}
function Initialize-HermesResearchGitEnvironment {
    param([string]$Python, [hashtable]$Environment)
    # The existing-Hermes environment intentionally strips the user's PATH.
    # Verify Python -> Git, not just Git in the interactive wizard's shell.
    $candidates = @(Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue)
    if ($candidates.Count -eq 0) { throw 'ResearchGitMissing: Git for Windows를 설치한 뒤 다시 확인하세요.' }
    $gitPath = [IO.Path]::GetFullPath([string]$candidates[0].Source)
    if (-not (Test-Path -LiteralPath $gitPath -PathType Leaf) -or -not (Test-HermesSafeTargetPath -LiteralPath $gitPath).Safe) { throw 'ResearchGitPathRejected' }
    $updated = @{} + $Environment
    $directory = Split-Path -Parent $gitPath
    $updated['PATH'] = (@($directory) + @(([string]$updated['PATH']).Split(';') | Where-Object { $_ -and $_ -ine $directory })) -join ';'
    $program = @'
# ResearchGitProbe: only the installed interpreter and selected local Git.
import shutil, subprocess, sys
found = shutil.which("git.exe")
if not found:
    sys.exit(1)
result = subprocess.run([found, "--version"], capture_output=True, timeout=15)
if result.returncode or not result.stdout.startswith(b"git version "):
    sys.exit(2)
print(found)
'@
    $probe = Invoke-HermesProcess -FilePath $Python -ArgumentList @('-B','-c',$program) -Environment $updated -TimeoutSeconds 30
    if (-not $probe.Started -or $probe.TimedOut -or $probe.ExitCode -ne 0 -or
        -not [string]::Equals($probe.StdOut.Trim(), $gitPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ResearchGitUnavailable: Python에서 Git을 실행하지 못했습니다. Git 설치·실행 권한을 확인하세요. 프로필 변경 전 중단했습니다.'
    }
    $updated['RESEARCH_GIT_DIRECTORY'] = $directory
    return $updated
}
function Invoke-HermesResearchCommand {
    param([string]$CommandPath, [string[]]$Arguments, [hashtable]$Environment, [int]$TimeoutSeconds = 90)
    try {
        $result = Invoke-HermesProcess -FilePath $CommandPath -ArgumentList $Arguments -Environment $Environment -TimeoutSeconds $TimeoutSeconds
        if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) { throw 'CommandFailed' }
    } catch { throw 'ResearchHermesCommandFailed' }
    # Never return subprocess output: profile commands may expose local secrets.
}

function Get-HermesResearchCurrentUserSID { return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value }

function Get-HermesResearchGatewayTask {
    param([string]$TaskName)
    # Listing with Stop distinguishes access failures from a missing task.
    return @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object { $_.TaskName -ceq $TaskName })
}

function Get-HermesResearchTaskPlan {
    <# -Label names the task when it is not a profile's gateway; -Manager reads tasks of an older team version. #>
    param([string]$ProfileName, [string]$HermesHome, [string]$RuntimeRoot, [string]$OwnerSID, [string]$TeamID, [string]$PowerShellPath,
          [string]$Label, [string]$Manager = $script:ResearchManager)
    if (-not $Label) { $Label = $ProfileName }
    $suffix = (ConvertTo-HermesSha256 -Text ($OwnerSID + '|' + $HermesHome.ToLowerInvariant())).Substring(0, 12)
    $runner = Join-Path (Join-Path (Join-Path $RuntimeRoot 'research\services') ($Label -replace '[^A-Za-z0-9_-]', '-')) 'Start-Gateway.ps1'
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + (ConvertTo-WindowsProcessArgument -Argument $runner)
    return [pscustomobject]@{ TaskName = "Hermes Research $suffix - $Label"; RunnerPath = $runner; Execute = $PowerShellPath; Arguments = $arguments; OwnerSID = $OwnerSID; Description = "$Manager; owner=$TeamID; profile=$ProfileName" }
}

function ConvertTo-HermesResearchPrincipalSID {
    param([AllowNull()][string]$Identity)
    if ([string]::IsNullOrWhiteSpace($Identity) -or $Identity -cne $Identity.Trim() -or $Identity -match '[\x00-\x1f]') { throw 'ResearchPrincipalIdentityRejected' }
    try {
        if ($Identity -match '^S-') { return (New-Object System.Security.Principal.SecurityIdentifier($Identity)).Value }
        # Task Scheduler may return a resolved account name even when registered with a SID.
        $account = New-Object System.Security.Principal.NTAccount($Identity)
        return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch { throw 'ResearchPrincipalIdentityUnresolved' }
}

function Assert-HermesResearchOwnedTask {
    param($Task, [Parameter(Mandatory = $true)]$Plan, [bool]$HasOwnership)
    if ($null -eq $Task) { return }
    try {
        $actions = @($Task.Actions)
        $actualOwnerSID = ConvertTo-HermesResearchPrincipalSID -Identity ([string]$Task.Principal.UserId)
        $expectedOwnerSID = (New-Object System.Security.Principal.SecurityIdentifier([string]$Plan.OwnerSID)).Value
        if (-not $HasOwnership -or $Task.Description -cne $Plan.Description -or $actions.Count -ne 1 -or
            -not [string]::Equals([string]$actions[0].Execute, [string]$Plan.Execute, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$actions[0].Arguments -cne $Plan.Arguments -or $actualOwnerSID -cne $expectedOwnerSID -or
            [string]$Task.Principal.LogonType -cnotin @('Interactive', 'InteractiveToken', '3') -or [string]$Task.Principal.RunLevel -cnotin @('Limited', '0')) { throw 'ForeignTask' }
    } catch { throw '기존 예약 작업의 소유권을 확인할 수 없습니다. 다른 작업은 덮어쓰지 않습니다.' }
}

function Register-HermesResearchGatewayTask {
    param($Plan, [string]$CommandPath, [string]$HermesHome, [string]$InstallDir, [string]$ProfileName, [bool]$HasOwnership, [string]$GitDirectory, $NativeLaunch, [string]$Python, [string]$TeamRoot)
    $existing = @(Get-HermesResearchGatewayTask -TaskName $Plan.TaskName)
    if ($existing.Count -gt 1) { throw 'ResearchTaskCollision' }
    if ($existing.Count -eq 1) {
        Assert-HermesResearchOwnedTask -Task $existing[0] -Plan $Plan -HasOwnership $HasOwnership
        if ([string]$existing[0].State -eq 'Running') {
            Stop-ScheduledTask -TaskName $Plan.TaskName -TaskPath '\' -ErrorAction Stop
            $deadline = (Get-Date).AddSeconds(20)
            do {
                $task = @(Get-HermesResearchGatewayTask -TaskName $Plan.TaskName)
                if ($task.Count -eq 1 -and [string]$task[0].State -ne 'Running') { break }
                Start-Sleep -Milliseconds 250
            } while ((Get-Date) -lt $deadline)
            if ($task.Count -ne 1 -or [string]$task[0].State -eq 'Running') { throw 'ResearchTaskStopTimeout' }
        }
    }
    $quote = { param([string]$Text) return "'" + $Text.Replace("'", "''") + "'" }
    $gatewayCommand = @($CommandPath, '-p', $ProfileName, 'gateway', 'run', '--replace')
    if ($null -ne $NativeLaunch -and $NativeLaunch.direct -eq $true) {
        $gatewayCommand = @([string]$NativeLaunch.python, '-I', '-B', [string]$NativeLaunch.main, '-p', $ProfileName, 'gateway', 'run', '--replace')
    }
    $contained = -not [string]::IsNullOrWhiteSpace($Python) -and -not [string]::IsNullOrWhiteSpace($TeamRoot)
    if ($contained) {
        $launchRecord = Join-Path (Split-Path -Parent $Plan.RunnerPath) 'launch-command.json'
        $log = Join-Path (Split-Path -Parent $TeamRoot) 'logs\lead-gateway.log'
        Write-HermesResearchAtomicText -LiteralPath $launchRecord -Text ((@{argv=$gatewayCommand;log=$log}|ConvertTo-Json -Depth 4)+"`n")
    }
    $runner = @(
        '$ErrorActionPreference = ''Stop'''
        ('$env:HERMES_HOME = {0}' -f (& $quote $HermesHome))
        ('$env:RESEARCH_HERMES_INSTALL = {0}' -f (& $quote $InstallDir))
        ('$env:VIRTUAL_ENV = {0}' -f (& $quote (Join-Path $InstallDir 'venv')))
        if ($GitDirectory) { ('$env:PATH = {0} + '';'' + $env:PATH' -f (& $quote $GitDirectory)) }
        '$env:PYTHONHOME = $null; $env:PYTHONPATH = $null; $env:PYTHONUSERBASE = $null; $env:PYTHONSTARTUP = $null; $env:PYTHONINSPECT = $null'
        '$env:PYTHONNOUSERSITE = ''1''; $env:PYTHONSAFEPATH = ''1'''
        '$env:GATEWAY_MULTIPLEX_PROFILES = ''false'' # this owned gateway serves research-lead only'
        '$env:GIT_CONFIG_COUNT = ''1''; $env:GIT_CONFIG_KEY_0 = ''safe.directory'''
        ('$env:GIT_CONFIG_VALUE_0 = {0}' -f (& $quote $InstallDir))
        if ($contained) {
            ('& {0} -B {1} --config {2}' -f (& $quote $Python), (& $quote (Join-Path $TeamRoot 'shared\gateway_service.py')), (& $quote $launchRecord))
        } elseif ($null -ne $NativeLaunch -and $NativeLaunch.direct -eq $true) {
            # Real script argv remains inspectable by the native PID/profile matcher.
            ('& {0} -I -B {1} -p {2} gateway run --replace' -f (& $quote $NativeLaunch.python), (& $quote $NativeLaunch.main), (& $quote $ProfileName))
        } else { ('& {0} -p {1} gateway run --replace' -f (& $quote $CommandPath), (& $quote $ProfileName)) }
        'exit $LASTEXITCODE'
    ) -join [Environment]::NewLine
    Write-HermesResearchAtomicText -LiteralPath $Plan.RunnerPath -Text ($runner + [Environment]::NewLine) -ByteOrderMark
    $action = New-ScheduledTaskAction -Execute $Plan.Execute -Argument $Plan.Arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $Plan.OwnerSID
    $principal = New-ScheduledTaskPrincipal -UserId $Plan.OwnerSID -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1)) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $Plan.Description
    Register-ScheduledTask -TaskName $Plan.TaskName -TaskPath '\' -InputObject $task -Force:($existing.Count -eq 1) -ErrorAction Stop | Out-Null
}

function Stop-HermesResearchOwnedGateway {
    param($Plan, [string]$Python, $Paths, [string]$PayloadRoot, [hashtable]$Environment)
    $tasks = @(Get-HermesResearchGatewayTask -TaskName $Plan.TaskName)
    if ($tasks.Count -gt 1) { throw 'ResearchTaskCollision' }
    if ($tasks.Count -eq 1) {
        Assert-HermesResearchOwnedTask -Task $tasks[0] -Plan $Plan -HasOwnership $true
        if ([string]$tasks[0].State -eq 'Running') { Stop-ScheduledTask -TaskName $Plan.TaskName -TaskPath '\' -ErrorAction Stop }
    }
    # Some legacy CLI bridges survived their Task Scheduler parent. The native
    # matcher intentionally rejects generic python -c; keep that protection.
    $team = Join-Path $Paths.RuntimeRoot 'research\team'
    $probe = Invoke-HermesProcess -FilePath $Python -ArgumentList @('-B', (Join-Path $PayloadRoot 'shared\gateway_process.py'), '--home', $Paths.HermesHome, '--install', $Paths.InstallDir, '--team', $team, '--profile', 'research-lead') -Environment $Environment -TimeoutSeconds 45
    if (-not $probe.Started -or $probe.TimedOut -or $probe.ExitCode -ne 0) { throw 'ResearchGatewayOwnershipUnconfirmed: 연구 총괄의 종료 소유권 또는 유휴 상태를 확인하지 못했습니다. 개인 Gateway는 종료하지 않습니다.' }
    $binding = $probe.StdOut.Trim() | ConvertFrom-Json
    if ($binding.state -ceq 'absent') { return }
    if ($binding.state -cne 'owned_idle') { throw 'ResearchGatewayOwnershipRejected' }
    $snapshot = Get-HermesResearchBrokerProcessSnapshot -ProcessID ([int]$binding.pid)
    if ($null -eq $snapshot) { return }
    try {
        $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc)
        $created = [datetime]::new([long]$snapshot.CreationTicks, [DateTimeKind]::Utc)
        if ([Math]::Abs(($created - $epoch).TotalSeconds * 100 - [double]$binding.start_time) -gt 2 -or
            -not [string]::Equals($snapshot.PhysicalPath, [string]$binding.exe, [StringComparison]::OrdinalIgnoreCase)) { throw 'ResearchGatewayProcessChanged' }
        # The snapshot retains the exact process handle, not merely a reusable PID.
        $snapshot.Process.Kill()
        if (-not $snapshot.Process.WaitForExit(20000)) { throw 'ResearchGatewayStopTimeout' }
    } finally { $snapshot.Process.Dispose() }
}

function Start-HermesResearchGatewayTask {
    param($Plan)
    Start-ScheduledTask -TaskName $Plan.TaskName -TaskPath '\' -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(30)
    do {
        $tasks = @(Get-HermesResearchGatewayTask -TaskName $Plan.TaskName)
        if ($tasks.Count -eq 1 -and [string]$tasks[0].State -eq 'Running') { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw 'ResearchGatewayStartTimeout'
}

function Wait-HermesResearchGatewayReady {
    param([string]$CommandPath, [string]$ProfileName, [hashtable]$Environment, $Plan, [int]$TimeoutSeconds = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $result = Invoke-HermesProcess -FilePath $CommandPath -ArgumentList @('-p', $ProfileName, 'gateway', 'status') -Environment $Environment -TimeoutSeconds 45
            if (-not $result.Started) { throw 'GatewayStatusStartFailed' }
            if ($result.TimedOut) { throw 'GatewayStatusTimeout45s' }
            if ($result.ExitCode -ne 0) { throw ('GatewayStatusExit' + [string]$result.ExitCode) }
            $text = [regex]::Replace([string]$result.StdOut, '\x1B\[[0-?]*[ -/]*[@-~]', '')
            # Pinned fcbd107 gateway.py/gateway_windows.py report PID-bearing
            # positive lines; stopped status also exits 0 and is insufficient.
            $positive = ($text -match '(?m)^\s*[\u2713\u2714]?\s*Gateway (?:is running|process running) \(PID: [1-9][0-9]*(?:,\s*[1-9][0-9]*)*\)\s*$')
            $negative = ($text -match '(?i)Gateway is not running|No gateway process detected')
            $tasks = @(Get-HermesResearchGatewayTask -TaskName $Plan.TaskName)
            if ($positive -and -not $negative -and $tasks.Count -eq 1 -and [string]$tasks[0].State -eq 'Running') {
                Assert-HermesResearchOwnedTask -Task $tasks[0] -Plan $Plan -HasOwnership $true
                return
            }
        } catch {
            $reason = Protect-HermesLogText ([string]$_.Exception.Message)
            throw ('ResearchGatewayStatusFailed: ' + $reason + ' — 연구 Gateway 확인 단계입니다. research\services\lead-chat\Start-Gateway.ps1 및 연구 프로필 logs\gateway.log를 확인하세요. 봇·토큰을 다시 발급할 필요는 없습니다.')
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw 'ResearchGatewayNotRunning'
}

function Wait-HermesResearchDashboardReady {
    param([string]$ResearchRoot, [datetime]$StartedAfter, [string]$WorkspacePath, [int]$TimeoutSeconds=90)
    $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
    $recordPath=Join-Path $ResearchRoot 'dashboard.json'
    $last='DashboardRecordPending'
    do {
        try {
            if(-not (Test-Path -LiteralPath $recordPath -PathType Leaf) -or (Get-Item -LiteralPath $recordPath).Length -gt 4096) { throw 'DashboardRecordPending' }
            $dashboard=[IO.File]::ReadAllText($recordPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
            if([string]$dashboard.url -cnotmatch '^http://127\.0\.0\.1:[1-9][0-9]{0,4}/$' -or
                (ConvertTo-HermesResearchUtc $dashboard.started) -lt $StartedAfter.ToUniversalTime().AddSeconds(-1)) { throw 'DashboardStarting' }
            $status=Read-HermesResearchServiceStatus -ResearchRoot $ResearchRoot
            $child=@($status.children | Where-Object {$_.name -ceq 'research-board' -and $_.state -ceq 'running'})
            if($child.Count -ne 1 -or [string]$dashboard.instance -cnotmatch '^[a-f0-9]{32}$' -or
                [string]$child[0].instance -cne [string]$dashboard.instance -or
                ([int]$child[0].pid -ne [int]$dashboard.pid -and [int]$child[0].pid -ne [int]$dashboard.parent)) { throw 'DashboardProcessPending' }
            $page=Invoke-WebRequest -Uri ([string]$dashboard.url+'api/projects') -UseBasicParsing -TimeoutSec 5
            $snapshot=$page.Content|ConvertFrom-Json
            if($page.StatusCode -ne 200 -or $null -eq $snapshot.PSObject.Properties['projects'] -or
                [string]$snapshot.workspace -ine $WorkspacePath) { throw 'DashboardResponseMismatch' }
            return $dashboard
        } catch { $last=Protect-HermesLogText ([string]$_.Exception.Message) }
        if((Get-Date) -ge $deadline){break}
        Start-Sleep -Milliseconds 500
    } while((Get-Date) -lt $deadline)
    throw ('ResearchDashboardNotReady: '+$last+' — research\logs\research-board.log')
}

function Get-HermesResearchPriorTeam {
    <# -> $null (fresh), or the recorded team with Kind 'Team' (this team, v2) or 'Broker' (the earlier governed broker). #>
    param([string]$StatePath, $Paths, [string]$OwnerSID, [string]$ServerURL, [string]$HomeChannelID)
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        if (-not (Test-HermesSafeTargetPath -LiteralPath $StatePath).Safe -or (Get-Item -LiteralPath $StatePath).Length -gt 262144) { throw 'Unsafe' }
        $prior = [IO.File]::ReadAllText($StatePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $kind = $(if ($prior.Manager -ceq $script:ResearchManager -and $prior.SchemaVersion -eq 2) { 'Team' } elseif ($prior.Manager -ceq $script:ResearchLegacyManager -and $prior.SchemaVersion -eq 1) { 'Broker' } else { throw 'UnknownManager' })
        if ($prior.OwnerSID -cne $OwnerSID -or $prior.TeamID -cnotmatch '^[a-f0-9]{32}$' -or
            $prior.HermesHome -ine $Paths.HermesHome -or $prior.InstallDir -ine $Paths.InstallDir -or $prior.RuntimeRoot -ine $Paths.RuntimeRoot -or
            $prior.ServerURL -cne $ServerURL.TrimEnd('/') -or $prior.HomeChannelID -cne $HomeChannelID) { throw 'ForeignTeam' }
        $prior | Add-Member NoteProperty Kind $kind -Force
        $prior | Add-Member NoteProperty StateSha256 (ConvertTo-HermesSha256 -LiteralPath $StatePath) -Force
        return $prior
    } catch { throw '기존 연구팀 기록의 소유자·경로·서버·채널이 지금 설정과 다릅니다. 기록은 변경하지 않았습니다.' }
}

function Test-HermesResearchMultiplexer {
    <# Prefer the named-profile opt-out; never rewrite the personal root gateway. #>
    param([string]$Python, $Paths, [hashtable]$Environment, [string]$PayloadRoot)
    $helper = Join-Path $PayloadRoot 'shared\gateway_isolation.py'
    $result = Invoke-HermesProcess -FilePath $Python -ArgumentList @('-B', $helper, 'probe', $Paths.InstallDir, $Paths.HermesHome) -Environment $Environment -TimeoutSeconds 60
    if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) { throw 'ResearchMultiplexProbeFailed' }
    try { $policy = $result.StdOut.Trim() | ConvertFrom-Json } catch { throw 'ResearchMultiplexProbeFailed' }
    if ($policy.schema -ne 1 -or $policy.mode -cnotin @('standalone','single','conflict')) { throw 'ResearchMultiplexProbeFailed' }
    if ($policy.mode -ceq 'conflict') {
        throw '현재 Hermes는 공용 gateway multiplex가 켜져 있지만 연구 프로필만 분리하는 gateway.standalone을 지원하지 않습니다. 개인 설정은 변경하지 않았습니다. 호환되는 Hermes 업데이트 또는 별도 데이터 경로가 필요합니다.'
    }
    return $policy
}

function Invoke-HermesResearchTeamSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [string]$HermesHome, [string]$InstallDir, [string]$RuntimeRoot,
        [AllowNull()][scriptblock]$ProgressCallback,
        [switch]$ReuseExistingProfiles, [switch]$UseExistingHermes
    )
    try { $summary = Assert-HermesResearchTeamInput -InputObject $InputObject } catch { throw ('연구팀 입력이 올바르지 않습니다: ' + $_.Exception.Message) }
    if (-not $InputObject.PSObject.Properties['WizardOptions'] -or $null -eq $InputObject.WizardOptions) { throw '연구팀 설치 선택(작업 폴더·요청자·한도·동의)이 필요합니다.' }
    $tokens = @{}
    foreach ($agent in @($InputObject.Agents)) { $tokens[[string]$agent.ProfileName] = [string]$agent.BotToken }
    $serverUri = [Uri]$summary.ServerURL
    $loopbackIP = $null
    $isLoopback = ($serverUri.DnsSafeHost -ieq 'localhost')
    if ([Net.IPAddress]::TryParse($serverUri.DnsSafeHost.Trim('[', ']'), [ref]$loopbackIP)) { $isLoopback = [Net.IPAddress]::IsLoopback($loopbackIP) }
    if (-not $isLoopback) { throw '1인 연구실은 이 PC의 loopback Mattermost 서버만 사용할 수 있습니다.' }

    # --- Hermes: the pinned install, or the user's existing one ---
    $runtime = $null
    if ($UseExistingHermes) {
        try { $runtime = Get-HermesExistingRuntime -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot } catch { throw '기존 Hermes 실행 환경을 안전하게 확인하지 못했습니다. 기존 설치는 변경하지 않았습니다.' }
        if ([string]$runtime.RuntimeKind -cne 'Existing' -or $null -eq $runtime.Paths -or $null -eq $runtime.Environment) { throw '기존 Hermes 실행 파일 구성을 안전하게 확인하지 못했습니다.' }
        $paths = $runtime.Paths
        $command = [IO.Path]::GetFullPath([string]$runtime.Command)
        $python = [IO.Path]::GetFullPath([string]$runtime.Python)
        foreach ($file in @($command, $python)) { if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or -not (Test-HermesPathContains -ParentPath ([string]$paths.InstallDir) -ChildPath $file)) { throw '기존 Hermes 실행 파일 구성을 안전하게 확인하지 못했습니다.' } }
        $environment = $runtime.Environment
    } else {
        $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
        $command = [IO.Path]::GetFullPath((Join-Path $paths.InstallDir 'bin\hermes.exe'))
        $python = Join-Path $paths.InstallDir 'venv\Scripts\python.exe'
        $environment = New-HermesResearchEnvironment -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir
    }
    $options = Assert-HermesResearchWizardOptions -Options $InputObject.WizardOptions -RuntimeRoot $paths.RuntimeRoot
    foreach ($path in @($paths.HermesHome, $paths.InstallDir, $paths.RuntimeRoot)) { if (-not (Test-HermesSafeTargetPath -LiteralPath $path).Safe) { throw '연구팀 경로가 안전하지 않습니다.' } }
    foreach ($protected in @($paths.HermesHome, $paths.InstallDir, $paths.RuntimeRoot)) {
        if ($options.WorkspacePath -ieq $protected -or (Test-HermesPathContains -ParentPath $protected -ChildPath $options.WorkspacePath) -or (Test-HermesPathContains -ParentPath $options.WorkspacePath -ChildPath $protected)) { throw '작업 폴더는 Hermes 설치·인증·운영 폴더와 분리하세요.' }
    }
    # Never echo a secret into any public setting.
    $publicText = (@($paths.HermesHome, $paths.InstallDir, $paths.RuntimeRoot, $summary.ServerURL, $options.WorkspacePath, $options.HumanUsername) + @($summary.Agents | ForEach-Object { $_.DisplayName })) -join "`n"
    $modelSecrets = @(foreach ($key in @('AnthropicKey', 'OpenAIKey')) { if ($InputObject.Model.PSObject.Properties[$key]) { [string]$InputObject.Model.$key } })
    foreach ($secret in @($tokens.Values) + $modelSecrets) {
        if ($secret -and $publicText.Contains($secret)) { throw '봇 토큰이나 API 키를 이름·경로·기타 공개 설정에 넣을 수 없습니다.' }
    }
    Publish-HermesResearchStage $ProgressCallback 'research-verify' 'Hermes 설치와 모델 연결 방식을 확인합니다.' 3
    if (-not $UseExistingHermes) {
        $verificationLog = Join-Path ([IO.Path]::GetTempPath()) ('hermes-research-verify-' + [guid]::NewGuid().ToString('N') + '.log')
        try { $verification = Test-HermesInstallation -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -LogPath $verificationLog } catch { throw '검증된 Hermes 설치가 필요합니다.' }
        finally { if (Test-Path -LiteralPath $verificationLog -PathType Leaf) { Remove-Item -LiteralPath $verificationLog -Force -ErrorAction SilentlyContinue } }
        if ($verification.Verified -isnot [bool] -or -not $verification.Verified -or -not [string]::Equals([string]$verification.CommandPath, $command, [StringComparison]::OrdinalIgnoreCase)) { throw '검증된 Hermes 설치가 필요합니다.' }
    }
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'ResearchPythonMissing' }
    if ($summary.Model.Mode -ceq 'Codex') {
        try { $codex = Get-HermesCodexStatus -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -UseExistingHermes:$UseExistingHermes } catch { throw 'OpenAI Codex 인증 확인에 실패했습니다.' }
        if ($codex.LoggedIn -isnot [bool] -or -not $codex.LoggedIn) { throw 'Codex 직접 연결에는 2단계의 OpenAI Codex 로그인이 필요합니다. 로그인하거나 라우터 연결을 선택하세요.' }
        if (@($codex.Models) -cnotcontains [string]$summary.Model.CodexModel) { throw '선택한 OpenAI Codex 모델을 현재 인증에서 확인할 수 없습니다.' }
    }
    $payload = Get-HermesResearchTeamPayload
    $isolation = Test-HermesResearchMultiplexer -Python $python -Paths $paths -Environment $environment -PayloadRoot $payload.Root
    Publish-HermesResearchStage $ProgressCallback 'research-gateway-isolation' '개인 Gateway 설정은 유지하고 연구 프로필만 전용 경로로 분리합니다. 총괄의 중복 응답을 차단합니다.' 5
    $environment = Initialize-HermesResearchGitEnvironment -Python $python -Environment $environment
    $notes = @()
    if ($null -eq (Get-Command latexmk -CommandType Application -ErrorAction SilentlyContinue)) { $notes += 'TeX(latexmk)를 찾지 못했습니다. 원고 PDF 빌드가 필요한 집필 작업은 보류됩니다. MiKTeX 또는 TeX Live를 설치하면 바로 사용할 수 있습니다.' }

    # --- Mattermost: four distinct bots in the channel, and the one person allowed to ask ---
    Publish-HermesResearchStage $ProgressCallback 'research-connection' '서로 다른 봇 4개와 연구 채널 참여, 요청자 계정을 확인합니다.' 8
    $connection = [pscustomobject]@{ ServerURL = $summary.ServerURL; HomeChannelID = $summary.HomeChannelID
        Agents = @($summary.Agents | ForEach-Object { [pscustomobject]@{ ProfileName = $_.ProfileName; BotToken = $tokens[$_.ProfileName] } }) }
    $identities = @(Test-HermesResearchTeamConnection -InputObject $connection)
    $humanID = Resolve-HermesResearchHuman -InputObject ([pscustomobject]@{ ServerURL = $summary.ServerURL; HomeChannelID = $summary.HomeChannelID; WizardOptions = $options; Agents = $connection.Agents })

    # --- Ownership: a fresh install, this team again, or the earlier broker team ---
    $owner = Get-HermesResearchCurrentUserSID
    $root = Join-Path $paths.RuntimeRoot 'research'
    $statePath = Join-Path $root 'team.json'
    $prior = Get-HermesResearchPriorTeam -StatePath $statePath -Paths $paths -OwnerSID $owner -ServerURL $summary.ServerURL -HomeChannelID $summary.HomeChannelID
    if ($null -ne $prior -and $prior.Kind -ceq 'Team' -and -not $ReuseExistingProfiles) { throw '이 PC에 이미 연구팀이 있습니다. 「연구팀 재설정」을 선택해 같은 팀을 갱신하세요.' }
    if ($null -ne $prior -and $prior.Kind -ceq 'Broker' -and -not $options.MigrationConsent) { throw '이전 4역할 연구팀(분배 서비스)이 있습니다. 「기존 연구팀 전환」에 동의하면 기록을 보존한 채 새 팀으로 바꿉니다.' }
    $teamID = $(if ($null -ne $prior) { [string]$prior.TeamID } else { [guid]::NewGuid().ToString('N') })
    $owned = @{}
    foreach ($agent in @($summary.Agents)) {
        $dir = Join-Path $paths.HermesHome ('profiles\' + $agent.ProfileName)
        $fromBroker = ($null -ne $prior -and $prior.Kind -ceq 'Broker' -and @($prior.Profiles | Where-Object { $_.ProfileName -ceq $agent.ProfileName -and $_.OwnsProfile -eq $true }).Count -eq 1)
        $owned[$agent.ProfileName] = (-not (Test-Path -LiteralPath $dir)) -or (Test-HermesResearchOwnedProfile -ProfileDir $dir -TeamID $teamID) -or $fromBroker
        if (-not $owned[$agent.ProfileName]) { throw ('Hermes 프로필 {0}이(가) 이미 있고 이 연구팀 소유가 아닙니다. 이름을 바꾸거나 제거한 뒤 다시 실행하세요. 변경하지 않았습니다.' -f $agent.ProfileName) }
    }
    $names = Get-HermesResearchTaskNames -OwnerSID $owner -HermesHome $paths.HermesHome
    $ps = Get-HermesPowerShellExecutable
    $servicePlan = Get-HermesResearchTaskPlan -ProfileName 'team-service' -Label 'team service' -HermesHome $paths.HermesHome -RuntimeRoot $paths.RuntimeRoot -OwnerSID $owner -TeamID $teamID -PowerShellPath $ps
    $leadPlan = Get-HermesResearchTaskPlan -ProfileName 'research-lead' -Label 'lead chat' -HermesHome $paths.HermesHome -RuntimeRoot $paths.RuntimeRoot -OwnerSID $owner -TeamID $teamID -PowerShellPath $ps
    foreach ($plan in @($servicePlan, $leadPlan)) {
        $existing = @(Get-HermesResearchGatewayTask -TaskName $plan.TaskName)
        if ($existing.Count -gt 1) { throw 'ResearchTaskCollision' }
        if ($existing.Count -eq 1) { Assert-HermesResearchOwnedTask -Task $existing[0] -Plan $plan -HasOwnership ($null -ne $prior -and $prior.Kind -ceq 'Team') }
    }

    Protect-HermesResearchPrivateDirectory -LiteralPath $root -OwnerSID $owner
    $lock = $null
    $migrationBackup = $null
    try {
        $lock = [IO.File]::Open((Join-Path $root 'team.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        if (($null -eq $prior -and (Test-Path -LiteralPath $statePath)) -or ($null -ne $prior -and (ConvertTo-HermesSha256 -LiteralPath $statePath) -cne $prior.StateSha256)) { throw '사전 검사 이후 연구팀 기록이 바뀌었습니다. 다시 확인하세요.' }
        $serviceConfig = Join-Path $root 'service.json'
        $serviceScript = Join-Path $root 'team\shared\team_service.py'
        if ($null -ne $prior -and $prior.Kind -ceq 'Team') {
            Publish-HermesResearchStage $ProgressCallback 'research-stop' '실행 중인 연구팀 서비스와 총괄 채팅을 멈춥니다. 진행 중이던 작업은 재시작 후 다시 이어집니다.' 12
            Stop-HermesResearchService -Plan $servicePlan -Python $python -ServiceScript $serviceScript -ConfigPath $serviceConfig -ResearchRoot $root -Environment $environment
            Stop-HermesResearchOwnedGateway -Plan $leadPlan -Python $python -Paths $paths -PayloadRoot $payload.Root -Environment $environment
        }
        if ($null -ne $prior -and $prior.Kind -ceq 'Broker') {
            Publish-HermesResearchStage $ProgressCallback 'research-migration' '이전 4역할 분배 서비스를 작업 종료 후 멈추고 설정을 백업합니다. 대화·산출물·기록은 그대로 둡니다.' 12
            $brokerPlan = Get-HermesResearchTaskPlan -ProfileName 'governed-team' -HermesHome $paths.HermesHome -RuntimeRoot $paths.RuntimeRoot -OwnerSID $prior.OwnerSID -TeamID $prior.TeamID -PowerShellPath $ps -Manager $script:ResearchLegacyManager
            $migrationTasks = @(Get-HermesResearchMigrationTasks -Prior $prior -Paths $paths -BrokerPlan $brokerPlan)
            $brokerIdentity = Enter-HermesResearchMaintenance -ResearchRoot $root -Tasks $migrationTasks -BrokerPlan $brokerPlan -Python $python
            Assert-HermesResearchBrokerIdle -ResearchRoot $root -Python $python -Environment $environment
            $migrationBackup = Backup-HermesResearchMigration -Paths $paths -Prior $prior -Tasks $migrationTasks
            Stop-HermesResearchMigrationTasks -Tasks $migrationTasks -BrokerIdentity $brokerIdentity
            Exit-HermesResearchMaintenance -ResearchRoot $root
        }

        Publish-HermesResearchStage $ProgressCallback 'research-files' '검증된 연구팀 구성 파일을 설치합니다.' 18
        $teamRoot = Install-HermesResearchTeamFiles -Payload $payload -ResearchRoot $root
        $private = Join-Path $root 'private'
        Protect-HermesResearchPrivateDirectory -LiteralPath $private -OwnerSID $owner
        $gateway = $null
        $overlays = @("gateway:`n  standalone: true`n  multiplex_profiles: false`n")
        if ($summary.Model.Mode -ceq 'Gateway') {
            $gateway = Install-HermesResearchModelGateway -Paths $paths -Python $python -TeamRoot $teamRoot -Model $InputObject.Model -ModelSummary $summary.Model -Port ([int]$options.GatewayPort) -OwnerSID $owner -Environment $environment -ProgressCallback $ProgressCallback
            $overlays += [IO.File]::ReadAllText((Join-Path $teamRoot 'gateway\hermes.overlay.yaml'), [Text.Encoding]::UTF8)
        } else {
            $overlays += ("model:`n  provider: openai-codex`n  default: {0}`nterminal:`n  backend: local`n" -f $summary.Model.CodexModel)
        }
        $placeholders = @{
            '__PYTHON__' = ConvertTo-HermesResearchBashPath $python
            '__RESEARCH_BOARD__' = ConvertTo-HermesResearchBashPath (Join-Path $teamRoot 'shared\research_board.py')
            '__WORKSPACE__' = ConvertTo-HermesResearchBashPath $options.WorkspacePath
            '__TEAM_HOME__' = ConvertTo-HermesResearchBashPath $root
            '__RESEARCH_GATEWAY_URL__' = $(if ($gateway) { $gateway.Url } else { 'http://127.0.0.1:1/v1' })
        }
        $profileManifest = [ordered]@{}
        $records = New-Object System.Collections.Generic.List[object]
        $index = 0
        foreach ($agent in @($summary.Agents)) {
            $index++
            Publish-HermesResearchStage $ProgressCallback 'research-profile' ('프로필 구성: {0} ({1}/4)' -f $agent.ProfileName, $index) (24 + 8 * $index)
            $identity = @($identities | Where-Object { $_.ProfileName -ceq $agent.ProfileName })[0]
            $isLead = ($agent.ProfileName -ceq 'research-lead')
            $values = @{ GATEWAY_MULTIPLEX_PROFILES = 'false' }
            if ($isLead) {
                $values += @{ MATTERMOST_URL = $summary.ServerURL; MATTERMOST_TOKEN = $tokens['research-lead']; MATTERMOST_ALLOWED_USERS = $humanID
                    MATTERMOST_ALLOW_ALL_USERS = 'false'; MATTERMOST_HOME_CHANNEL = $summary.HomeChannelID; MATTERMOST_REPLY_MODE = 'thread'; MATTERMOST_REQUIRE_MENTION = 'true' }
                if ($gateway) { $values['RESEARCH_GATEWAY_API_KEY'] = 'rgw.research-lead.public.' + $gateway.Secret; $values['RESEARCH_GATEWAY_URL'] = $gateway.Url }
            }
            # Runner profiles hold no bot token or gateway key: the service hands each runner its own,
            # and the runner never passes them to the agent.
            $remove = @('MATTERMOST_', 'SLACK_', 'DISCORD_', 'TELEGRAM_', 'WHATSAPP_', 'SIGNAL_', 'IMESSAGE_', 'MATRIX_', 'RESEARCH_GATEWAY_')
            if ($gateway) { $remove += @('ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'OPENROUTER_API_KEY', 'GOOGLE_API_KEY', 'GEMINI_API_KEY') }
            $manifest = Install-HermesResearchProfile -ProfileName $agent.ProfileName -Paths $paths -TeamRoot $teamRoot -CommandPath $command -Environment $environment -Python $python `
                -TeamID $teamID -Placeholders $placeholders -Overlays $overlays -EnvValues $values -RemoveEnvPrefixes $remove -AllowExisting ([bool]$owned[$agent.ProfileName]) -EnableMattermost:$isLead
            $profileManifest[$agent.ProfileName] = $manifest
            $records.Add([pscustomobject][ordered]@{ ProfileName = $agent.ProfileName; DisplayName = $agent.DisplayName; BotUserID = $identity.BotUserID; BotUsername = $identity.BotUsername; OwnsProfile = $true; Status = 'Configured' })
        }
        Write-HermesResearchAtomicText -LiteralPath (Join-Path $teamRoot 'shared\profile-manifest.json') -Text ((@{ schema = 1; profiles = $profileManifest } | ConvertTo-Json -Depth 6) + "`n")

        $isolated = Invoke-HermesProcess -FilePath $python -ArgumentList @('-B', (Join-Path $teamRoot 'shared\gateway_isolation.py'), 'verify', $paths.HermesHome) -Environment $environment -TimeoutSeconds 60
        if (-not $isolated.Started -or $isolated.TimedOut -or $isolated.ExitCode -ne 0) { throw 'ResearchGatewayIsolationFailed' }
        try { $isolatedResult = $isolated.StdOut.Trim() | ConvertFrom-Json } catch { throw 'ResearchGatewayIsolationFailed' }
        if ($isolatedResult.verified -isnot [bool] -or -not $isolatedResult.verified -or (@($isolatedResult.profiles) -join ',') -cne 'research-lead,research-scout,research-worker,research-reviewer') { throw 'ResearchGatewayIsolationFailed' }

        Publish-HermesResearchStage $ProgressCallback 'research-workspace' '작업 폴더(_template, reports 보고서 보드)를 준비합니다.' 66
        $leadName = @($identities | Where-Object { $_.ProfileName -ceq 'research-lead' })[0].BotUsername
        $mention = '@' + $options.HumanUsername
        $boardEnv = @{} + $environment
        $boardEnv['MATTERMOST_URL'] = $summary.ServerURL; $boardEnv['MATTERMOST_TOKEN'] = $tokens['research-lead']
        Write-HermesResearchAtomicText -LiteralPath (Join-Path $root 'workspace-root.txt') -Text ($options.WorkspacePath + "`n")
        $null = Install-HermesResearchWorkspace -WorkspacePath $options.WorkspacePath -TeamRoot $teamRoot -Python $python -Environment $boardEnv -ChannelID $summary.HomeChannelID -Mention $mention

        $secrets = [ordered]@{ MATTERMOST_URL = $summary.ServerURL }
        foreach ($agent in @($summary.Agents | Where-Object { $_.ProfileName -cne 'research-lead' })) { $secrets['MATTERMOST_TOKEN__' + $agent.ProfileName] = $tokens[$agent.ProfileName] }
        if ($gateway) { $secrets['RESEARCH_GATEWAY_SECRET'] = $gateway.Secret; $secrets['RESEARCH_GATEWAY_URL'] = $gateway.Url }
        $secretsPath = Join-Path $private 'service.env'
        Write-HermesResearchEnvValues -LiteralPath $secretsPath -Values $secrets -Header 'Research team service — bot tokens per runner. Managed by Hermes Easy Setup.'
        $bots = [ordered]@{}
        foreach ($agent in @($summary.Agents)) { $bots[$agent.ProfileName] = $tokens[$agent.ProfileName] }
        Write-HermesResearchAtomicText -LiteralPath (Join-Path $private 'bots.json') -Text (($bots | ConvertTo-Json) + "`n")
        $runners = New-Object System.Collections.Generic.List[object]
        foreach ($role in @('research-scout', 'research-worker')) { $runners.Add([ordered]@{ role = $role; slot = 1; task_timeout = 60 * [int]$options.TaskTimeoutMinutes; heartbeat = 60 }) }
        for ($slot = 1; $slot -le [int]$options.ReviewerSlots; $slot++) { $runners.Add([ordered]@{ role = 'research-reviewer'; slot = $slot; task_timeout = 60 * [int]$options.TaskTimeoutMinutes; heartbeat = 60 }) }
        $service = [ordered]@{
            team_home = $root; hermes_home = $paths.HermesHome; python = $python; hermes = $command
            board = (Join-Path $teamRoot 'shared\research_board.py'); papers_file = (Join-Path $root 'papers')
            secrets_file = $secretsPath; runners = $runners.ToArray()
            dashboard = [ordered]@{ workspace = $options.WorkspacePath }
            coordinator = [ordered]@{ enabled = $true; task_timeout = 60 * [int]$options.TaskTimeoutMinutes }
            limits = [ordered]@{ max_turns = 2000; max_attempts = 50; model_retries = 100 }
            gateway = $(if ($gateway) { [ordered]@{ dir = $gateway.Dir; port = $gateway.Port; litellm = $gateway.Litellm } } else { $null })
        }
        Write-HermesResearchAtomicText -LiteralPath $serviceConfig -Text (($service | ConvertTo-Json -Depth 6) + "`n")

        $state = [pscustomobject][ordered]@{
            SchemaVersion = 2; Manager = $script:ResearchManager; OwnerSID = $owner; TeamID = $teamID; RuntimeKind = $(if ($UseExistingHermes) { 'Existing' } else { 'Pinned' })
            HermesHome = $paths.HermesHome; InstallDir = $paths.InstallDir; RuntimeRoot = $paths.RuntimeRoot
            ServerURL = $summary.ServerURL; HomeChannelID = $summary.HomeChannelID; Model = $summary.Model; WizardOptions = $options
            PayloadManifestSha256 = $payload.ManifestSha256; MigrationBackupPath = $migrationBackup
            Tasks = @($servicePlan.TaskName, $leadPlan.TaskName); Profiles = $records.ToArray(); UpdatedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        Write-HermesResearchAtomicText -LiteralPath $statePath -Text (($state | ConvertTo-Json -Depth 8) + "`n")
        $locationsPath = Join-Path $options.WorkspacePath 'RESEARCH_PATHS.md'
        $locations = Invoke-HermesProcess -FilePath $python -ArgumentList @('-B', (Join-Path $teamRoot 'shared\research_board.py'), 'locations', '--workspace', $options.WorkspacePath, '--write') -WorkingDirectory $options.WorkspacePath -Environment $boardEnv -TimeoutSeconds 120
        if (-not $locations.Started -or $locations.TimedOut -or $locations.ExitCode -ne 0) { throw 'ResearchLocationsGuideFailed' }

        Publish-HermesResearchStage $ProgressCallback 'research-service' '연구팀 서비스(모델 라우터·실행기)와 총괄 채팅을 로그인 자동 실행으로 등록하고 시작합니다.' 72
        Register-HermesResearchServiceTask -Plan $servicePlan -Python $python -ServiceScript $serviceScript -ConfigPath $serviceConfig -HermesHome $paths.HermesHome -HasOwnership ($null -ne $prior -and $prior.Kind -ceq 'Team') -GitDirectory $environment['RESEARCH_GIT_DIRECTORY']
        $nativeResult = Invoke-HermesProcess -FilePath $python -ArgumentList @('-B', (Join-Path $teamRoot 'shared\research_launch.py'), $paths.InstallDir) -Environment $environment -TimeoutSeconds 45
        if (-not $nativeResult.Started -or $nativeResult.TimedOut -or $nativeResult.ExitCode -ne 0) { throw 'ResearchGatewayLauncherProbeFailed: 설치된 Hermes 실행 경로 확인 실패. 개인 설정은 변경하지 않았습니다.' }
        $nativeLaunch = $nativeResult.StdOut.Trim() | ConvertFrom-Json
        Register-HermesResearchGatewayTask -Plan $leadPlan -CommandPath $command -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -ProfileName 'research-lead' -HasOwnership ($null -ne $prior -and $prior.Kind -ceq 'Team') -GitDirectory $environment['RESEARCH_GIT_DIRECTORY'] -NativeLaunch $nativeLaunch -Python $python -TeamRoot $teamRoot
        $startedAt = Get-Date
        Start-HermesResearchGatewayTask -Plan $servicePlan
        $null = Wait-HermesResearchServiceReady -ResearchRoot $root -StartedAfter $startedAt -ExpectedChildren ($runners.Count + 2 + $(if ($gateway) { 1 } else { 0 })) -Gateway ($null -ne $gateway)
        $dashboard=Wait-HermesResearchDashboardReady -ResearchRoot $root -StartedAfter $startedAt -WorkspacePath $options.WorkspacePath
        $boardPlugins=Invoke-HermesResearchPluginsSetup -RuntimeRoot $paths.RuntimeRoot -Python $python -AllowedUserID $humanID -Apply -ProgressCallback $ProgressCallback
        if(-not $boardPlugins.Ready -or -not $boardPlugins.UploadsLocked){throw 'ResearchMattermostPluginsNotReady'}
        Start-HermesResearchGatewayTask -Plan $leadPlan
        Wait-HermesResearchGatewayReady -CommandPath $command -ProfileName 'research-lead' -Environment $environment -Plan $leadPlan -TimeoutSeconds 90

        Publish-HermesResearchStage $ProgressCallback 'research-live-test' '설치된 총괄·독립 실행기로 실제 S1·S2·S3을 수행합니다. 원문 조사·분석·감사·첨부 검증이 끝나야 사용 준비 완료입니다. 진행 중에는 기록을 보존합니다.' 80
        $testEnv = @{} + $environment
        $testEnv['MATTERMOST_URL'] = $summary.ServerURL; $testEnv['MATTERMOST_TOKEN'] = $tokens['research-lead']
        $workflowTest = Invoke-HermesResearchSelfTest -ResearchRoot $root -Python $python -Environment $testEnv -WorkspacePath $options.WorkspacePath -ChannelID $summary.HomeChannelID -CommandPath $command -Mention $mention
        $pending = @()
        if (-not $workflowTest.Passed) { $pending += ('실제 네 역할 테스트 미통과: ' + $workflowTest.ErrorCode + $(if ($workflowTest.Detail) { ' — ' + $workflowTest.Detail } else { '' })) }
        return [pscustomobject]@{
            Succeeded = [bool]$workflowTest.Passed; PartialSuccess = -not $workflowTest.Passed; ExecutionReady = [bool]$workflowTest.Passed; WorkflowTest = $workflowTest
            ExecutionMode = 'ResearchTeam'; PendingSettings = $pending; Profiles = $records.ToArray(); StatePath = $statePath; MigrationBackupPath = $migrationBackup
            RuntimeKind = $state.RuntimeKind; ServerURL = $summary.ServerURL; HomeChannelID = $summary.HomeChannelID; Model = $summary.Model
            LeadUsername = $leadName; WorkspacePath = $options.WorkspacePath; LocationsPath = $locationsPath; TaskNames = $state.Tasks; Notes = @($notes); DashboardURL = [string]$dashboard.url
        }
    } finally { if ($null -ne $lock) { $lock.Dispose() } }
}

function Get-HermesResearchTeamStatus {
    <# The saved team (no secrets) and the service's last heartbeat, for the wizard. #>
    param([string]$RuntimeRoot)
    $root = Join-Path $RuntimeRoot 'research'
    $statePath = Join-Path $root 'team.json'
    $state = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) { try { $state = [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $state = $null } }
    return [pscustomobject]@{ State = $state; Service = (Read-HermesResearchServiceStatus -ResearchRoot $root) }
}

Export-ModuleMember -Function @(
    'Invoke-HermesResearchTeamSetup', 'New-HermesResearchWizardOptions', 'Assert-HermesResearchWizardOptions',
    'Get-HermesResearchGatewayState', 'Get-HermesResearchTeamStatus'
)
