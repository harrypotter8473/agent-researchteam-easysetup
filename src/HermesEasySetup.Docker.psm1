Set-StrictMode -Version 2.0

$script:DockerLinuxHost = 'npipe:////./pipe/dockerDesktopLinuxEngine'
$script:DockerDownloadMaximumBytes = [int64]1610612736
$script:DockerAlternatives = @('WSL2 Ubuntu에 Mattermost와 PostgreSQL을 직접 구성하는 대안은 펌웨어 가상화가 필요하며, 이 마법사의 자동 설치 경로로 구현되어 있지 않습니다.', '별도 Linux PC·VM 또는 기존 Mattermost 서버를 사용하는 대안은 별도 구성이 필요하며 1대 PC 조건이 달라집니다.', '조직에서 Docker 또는 WSL을 제한하는 경우 관리자에게 허용된 구성을 확인하세요. 조직 정책을 우회하지 않습니다.')

function Publish-HermesDockerStage {
    param([AllowNull()][scriptblock]$Callback, [string]$Stage, [string]$Message, [int]$Percent)
    if ($null -ne $Callback) { [void](Publish-HermesEvent -Callback $Callback -Type 'stage' -Stage $Stage -State 'running' -Message $Message -Percent $Percent) }
}

function Get-HermesDockerKnownRoots {
    return @(
        [pscustomobject]@{ Root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\DockerDesktop'; Kind = 'PerUser' }
        [pscustomobject]@{ Root = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Docker\Docker'; Kind = 'AllUsers' }
    )
}

function Test-HermesDockerRegistryEvidence {
    foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        try {
            foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
                $entry = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
                if ($null -ne $entry -and $entry.PSObject.Properties['DisplayName'] -and [string]$entry.DisplayName -match '^Docker Desktop(?:\s|$)') { return $true }
            }
        } catch { }
    }
    foreach ($path in @('HKCU:\Software\Docker Inc.\Docker Desktop', 'HKLM:\Software\Docker Inc.\Docker Desktop')) { if (Test-Path -LiteralPath $path) { return $true } }
    return $false
}

function Test-HermesDockerExecutablePath {
    param([string]$LiteralPath)
    # This is a read/execute check, not a writable destination check. Trusted
    # Microsoft System32 binaries such as wsl.exe must remain readable here.
    try {
        if ([string]::IsNullOrWhiteSpace($LiteralPath) -or -not [IO.Path]::IsPathRooted($LiteralPath) -or
            $LiteralPath -cnotmatch '^[A-Za-z]:[\\/]' -or $LiteralPath -match '[\x00-\x1f*?]' -or $LiteralPath.StartsWith('\\')) { return $false }
        $full = [IO.Path]::GetFullPath($LiteralPath)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
        $probe = $full
        while ($probe) {
            $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            $parent = Split-Path -Parent $probe
            if (-not $parent -or $parent -eq $probe) { break }
            $probe = $parent
        }
        return $true
    } catch { return $false }
}

function Test-HermesDockerPublisher {
    param([string]$LiteralPath, [string]$Publisher = 'Docker Inc')
    try {
        if (-not (Test-HermesDockerExecutablePath -LiteralPath $LiteralPath)) { return $false }
        $signature = Get-HermesAuthenticodeSignature -LiteralPath $LiteralPath
        if ([string]$signature.Status -cne 'Valid' -or $null -eq $signature.SignerCertificate) { return $false }
        $pattern = '(?i)(?:^|,\s*)O=' + [regex]::Escape($Publisher) + '\.?(?:,|$)'
        return ([string]$signature.SignerCertificate.Subject -match $pattern)
    } catch { return $false }
}

