Set-StrictMode -Version 2.0

# Installs the research team (team/ in this repository) into Hermes profiles and the runtime
# folder. Safeguards kept from the governed broker: hash-verified payload, wizard-owned
# profiles only, ACL-protected secrets, owned scheduled tasks, and a live end-to-end test.
$script:ResearchTeamMarker = '.research-team'
$script:ResearchRenderedSuffixes = @('.md', '.yaml', '.yml')

function Protect-HermesResearchPrivateDirectory {
    param([string]$LiteralPath, [string]$OwnerSID)
    if (-not (Test-HermesSafeTargetPath -LiteralPath $LiteralPath).Safe) { throw 'ResearchPrivatePathRejected' }
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Container)) { New-Item -ItemType Directory -Path $LiteralPath -Force | Out-Null }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($OwnerSID, 'S-1-5-18')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    # Replace only the DACL. A brand-new descriptor passed to Set-Acl can
    # request owner/SACL writes and SeSecurityPrivilege on an existing folder.
    # Preserve those sections so a normal current-user install remains possible.
    $section = [Security.AccessControl.AccessControlSections]::Access
    $directory = New-Object IO.DirectoryInfo($LiteralPath)
    $existing = $(if ($PSVersionTable.PSVersion.Major -ge 6) { [IO.FileSystemAclExtensions]::GetAccessControl($directory, $section) } else { $directory.GetAccessControl($section) })
    $rules = @($existing.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    $correct = $existing.AreAccessRulesProtected -and $rules.Count -eq 2 -and @($rules | Where-Object {
        $_.IdentityReference.Value -cnotin @($OwnerSID,'S-1-5-18') -or $_.AccessControlType -ne 'Allow' -or
        $_.FileSystemRights -ne 'FullControl' -or $_.InheritanceFlags -ne 'ContainerInherit, ObjectInherit' -or $_.PropagationFlags -ne 'None'
    }).Count -eq 0
    if ($correct) { return }
    $existing.SetSecurityDescriptorSddlForm($acl.GetSecurityDescriptorSddlForm($section), $section)
    if ($PSVersionTable.PSVersion.Major -ge 6) { [IO.FileSystemAclExtensions]::SetAccessControl($directory,$existing) }
    else { $directory.SetAccessControl($existing) }
}
function Get-HermesResearchPythonProcessPath {
    param([string]$Python)
    # Windows venv python.exe is a launcher. Its child process MainModule is
    # the base interpreter, not the launcher's path. Ask that exact interpreter
    # for its OS module path instead of trusting arbitrary heartbeat metadata.
    $program = 'import ctypes,sys; b=ctypes.create_unicode_buffer(32768); n=ctypes.windll.kernel32.GetModuleFileNameW(None,b,len(b)); print(b.value if n else ""); sys.exit(0 if n else 1)'
    $probe = Invoke-HermesProcess -FilePath $Python -ArgumentList @('-I','-S','-B','-c',$program) -Environment @{ PYTHONHOME=''; PYTHONPATH=''; PYTHONUSERBASE=''; PYTHONSTARTUP='' } -TimeoutSeconds 15
    if (-not $probe.Started -or $probe.TimedOut -or $probe.ExitCode -ne 0) { throw 'ResearchPythonIdentityProbeFailed' }
    $physical = $probe.StdOut.Trim()
    # A verified Hermes venv may use uv's junction-backed base interpreter.
    # This is the OS path returned by the selected process, not an input path
    # to read/write or a value supplied by the heartbeat file.
    if (-not [IO.Path]::IsPathRooted($physical) -or $physical.StartsWith('\\') -or -not (Test-Path -LiteralPath $physical -PathType Leaf)) { throw 'ResearchPythonIdentityRejected' }
    return [IO.Path]::GetFullPath($physical)
}

function ConvertTo-HermesResearchBashPath {
    <# Agents run commands in Git Bash: give them C:/forward/slash paths, quoted by the skills. #>
    param([string]$Path)
    return ([IO.Path]::GetFullPath($Path) -replace '\\', '/')
}

function Expand-HermesResearchPlaceholders {
    param([string]$Text, [hashtable]$Values)
    foreach ($key in $Values.Keys) { $Text = $Text.Replace($key, [string]$Values[$key]) }
    if ($Text -cmatch '__(PYTHON|RESEARCH_BOARD|SKILLS_DIR|WORKSPACE|TEAM_HOME|RESEARCH_GATEWAY_URL)__') { throw 'ResearchPlaceholderUnresolved' }
    return $Text
}

