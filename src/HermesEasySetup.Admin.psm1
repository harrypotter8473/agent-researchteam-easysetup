Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:AdminOwnerLabel = 'com.infonet.easy-setup.deployment'
$script:AdminDockerHost = 'npipe:////./pipe/dockerDesktopLinuxEngine'

function Assert-HermesAdminPath {
    param([string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\') -or $Path -match '[\x00-\x1f]') { throw '관리자 설치 경로는 로컬 절대 경로여야 합니다.' }
    $current = [IO.Path]::GetFullPath($Path)
    if ($current.TrimEnd('\') -eq [IO.Path]::GetPathRoot($current).TrimEnd('\')) { throw '드라이브 루트는 설치 폴더로 사용할 수 없습니다.' }
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '설치 경로의 링크·junction은 지원하지 않습니다.' }
        }
        $current = Split-Path -Parent $current
    }
}

function Get-HermesAdminRoot {
    return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'HermesEasySetup\servers')
}

function Get-HermesAdminPin {
    $pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config\mattermost-server.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($pin.schema -ne 1 -or $pin.platform -cne 'linux/amd64' -or
        $pin.mattermostImage -cnotmatch '^mattermost/mattermost-enterprise-edition@sha256:[a-f0-9]{64}$' -or
        $pin.postgresImage -cnotmatch '^postgres@sha256:[a-f0-9]{64}$') { throw 'Mattermost 서버 공식 이미지 pin이 올바르지 않습니다.' }
    return $pin
}

function Assert-HermesAdminInput {
    param($InputData)
    foreach ($key in @('ServerId','SiteName','TeamName','TeamDisplayName','ChannelName','AdminUsername','AdminEmail','AdminPassword','Port')) {
        if (-not $InputData.PSObject.Properties[$key]) { throw "필수 입력이 없습니다: $key" }
    }
    foreach ($key in @('ServerId','TeamName','ChannelName')) {
        if ([string]$InputData.$key -cnotmatch '^[a-z][a-z0-9-]{1,30}[a-z0-9]$') { throw "$key 값은 영문 소문자로 시작하는 3~32자의 소문자·숫자·하이픈이어야 합니다." }
    }
    if ([string]$InputData.AdminUsername -cnotmatch '^[a-z][a-z0-9._-]{2,21}$') { throw '관리자 사용자 이름은 영문 소문자로 시작하는 3~22자여야 합니다.' }
    foreach ($key in @('SiteName','TeamDisplayName')) {
        if ([string]::IsNullOrWhiteSpace([string]$InputData.$key) -or ([string]$InputData.$key).Length -gt 64 -or [string]$InputData.$key -match '[\x00-\x1f]') { throw "$key 값은 줄바꿈 없이 1~64자로 입력하세요." }
    }
    try { $mail = New-Object Net.Mail.MailAddress([string]$InputData.AdminEmail) } catch { throw '관리자 이메일 주소를 확인하세요.' }
    if ($mail.Address -cne [string]$InputData.AdminEmail -or $mail.Address.Length -gt 128) { throw '관리자 이메일에는 주소만 입력하세요.' }
    $password = [string]$InputData.AdminPassword
    if ($password.Length -lt 12 -or $password.Length -gt 128 -or $password -match '[\x00-\x1f]' -or
        $password -cnotmatch '[A-Z]' -or $password -cnotmatch '[a-z]' -or $password -notmatch '[0-9]' -or $password -notmatch '[^A-Za-z0-9]') {
        throw '관리자 비밀번호는 12~128자이며 영문 대문자·소문자·숫자·특수문자를 모두 포함해야 합니다.'
    }
    $portNumber = 0
    if (-not [int]::TryParse([string]$InputData.Port, [ref]$portNumber) -or $portNumber -lt 1024 -or $portNumber -gt 65535 -or $portNumber -eq 8065) { throw '테스트 포트는 1024~65535에서 선택하세요. 기존 Mattermost 보호를 위해 8065는 사용하지 않습니다.' }
}

function Get-HermesAdminDocker {
    $installation = Get-HermesDockerDesktopInstallation
    if (-not $installation.Installed) { throw 'Docker Desktop이 없거나 설치 위치를 확인하지 못했습니다. 개인 연구실 마법사의 Docker 준비 확인 또는 공식 설치 안내를 사용하세요.' }
    if (-not $installation.Trusted) { throw 'Docker Desktop 구성 파일의 공식 서명을 확인하지 못했습니다. 복구 안내를 확인하세요. 실행하지 않습니다.' }
    $path = [string]$installation.CLIPath
    Assert-HermesAdminPath $path
    return $path
}