function Get-HermesDockerDesktopInstallation {
    [CmdletBinding()]
    param()
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in @(Get-HermesDockerKnownRoots)) {
        $root = [IO.Path]::GetFullPath([string]$candidate.Root)
        $desktop = Join-Path $root 'Docker Desktop.exe'
        $cli = Join-Path $root 'resources\bin\docker.exe'
        $compose = Join-Path $root 'resources\cli-plugins\docker-compose.exe'
        if (-not (Test-Path -LiteralPath $root) -and -not (Test-Path -LiteralPath $desktop)) { continue }
        $complete = (Test-Path -LiteralPath $desktop -PathType Leaf) -and (Test-Path -LiteralPath $cli -PathType Leaf) -and (Test-Path -LiteralPath $compose -PathType Leaf)
        $trusted = $complete -and (Test-HermesDockerPublisher $desktop) -and (Test-HermesDockerPublisher $cli) -and (Test-HermesDockerPublisher $compose)
        $found.Add([pscustomobject][ordered]@{ Installed = $true; Root = $root; DesktopPath = $desktop; CLIPath = $cli; ComposePath = $compose; Kind = $(if ($complete) { [string]$candidate.Kind } else { 'Incomplete' }); Trusted = [bool]$trusted })
    }
    $trustedCandidates = @($found | Where-Object { $_.Trusted })
    if ($trustedCandidates.Count -gt 0) { return $trustedCandidates[0] }
    if ($found.Count -gt 0) { return $found[0] }
    $registryEvidence = Test-HermesDockerRegistryEvidence
    return [pscustomobject][ordered]@{ Installed = [bool]$registryEvidence; Root = $null; DesktopPath = $null; CLIPath = $null; ComposePath = $null; Kind = $(if ($registryEvidence) { 'UnknownLocation' } else { 'Missing' }); Trusted = $false }
}

function Get-HermesDockerHostFacts {
    $facts = [ordered]@{ Windows = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT); Architecture = 'Unknown'; ProductType = $null; Build = $null; MemoryBytes = $null; Virtualization = $null; HypervisorPresent = $null }
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop; $facts.Build = [int]$os.BuildNumber; $facts.ProductType = [int]$os.ProductType } catch { }
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop; $facts.MemoryBytes = [int64]$cs.TotalPhysicalMemory; $facts.HypervisorPresent = $cs.HypervisorPresent } catch { }
    try {
        $cpu = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)[0]
        $facts.Architecture = $(switch ([int]$cpu.Architecture) { 9 { 'x64' } 12 { 'ARM64' } 0 { 'x86' } default { 'Unknown' } })
        $facts.Virtualization = $cpu.VirtualizationFirmwareEnabled
    } catch { }
    return [pscustomobject]$facts
}

function Get-HermesDockerWSLVersion {
    $windowsDirectory = [Environment]::GetFolderPath('Windows')
    $wsl = Join-Path $windowsDirectory 'System32\wsl.exe'
    if (-not (Test-Path -LiteralPath $wsl -PathType Leaf)) { return [pscustomobject]@{ State = 'Fail'; Version = $null; Summary = 'WSL이 설치되어 있지 않습니다.' } }
    if (-not (Test-HermesDockerPublisher -LiteralPath $wsl -Publisher 'Microsoft Corporation')) { return [pscustomobject]@{ State = 'Unknown'; Version = $null; Summary = 'WSL 실행 파일의 신뢰를 확인하지 못했습니다.' } }
    try {
        $result = Invoke-HermesProcess -FilePath $wsl -ArgumentList @('--version') -TimeoutSeconds 15 -Environment @{ WSL_UTF8 = '1' }
        if (-not $result.Started -or $result.TimedOut) { throw 'WSLProbeUnavailable' }
        if ($result.ExitCode -ne 0) { return [pscustomobject]@{ State = 'Fail'; Version = $null; Summary = 'WSL 2.1.5 이상으로 설치 또는 업데이트가 필요합니다.' } }
        $text = [string]$result.StdOut
        if ($text -match '(?im)^\s*WSL(?:\s+(?:version|버전))?\s*:\s*(\d+\.\d+\.\d+(?:\.\d+)?)\s*$') {
            $version = [version]$matches[1]
            return [pscustomobject]@{ State = $(if ($version -ge [version]'2.1.5') { 'Pass' } else { 'Fail' }); Version = $version.ToString(); Summary = $(if ($version -ge [version]'2.1.5') { 'WSL 버전 요구 충족' } else { 'WSL 2.1.5 이상으로 업데이트가 필요합니다.' }) }
        }
    } catch { }
    return [pscustomobject]@{ State = 'Unknown'; Version = $null; Summary = 'WSL 버전을 확인하지 못했습니다. 직접 확인이 필요합니다.' }
}

