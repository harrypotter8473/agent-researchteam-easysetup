Set-StrictMode -Version 2.0
# Dot-sourced inside Admin: reuse its owned-deployment and Docker boundaries.
$script:ResearchPluginManager = 'HermesEasySetup.ResearchPlugins.v1'

function Invoke-HermesPluginDocker {
    param([string[]]$Arguments,[string]$InputJSON)
    if (-not $PSBoundParameters.ContainsKey('InputJSON')) {
        return (Invoke-HermesAdminDocker -Arguments $Arguments -TimeoutSeconds 120).StdOut
    }
    $dockerPath = Get-HermesAdminDocker
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $dockerPath
    $info.Arguments = ((@('--host',$script:AdminDockerHost) + $Arguments | ForEach-Object { ConvertTo-WindowsProcessArgument ([string]$_) }) -join ' ')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach($key in @('DOCKER_HOST','DOCKER_CONTEXT','DOCKER_TLS_VERIFY','DOCKER_CERT_PATH')){$info.EnvironmentVariables.Remove($key)}
    $p = New-Object Diagnostics.Process; $p.StartInfo = $info
    try {
        $null = $p.Start()
        $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
        $raw = [Text.Encoding]::UTF8.GetBytes($InputJSON)
        $p.StandardInput.BaseStream.Write($raw,0,$raw.Length); $p.StandardInput.Close()
        if (-not $p.WaitForExit(120000)) { $p.Kill(); throw '플러그인 로컬 관리 요청 시간이 초과되었습니다.' }
        $null = $stdout.GetAwaiter().GetResult(); $null = $stderr.GetAwaiter().GetResult()
        # mmctl may return a full config, including other secrets: never return/log it.
        if ($p.ExitCode -ne 0) { throw ('플러그인 로컬 관리 요청 실패 (종료 코드 '+$p.ExitCode+'). 서버 로그를 확인하세요.') }
    } finally { $p.Dispose() }
}