function Invoke-HermesAdminDocker {
    param([string[]]$Arguments, [string]$Directory, [hashtable]$Environment = @{}, [int]$TimeoutSeconds = 120, [switch]$AllowFailure)
    $environmentValues = @{
        DOCKER_HOST = $null; DOCKER_CONTEXT = $null; DOCKER_TLS_VERIFY = $null; DOCKER_CERT_PATH = $null
        COMPOSE_FILE = $null; COMPOSE_PROJECT_NAME = $null; COMPOSE_PROFILES = $null; COMPOSE_ENV_FILES = $null
    }
    foreach ($key in $Environment.Keys) { $environmentValues[$key] = $Environment[$key] }
    $executable = Get-HermesAdminDocker
    $environmentValues['PATH'] = (Split-Path -Parent $executable) + ';' + [Environment]::GetEnvironmentVariable('PATH','Process')
    $commandArguments = @('--host',$script:AdminDockerHost) + $Arguments
    if ($Arguments[0] -ceq 'compose') {
        # Desktop can have Compose installed without registering its CLI plugin search path.
        $installation = Get-HermesDockerDesktopInstallation
        if (-not $installation.Installed -or -not $installation.Trusted) { throw 'Docker Desktop 구성을 다시 확인하지 못했습니다.' }
        $executable = [string]$installation.ComposePath
        Assert-HermesAdminPath $executable
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Docker Desktop의 Compose 구성 요소가 없습니다. Docker Desktop 설치를 복구하세요.' }
        $commandArguments = @($Arguments | Select-Object -Skip 1)
        $environmentValues['DOCKER_HOST'] = $script:AdminDockerHost
    }
    $result = Invoke-HermesProcess -FilePath $executable -ArgumentList $commandArguments -WorkingDirectory $Directory -Environment $environmentValues -TimeoutSeconds $TimeoutSeconds
    if ((-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) -and -not $AllowFailure) {
        # Do not surface docker inspect/config output: it can contain database credentials.
        throw "Docker 작업을 완료하지 못했습니다 ($($Arguments[0]), 종료 코드 $($result.ExitCode)). Docker Desktop 상태·디스크·네트워크를 확인한 뒤 같은 입력으로 재시도하세요."
    }
    return $result
}

function Get-HermesAdminPreflight {
    $docker = Invoke-HermesAdminDocker -Arguments @('info','--format','{{json .}}') -TimeoutSeconds 20 -AllowFailure
    if (-not $docker.Started -or $docker.ExitCode -ne 0) { throw 'Docker Desktop이 준비되지 않았습니다. Docker Desktop을 열고 Linux 엔진이 실행된 뒤 다시 확인하세요.' }
    $info = $docker.StdOut | ConvertFrom-Json
    if ($info.OSType -cne 'linux' -or $info.Architecture -notin @('x86_64','amd64')) { throw '이번 테스트 버전은 Docker Desktop Linux/AMD64 엔진만 지원합니다.' }
    $compose = Invoke-HermesAdminDocker -Arguments @('compose','version','--short') -TimeoutSeconds 20
    return [pscustomobject]@{ Ready = $true; Engine = 'Docker Desktop (local Linux/AMD64)'; ComposeVersion = $compose.StdOut.Trim(); RuntimeRoot = Get-HermesAdminRoot; Scope = 'localhost test only' }
}

function Get-HermesAdminIdentity {
    param($InputData)
    return [ordered]@{ ServerId = [string]$InputData.ServerId; SiteName = [string]$InputData.SiteName; TeamName = [string]$InputData.TeamName; TeamDisplayName = [string]$InputData.TeamDisplayName; ChannelName = [string]$InputData.ChannelName; AdminUsername = [string]$InputData.AdminUsername; AdminEmail = [string]$InputData.AdminEmail; Port = [int]$InputData.Port }
}

function Write-HermesAdminJSON {
    param([string]$Path, $Value)
    Assert-HermesAdminPath $Path
    $temp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding $false))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force } }
}