function Get-HermesDockerPrerequisites {
    [CmdletBinding()]
    param()
    $facts = Get-HermesDockerHostFacts
    $checks = New-Object System.Collections.Generic.List[object]
    $checks.Add([pscustomobject]@{ Name = 'Windows'; State = $(if ($facts.Windows) { 'Pass' } else { 'Fail' }); Summary = 'Windows Desktop용 설치입니다.' })
    $checks.Add([pscustomobject]@{ Name = 'Architecture'; State = $(if ($facts.Architecture -ceq 'x64') { 'Pass' } elseif ($facts.Architecture -ceq 'Unknown') { 'Unknown' } else { 'Fail' }); Summary = 'x64 CPU가 필요합니다.' })
    $buildOK = $null
    if ($null -ne $facts.Build) { $buildOK = (($facts.Build -ge 19045 -and $facts.Build -lt 22000) -or $facts.Build -ge 22631) }
    $checks.Add([pscustomobject]@{ Name = 'WindowsBuild'; State = $(if ($null -eq $buildOK) { 'Unknown' } elseif ($buildOK) { 'Pass' } else { 'Fail' }); Summary = 'Windows 10 build 19045 또는 Windows 11 build 22631 이상이 필요합니다.' })
    $checks.Add([pscustomobject]@{ Name = 'WindowsEdition'; State = $(if ($null -eq $facts.ProductType) { 'Unknown' } elseif ($facts.ProductType -eq 1) { 'Pass' } else { 'Fail' }); Summary = 'Windows Server는 이 설치 경로에서 지원하지 않습니다.' })
    $checks.Add([pscustomobject]@{ Name = 'RAM'; State = $(if ($null -eq $facts.MemoryBytes) { 'Unknown' } elseif ($facts.MemoryBytes -ge [int64]8GB) { 'Pass' } else { 'Fail' }); Summary = 'RAM 8 GiB 이상이 필요합니다.' })
    $virt = $(if ($facts.HypervisorPresent -is [bool] -and $facts.HypervisorPresent) { $true } else { $facts.Virtualization })
    $checks.Add([pscustomobject]@{ Name = 'Virtualization'; State = $(if ($virt -isnot [bool]) { 'Unknown' } elseif ($virt) { 'Pass' } else { 'Fail' }); Summary = '펌웨어 가상화 또는 이미 실행 중인 Hypervisor가 필요합니다.' })
    $wsl = Get-HermesDockerWSLVersion
    $checks.Add([pscustomobject]@{ Name = 'WSL'; State = $wsl.State; Summary = $wsl.Summary })
    return [pscustomobject]@{ Checks = $checks.ToArray(); Failed = @($checks | Where-Object { $_.State -ceq 'Fail' }).Count; Unknown = @($checks | Where-Object { $_.State -ceq 'Unknown' }).Count; WSLVersion = $wsl.Version; Build = $facts.Build; Architecture = $facts.Architecture }
}

function Invoke-HermesDockerDesktopCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [switch]$Compose, [string]$Directory, [hashtable]$Environment = @{}, [int]$TimeoutSeconds = 30)
    $installation = Get-HermesDockerDesktopInstallation
    if (-not $installation.Installed -or -not $installation.Trusted) { throw 'Docker Desktop 실행 파일의 설치 위치·공식 서명을 확인해야 합니다.' }
    $executable = $(if ($Compose) { $installation.ComposePath } else { $installation.CLIPath })
    # Recheck the exact executable immediately before launch.
    if (-not (Test-HermesDockerPublisher -LiteralPath $executable)) { throw 'Docker 실행 파일의 공식 서명을 확인하지 못했습니다.' }
    $values = @{ DOCKER_HOST = $null; DOCKER_CONTEXT = $null; DOCKER_TLS_VERIFY = $null; DOCKER_CERT_PATH = $null; COMPOSE_FILE = $null; COMPOSE_PROJECT_NAME = $null; COMPOSE_PROFILES = $null; COMPOSE_ENV_FILES = $null }
    foreach ($key in $Environment.Keys) { $values[$key] = $Environment[$key] }
    $values.DOCKER_HOST = $script:DockerLinuxHost
    $values.DOCKER_CONTEXT = $null; $values.DOCKER_TLS_VERIFY = $null; $values.DOCKER_CERT_PATH = $null
    $values.PATH = (Split-Path -Parent $installation.CLIPath) + ';' + [Environment]::GetEnvironmentVariable('PATH', 'Process')
    $argv = $(if ($Compose) { $Arguments } else { @('--host', $script:DockerLinuxHost) + $Arguments })
    try { return Invoke-HermesProcess -FilePath $executable -ArgumentList $argv -WorkingDirectory $Directory -Environment $values -TimeoutSeconds $TimeoutSeconds }
    catch { throw '로컬 Docker 명령 실행에 실패했습니다. Docker Desktop 상태를 확인하세요.' }
}