function Install-HermesResearchTeamFiles {
    <# The verified payload, copied to <research>\team as one unit; the runner finds its home from team-home.txt. #>
    param([Parameter(Mandatory = $true)]$Payload, [Parameter(Mandatory = $true)][string]$ResearchRoot)
    $target = Join-Path $ResearchRoot 'team'
    $stage = Join-Path $ResearchRoot ('team.new-' + [guid]::NewGuid().ToString('N'))
    foreach ($path in @($target, $stage)) { if (-not (Test-HermesSafeTargetPath -LiteralPath $path).Safe) { throw 'ResearchTeamPathRejected' } }
    try {
        foreach ($file in @($Payload.Files)) {
            $to = Join-Path $stage ($file.Relative -replace '/', '\')
            $parent = Split-Path -Parent $to
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            [IO.File]::WriteAllBytes($to, [IO.File]::ReadAllBytes($file.Path))
            if ((ConvertTo-HermesSha256 -LiteralPath $to).ToLowerInvariant() -cne $file.Sha256) { throw 'ResearchTeamPayloadHashMismatch' }
        }
        [IO.File]::WriteAllBytes((Join-Path $stage 'manifest.json'), [IO.File]::ReadAllBytes((Join-Path $Payload.Root 'manifest.json')))
        [IO.File]::WriteAllText((Join-Path $stage 'shared\team-home.txt'), $ResearchRoot, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $target) {
            $old = Join-Path $ResearchRoot ('team.old-' + [guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $target -Destination $old -ErrorAction Stop
            Move-Item -LiteralPath $stage -Destination $target -ErrorAction Stop
            Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
        } else { Move-Item -LiteralPath $stage -Destination $target -ErrorAction Stop }
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return $target
}

function Set-HermesResearchProfileEnv {
    <# Rewrites only the keys the team manages; every other line of the profile's .env is kept. #>
    param([string]$LiteralPath, [hashtable]$Values, [string[]]$RemovePrefixes)
    $kept = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $LiteralPath -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($LiteralPath, [Text.Encoding]::UTF8)) {
            if ($line -ceq '# Managed by Hermes Easy Setup research team') { continue }
            $key = $(if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=') { $Matches[1] } else { $null })
            if ($null -ne $key -and ($Values.ContainsKey($key) -or @($RemovePrefixes | Where-Object { $key.StartsWith($_) }).Count -gt 0)) { continue }
            $kept.Add($line)
        }
    }
    $kept.Add('# Managed by Hermes Easy Setup research team')
    foreach ($key in @($Values.Keys | Sort-Object)) {
        $value = [string]$Values[$key]
        if ($value -match '[\r\n]') { throw 'ResearchEnvValueRejected' }
        $kept.Add(('{0}={1}' -f $key, $value))
    }
    Write-HermesResearchAtomicText -LiteralPath $LiteralPath -Text (($kept.ToArray() -join "`n") + "`n")
}

function Test-HermesResearchOwnedProfile {
    param([string]$ProfileDir, [string]$TeamID)
    $marker = Join-Path $ProfileDir $script:ResearchTeamMarker
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $false }
    return ([IO.File]::ReadAllText($marker, [Text.Encoding]::UTF8) -cmatch ('(?m)^team=' + [regex]::Escape($TeamID) + '\s*$'))
}

function Install-HermesResearchProfile {
    <# One profile: created new (never cloned), SOUL and skills rendered, config overlays merged,
       its .env written. -> the files the runner checks before every task. #>
    param(
        [Parameter(Mandatory = $true)][string]$ProfileName, [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$TeamRoot, [Parameter(Mandatory = $true)][string]$CommandPath,
        [Parameter(Mandatory = $true)][hashtable]$Environment, [Parameter(Mandatory = $true)][string]$Python,
        [Parameter(Mandatory = $true)][string]$TeamID, [Parameter(Mandatory = $true)][hashtable]$Placeholders,
        [string[]]$Overlays = @(), [hashtable]$EnvValues = @{}, [string[]]$RemoveEnvPrefixes = @(),
        [bool]$AllowExisting, [switch]$EnableMattermost
    )
    $dir = Join-Path $Paths.HermesHome ('profiles\' + $ProfileName)
    foreach ($target in @($dir, (Join-Path $dir '.env'), (Join-Path $dir 'SOUL.md'), (Join-Path $dir 'config.yaml'), (Join-Path $dir 'skills\research-team'))) {
        if (-not (Test-HermesSafeTargetPath -LiteralPath $target).Safe) { throw 'ResearchProfilePathRejected' }
    }
    if (Test-Path -LiteralPath $dir) {
        if (-not $AllowExisting) { throw ('Hermes 프로필 {0}이(가) 이미 있고 이 마법사의 연구팀 소유가 아닙니다. 변경하지 않았습니다.' -f $ProfileName) }
    } else {
        Invoke-HermesResearchCommand -CommandPath $CommandPath -Arguments @('profile', 'create', $ProfileName, '--no-alias') -Environment $Environment -TimeoutSeconds 180
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw 'ResearchProfileCreateFailed' }
    }
    Write-HermesResearchAtomicText -LiteralPath (Join-Path $dir $script:ResearchTeamMarker) -Text ("created-by=Hermes Easy Setup research team`nteam=$TeamID`n")
    $source = Join-Path $TeamRoot $ProfileName
    $skills = Join-Path $dir 'skills\research-team'
    $values = @{} + $Placeholders
    $values['__SKILLS_DIR__'] = ConvertTo-HermesResearchBashPath $skills
    Write-HermesResearchAtomicText -LiteralPath (Join-Path $dir 'SOUL.md') -Text (Expand-HermesResearchPlaceholders ([IO.File]::ReadAllText((Join-Path $source 'SOUL.md'), [Text.Encoding]::UTF8)) $values)
    if (Test-Path -LiteralPath $skills) { Remove-Item -LiteralPath $skills -Recurse -Force -ErrorAction Stop }
    $skillSource = Join-Path $source 'skills'
    if (Test-Path -LiteralPath $skillSource -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $skillSource -Recurse -File)) {
            $relative = $file.FullName.Substring($skillSource.Length).TrimStart('\', '/')
            $to = Join-Path $skills $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force | Out-Null
            if ($script:ResearchRenderedSuffixes -contains $file.Extension.ToLowerInvariant()) {
                Write-HermesResearchAtomicText -LiteralPath $to -Text (Expand-HermesResearchPlaceholders ([IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)) $values)
            } else { [IO.File]::WriteAllBytes($to, [IO.File]::ReadAllBytes($file.FullName)) }
        }
    }
    $merge = Join-Path $TeamRoot 'shared\merge_config.py'
    $config = Join-Path $dir 'config.yaml'
    $overlayTexts = @([IO.File]::ReadAllText((Join-Path $source 'config.overlay.yaml'), [Text.Encoding]::UTF8)) + @($Overlays)
    foreach ($overlay in $overlayTexts) {
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ('research-overlay-' + [guid]::NewGuid().ToString('N') + '.yaml')
        try {
            [IO.File]::WriteAllText($temporary, (Expand-HermesResearchPlaceholders $overlay $values), (New-Object Text.UTF8Encoding($false)))
            $result = Invoke-HermesProcess -FilePath $Python -ArgumentList @('-B', $merge, $config, $temporary) -Environment $Environment -TimeoutSeconds 60
            if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) { throw 'ResearchProfileConfigMergeFailed' }
        } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } }
    }
    # A taken-over profile of the earlier broker team had every platform disabled.
    $program = @'