function New-HermesAdminCompose {
    param($State)
    $pluginMode = Get-HermesAdminPluginMode $State
    $owner = [ordered]@{ $script:AdminOwnerLabel = $State.DeploymentId }
    $appVolumes = @('config','data','logs','plugins','client_plugins','bleve')
    $volumes = [ordered]@{ database = [ordered]@{ name = "$($State.Project)_database"; labels = $owner } }
    foreach ($volume in $appVolumes) { $volumes[$volume] = [ordered]@{ name = "$($State.Project)_$volume"; labels = $owner } }
    $compose = [ordered]@{
        services = [ordered]@{
            database = [ordered]@{
                image = $State.Pin.postgresImage; platform = 'linux/amd64'; restart = 'unless-stopped'; labels = $owner
                environment = [ordered]@{ POSTGRES_USER = 'mattermost'; POSTGRES_DB = 'mattermost'; POSTGRES_PASSWORD = '${HES_DATABASE_PASSWORD:?database credential required}' }
                volumes = @('database:/var/lib/postgresql/data')
                healthcheck = [ordered]@{ test = @('CMD-SHELL','pg_isready -U mattermost -d mattermost'); interval = '5s'; timeout = '5s'; retries = 30 }
            }
            mattermost = [ordered]@{
                image = $State.Pin.mattermostImage; platform = 'linux/amd64'; restart = 'unless-stopped'; labels = $owner
                depends_on = [ordered]@{ database = [ordered]@{ condition = 'service_healthy' } }
                ports = @("127.0.0.1:$($State.Identity.Port):8065")
                environment = [ordered]@{
                    MM_SQLSETTINGS_DRIVERNAME = 'postgres'
                    MM_SQLSETTINGS_DATASOURCE = 'postgres://mattermost:${HES_DATABASE_PASSWORD:?database credential required}@database:5432/mattermost?sslmode=disable&connect_timeout=10'
                    MM_SERVICESETTINGS_SITEURL = "http://127.0.0.1:$($State.Identity.Port)"
                    MM_SERVICESETTINGS_LISTENADDRESS = ':8065'
                    MM_TEAMSETTINGS_SITENAME = $State.Identity.SiteName
                    MM_TEAMSETTINGS_ENABLEOPENSERVER = 'false'
                    MM_TEAMSETTINGS_ENABLEUSERCREATION = 'true'
                    MM_EMAILSETTINGS_ENABLESIGNUPWITHEMAIL = 'true'
                    MM_EMAILSETTINGS_ENABLESIGNINWITHEMAIL = 'true'
                    MM_EMAILSETTINGS_ENABLESIGNINWITHUSERNAME = 'true'
                    MM_EMAILSETTINGS_REQUIREEMAILVERIFICATION = 'false'
                    MM_EMAILSETTINGS_SENDEMAILNOTIFICATIONS = 'false'
                    MM_PLUGINSETTINGS_ENABLE = 'false'
                    MM_PLUGINSETTINGS_ENABLEUPLOADS = 'false'
                    MM_PLUGINSETTINGS_AUTOMATICPREPACKAGEDPLUGINS = 'false'
                    MM_PASSWORDSETTINGS_MINIMUMLENGTH = '12'
                    MM_PASSWORDSETTINGS_LOWERCASE = 'true'; MM_PASSWORDSETTINGS_UPPERCASE = 'true'
                    MM_PASSWORDSETTINGS_NUMBER = 'true'; MM_PASSWORDSETTINGS_SYMBOL = 'true'
                }
                volumes = @('config:/mattermost/config','data:/mattermost/data','logs:/mattermost/logs','plugins:/mattermost/plugins','client_plugins:/mattermost/client/plugins','bleve:/mattermost/bleve-indexes')
            }
        }
        volumes = $volumes
        networks = [ordered]@{ default = [ordered]@{ name = "$($State.Project)_network"; labels = $owner } }
    }
    if ($pluginMode -ne 'disabled') {
        $compose.services.mattermost.environment.MM_PLUGINSETTINGS_ENABLE = 'true'
        $compose.services.mattermost.environment.MM_PLUGINSETTINGS_ENABLEUPLOADS = $(if ($pluginMode -eq 'upload') { 'true' } else { 'false' })
        $compose.services.mattermost.environment['MM_PLUGINSETTINGS_REQUIREPLUGINSIGNATURE'] = 'false'
    }
    $sharedAddress = Get-HermesAdminNetworkAddress $State
    if ($sharedAddress) {
        $compose.services.mattermost.ports += "${sharedAddress}:$($State.Identity.Port):8065"
        $compose.services.mattermost.environment.MM_SERVICESETTINGS_SITEURL = Get-HermesAdminServerURL $State
    }
    return $compose
}

function Get-HermesAdminPluginMode {
    param($State)
    $mode = $(if ($State.PSObject.Properties['PluginMode']) { [string]$State.PluginMode } else { 'disabled' })
    if ($mode -cnotin @('disabled','enabled','upload')) { throw '플러그인 설치 상태가 올바르지 않습니다.' }
    return $mode
}