function Get-HermesDockerDesktopProcessState {
    try { if (@(Get-Process -Name 'Docker Desktop', 'com.docker.backend' -ErrorAction SilentlyContinue).Count -gt 0) { return 'Running' }; return 'Stopped' } catch { return 'Unknown' }
}

function Get-HermesDockerDesktopStatus {
    [CmdletBinding()]
    param()
    $installation = Get-HermesDockerDesktopInstallation
    $prerequisites = Get-HermesDockerPrerequisites
    $code = 'Missing'; $summary = 'Docker Desktop이 없습니다. 공식 설치 파일을 검증한 뒤 설치할 수 있습니다.'; $ready = $false; $composeVersion = $null
    if ($installation.Installed) {
        if ($installation.Kind -ceq 'UnknownLocation') { $code = 'UnknownLocation'; $summary = 'Docker Desktop 설치 기록이 있지만 위치를 확인하지 못했습니다. 중복 설치하지 말고 설치 경로를 확인하세요.' }
        elseif ($installation.Kind -ceq 'Incomplete') { $code = 'Incomplete'; $summary = '기존 Docker Desktop 구성 요소가 누락되어 있습니다. 기존 설치를 직접 복구하세요.' }
        elseif (-not $installation.Trusted) { $code = 'Untrusted'; $summary = 'Docker Desktop 공식 서명 또는 안전한 경로를 확인하지 못했습니다. 실행·재설치는 보류합니다.' }
        else {
            try {
                $probe = Invoke-HermesDockerDesktopCommand -Arguments @('info', '--format', '{{json .}}') -TimeoutSeconds 20
                if (-not $probe.Started -or $probe.TimedOut -or $probe.ExitCode -ne 0) { throw 'EngineUnavailable' }
                $info = $probe.StdOut | ConvertFrom-Json
                if ($info.OSType -cne 'linux' -or $info.Architecture -cnotin @('x86_64', 'amd64')) { $code = 'UnsupportedEngine'; $summary = 'Docker Desktop을 Linux/AMD64 엔진으로 전환하세요.' }
                else {
                    $compose = Invoke-HermesDockerDesktopCommand -Compose -Arguments @('version', '--short') -TimeoutSeconds 20
                    if (-not $compose.Started -or $compose.TimedOut -or $compose.ExitCode -ne 0 -or $compose.StdOut.Trim() -cnotmatch '^v?\d+\.\d+\.\d+(?:[-+][A-Za-z0-9._-]+)?$') { $code = 'ComposeUnavailable'; $summary = 'Docker Compose를 확인하지 못했습니다. 기존 Docker Desktop 설치를 직접 복구하세요.' }
                    else { $ready = $true; $code = 'Ready'; $summary = 'Docker Desktop의 로컬 Linux/AMD64 엔진과 Compose가 준비되었습니다.'; $composeVersion = $compose.StdOut.Trim() }
                }
            } catch {
                if ((Get-HermesDockerDesktopProcessState) -ceq 'Stopped') { $code = 'Stopped'; $summary = 'Docker Desktop이 설치되어 있지만 실행되지 않았습니다. Docker Desktop을 열어주세요.' }
                else { $code = 'EngineUnavailable'; $summary = 'Docker Desktop은 실행 중이지만 로컬 Linux 엔진에 연결할 수 없습니다. Linux 컨테이너 모드·WSL·권한을 확인하세요.' }
            }
        }
    }
    # A working engine is stronger evidence than an unavailable CIM/WSL probe.
    if (-not $ready -and $prerequisites.Failed -gt 0 -and $code -cin @('Missing', 'Stopped', 'EngineUnavailable')) {
        $code = 'PrerequisitesNotMet'; $summary = 'Docker 요구 조건을 충족하지 못했습니다. Windows·메모리·가상화·WSL 검사 항목을 확인하세요.'
    }
    elseif (-not $ready -and $prerequisites.Unknown -gt 0 -and $code -cin @('Missing', 'Stopped', 'EngineUnavailable')) {
        $code = 'PrerequisitesUnknown'; $summary = 'PC의 Docker 요구 조건을 모두 확인하지 못했습니다. 미확인 항목을 직접 확인한 뒤 다시 검사하세요.'
    }
    $publicPrerequisites = @($prerequisites.Checks | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Message = [string]$_.Summary; State = [string]$_.State } })
    return [pscustomobject][ordered]@{ Installed = [bool]$installation.Installed; Ready = [bool]$ready; StatusCode = $code; Summary = $summary; CanInstall = [bool](-not $installation.Installed -and $prerequisites.Failed -eq 0 -and $prerequisites.Unknown -eq 0); CanOpen = [bool]($installation.Installed -and $installation.Trusted); DesktopPath = $installation.DesktopPath; Installation = $installation; Prerequisites = $publicPrerequisites; Alternatives = [string[]]$script:DockerAlternatives; ComposeVersion = $composeVersion; Engine = $(if ($ready) { 'Docker Desktop (local Linux/AMD64)' } else { $null }) }
}