import sys, yaml
from pathlib import Path
f = Path(sys.argv[1]); cfg = yaml.safe_load(f.read_text(encoding="utf-8")) or {}
want_mm = sys.argv[2] == "1"
gw = cfg.get("gateway") or {}
if gw.get("standalone") is not True or gw.get("multiplex_profiles") is not False:
    raise SystemExit("ResearchGatewayIsolationMissingBeforeCredentials")
model = cfg.get("model") if isinstance(cfg.get("model"), dict) else None
changed = False
plat = cfg.get("platforms") if isinstance(cfg.get("platforms"), dict) else None
if want_mm and plat and isinstance(plat.get("mattermost"), dict) and plat["mattermost"].get("enabled") is False:
    del plat["mattermost"]["enabled"]; changed = True
if sys.argv[3] in ("gateway", "direct") and model:
    for k in ("base_url", "api_mode", "api_key"):
        if k in model: model.pop(k); changed = True
if changed:
    f.write_text(yaml.safe_dump(cfg, sort_keys=False, allow_unicode=True), encoding="utf-8")
'@
    $mode = $(if ($Overlays | Where-Object { $_ -match 'research-gateway' }) { 'gateway' } else { 'direct' })
    $fix = Invoke-HermesProcess -FilePath $Python -ArgumentList @('-B', '-c', $program, $config, $(if ($EnableMattermost) { '1' } else { '0' }), $mode) -Environment $Environment -TimeoutSeconds 60
    if (-not $fix.Started -or $fix.TimedOut -or $fix.ExitCode -ne 0) { throw 'ResearchProfileConfigFixFailed' }
    Set-HermesResearchProfileEnv -LiteralPath (Join-Path $dir '.env') -Values $EnvValues -RemovePrefixes $RemoveEnvPrefixes
    $manifest = [ordered]@{ 'SOUL.md' = (ConvertTo-HermesSha256 -LiteralPath (Join-Path $dir 'SOUL.md')).ToLowerInvariant(); 'config.yaml' = (ConvertTo-HermesSha256 -LiteralPath $config).ToLowerInvariant() }
    if (Test-Path -LiteralPath $skills) {
        foreach ($file in @(Get-ChildItem -LiteralPath $skills -Recurse -File | Sort-Object FullName)) {
            $relative = 'skills/research-team/' + ($file.FullName.Substring($skills.Length).TrimStart('\', '/') -replace '\\', '/')
            $manifest[$relative] = (ConvertTo-HermesSha256 -LiteralPath $file.FullName).ToLowerInvariant()
        }
    }
    return $manifest
}

function Install-HermesResearchWorkspace {
    <# _template, the team context, a scratch folder and the shared reports board. #>
    param([string]$WorkspacePath, [string]$TeamRoot, [string]$Python, [hashtable]$Environment, [string]$ChannelID, [string]$Mention)
    New-Item -ItemType Directory -Path $WorkspacePath -Force | Out-Null
    $template = Join-Path $WorkspacePath '_template'
    if (Test-Path -LiteralPath $template) { Remove-Item -LiteralPath $template -Recurse -Force -ErrorAction Stop }
    Copy-Item -LiteralPath (Join-Path $TeamRoot 'template') -Destination $template -Recurse -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path $TeamRoot 'shared\team.hermes.md') -Destination (Join-Path $WorkspacePath '.hermes.md') -Force -ErrorAction Stop
    New-Item -ItemType Directory -Path (Join-Path $WorkspacePath '.scratch') -Force | Out-Null
    $reports = Join-Path $WorkspacePath 'reports'
    $board = Join-Path $TeamRoot 'shared\research_board.py'
    if (-not (Test-Path -LiteralPath $reports)) {
        Copy-Item -LiteralPath (Join-Path $TeamRoot 'reports-template') -Destination $reports -Recurse -ErrorAction Stop
        $markerDir = Join-Path $reports '.tasks'
        New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
        $marker = [ordered]@{ schema = 1; name = 'reports'; created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        Write-HermesResearchAtomicText -LiteralPath (Join-Path $markerDir 'project.json') -Text (($marker | ConvertTo-Json -Compress) + "`n")
    }
    foreach ($arguments in @(@('init', $reports), @('setup', $reports, '--channel', $ChannelID, '--mention', $Mention))) {
        $result = Invoke-HermesProcess -FilePath $Python -ArgumentList (@('-B', $board) + $arguments) -WorkingDirectory $WorkspacePath -Environment $Environment -TimeoutSeconds 120
        if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) {
            # Preserve a private, redacted cause instead of hiding import/Git failures
            # behind the same generic UI message. Never record arguments or bot tokens.
            $detail = Protect-HermesLogText -Text ([string]$result.StdErr + "`n" + [string]$result.StdOut)
            if ($detail.Length -gt 6000) { $detail = $detail.Substring($detail.Length - 6000) }
            $diagnostic = [ordered]@{ Stage = [string]$arguments[0]; Started = $result.Started; TimedOut = $result.TimedOut; ExitCode = $result.ExitCode; Detail = $detail }
            $logPath = Join-Path (Split-Path -Parent $TeamRoot) 'workspace-init-error.json'
            Write-HermesResearchAtomicText -LiteralPath $logPath -Text ($diagnostic | ConvertTo-Json -Depth 3)
            $cause = if ($detail -match 'ModuleNotFoundError') { 'PythonModuleImportFailed' } elseif ($result.TimedOut) { 'ProcessTimeout' } else { 'ProcessFailed' }
            throw ('ResearchReportsBoard' + $arguments[0] + 'Failed / ' + $cause + ' / ' + $logPath)
        }
    }
    return $reports
}