function New-HermesAdminState {
    param($InputData, [string]$DeploymentRoot, [switch]$Resume)
    Assert-HermesAdminInput $InputData
    Assert-HermesAdminPath $DeploymentRoot
    $directory = [IO.Path]::GetFullPath((Join-Path $DeploymentRoot $InputData.ServerId))
    Assert-HermesAdminPath $directory
    $statePath = Join-Path $directory 'deployment.json'
    Assert-HermesAdminPath $statePath
    Assert-HermesAdminPath (Join-Path $directory 'database.bin')
    $identity = Get-HermesAdminIdentity $InputData
    if (Test-Path -LiteralPath $statePath) {
        if (-not $Resume) { throw '같은 이름의 테스트 서버 기록이 있습니다. 기존 입력을 유지하고 이어서 설정을 선택하세요.' }
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.Schema -ne 1 -or $state.Owner -cne 'HermesEasySetup.Admin' -or $state.DeploymentId -cnotmatch '^[a-f0-9]{32}$' -or
            $state.Project -cne "hes-$($InputData.ServerId)-$($state.DeploymentId.Substring(0,8))" -or
            -not [string]::Equals([string]$state.Directory,$directory,[StringComparison]::OrdinalIgnoreCase)) { throw '이 마법사의 동일 테스트 서버 기록이 아닙니다. 변경하지 않습니다.' }
        foreach ($key in $identity.Keys) { if ([string]$state.Identity.$key -cne [string]$identity[$key]) { throw "기존 서버의 $key 값과 다릅니다. 기존 입력을 사용하거나 다른 서버 ID를 선택하세요." } }
        $pin = Get-HermesAdminPin
        if ($state.Pin.mattermostImage -cne $pin.mattermostImage -or $state.Pin.postgresImage -cne $pin.postgresImage) { throw '기존 서버 이미지와 현재 pin이 다릅니다. 자동 업그레이드는 하지 않습니다.' }
        if (-not (Test-Path -LiteralPath (Join-Path $directory 'database.bin'))) { throw '기존 데이터베이스 인증 파일이 없습니다. 새 암호로 덮어쓰지 않습니다.' }
        return $state
    }
    if (Test-Path -LiteralPath $directory) {
        if (@(Get-ChildItem -LiteralPath $directory -Force).Count -gt 0) { throw '설치 폴더가 비어 있지 않습니다. 기존 파일을 변경하지 않습니다.' }
    } else { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    # Keep deployment metadata and DPAPI payload accessible only to this Windows user and SYSTEM.
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($principal in @($sid,(New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($principal,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $directory -AclObject $acl
    $deploymentId = [Guid]::NewGuid().ToString('N')
    $state = [pscustomobject][ordered]@{ Schema = 1; Owner = 'HermesEasySetup.Admin'; DeploymentId = $deploymentId; Project = "hes-$($InputData.ServerId)-$($deploymentId.Substring(0,8))"; Directory = $directory; Identity = $identity; Pin = Get-HermesAdminPin; Status = 'Prepared'; Stage = 'prepare'; AdminUserId = ''; TeamId = ''; ChannelId = '' }
    $random = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($random) } finally { $rng.Dispose() }
    $dbPassword = ([BitConverter]::ToString($random)).Replace('-','').ToLowerInvariant()
    Protect-HermesLabInput -Value ([pscustomobject]@{ Password = $dbPassword }) -LiteralPath (Join-Path $directory 'database.bin') | Out-Null
    Write-HermesAdminJSON -Path $statePath -Value $state
    return $state
}

function Assert-HermesAdminResources {
    param($State)
    $containers = Invoke-HermesAdminDocker -Arguments @('ps','-a','--filter',"label=com.docker.compose.project=$($State.Project)",'--format','{{.ID}}')
    foreach ($id in @($containers.StdOut -split '\r?\n' | Where-Object { $_ })) {
        $inspect = Invoke-HermesAdminDocker -Arguments @('inspect',$id)
        $item = @($inspect.StdOut | ConvertFrom-Json)[0]
        if (-not $item.Config.Labels.PSObject.Properties[$script:AdminOwnerLabel] -or $item.Config.Labels.PSObject.Properties[$script:AdminOwnerLabel].Value -cne $State.DeploymentId) { throw '동일 프로젝트 이름의 다른 컨테이너가 있습니다. 변경하지 않습니다.' }
    }
    foreach ($kind in @('volume','network')) {
        $names = $(if ($kind -eq 'volume') { @('database','config','data','logs','plugins','client_plugins','bleve') } else { @('network') })
        foreach ($suffix in $names) {
            $result = Invoke-HermesAdminDocker -Arguments @($kind,'inspect',"$($State.Project)_$suffix") -AllowFailure
            if ($result.ExitCode -eq 0) {
                $item = @($result.StdOut | ConvertFrom-Json)[0]
                if ($null -eq $item.Labels -or -not $item.Labels.PSObject.Properties[$script:AdminOwnerLabel] -or $item.Labels.PSObject.Properties[$script:AdminOwnerLabel].Value -cne $State.DeploymentId) { throw '다른 배포의 Docker 데이터 또는 네트워크입니다. 재사용하지 않습니다.' }
            } elseif ($result.StdErr -notmatch '(?i)no such (volume|network)' -and $result.StdErr -notmatch ('(?i)network ' + [regex]::Escape("$($State.Project)_$suffix") + ' not found')) { throw 'Docker 데이터 소유권 확인에 실패했습니다. 변경하지 않습니다.' }
        }
    }
}

function Invoke-HermesAdminCompose {
    param($State, [string[]]$Arguments, [int]$TimeoutSeconds = 600)
    $secret = Unprotect-HermesLabInput -LiteralPath (Join-Path $State.Directory 'database.bin')
    if ($secret.Password -cnotmatch '^[a-f0-9]{64}$') { throw '데이터베이스 인증 파일이 올바르지 않습니다.' }
    return Invoke-HermesAdminDocker -Arguments (@('compose','--project-name',$State.Project,'--project-directory',$State.Directory,'--env-file',(Join-Path $State.Directory 'compose.env'),'--file',(Join-Path $State.Directory 'compose.json')) + $Arguments) -Directory $State.Directory -Environment @{ HES_DATABASE_PASSWORD = [string]$secret.Password } -TimeoutSeconds $TimeoutSeconds
}

function Invoke-HermesAdminAPI {
    param([string]$BaseURL, [string]$Path, [string]$Method = 'GET', $Body = $null, [AllowNull()][string]$Token)
    if ($BaseURL -cnotmatch '^http://127\.0\.0\.1:[0-9]{4,5}$' -or -not $Path.StartsWith('/api/v4/')) { throw '관리자 초기화 API는 이 PC의 테스트 서버에만 연결할 수 있습니다.' }
    $request = @{ Uri = $BaseURL + $Path; Method = $Method; UseBasicParsing = $true; TimeoutSec = 20; MaximumRedirection = 0; ErrorAction = 'Stop' }
    $request.Headers = @{ 'X-Requested-With' = 'XMLHttpRequest' }
    if ($Token) { $request.Headers.Authorization = "Bearer $Token" }
    if ($null -ne $Body) { $request.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress)); $request.ContentType = 'application/json; charset=utf-8' }
    try {
        $response = Invoke-WebRequest @request
        # Mattermost JSON is UTF-8; Windows PowerShell 5.1 may decode Content
        # incorrectly when the server omits a charset parameter.
        $jsonContent = [string]$response.Content
        if ($response.PSObject.Properties['RawContentStream'] -and $response.RawContentStream -is [IO.MemoryStream]) {
            $jsonContent = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
        }
        $data = $(if ($jsonContent) { $jsonContent | ConvertFrom-Json } else { $null })
        return [pscustomobject]@{ Data = $data; Token = [string]$response.Headers['Token'] }
    } catch {
        $code = 0
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        $error = New-Object Exception("Mattermost API 요청 실패 (HTTP $code). 서버 준비 상태와 입력값을 확인하세요.")
        $error.Data['HttpStatus'] = $code
        throw $error
    }
}

function Wait-HermesAdminServer {
    param([string]$BaseURL, [int]$TimeoutSeconds = 300)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try { $result = Invoke-HermesAdminAPI -BaseURL $BaseURL -Path '/api/v4/system/ping'; if ($result.Data.status -ceq 'OK') { return } } catch { }
        Start-Sleep -Seconds 3
    }
    throw 'Mattermost 서버 준비 제한 시간을 초과했습니다. 데이터는 보존되어 있습니다. Docker 상태를 확인한 뒤 이어서 설정하세요.'
}