function Open-HermesDockerDesktop {
    [CmdletBinding()]
    param([AllowNull()][scriptblock]$ProgressCallback)
    $installation = Get-HermesDockerDesktopInstallation
    if (-not $installation.Installed -or -not $installation.Trusted -or -not (Test-HermesDockerPublisher -LiteralPath $installation.DesktopPath)) { throw '설치된 Docker Desktop의 공식 서명과 안전한 경로를 확인해야 합니다.' }
    Publish-HermesDockerStage $ProgressCallback 'docker-open' 'Docker Desktop을 열었습니다. 표시되는 이용 약관은 직접 확인하고 승인하세요.' 90
    Start-Process -FilePath $installation.DesktopPath -WindowStyle Hidden -ErrorAction Stop | Out-Null
    return [pscustomobject]@{ Opened = $true; DesktopPath = $installation.DesktopPath; Summary = 'Docker Desktop을 열었습니다. Linux 엔진 준비 후 다시 확인하세요.' }
}

function Get-HermesDockerInstallerPin {
    try { $pin = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config\docker-desktop.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { throw '검토된 Docker Desktop 설치 파일 pin이 없습니다.' }
    $uri = $null
    if ($pin.schema -ne 1 -or $pin.architecture -cne 'x64' -or $pin.version -cnotmatch '^\d+\.\d+\.\d+$' -or $pin.sha256 -cnotmatch '^[a-fA-F0-9]{64}$' -or $pin.publisher -cne 'Docker Inc' -or
        -not [Uri]::TryCreate([string]$pin.url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'desktop.docker.com' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cnotmatch '^/win/main/amd64/[0-9]+/Docker%20Desktop%20Installer\.exe$') { throw 'Docker Desktop 공식 설치 파일 pin 형식이 올바르지 않습니다.' }
    return $pin
}

function Invoke-HermesDockerInstallerDownload {
    param([string]$Uri, [string]$Destination, [int64]$MaximumBytes = 1610612736, [int]$TimeoutSeconds = 600)
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.AllowAutoRedirect = $false; $request.Timeout = 30000; $request.ReadWriteTimeout = 30000
    $response = $null; $source = $null; $target = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    try {
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200 -or $response.ResponseUri.AbsoluteUri -cne ([Uri]$Uri).AbsoluteUri -or $response.ContentLength -gt $MaximumBytes) { throw 'DownloadResponseRejected' }
        $source = $response.GetResponseStream(); $target = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 65536; $total = [int64]0
        while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $total += $count
            if ($total -gt $MaximumBytes -or (Get-Date) -gt $deadline) { throw 'DownloadLimitExceeded' }
            $target.Write($buffer, 0, $count)
        }
        if ($total -eq 0) { throw 'EmptyDownload' }
    } catch { throw '공식 Docker 설치 파일 다운로드에 실패했습니다. 리디렉션 없이 크기·시간 제한 내에서 다시 시도하세요.' }
    finally { if ($null -ne $target) { $target.Dispose() }; if ($null -ne $source) { $source.Dispose() }; if ($null -ne $response) { $response.Dispose() } }
}