function Get-HermesResearchPluginPackages {
    $root = Split-Path -Parent $PSScriptRoot
    $pinPath = Join-Path $root 'config\mattermost-plugins.json'
    Assert-HermesAdminPath $pinPath
    $pin = [IO.File]::ReadAllText($pinPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
    if ($pin.schema -ne 1 -or @($pin.packages).Count -ne 2 -or $pin.bridge.path -cne 'plugins/research-board/bridge.py') { throw '연구 플러그인 pin 형식 오류' }
    $ids=@()
    foreach ($item in $pin.packages) {
        if ($item.id -cnotin @('com.hermes.research-board','com.nst.wordmark') -or $item.version -cnotmatch '^\d+\.\d+\.\d+$' -or
            $item.file -cne ($item.id+'-'+$item.version+'.tar.gz') -or $item.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw '허용되지 않은 연구 플러그인 pin' }
        $path=Join-Path $root ('assets\mattermost-plugins\'+$item.file)
        Assert-HermesAdminPath $path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $item.sha256) { throw ('플러그인 패키지 해시 불일치: '+$item.id) }
        $ids+=$item.id
    }
    if (@($ids|Sort-Object -Unique).Count -ne 2) { throw '중복 플러그인 pin' }
    $bridgePath=Join-Path $root $pin.bridge.path
    Assert-HermesAdminPath $bridgePath
    if ((Get-FileHash -LiteralPath $bridgePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.bridge.sha256) { throw '보드 연결 프로그램 해시 불일치' }
    return $pin
}

function Protect-HermesPluginDirectory {
    param([string]$Path)
    Assert-HermesAdminPath $Path
    $null=New-Item -ItemType Directory -Path $Path -Force
    $userSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $allowed=@($userSID,'S-1-5-18')
    $current=Get-Acl -LiteralPath $Path
    $rules=@($current.Access)
    $valid=$current.AreAccessRulesProtected -and $rules.Count -eq 2
    foreach($rule in $rules){if($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -cnotin $allowed -or $rule.AccessControlType -ne 'Allow' -or $rule.FileSystemRights -ne 'FullControl'){$valid=$false}}
    if($valid){return}
    # Change the DACL only. WinPS Set-Acl may request SeSecurityPrivilege/SACL
    # access when reapplying a fresh DirectorySecurity to an existing folder.
    $icacls=Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\icacls.exe'
    $result=Invoke-HermesProcess -FilePath $icacls -ArgumentList @($Path,'/inheritance:r','/grant:r',('*'+$userSID+':(OI)(CI)F'),'*S-1-5-18:(OI)(CI)F') -TimeoutSeconds 20
    if(-not $result.Started -or $result.ExitCode -ne 0){throw '보드 비공개 폴더의 사용자·SYSTEM 권한을 설정하지 못했습니다.'}
    $current=Get-Acl -LiteralPath $Path
    if(-not $current.AreAccessRulesProtected){throw '보드 비공개 폴더의 상속 차단 확인 실패'}
    foreach($rule in @($current.Access)){if($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -cnotin $allowed -or $rule.AccessControlType -ne 'Allow'){throw '다른 사용자의 명시적 권한이 있는 폴더에는 비밀값을 저장하지 않습니다.'}}
}

function Get-HermesResearchPluginContainer {
    param($State)
    $ids=@((Invoke-HermesPluginDocker @('ps','--filter',('label=com.docker.compose.project='+$State.Project),'--filter','label=com.docker.compose.service=mattermost','--format','{{.ID}}')) -split '\r?\n'|Where-Object {$_})
    if($ids.Count -ne 1){throw '소유 연구 Mattermost 컨테이너를 하나로 확인하지 못했습니다.'}
    $item=@((Invoke-HermesPluginDocker @('inspect',$ids[0]))|ConvertFrom-Json)[0]
    if($item.Config.Labels.'com.infonet.easy-setup.deployment' -cne $State.DeploymentId -or
        $item.Config.Labels.'com.docker.compose.project' -cne $State.Project -or -not $item.State.Running -or
        $item.Config.Image -cne $State.Pin.mattermostImage) {throw '연구 서버 소유권·이미지 확인 실패'}
    return [string]$item.Id
}

function Set-HermesResearchPluginConfig {
    param([string]$Container,$Patch)
    $json=$Patch|ConvertTo-Json -Depth 10 -Compress
    $null=Invoke-HermesPluginDocker -Arguments @('exec','-i',$Container,'/mattermost/bin/mmctl','--local','--quiet','config','patch','/dev/stdin') -InputJSON $json
}

function Test-HermesResearchPluginReady {
    param([string]$BaseURL,[string]$Secret)
    if($BaseURL -cnotmatch '^http://127\.0\.0\.1:[0-9]{4,5}/?$' -or $Secret -cnotmatch '^[a-f0-9]{64}$'){return $false}
    try{
        $health=Invoke-RestMethod -Uri ($BaseURL.TrimEnd('/')+'/plugins/com.hermes.research-board/installer-health') -Headers @{'X-Hermes-Setup-Probe'=$Secret} -TimeoutSec 30 -MaximumRedirection 0
        return ($health.ready -eq $true -and $health.read_only -eq $true)
    }catch{return $false}
}

function Get-HermesResearchPluginList {
    param([string]$Container)
    $raw=Invoke-HermesPluginDocker @('exec',$Container,'/mattermost/bin/mmctl','--local','--json','plugin','list')
    if([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -ceq 'null'){return @()}
    $data=$raw|ConvertFrom-Json
    # mmctl can wrap PluginsResponse in a JSON array. WinPS5 also preserves
    # this one-element array, unlike property enumeration in newer shells.
    foreach($entry in @($data)) {
        if($null -eq $entry){continue}
        $isResponse=$null -ne $entry.PSObject.Properties['active'] -or $null -ne $entry.PSObject.Properties['inactive']
        if($isResponse) {
            foreach($group in @('active','inactive')) {
                if($null -eq $entry.PSObject.Properties[$group]){continue}
                foreach($p in @($entry.$group)) {
                    if($null -eq $p){continue}
                    if($null -eq $p.PSObject.Properties['id'] -or $null -eq $p.PSObject.Properties['version']){throw '플러그인 목록 항목 형식 오류'}
                    [pscustomobject]@{id=[string]$p.id;version=[string]$p.version;Enabled=($group -ceq 'active')}
                }
            }
        } else {
            if($null -eq $entry.PSObject.Properties['id'] -or $null -eq $entry.PSObject.Properties['version']){throw '플러그인 목록 응답 형식 오류'}
            $entry
        }
    }
}

function Assert-HermesResearchPluginsIdle {
    param($Config)
    try{
        $snapshot=Invoke-RestMethod -Uri ('http://127.0.0.1:'+$Config.port+'/api/projects') -Headers @{'X-Hermes-Board-Secret'=$Config.secret} -TimeoutSec 30 -MaximumRedirection 0
        if($null -eq $snapshot.PSObject.Properties['projects']){throw '작업 목록 확인 실패'}
        $running=@($snapshot.projects|ForEach-Object {$_.tasks}|Where-Object {$_.status -ceq 'running'})
    }catch{throw '실행 중인 연구 유무를 확인하지 못해 Mattermost를 재시작하지 않았습니다. 보드 연결을 확인한 뒤 다시 시도하세요.'}
    if($running.Count){throw '현재 연구 작업이 진행 중이므로 Mattermost를 재시작하지 않았습니다. 작업 종료 후 보드·NST 연결을 다시 실행하세요.'}
}

function Start-HermesResearchPluginBridge {
    param([string]$Root,[string]$Python,$Team,$Pin)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $dir=Join-Path $Root 'mattermost-plugins'
    Protect-HermesPluginDirectory $dir
    $recordPath=Join-Path $dir 'state.json'
    $configPath=Join-Path $dir 'bridge.json'
    $taskName='Hermes Research Board '+$Team.TeamID.Substring(0,12)
    $description=$script:ResearchPluginManager+'; owner='+$sid+'; team='+$Team.TeamID
    $existing=@(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
    if($existing.Count -gt 1 -or ($existing.Count -eq 1 -and $existing[0].Description -cne $description)){throw '보드 연결 예약 작업 소유권 불일치'}
    $prior=$null
    if(Test-Path -LiteralPath $recordPath) {
        $prior=[IO.File]::ReadAllText($recordPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
        if($prior.Manager -cne $script:ResearchPluginManager -or $prior.OwnerSID -cne $sid -or $prior.TeamID -cne $Team.TeamID){throw '다른 연구팀 보드 설정은 덮어쓰지 않습니다.'}
    } elseif($existing.Count){throw '보드 연결 소유 기록 없음'}
    $bridgePath=Join-Path $dir 'bridge.py'
    if($prior -and (Test-Path -LiteralPath (Join-Path $dir 'process.json'))) {
        $processRecord=[IO.File]::ReadAllText((Join-Path $dir 'process.json'))|ConvertFrom-Json
        $proc=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$processRecord.pid) -ErrorAction SilentlyContinue
        if($proc) {
            if([IO.Path]::GetFileName($proc.ExecutablePath) -ine 'python.exe' -or $proc.CommandLine -notlike ('*'+$bridgePath+'*') -or $proc.CommandLine -notlike ('*'+$configPath+'*') -or
                $processRecord.config_sha256 -ine (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash){throw '보드 연결 프로세스 소유권 불일치'}
            if($existing.Count){Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop}
            Stop-Process -Id ([int]$processRecord.pid) -ErrorAction SilentlyContinue
        }
    }
    if(Test-Path -LiteralPath $configPath){
        if(-not $prior){throw '소유 기록 없는 보드 비밀 파일은 재사용하지 않습니다.'}
        $cfg=[IO.File]::ReadAllText($configPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
        if($cfg.team_id -cne $Team.TeamID -or $cfg.secret -cnotmatch '^[a-f0-9]{64}$' -or [int]$cfg.port -lt 1024 -or [int]$cfg.port -gt 65535){throw '보드 연결 설정 불일치'}
    }else{
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
        try{$listener.Start();$port=$listener.LocalEndpoint.Port}finally{$listener.Stop()}
        $bytes=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create()
        try{$rng.GetBytes($bytes)}finally{$rng.Dispose()}
        $cfg=[pscustomobject]@{research_root=(Join-Path $Root 'research');workspace=[string]$Team.WizardOptions.WorkspacePath;team_id=[string]$Team.TeamID;port=$port;secret=([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant()}
    }
    Write-HermesAdminJSON $configPath $cfg
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) $Pin.bridge.path) -Destination $bridgePath -Force
    $startPath=Join-Path $dir 'Start-Bridge.ps1'
    $scriptText="`$ErrorActionPreference='Continue'`r`n& '"+$Python.Replace("'","''")+"' -I -B '"+$bridgePath.Replace("'","''")+"' --config '"+$configPath.Replace("'","''")+"' *> '"+(Join-Path $dir 'bridge.log').Replace("'","''")+"'`r`nexit `$LASTEXITCODE`r`n"
    [IO.File]::WriteAllText($startPath,$scriptText,(New-Object Text.UTF8Encoding($true)))
    $powershell=Get-HermesPowerShellExecutable
    $action=New-ScheduledTaskAction -Execute $powershell -Argument ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$startPath+'"') -WorkingDirectory $dir
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User $sid
    $principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
    $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $null=Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $description -Force
    $knownPackages=@();if($prior){$knownPackages=@($prior.Packages)}
    $record=[pscustomobject]@{Manager=$script:ResearchPluginManager;OwnerSID=$sid;TeamID=$Team.TeamID;TaskName=$taskName;Ready=$false;Packages=$knownPackages;BoardURL=''}
    Write-HermesAdminJSON $recordPath $record
    Start-ScheduledTask -TaskName $taskName
    $healthy=$false
    for($i=0;$i -lt 30;$i++){
        try{$health=Invoke-RestMethod -Uri ('http://127.0.0.1:'+$cfg.port+'/health') -Headers @{'X-Hermes-Board-Secret'=$cfg.secret} -TimeoutSec 5;if($health.ready){$healthy=$true;break}}catch{}
        Start-Sleep -Milliseconds 500
    }
    if(-not $healthy){throw '보드 연결 프로그램이 준비되지 않았습니다. 연구팀은 변경하지 않았습니다.'}
    return [pscustomobject]@{Config=$cfg;Record=$record;Prior=$prior;Directory=$dir}
}

function Invoke-HermesResearchPluginsSetup {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$RuntimeRoot,[string]$Python,[string]$AllowedUserID,[switch]$Apply,[scriptblock]$ProgressCallback)
    if(-not $Apply){throw '보드·브랜딩 적용에는 -Apply 승인이 필요합니다.'}
    Assert-HermesAdminPath $RuntimeRoot
    $teamPath=Join-Path $RuntimeRoot 'research\team.json'
    Assert-HermesAdminPath $teamPath
    $team=[IO.File]::ReadAllText($teamPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if($team.Manager -cne 'HermesEasySetup.ResearchTeam.v2' -or $team.OwnerSID -cne $sid -or $team.RuntimeRoot -ine $RuntimeRoot -or $team.TeamID -cnotmatch '^[a-f0-9]{32}$' -or $team.HomeChannelID -cnotmatch '^[a-z0-9]{26}$'){throw '이 사용자의 연구팀 소유권 확인 실패'}
    if($team.ServerURL -cnotmatch '^http://127\.0\.0\.1:[0-9]{4,5}/?$'){throw '외부 서버의 플러그인은 해당 서버 관리자가 설치해야 합니다. 자동 적용은 이 PC의 마법사 소유 서버만 지원합니다.'}
    $matches=@(Get-ChildItem -LiteralPath (Get-HermesAdminRoot) -Directory|ForEach-Object{
        $p=Join-Path $_.FullName 'deployment.json';if(Test-Path -LiteralPath $p){$s=[IO.File]::ReadAllText($p)|ConvertFrom-Json;if($s.ChannelId -ceq $team.HomeChannelID -and [int]$s.Identity.Port -eq ([uri]$team.ServerURL).Port){$s}}
    })
    if($matches.Count -ne 1){throw '플러그인을 적용할 소유 서버를 하나로 확인하지 못했습니다.'}
    $state=$matches[0]
    if($state.Owner -cne 'HermesEasySetup.Admin' -or $state.DeploymentId -cnotmatch '^[a-f0-9]{32}$' -or $state.Project -cne ('hes-'+$state.Identity.ServerId+'-'+$state.DeploymentId.Substring(0,8))){throw '서버 소유 기록 오류'}
    Set-HermesAdminComposeFiles $state  # Refuse edited compose; do not restart it.
    $container=Get-HermesResearchPluginContainer $state
    if(-not $Python){$service=[IO.File]::ReadAllText((Join-Path $RuntimeRoot 'research\service.json'))|ConvertFrom-Json;$Python=[string]$service.python}
    Assert-HermesAdminPath $Python
    if(-not (Test-Path -LiteralPath $Python -PathType Leaf) -or [IO.Path]::GetFileName($Python) -cne 'python.exe'){throw '설치된 연구팀 Python을 확인하지 못했습니다.'}
    if(-not $AllowedUserID){
        $name=[string]$team.WizardOptions.HumanUsername
        if($name -cnotmatch '^[a-z][a-z0-9._-]{2,63}$'){throw '연구 요청자 이름 확인 실패'}
        if($state.Identity.PSObject.Properties['AdminUsername'] -and $name -ceq [string]$state.Identity.AdminUsername){
            $AllowedUserID=[string]$state.AdminUserId
        }else{
            $users=@((Invoke-HermesPluginDocker @('exec',$container,'/mattermost/bin/mmctl','--local','--json','user','search',$name))|ConvertFrom-Json|Where-Object {$_.username -ceq $name -and $_.delete_at -eq 0})
            if($users.Count -ne 1){throw '보드 열람 요청자를 하나로 확인하지 못했습니다.'}
            $AllowedUserID=[string]$users[0].id
        }
    }
    if($AllowedUserID -cnotmatch '^[a-z0-9]{26}$'){throw '보드 열람 허용 사용자 확인 실패'}
    $pin=Get-HermesResearchPluginPackages
    $signature=(Invoke-HermesPluginDocker @('exec',$container,'/mattermost/bin/mmctl','--local','config','get','PluginSettings.RequirePluginSignature')).Trim()
    if($signature -cne 'false'){throw '서명 필수 정책은 자동 해제하지 않습니다. 관리자가 승인한 서명 패키지가 필요합니다.'}
    # Healthy reapply is a true no-op: do not bounce Mattermost, reset edited
    # permission settings, rotate secrets or restart even the read-only bridge.
    $savedPath=Join-Path $RuntimeRoot 'mattermost-plugins\state.json'
    $savedConfig=Join-Path $RuntimeRoot 'mattermost-plugins\bridge.json'
    if((Get-HermesAdminPluginMode $state) -ceq 'enabled' -and (Test-Path -LiteralPath $savedPath) -and (Test-Path -LiteralPath $savedConfig)){
        $saved=[IO.File]::ReadAllText($savedPath)|ConvertFrom-Json
        $same=$saved.Manager -ceq $script:ResearchPluginManager -and $saved.OwnerSID -ceq $sid -and $saved.TeamID -ceq $team.TeamID -and $saved.Ready
        foreach($p in $pin.packages){if(@($saved.Packages|Where-Object {$_.id -ceq $p.id -and $_.sha256 -ceq $p.sha256}).Count -ne 1){$same=$false}}
        $live=@(Get-HermesResearchPluginList $container)
        foreach($p in $pin.packages){if(@($live|Where-Object {$_.id -ceq $p.id -and $_.version -ceq $p.version -and $_.Enabled}).Count -ne 1){$same=$false}}
        if(@($live|Where-Object {$_.id -cin @('com.gist.wordmark','com.infonet.wordmark') -and $_.Enabled}).Count){$same=$false}
        if((Invoke-HermesPluginDocker @('exec',$container,'/mattermost/bin/mmctl','--local','config','get','PluginSettings.EnableUploads')).Trim() -cne 'false'){$same=$false}
        if($same){
            $cfg=[IO.File]::ReadAllText($savedConfig)|ConvertFrom-Json
            if($cfg.team_id -ceq $team.TeamID -and (Test-HermesResearchPluginReady $team.ServerURL $cfg.secret)){
                return [pscustomobject]@{Ready=$true;BoardURL=$saved.BoardURL;Plugins=@($pin.packages.id);UploadsLocked=$true;ResearchChanged=$false;ScenariosRerun=$false;AlreadyApplied=$true}
            }
        }
    }
    if($ProgressCallback){[void](& $ProgressCallback ([pscustomobject]@{type='stage';stage='research-plugins';state='running';percent=77;message='한국어 작업보드·NST 브랜딩을 검증하고 Mattermost 내부에 연결합니다.'}))}
    $bridge=Start-HermesResearchPluginBridge -Root $RuntimeRoot -Python $Python -Team $team -Pin $pin
    Assert-HermesResearchPluginsIdle $bridge.Config
    # Small metadata backup only. No research files, model credentials, or SQL config.
    $savedState=Join-Path $bridge.Directory 'prior-deployment.json'
    if(-not (Test-Path -LiteralPath $savedState)){Copy-Item -LiteralPath (Join-Path $state.Directory 'deployment.json') -Destination $savedState}
    $savedCompose=Join-Path $bridge.Directory 'prior-compose.json'
    if(-not (Test-Path -LiteralPath $savedCompose)){Copy-Item -LiteralPath (Join-Path $state.Directory 'compose.json') -Destination $savedCompose}
    $locked=$false
    try{
        # Local mmctl communicates over the owned container's Unix socket, not a
        # stored admin token. Secret config travels only over stdin.
        Set-HermesAdminPluginMode $state 'upload'
        $null=Invoke-HermesAdminCompose $state @('up','-d','mattermost')
        Wait-HermesAdminServer $team.ServerURL.TrimEnd('/')
        $container=Get-HermesResearchPluginContainer $state
        $plugins=@(Get-HermesResearchPluginList $container)
        foreach($package in $pin.packages){
            $existing=@($plugins|Where-Object {$_.id -ceq $package.id})
            $owned=@()
            if($bridge.Prior){$owned=@($bridge.Prior.Packages|Where-Object {$_.id -ceq $package.id})}
            $upgrade=$false
            if($existing.Count -gt 1){throw ('중복 플러그인 항목: '+$package.id)}
            if($existing.Count -eq 1){
                if($owned.Count -ne 1 -or $owned[0].version -cne $existing[0].version -or $owned[0].sha256 -cnotmatch '^[a-f0-9]{64}$'){throw ('다른 경로로 설치된 플러그인은 자동 교체하지 않습니다: '+$package.id)}
                if($owned[0].sha256 -cne $package.sha256){
                    if([version]$package.version -le [version]$owned[0].version){throw ('버전이 같은 변경본 또는 이전 플러그인은 자동 교체하지 않습니다: '+$package.id)}
                    $upgrade=$true
                }elseif($existing[0].version -cne $package.version){throw ('플러그인 소유 버전 불일치: '+$package.id)}
            }
            if(-not $existing.Count -or $upgrade){
                $source=Join-Path (Split-Path -Parent $PSScriptRoot) ('assets\mattermost-plugins\'+$package.file)
                $destination='/tmp/'+$package.file
                $null=Invoke-HermesPluginDocker @('cp',$source,($container+':'+$destination))
                if(-not $upgrade){
                    # Receipt before first install allows a retry after an
                    # interrupted successful upload, without claiming Ready.
                    $bridge.Record.Packages=@($bridge.Record.Packages|Where-Object {$_.id -cne $package.id})+@($package)
                    Write-HermesAdminJSON (Join-Path $bridge.Directory 'state.json') $bridge.Record
                }
                $pluginArguments=@('exec',$container,'/mattermost/bin/mmctl','--local','--quiet','plugin','add',$destination)
                if($upgrade){$pluginArguments+=@('--force')}
                $null=Invoke-HermesPluginDocker $pluginArguments
                $bridge.Record.Packages=@($bridge.Record.Packages|Where-Object {$_.id -cne $package.id})+@($package)
                Write-HermesAdminJSON (Join-Path $bridge.Directory 'state.json') $bridge.Record
            }else{$bridge.Record.Packages=@($bridge.Record.Packages|Where-Object {$_.id -cne $package.id})+@($package)}
        }
        $settings=@{BridgeURL=('http://host.docker.internal:'+$bridge.Config.port);BridgeSecret=$bridge.Config.secret;HomeChannelID=$team.HomeChannelID;AllowedUserIDs=$AllowedUserID}
        Set-HermesResearchPluginConfig $container @{PluginSettings=@{Plugins=@{'com.hermes.research-board'=$settings}}}
        # Mutually exclusive branding plugins must not fight over the same logo.
        foreach($id in @('com.gist.wordmark','com.infonet.wordmark')){if(@($plugins|Where-Object {$_.id -ceq $id -and $_.Enabled}).Count){$null=Invoke-HermesPluginDocker @('exec',$container,'/mattermost/bin/mmctl','--local','--quiet','plugin','disable',$id)}}
        foreach($package in $pin.packages){$null=Invoke-HermesPluginDocker @('exec',$container,'/mattermost/bin/mmctl','--local','--quiet','plugin','enable',$package.id)}
    }finally{
        Set-HermesAdminPluginMode $state 'enabled'
        $null=Invoke-HermesAdminCompose $state @('up','-d','mattermost')
        Wait-HermesAdminServer $team.ServerURL.TrimEnd('/')
        $container=Get-HermesResearchPluginContainer $state
        $lock=(Invoke-HermesPluginDocker @('exec',$container,'/mattermost/bin/mmctl','--local','config','get','PluginSettings.EnableUploads')).Trim()
        $locked=$lock -ceq 'false'
        if(-not $locked){throw '플러그인 설치 후 업로드 잠금 확인 실패'}
    }
    $null=Invoke-HermesPluginDocker -Arguments @('exec','-i',$container,'/mattermost/plugins/com.hermes.research-board/server/dist/plugin-linux-amd64','--probe') -InputJSON ($settings|ConvertTo-Json -Compress)
    if(-not (Test-HermesResearchPluginReady $team.ServerURL $bridge.Config.secret)){throw 'Mattermost 실제 보드 연결 확인 실패. 연구팀과 검증 기록은 유지했습니다.'}
    $list=@(Get-HermesResearchPluginList $container)
    foreach($package in $pin.packages){if(@($list|Where-Object {$_.id -ceq $package.id -and $_.version -ceq $package.version -and $_.Enabled}).Count -ne 1){throw ('적용된 플러그인 버전 확인 실패: '+$package.id)}}
    if(@($list|Where-Object {$_.id -cin @('com.gist.wordmark','com.infonet.wordmark') -and $_.Enabled}).Count){throw 'NST와 충돌하는 기존 브랜딩이 아직 활성화되어 있습니다.'}
    $url=$team.ServerURL.TrimEnd('/')+'/'+$state.Identity.TeamName+'/com.hermes.research-board/board'
    $bridge.Record.Ready=$true;$bridge.Record.BoardURL=$url
    Write-HermesAdminJSON (Join-Path $bridge.Directory 'state.json') $bridge.Record
    $state|Add-Member -NotePropertyName ResearchPluginsSHA256 -NotePropertyValue @($pin.packages.sha256) -Force
    Write-HermesAdminJSON (Join-Path $state.Directory 'deployment.json') $state
    [IO.File]::WriteAllText((Join-Path $team.WizardOptions.WorkspacePath 'Mattermost Research Board.url'),("[InternetShortcut]`nURL="+$url+"`n"),(New-Object Text.UTF8Encoding($false)))
    $result=[pscustomobject]@{Ready=$true;BoardURL=$url;Plugins=@($pin.packages.id);UploadsLocked=$locked;ResearchChanged=$false;ScenariosRerun=$false}
    if($ProgressCallback){[void](& $ProgressCallback ([pscustomobject]@{type='stage';stage='research-plugins';state='succeeded';percent=78;message='Mattermost 한국어 작업보드·NST 브랜딩 적용과 업로드 잠금을 확인했습니다.'}))}
    return $result
}