function Assert-HermesAdminPort {
    param($State,[switch]$Exact)
    # A running container is reusable only if its deployment label AND published port match.
    $result = Invoke-HermesAdminDocker -Arguments @('ps','--filter',"label=com.docker.compose.project=$($State.Project)",'--filter','label=com.docker.compose.service=mattermost','--format','{{.ID}}')
    $ids = @($result.StdOut -split '\r?\n' | Where-Object { $_ })
    if ($ids.Count -gt 1) { throw '같은 배포에 Mattermost 컨테이너가 여러 개 있습니다.' }
    if ($ids.Count -eq 1) {
        $inspect = Invoke-HermesAdminDocker -Arguments @('inspect',$ids[0])
        $item = @($inspect.StdOut | ConvertFrom-Json)[0]
        $ports = @($item.HostConfig.PortBindings.'8065/tcp')
        Assert-HermesAdminPublishedPorts $State $ports -AllowTransition:(-not $Exact)
        return
    }
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,[int]$State.Identity.Port)
    try { $listener.Server.ExclusiveAddressUse = $true; $listener.Start() }
    catch { throw '선택한 테스트 포트가 이미 사용 중입니다. 기존 서버를 종료하지 말고 다른 서버 ID와 포트로 설정하세요.' }
    finally { $listener.Stop() }
}