function Get-HermesVerifiedDockerInstaller {
    param([string]$RuntimeRoot, $Pin, [AllowNull()][scriptblock]$ProgressCallback)
    $cacheDir = Join-Path $RuntimeRoot 'docker\cache'
    if (-not (Test-HermesSafeTargetPath -LiteralPath $cacheDir).Safe) { throw 'Docker 설치 파일 캐시 경로가 안전하지 않습니다.' }
    $cache = Join-Path $cacheDir ('DockerDesktop-{0}-{1}.exe' -f $Pin.version, $Pin.sha256.Substring(0, 16).ToLowerInvariant())
    if (Test-Path -LiteralPath $cache) {
        if (-not (Test-HermesSafeTargetPath -LiteralPath $cache).Safe -or (ConvertTo-HermesSha256 -LiteralPath $cache) -ine $Pin.sha256 -or -not (Test-HermesDockerPublisher -LiteralPath $cache -Publisher $Pin.publisher)) { throw '기존 Docker 설치 파일 캐시가 pin·공식 서명과 다릅니다. 자동 실행하거나 덮어쓰지 않습니다.' }
        return $cache
    }
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
    $temporary = Join-Path $cacheDir ('download-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Publish-HermesDockerStage $ProgressCallback 'docker-download' '공식 Docker Desktop 설치 파일을 다운로드하고 검증합니다.' 20
        Invoke-HermesDockerInstallerDownload -Uri $Pin.url -Destination $temporary -MaximumBytes $script:DockerDownloadMaximumBytes -TimeoutSeconds 600
        if ((Get-Item -LiteralPath $temporary -ErrorAction Stop).Length -gt $script:DockerDownloadMaximumBytes -or (ConvertTo-HermesSha256 -LiteralPath $temporary) -ine $Pin.sha256 -or -not (Test-HermesDockerPublisher -LiteralPath $temporary -Publisher $Pin.publisher)) { throw 'Docker 설치 파일의 크기·SHA-256·공식 서명 검증에 실패했습니다.' }
        [IO.File]::Move($temporary, $cache)
        return $cache
    } finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } }
}

function Get-HermesDockerInstallerStartInfo {
    param([string]$InstallerPath)
    $argv = @('install', '--user', '--backend=wsl-2') | ForEach-Object { ConvertTo-WindowsProcessArgument -Argument $_ }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = [IO.Path]::GetFullPath($InstallerPath)
    $info.Arguments = $argv -join ' '
    $info.UseShellExecute = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
    return $info
}

function Start-HermesDockerInstaller {
    param([string]$InstallerPath)
    $process = [Diagnostics.Process]::Start((Get-HermesDockerInstallerStartInfo -InstallerPath $InstallerPath))
    if ($null -eq $process) { throw 'DockerInstallerProcessUnavailable' }
    return $process
}

function Wait-HermesDockerInstaller {
    param($Process, [AllowNull()][scriptblock]$ProgressCallback, [int]$TimeoutSeconds = 1800)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds); $nextProgress = (Get-Date).AddSeconds(30)
    while (-not $Process.WaitForExit(1000)) {
        if ((Get-Date) -ge $deadline) { return [pscustomobject]@{ Completed = $false; ExitCode = $null } }
        if ((Get-Date) -ge $nextProgress) { Publish-HermesDockerStage $ProgressCallback 'docker-install' 'Docker 설치 창에서 설치를 완료해주세요. 설치 프로세스를 기다리고 있습니다.' 60; $nextProgress = (Get-Date).AddSeconds(30) }
    }
    $Process.Refresh()
    if (-not $Process.HasExited) { throw 'DockerInstallerExitUnconfirmed' }
    $exitCode = $Process.ExitCode
    if ($null -eq $exitCode) { throw 'DockerInstallerExitCodeUnavailable' }
    return [pscustomobject]@{ Completed = $true; ExitCode = [int]$exitCode }
}