function Get-HermesResearchTaskNames {
    param([string]$OwnerSID, [string]$HermesHome)
    $suffix = (ConvertTo-HermesSha256 -Text ($OwnerSID + '|' + $HermesHome.ToLowerInvariant())).Substring(0, 12)
    return [pscustomobject]@{ Service = "Hermes Research $suffix - team service"; Lead = "Hermes Research $suffix - research-lead" }
}

function Register-HermesResearchServiceTask {
    param($Plan, [string]$Python, [string]$ServiceScript, [string]$ConfigPath, [string]$HermesHome, [bool]$HasOwnership, [string]$GitDirectory)
    $existing = @(Get-HermesResearchGatewayTask -TaskName $Plan.TaskName)
    if ($existing.Count -gt 1) { throw 'ResearchServiceTaskCollision' }
    if ($existing.Count -eq 1) {
        Assert-HermesResearchOwnedTask -Task $existing[0] -Plan $Plan -HasOwnership $HasOwnership
        if ([string]$existing[0].State -eq 'Running') { throw '연구팀 서비스가 아직 실행 중입니다. 중지한 뒤 다시 시도하세요.' }
    }
    $quote = { param([string]$Text) "'" + $Text.Replace("'", "''") + "'" }
    $runner = @(
        '$ErrorActionPreference = ''Stop'''
        ('$env:HERMES_HOME = {0}' -f (& $quote $HermesHome))
        if ($GitDirectory) { ('$env:PATH = {0} + '';'' + $env:PATH' -f (& $quote $GitDirectory)) }
        '$env:PYTHONHOME = $null; $env:PYTHONPATH = $null; $env:PYTHONUSERBASE = $null; $env:PYTHONSTARTUP = $null'
        '$env:PYTHONNOUSERSITE = ''1''; $env:PYTHONDONTWRITEBYTECODE = ''1''; $env:PYTHONUTF8 = ''1'''
        ('& {0} -B {1} serve --config {2}' -f (& $quote $Python), (& $quote $ServiceScript), (& $quote $ConfigPath))
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

function ConvertTo-HermesResearchUtc {
    <# PowerShell 7 turns ISO timestamps in JSON into DateTime; 5.1 leaves them as strings. #>
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Read-HermesResearchServiceStatus {
    param([string]$ResearchRoot)
    $path = Join-Path $ResearchRoot 'service-status.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -gt 262144) { return $null }
    try { return ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Wait-HermesResearchServiceReady {
    <# Every runner running and, with a router, the router answering as this team's router. #>
    param([string]$ResearchRoot, [datetime]$StartedAfter, [int]$ExpectedChildren, [bool]$Gateway, [int]$TimeoutSeconds = 240)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = $null
    do {
        $status = Read-HermesResearchServiceStatus -ResearchRoot $ResearchRoot
        if ($null -ne $status -and $status.PSObject.Properties['updated'] -and (ConvertTo-HermesResearchUtc $status.updated) -ge $StartedAfter.ToUniversalTime().AddSeconds(-1)) {
            $running = @($status.children | Where-Object { $_.state -ceq 'running' })
            $last = $status
            if ($running.Count -eq $ExpectedChildren -and (-not $Gateway -or $status.gateway.ok -eq $true)) { return $status }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    if ($null -ne $last -and $Gateway -and $last.gateway.ok -ne $true) { throw ('모델 라우터가 준비되지 않았습니다: ' + [string]$last.gateway.detail + ' — 로그: research\logs\gateway.log') }
    throw '연구팀 서비스(실행기)가 시간 안에 준비되지 않았습니다. research\logs 아래 로그를 확인하세요.'
}

function Stop-HermesResearchService {
    <# Ask the service to stop its runners cleanly, then end the scheduled task. #>
    param($Plan, [string]$Python, [string]$ServiceScript, [string]$ConfigPath, [string]$ResearchRoot, [hashtable]$Environment)
    $tasks = @(Get-HermesResearchGatewayTask -TaskName $Plan.TaskName)
    if ($tasks.Count -ne 1) { return }
    Assert-HermesResearchOwnedTask -Task $tasks[0] -Plan $Plan -HasOwnership $true
    if ([string]$tasks[0].State -ne 'Running') { return }
    if ((Test-Path -LiteralPath $ServiceScript -PathType Leaf) -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        $null = Invoke-HermesProcess -FilePath $Python -ArgumentList @('-B', $ServiceScript, 'stop', '--config', $ConfigPath) -Environment $Environment -TimeoutSeconds 30
        $deadline = (Get-Date).AddSeconds(90)
        do {
            $status = Read-HermesResearchServiceStatus -ResearchRoot $ResearchRoot
            if ($null -ne $status -and $status.PSObject.Properties['stopped'] -and $status.stopped -eq $true) { break }
            Start-Sleep -Seconds 1
        } while ((Get-Date) -lt $deadline)
    }
    Stop-ScheduledTask -TaskName $Plan.TaskName -TaskPath '\' -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(30)
    do {
        $current = @(Get-HermesResearchGatewayTask -TaskName $Plan.TaskName)
        if ($current.Count -eq 1 -and [string]$current[0].State -ne 'Running') { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw 'ResearchServiceStopTimeout'
}