function Set-HermesAdminComposeFiles {
    param($State)
    $expected = New-HermesAdminCompose $State | ConvertTo-Json -Depth 32
    $path = Join-Path $State.Directory 'compose.json'
    Assert-HermesAdminPath $path
    Set-HermesAdminNetworkCompose $State $path
    if ($State.PSObject.Properties['PluginTransition'] -and $null -ne $State.PluginTransition) {
        # Recover an interrupted *known* transition, never arbitrary edited compose contents.
        $previous = $State | ConvertTo-Json -Depth 32 | ConvertFrom-Json
        $previous.PluginMode = [string]$State.PluginTransition
        $oldExpected = New-HermesAdminCompose $previous | ConvertTo-Json -Depth 32
        if (-not (Test-Path -LiteralPath $path)) { throw '플러그인 전환 중 compose 파일이 사라졌습니다.' }
        $actual = [IO.File]::ReadAllText($path)
        if ($actual -cne $oldExpected -and $actual -cne $expected) { throw '플러그인 전환 기록과 다른 compose 파일입니다. 덮어쓰지 않습니다.' }
        Write-HermesAdminJSON $path (New-HermesAdminCompose $State)
        $State.PluginTransition = $null
        Write-HermesAdminJSON (Join-Path $State.Directory 'deployment.json') $State
    }
    if (Test-Path -LiteralPath $path) {
        if ([IO.File]::ReadAllText($path) -cne $expected) { throw '기존 compose.json이 변경되어 있습니다. 자동으로 덮어쓰거나 실행하지 않습니다.' }
    } else { [IO.File]::WriteAllText($path,$expected,(New-Object Text.UTF8Encoding $false)) }
    $envPath = Join-Path $State.Directory 'compose.env'
    Assert-HermesAdminPath $envPath
    if ((Test-Path -LiteralPath $envPath) -and [IO.File]::ReadAllText($envPath).Length -ne 0) { throw 'compose.env는 비어 있어야 합니다. 외부 설정을 가져오지 않습니다.' }
    if (-not (Test-Path -LiteralPath $envPath)) { [IO.File]::WriteAllText($envPath,'') }
}

function Set-HermesAdminPluginMode {
    param($State,[ValidateSet('disabled','enabled','upload')][string]$Mode)
    Set-HermesAdminComposeFiles $State
    $previous = Get-HermesAdminPluginMode $State
    if ($previous -ceq $Mode) { return }
    $State | Add-Member -NotePropertyName PluginMode -NotePropertyValue $Mode -Force
    $State | Add-Member -NotePropertyName PluginTransition -NotePropertyValue $previous -Force
    Write-HermesAdminJSON (Join-Path $State.Directory 'deployment.json') $State
    Set-HermesAdminComposeFiles $State
}