function Install-HermesDockerDesktop {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot, [AllowNull()][scriptblock]$ProgressCallback, [switch]$Apply)
    if (-not $Apply) { throw 'Docker 설치는 사용자가 설치를 승인한 -Apply 요청에서만 실행합니다.' }
    if (-not [IO.Path]::IsPathRooted($RuntimeRoot) -or $RuntimeRoot -cnotmatch '^[A-Za-z]:[\\/]' -or -not (Test-HermesSafeTargetPath -LiteralPath $RuntimeRoot).Safe) { throw 'Docker 설치 런타임 경로는 안전한 로컬 절대 경로여야 합니다.' }
    $before = Get-HermesDockerDesktopStatus
    if ($before.Installed) { throw '기존 Docker Desktop은 자동 업데이트·재설치하지 않습니다. 기존 설치를 열거나 직접 복구하세요.' }
    if (-not $before.CanInstall) { throw 'Docker 설치 요구 조건을 먼저 충족해야 합니다. 자동 권한 상승·WSL 변경·재부팅은 수행하지 않습니다.' }
    $pin = Get-HermesDockerInstallerPin
    $installer = Get-HermesVerifiedDockerInstaller -RuntimeRoot ([IO.Path]::GetFullPath($RuntimeRoot)) -Pin $pin -ProgressCallback $ProgressCallback
    # Repeat installation evidence and binary trust immediately before launch.
    if ((Get-HermesDockerDesktopInstallation).Installed) { throw '다운로드 중 기존 Docker Desktop 설치가 감지되었습니다. 중복 설치하지 않습니다.' }
    if ((ConvertTo-HermesSha256 -LiteralPath $installer) -ine $pin.sha256 -or -not (Test-HermesDockerPublisher -LiteralPath $installer -Publisher $pin.publisher)) { throw '실행 직전 Docker 설치 파일 신뢰 검증에 실패했습니다.' }
    Publish-HermesDockerStage $ProgressCallback 'docker-install' '사용자별 Docker 설치 창을 엽니다. 약관과 설치 화면은 직접 확인하세요.' 45
    $process = $null
    try { $process = Start-HermesDockerInstaller -InstallerPath $installer; $outcome = Wait-HermesDockerInstaller -Process $process -ProgressCallback $ProgressCallback -TimeoutSeconds 1800 }
    catch {
        $nativeError = 0; $exception = $_.Exception
        while ($null -ne $exception) {
            if ($exception.PSObject.Properties['NativeErrorCode']) { $nativeError = [int]$exception.NativeErrorCode; break }
            $exception = $exception.InnerException
        }
        if ($nativeError -eq 1223) { $outcome = [pscustomobject]@{ Completed = $true; ExitCode = 1223 } }
        else { throw 'Docker 설치 프로세스를 시작하거나 확인하지 못했습니다. 설치 창 상태를 직접 확인하세요.' }
    }
    finally { if ($null -ne $process) { try { $process.Dispose() } catch { } } }
    $after = Get-HermesDockerDesktopStatus
    $reboot = ($outcome.Completed -and $outcome.ExitCode -in @(3010, 1641))
    $code = $after.StatusCode; $summary = $after.Summary
    if (-not $outcome.Completed) { $code = 'InstallerStillRunning'; $summary = '설치 완료를 30분 내 확인하지 못했습니다. 설치 창을 직접 확인하세요. 실행 중인 설치 프로세스는 종료하지 않았습니다.' }
    elseif ($outcome.ExitCode -in @(1223, 1602)) { $code = 'Cancelled'; $summary = '사용자가 Docker 설치를 취소했습니다. 필요할 때 다시 설치를 승인하세요.' }
    elseif ($outcome.ExitCode -notin @(0, 3010, 1641)) { $code = 'InstallFailed'; $summary = "Docker 설치가 완료되지 않았습니다 (종료 코드 $($outcome.ExitCode)). 설치 창의 안내를 확인하세요." }
    elseif ($reboot) { $code = 'RebootRequired'; $summary = 'Docker 설치에서 재부팅 필요 상태를 반환했습니다. 작업을 저장한 뒤 직접 재부팅하고 다시 확인하세요.' }
    elseif (-not $after.Installed) { $code = 'InstallNotDetected'; $summary = '설치 프로세스는 완료됐지만 Docker 설치 위치를 확인하지 못했습니다. 직접 확인이 필요합니다.' }
    return [pscustomobject][ordered]@{ Installed = [bool]$after.Installed; Ready = [bool]($after.Ready -and $outcome.Completed -and $outcome.ExitCode -eq 0); RebootRequired = [bool]$reboot; StatusCode = $code; Summary = $summary; DesktopPath = $after.DesktopPath; CanOpen = [bool]$after.CanOpen; CanInstall = $false; Prerequisites = $after.Prerequisites; Alternatives = [string[]]$after.Alternatives; Version = $pin.version; InstallerExitCode = $outcome.ExitCode }
}

Export-ModuleMember -Function @('Get-HermesDockerDesktopInstallation', 'Get-HermesDockerPrerequisites', 'Get-HermesDockerDesktopStatus', 'Invoke-HermesDockerDesktopCommand', 'Open-HermesDockerDesktop', 'Install-HermesDockerDesktop')