function Initialize-HermesAdminAccount {
    param($State,$InputData,[string]$BaseURL)
    $token = $null
    $credentials = @{ login_id = [string]$InputData.AdminUsername; password = [string]$InputData.AdminPassword }
    try {
        try { $login = Invoke-HermesAdminAPI $BaseURL '/api/v4/users/login' 'POST' $credentials }
        catch {
            if ($_.Exception.Data['HttpStatus'] -ne 401 -or $State.AdminUserId) { throw }
            # Mattermost grants system_admin to its first human account. Never elevate an existing account.
            $null = Invoke-HermesAdminAPI $BaseURL '/api/v4/users' 'POST' @{ username = [string]$InputData.AdminUsername; email = [string]$InputData.AdminEmail; password = [string]$InputData.AdminPassword }
            $login = Invoke-HermesAdminAPI $BaseURL '/api/v4/users/login' 'POST' $credentials
        }
        $token = $login.Token
        if (-not $token) { throw '관리자 로그인 세션을 확인하지 못했습니다.' }
        $user = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path '/api/v4/users/me' -Token $token).Data
        if (@($user.roles -split ' ') -notcontains 'system_admin' -or $user.delete_at -ne 0 -or
            $user.username -cne $InputData.AdminUsername -or $user.email -cne $InputData.AdminEmail -or
            ($State.AdminUserId -and $State.AdminUserId -cne $user.id)) { throw '입력한 계정이 이 배포의 활성 시스템 관리자가 아닙니다. 권한을 임의로 변경하지 않습니다.' }
        $State.AdminUserId = $user.id
        Restore-HermesAdminBotCreation -State $State -BaseURL $BaseURL -Token $token
        Write-HermesAdminJSON (Join-Path $State.Directory 'deployment.json') $State
        $teamPath = '/api/v4/teams/name/' + $State.Identity.TeamName
        try { $team = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path $teamPath -Token $token).Data }
        catch {
            if ($_.Exception.Data['HttpStatus'] -ne 404) { throw }
            $team = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path '/api/v4/teams' -Method POST -Token $token -Body @{ name = $State.Identity.TeamName; display_name = $State.Identity.TeamDisplayName; type = 'I'; allow_open_invite = $false }).Data
        }
        if ($State.TeamId -and $State.TeamId -cne $team.id) { throw '팀 ID가 기존 기록과 다릅니다.' }
        $membershipPath = "/api/v4/teams/$($team.id)/members/$($user.id)"
        try { $null = Invoke-HermesAdminAPI -BaseURL $BaseURL -Path $membershipPath -Token $token }
        catch {
            if ($_.Exception.Data['HttpStatus'] -ne 404) { throw }
            $null = Invoke-HermesAdminAPI -BaseURL $BaseURL -Path "/api/v4/teams/$($team.id)/members" -Method POST -Token $token -Body @{ team_id = $team.id; user_id = $user.id }
        }
        $channelPath = "/api/v4/teams/$($team.id)/channels/name/$($State.Identity.ChannelName)"
        try { $channel = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path $channelPath -Token $token).Data }
        catch {
            if ($_.Exception.Data['HttpStatus'] -ne 404) { throw }
            $channel = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path '/api/v4/channels' -Method POST -Token $token -Body @{ team_id = $team.id; name = $State.Identity.ChannelName; display_name = $State.Identity.ChannelName; type = 'O' }).Data
        }
        if ($State.ChannelId -and $State.ChannelId -cne $channel.id) { throw '채널 ID가 기존 기록과 다릅니다.' }
        $config = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path '/api/v4/config' -Token $token).Data
        $expectPlugins = (Get-HermesAdminPluginMode $State) -ne 'disabled'
        if ($config.TeamSettings.EnableOpenServer -or [bool]$config.PluginSettings.Enable -ne $expectPlugins) { throw '서버 가입·플러그인 정책이 설치 기록과 다릅니다.' }
        $State.TeamId = $team.id
        $State.ChannelId = $channel.id
    } finally {
        if ($token) { try { $null = Invoke-HermesAdminAPI -BaseURL $BaseURL -Path '/api/v4/users/logout' -Method POST -Token $token } catch { } }
        $token = $null
        $credentials = $null
    }
}

function Invoke-HermesAdminSetup {
    [CmdletBinding()]
    param($InputData,[string]$DeploymentRoot = (Get-HermesAdminRoot),[switch]$Resume,[scriptblock]$ProgressCallback)
    Assert-HermesAdminInput $InputData
    Assert-HermesAdminNetworkInput $InputData
    $state = $null
    $owned = $false
    $mutex = New-Object Threading.Mutex($false,('Local\HermesAdminSetup-' + $InputData.ServerId))
    function Report { param($Stage,$Percent,$Message) if ($ProgressCallback) { & $ProgressCallback ([pscustomobject]@{ type = 'stage'; state = 'running'; stage = $Stage; percent = $Percent; message = $Message }) } }
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw '동일 테스트 서버의 설치가 이미 진행 중입니다.' }
        Report 'preflight' 5 '로컬 Docker Desktop과 별도 설치 경로를 확인합니다.'
        $null = Get-HermesAdminPreflight
        $state = New-HermesAdminState -InputData $InputData -DeploymentRoot $DeploymentRoot -Resume:$Resume
        Assert-HermesAdminResources $state
        if (Test-HermesAdminNetworkTransition $state) {
            # An interrupted switch is restored to its previous approved scope before retrying it.
            $state.NetworkAddress = [string]$state.NetworkTransition.Previous
            Write-HermesAdminJSON (Join-Path $state.Directory 'deployment.json') $state
        }
        Assert-HermesAdminPort $state
        Set-HermesAdminComposeFiles $state
        if ((Get-HermesAdminPluginMode $state) -eq 'upload') { Set-HermesAdminPluginMode $state 'enabled' }
        $state.Status = 'Installing'; $state.Stage = 'images'
        Write-HermesAdminJSON (Join-Path $state.Directory 'deployment.json') $state
        Report 'images' 20 '고정된 공식 Mattermost·PostgreSQL 이미지를 준비합니다. 첫 다운로드는 몇 분 걸릴 수 있습니다.'
        $null = Invoke-HermesAdminCompose $state @('pull') -TimeoutSeconds 1200
        $state.Stage = 'server'
        Report 'server' 55 '별도 컨테이너와 영구 저장소를 만들고 서버 응답을 기다립니다.'
        $null = Invoke-HermesAdminCompose $state @('up','-d')
        $baseURL = "http://127.0.0.1:$($state.Identity.Port)"
        Wait-HermesAdminServer $baseURL
        $state.Stage = 'account'
        Report 'account' 80 '최초 관리자 계정·팀·채널을 준비하고 실제 시스템 관리자 권한을 검증합니다.'
        Initialize-HermesAdminAccount -State $state -InputData $InputData -BaseURL $baseURL
        if (Test-HermesAdminNetworkTransition $state) {
            Assert-HermesAdminPort $state -Exact
            $state.NetworkTransition = $null
            Write-HermesAdminJSON (Join-Path $state.Directory 'deployment.json') $state
        }
        Report 'network' 95 '선택한 서버 공개 범위와 NetBird 공유 주소를 확인합니다.'
        Set-HermesAdminNetwork $state $InputData $baseURL
        $state.Status = 'Ready'; $state.Stage = 'complete'
        Write-HermesAdminJSON (Join-Path $state.Directory 'deployment.json') $state
        $result = [pscustomobject]@{ Ready = $true; ServerURL = $baseURL; AdminURL = "$baseURL/admin_console"; ChannelURL = "$baseURL/$($state.Identity.TeamName)/channels/$($state.Identity.ChannelName)"; AdminUsername = $state.Identity.AdminUsername; AdminRoleVerified = $true; Directory = $state.Directory; Project = $state.Project; MattermostVersion = $state.Pin.mattermostVersion; Scope = 'localhost test only'; RestartPolicy = 'unless-stopped (Docker Desktop must be running)' }
        $result.ServerURL = Get-HermesAdminServerURL $state
        $result.ChannelURL = "$($result.ServerURL)/$($state.Identity.TeamName)/channels/$($state.Identity.ChannelName)"
        $result.Scope = $(if (Get-HermesAdminNetworkAddress $state) { 'NetBird IP + localhost; peer access not yet verified' } else { 'localhost test only' })
        $result | Add-Member PeerAccessVerified $false
        if ($ProgressCallback) { & $ProgressCallback ([pscustomobject]@{ type = 'complete'; percent = 100; message = '로컬 테스트 서버와 관리자 계정이 준비되었습니다. 브라우저에서 입력한 계정으로 로그인하세요.'; data = $result }) }
        return $result
    } catch {
        if ($state) { $state.Status = 'Failed'; try { Write-HermesAdminJSON (Join-Path $state.Directory 'deployment.json') $state } catch { } }
        throw
    } finally { if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

. (Join-Path $PSScriptRoot 'HermesEasySetup.AdminBots.ps1')
. (Join-Path $PSScriptRoot 'HermesEasySetup.AdminNetwork.ps1')
. (Join-Path $PSScriptRoot 'HermesEasySetup.ResearchPlugins.ps1')
Export-ModuleMember -Function @('Get-HermesAdminRoot','Get-HermesAdminPin','Assert-HermesAdminInput','Get-HermesAdminPreflight','Invoke-HermesAdminSetup','Assert-HermesAdminBotInput','Invoke-HermesAdminBotSetup','Read-HermesAdminBotCredential','Invoke-HermesResearchPluginsSetup')
