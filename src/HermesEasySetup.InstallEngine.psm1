Set-StrictMode -Version 2.0

$script:HermesManagedLauncherNames = @('hermes.exe', 'hermes-acp.exe')
$script:HermesManagedLauncherPatterns = @('/bin/hermes.exe', '/bin/hermes-acp.exe')
$script:HermesBareCommandExtensions = @('.com', '.exe', '.bat', '.cmd', '.ps1')
$script:HermesStageBareCommandNames = @{
    'uv' = @('uv')
    'python' = @('uv', 'python')
    'git' = @('git')
    'node' = @('node', 'winget')
    'system-packages' = @('rg', 'ffmpeg', 'winget', 'choco', 'scoop')
    'repository' = @('git', 'ssh')
    'venv' = @('uv', 'schtasks', 'taskkill')
    'dependencies' = @('uv', 'node', 'npm', 'npx', 'taskkill', 'cua-driver')
    'node-deps' = @('uv', 'node', 'npm', 'npx', 'taskkill', 'cua-driver')
    'desktop' = @('uv', 'git', 'node', 'npm', 'npx', 'winget', 'taskkill', 'icacls', 'ie4uinit')
    'path' = @()
    'config-templates' = @()
    'platform-sdks' = @('uv')
    'bootstrap-marker' = @('git')
}

function Get-HermesStageArguments {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$SourceConfig
    )

    $arguments = @(
        '-Commit', [string]$SourceConfig.hermes.commitSha,
        '-HermesHome', [string]$Plan.HermesHome,
        '-InstallDir', [string]$Plan.InstallDir,
        '-SkipSetup', '-NonInteractive', '-Json'
    )
    if ([bool]$Plan.IncludeDesktop) { $arguments += '-IncludeDesktop' }
    if ([bool]$Plan.SkipComputerUse) { $arguments += '-SkipComputerUse' }
    return $arguments
}

function Write-HermesExclusiveFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )

    $stream = New-Object System.IO.FileStream($LiteralPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        if ($Bytes.Length -gt 0) { $stream.Write($Bytes, 0, $Bytes.Length) }
        $stream.Flush()
    } finally {
        $stream.Dispose()
    }
}

function Remove-HermesManagedGitFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot
    )

    try {
        $runtimeFull = [System.IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\', '/')
        $configFull = [System.IO.Path]::GetFullPath($ConfigPath)
        $runtimePrefix = $runtimeFull + [System.IO.Path]::DirectorySeparatorChar
        $leaf = Split-Path -Leaf $configFull
        if (-not $configFull.StartsWith($runtimePrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals((Split-Path -Parent $configFull).TrimEnd('\', '/'), $runtimeFull, [System.StringComparison]::OrdinalIgnoreCase) -or
            $leaf -notmatch '^git-global-(?<Token>[0-9a-f]{32})\.config$') { return }

        $token = [string]$Matches['Token']
        foreach ($path in @(
            $configFull,
            (Join-Path $runtimeFull ("git-attributes-$token.txt")),
            (Join-Path $runtimeFull ("git-excludes-$token.txt"))
        )) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $item = Get-Item -LiteralPath $path -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            Remove-Item -LiteralPath $path -Force
        }
    } catch {
        # Best effort: these files contain no secret, and unsafe replacements are never followed.
    }
}

function New-HermesManagedStageProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)

    $runtimeFull = [System.IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $runtimeFull -PathType Container)) {
        throw 'RuntimeRoot must exist before creating an isolated stage profile'
    }
    $runtimeItem = Get-Item -LiteralPath $runtimeFull -Force -ErrorAction Stop
    if (($runtimeItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'RuntimeRoot reparse point rejected for isolated stage profile'
    }

    $token = [guid]::NewGuid().ToString('N')
    $profileRoot = [System.IO.Path]::GetFullPath((Join-Path $runtimeFull ("stage-profile-$token")))
    $runtimePrefix = $runtimeFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $profileRoot.StartsWith($runtimePrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Split-Path -Parent $profileRoot).TrimEnd('\', '/'), $runtimeFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Isolated stage profile escaped RuntimeRoot'
    }
    New-Item -ItemType Directory -Path $profileRoot -ErrorAction Stop | Out-Null

    $paths = [ordered]@{
        Root = $profileRoot
        LocalAppData = (Join-Path $profileRoot 'AppData\Local')
        AppData = (Join-Path $profileRoot 'AppData\Roaming')
        Temp = (Join-Path $profileRoot 'Temp')
        XdgConfig = (Join-Path $profileRoot 'xdg\config')
        XdgData = (Join-Path $profileRoot 'xdg\data')
        XdgCache = (Join-Path $profileRoot 'xdg\cache')
        NpmCache = (Join-Path $profileRoot 'npm-cache')
        CorepackHome = (Join-Path $profileRoot 'corepack')
    }
    foreach ($path in @($paths.Values | Where-Object { -not [string]::Equals([string]$_, $profileRoot, [System.StringComparison]::OrdinalIgnoreCase) })) {
        New-Item -ItemType Directory -Path ([string]$path) -Force -ErrorAction Stop | Out-Null
        $item = Get-Item -LiteralPath ([string]$path) -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Isolated stage profile reparse point rejected' }
    }
    $npmUserConfig = Join-Path $profileRoot 'npm-user.config'
    $npmGlobalConfig = Join-Path $profileRoot 'npm-global.config'
    Write-HermesExclusiveFile -LiteralPath $npmUserConfig -Bytes ([byte[]]@())
    Write-HermesExclusiveFile -LiteralPath $npmGlobalConfig -Bytes ([byte[]]@())

    return [pscustomobject]@{
        Token = $token
        Root = $profileRoot
        LocalAppData = [string]$paths.LocalAppData
        AppData = [string]$paths.AppData
        Temp = [string]$paths.Temp
        XdgConfig = [string]$paths.XdgConfig
        XdgData = [string]$paths.XdgData
        XdgCache = [string]$paths.XdgCache
        NpmCache = [string]$paths.NpmCache
        CorepackHome = [string]$paths.CorepackHome
        NpmUserConfig = $npmUserConfig
        NpmGlobalConfig = $npmGlobalConfig
    }
}

function Remove-HermesManagedStageProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProfileRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot
    )

    try {
        $runtimeFull = [System.IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\', '/')
        $profileFull = [System.IO.Path]::GetFullPath($ProfileRoot).TrimEnd('\', '/')
        if (-not [string]::Equals((Split-Path -Parent $profileFull).TrimEnd('\', '/'), $runtimeFull, [System.StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $profileFull) -notmatch '^stage-profile-[0-9a-f]{32}$' -or
            -not (Test-Path -LiteralPath $profileFull -PathType Container)) { return }
        $rootItem = Get-Item -LiteralPath $profileFull -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return }
        $reparseChild = Get-ChildItem -LiteralPath $profileFull -Force -Recurse -ErrorAction Stop |
            Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
            Select-Object -First 1
        if ($null -ne $reparseChild) { return }
        Remove-Item -LiteralPath $profileFull -Recurse -Force -ErrorAction Stop
    } catch {
        # Best effort: unsafe or busy stage profiles are left in RuntimeRoot for inspection.
    }
}

function Remove-HermesStageEnvironmentArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Environment,
        [Parameter(Mandatory = $true)]$Plan
    )

    if ($Environment.ContainsKey('GIT_CONFIG_GLOBAL') -and -not [string]::IsNullOrWhiteSpace([string]$Environment['GIT_CONFIG_GLOBAL'])) {
        Remove-HermesManagedGitFiles -ConfigPath ([string]$Environment['GIT_CONFIG_GLOBAL']) -RuntimeRoot ([string]$Plan.RuntimeRoot)
    }
    if ($Environment.ContainsKey('HERMES_EASY_SETUP_STAGE_PROFILE') -and -not [string]::IsNullOrWhiteSpace([string]$Environment['HERMES_EASY_SETUP_STAGE_PROFILE'])) {
        Remove-HermesManagedStageProfile -ProfileRoot ([string]$Environment['HERMES_EASY_SETUP_STAGE_PROFILE']) -RuntimeRoot ([string]$Plan.RuntimeRoot)
    }
}

function New-HermesStageEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$Stage,
        [switch]$ExistingCheckout,
        [switch]$IsolatedGitVerification
    )

    $environment = Get-HermesCuratedProcessEnvironment
    $environment['HERMES_HOME'] = [string]$Plan.HermesHome
    $stageProfile = New-HermesManagedStageProfile -RuntimeRoot ([string]$Plan.RuntimeRoot)
    $environment['HERMES_EASY_SETUP_STAGE_PROFILE'] = [string]$stageProfile.Root
    $environment['USERPROFILE'] = [string]$stageProfile.Root
    $environment['HOME'] = [string]$stageProfile.Root
    $environment['HOMEDRIVE'] = [System.IO.Path]::GetPathRoot([string]$stageProfile.Root).TrimEnd('\', '/')
    $environment['HOMEPATH'] = ([string]$stageProfile.Root).Substring(2)
    $environment['LOCALAPPDATA'] = [string]$stageProfile.LocalAppData
    $environment['APPDATA'] = [string]$stageProfile.AppData
    $environment['TEMP'] = [string]$stageProfile.Temp
    $environment['TMP'] = [string]$stageProfile.Temp
    $environment['XDG_CONFIG_HOME'] = [string]$stageProfile.XdgConfig
    $environment['XDG_DATA_HOME'] = [string]$stageProfile.XdgData
    $environment['XDG_CACHE_HOME'] = [string]$stageProfile.XdgCache
    $environment['NPM_CONFIG_USERCONFIG'] = [string]$stageProfile.NpmUserConfig
    $environment['NPM_CONFIG_GLOBALCONFIG'] = [string]$stageProfile.NpmGlobalConfig
    $environment['NPM_CONFIG_CACHE'] = [string]$stageProfile.NpmCache
    $environment['COREPACK_HOME'] = [string]$stageProfile.CorepackHome
    $environment['PIP_CONFIG_FILE'] = 'NUL'
    $environment['PYTHONNOUSERSITE'] = '1'
    $environment['PYTHONSAFEPATH'] = '1'
    $environment['UV_NO_MODIFY_PATH'] = '1'
    $environment['UV_MANAGED_PYTHON'] = '1'
    $environment['UV_PYTHON_NO_REGISTRY'] = '1'
    if ($Stage -ceq 'python') { $environment['UV_NO_PROJECT'] = '1' }
    $environment['UV_PYTHON_INSTALL_DIR'] = [System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.HermesHome) 'python'))
    $environment['UV_TOOL_DIR'] = [System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.HermesHome) 'uv-tools'))
    $environment['UV_TOOL_BIN_DIR'] = [System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.HermesHome) 'bin'))
    $environment['UV_CACHE_DIR'] = Join-Path ([string]$stageProfile.XdgCache) 'uv'
    $environment['PLAYWRIGHT_BROWSERS_PATH'] = '0'
    $git = Get-HermesVerificationGitPath -HermesHome ([string]$Plan.HermesHome)
    if ([string]::IsNullOrWhiteSpace($git)) {
        Throw-HermesEasySetupError -Message '공식 설치 단계를 실행할 신뢰 가능한 Git을 찾지 못했습니다.' -ExitCode 10 -Category 'Preflight'
    }
    $gitDirectory = Split-Path -Parent $git
    $gitRoot = Split-Path -Parent $gitDirectory
    $gitSsh = [System.IO.Path]::GetFullPath((Join-Path $gitRoot 'usr\bin\ssh.exe'))
    if (-not (Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath $gitSsh -RootPath $gitRoot) -or
        -not (Test-HermesPortableExecutableHeader -LiteralPath $gitSsh -MaximumLength 128MB)) {
        Throw-HermesEasySetupError -Message 'Program Files Git의 신뢰 가능한 bundled SSH를 찾지 못했습니다.' -ExitCode 10 -Category 'Preflight'
    }
    $trustedCmd = Get-HermesTrustedWindowsCommandPath -CommandName 'cmd'
    if ([string]::IsNullOrWhiteSpace($trustedCmd)) {
        Throw-HermesEasySetupError -Message '신뢰 가능한 System32 cmd.exe를 찾지 못했습니다.' -ExitCode 10 -Category 'Preflight'
    }
    $currentPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Process)
    $environment['PATH'] = $(if ([string]::IsNullOrWhiteSpace($currentPath)) { $gitDirectory } else { $gitDirectory + [System.IO.Path]::PathSeparator + $currentPath })
    $environment['ComSpec'] = $trustedCmd
    $environment['SystemRoot'] = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    $environment['WINDIR'] = $environment['SystemRoot']
    $systemModulePath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)) 'System32\WindowsPowerShell\v1.0\Modules'
    if (-not (Test-Path -LiteralPath $systemModulePath -PathType Container) -or
        ((Get-Item -LiteralPath $systemModulePath -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-HermesEasySetupError -Message '신뢰 가능한 Windows PowerShell system module 경로를 찾지 못했습니다.' -ExitCode 10 -Category 'Preflight'
    }
    $environment['PSModulePath'] = [System.IO.Path]::GetFullPath($systemModulePath)
    $environment['PATHEXT'] = '.COM;.EXE;.BAT;.CMD'

    foreach ($key in @(
        'VIRTUAL_ENV', 'UV_PROJECT', 'UV_PROJECT_ENVIRONMENT', 'UV_PYTHON',
        'CONDA_PREFIX', 'CONDA_DEFAULT_ENV', 'PIPENV_ACTIVE', 'POETRY_ACTIVE',
        'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0',
        'GIT_CONFIG_KEY_1', 'GIT_CONFIG_VALUE_1', 'GIT_CONFIG_SYSTEM', 'GIT_EXEC_PATH', 'GIT_TEMPLATE_DIR',
        'GIT_DIR', 'GIT_COMMON_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
        'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_NAMESPACE', 'GIT_SSH', 'GIT_SSH_COMMAND',
        'GIT_PROXY_COMMAND', 'GIT_SSL_NO_VERIFY', 'GIT_ATTR_SOURCE', 'GIT_EXTERNAL_DIFF', 'GIT_PAGER',
        'PAGER', 'GIT_EDITOR', 'GIT_SEQUENCE_EDITOR', 'GIT_ASKPASS', 'SSH_ASKPASS', 'GIT_REPLACE_REF_BASE',
        'GIT_TRACE', 'GIT_TRACE_PACKET', 'GIT_TRACE_PERFORMANCE', 'GIT_TRACE_SETUP', 'GIT_TRACE_SHALLOW',
        'GIT_TRACE_CURL', 'GIT_TRACE_CURL_NO_DATA', 'GIT_TRACE2', 'GIT_TRACE2_EVENT', 'GIT_TRACE2_PERF'
    )) {
        $environment[$key] = $null
    }
    $environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $environment['GIT_ATTR_NOSYSTEM'] = '1'
    $environment['GIT_NO_REPLACE_OBJECTS'] = '1'
    $environment['GIT_OPTIONAL_LOCKS'] = '0'
    $environment['GIT_TERMINAL_PROMPT'] = '0'
    $environment['GCM_INTERACTIVE'] = 'Never'
    $environment['SSH_ASKPASS_REQUIRE'] = 'never'
    $environment['GIT_ALLOW_PROTOCOL'] = 'https:ssh'
    $environment['GIT_CONFIG_COUNT'] = '2'
    $environment['GIT_CONFIG_KEY_0'] = 'core.hooksPath'
    $environment['GIT_CONFIG_VALUE_0'] = 'NUL'
    $environment['GIT_CONFIG_KEY_1'] = 'core.fsmonitor'
    $environment['GIT_CONFIG_VALUE_1'] = 'false'
    $environment['GIT_SSH'] = $gitSsh

    $runtimeRoot = [System.IO.Path]::GetFullPath([string]$Plan.RuntimeRoot)
    $token = [guid]::NewGuid().ToString('N')
    $configPath = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot ("git-global-$token.config")))
    $attributesPath = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot ("git-attributes-$token.txt")))
    $excludesPath = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot ("git-excludes-$token.txt")))
    $runtimePrefix = $runtimeRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    foreach ($path in @($configPath, $attributesPath, $excludesPath)) {
        if (-not $path.StartsWith($runtimePrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals((Split-Path -Parent $path).TrimEnd('\', '/'), $runtimeRoot.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) {
            Throw-HermesEasySetupError -Message '관리형 Git 설정 경로가 RuntimeRoot 밖을 가리킵니다.' -ExitCode 10 -Category 'PathSafety'
        }
    }

    $attributesConfigValue = $attributesPath.Replace('\', '/').Replace('"', '\"')
    $excludesConfigValue = $excludesPath.Replace('\', '/').Replace('"', '\"')
    $configText = '[core]' + [char]10 +
        [char]9 + 'autocrlf = false' + [char]10 +
        [char]9 + 'longpaths = true' + [char]10 +
        [char]9 + 'attributesFile = "' + $attributesConfigValue + '"' + [char]10 +
        [char]9 + 'excludesFile = "' + $excludesConfigValue + '"' + [char]10 +
        [char]9 + 'hooksPath = NUL' + [char]10 +
        [char]9 + 'fsmonitor = false' + [char]10
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        Write-HermesExclusiveFile -LiteralPath $attributesPath -Bytes ([byte[]]@())
        Write-HermesExclusiveFile -LiteralPath $excludesPath -Bytes ([byte[]]@())
        Write-HermesExclusiveFile -LiteralPath $configPath -Bytes $utf8.GetBytes($configText)
        $configItem = Get-Item -LiteralPath $configPath -Force
        $attributesItem = Get-Item -LiteralPath $attributesPath -Force
        $excludesItem = Get-Item -LiteralPath $excludesPath -Force
        if ([bool]$configItem.PSIsContainer -or [bool]$attributesItem.PSIsContainer -or [bool]$excludesItem.PSIsContainer -or
            ($configItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($attributesItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($excludesItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $attributesItem.Length -ne 0 -or $excludesItem.Length -ne 0 -or
            [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) -cne $configText) {
            throw 'managed Git file verification failed'
        }
    } catch {
        Remove-HermesManagedGitFiles -ConfigPath $configPath -RuntimeRoot $runtimeRoot
        Remove-HermesManagedStageProfile -ProfileRoot ([string]$stageProfile.Root) -RuntimeRoot $runtimeRoot
        Throw-HermesEasySetupError -Message '관리형 Git 설정 파일을 안전하게 만들지 못했습니다.' -ExitCode 10 -Category 'PathSafety'
    }

    $environment['GIT_CONFIG_GLOBAL'] = $configPath
    return $environment
}

function Convert-HermesBrokenUvPythonMinorJunction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [string]$PythonVersion = '3.11'
    )

    $unchanged = { param([string]$Reason) [pscustomobject]@{ Changed = $false; Reason = $Reason; Path = $null } }
    try {
        if ($PythonVersion -cnotmatch '^[0-9]+\.[0-9]+$') { return & $unchanged 'Unsupported Python minor version' }
        $hermesHomeFull = [System.IO.Path]::GetFullPath([string]$Plan.HermesHome).TrimEnd('\', '/')
        $pythonRoot = [System.IO.Path]::GetFullPath((Join-Path $hermesHomeFull 'python')).TrimEnd('\', '/')
        if (-not $pythonRoot.StartsWith($hermesHomeFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $pythonRoot -PathType Container)) {
            return & $unchanged 'Managed Python root is absent'
        }
        $pythonRootItem = Get-Item -LiteralPath $pythonRoot -Force
        if (($pythonRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return & $unchanged 'Managed Python root is a reparse point' }

        $minorPattern = '^cpython-' + [regex]::Escape($PythonVersion) + '-windows-(x86_64|aarch64)-none$'
        $links = @(Get-ChildItem -LiteralPath $pythonRoot -Force -Directory -ErrorAction Stop | Where-Object { $_.Name -cmatch $minorPattern })
        if ($links.Count -ne 1) { return & $unchanged 'A unique managed Python minor junction was not found' }
        $linkItem = $links[0]
        if (($linkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -or [string]$linkItem.LinkType -cne 'Junction') {
            return & $unchanged 'Managed Python minor path is not a junction'
        }
        $linkFull = [System.IO.Path]::GetFullPath([string]$linkItem.FullName).TrimEnd('\', '/')
        if (-not [string]::Equals((Split-Path -Parent $linkFull).TrimEnd('\', '/'), $pythonRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return & $unchanged 'Managed Python minor junction escaped its root'
        }
        $targetValue = [string]$linkItem.Target
        if ([string]::IsNullOrWhiteSpace($targetValue)) { return & $unchanged 'Managed Python minor junction target is empty' }
        $targetFull = [System.IO.Path]::GetFullPath($targetValue).TrimEnd('\', '/')
        if (-not [string]::Equals((Split-Path -Parent $targetFull).TrimEnd('\', '/'), $pythonRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return & $unchanged 'Managed Python patch directory escaped its root'
        }
        $suffix = $linkItem.Name.Substring(('cpython-' + $PythonVersion + '-').Length)
        $targetPattern = '^cpython-' + [regex]::Escape($PythonVersion) + '\.[0-9]+-' + [regex]::Escape($suffix) + '$'
        if ((Split-Path -Leaf $targetFull) -cnotmatch $targetPattern -or -not (Test-Path -LiteralPath $targetFull -PathType Container)) {
            return & $unchanged 'Managed Python patch directory is invalid'
        }
        $targetItem = Get-Item -LiteralPath $targetFull -Force
        $targetPython = Join-Path $targetFull 'python.exe'
        if (($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not (Test-HermesPortableExecutableHeader -LiteralPath $targetPython -MaximumLength 128MB)) {
            return & $unchanged 'Managed Python patch executable is invalid'
        }

        # uv can create a non-resolving minor-version junction on Windows even
        # though the patch-version directory is complete. Materialize the patch
        # directory at the minor path so the official installer can verify it.
        [System.IO.Directory]::Delete($linkFull, $false)
        [System.IO.Directory]::Move($targetFull, $linkFull)
        $materialized = Get-Item -LiteralPath $linkFull -Force
        if (($materialized.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not (Test-HermesPortableExecutableHeader -LiteralPath (Join-Path $linkFull 'python.exe') -MaximumLength 128MB)) {
            throw 'Materialized managed Python directory did not verify'
        }
        return [pscustomobject]@{ Changed = $true; Reason = $null; Path = $linkFull }
    } catch {
        return & $unchanged (Protect-HermesLogText $_.Exception.Message)
    }
}

function Get-HermesStageTimeoutSeconds {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Stage)

    switch ($Stage) {
        'dependencies' { return 5400 }
        'node-deps' { return 5400 }
        'platform-sdks' { return 5400 }
        'desktop' { return 10800 }
        default { return 1800 }
    }
}

function Get-HermesMvpPolicyStageSkipReason {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Stage)

    if ($Stage -ceq 'node-deps') {
        return 'v0.1.2 초기판은 core Hermes CLI만 설치하므로 선택적 Browser/TUI npm 의존성은 후속 버전까지 자동 실행하지 않습니다.'
    }
    return $null
}

function Test-HermesStageFrame {
    param(
        [AllowNull()]$Frame,
        [Parameter(Mandatory = $true)][string]$ExpectedStage
    )

    if ($null -eq $Frame) { return [pscustomobject]@{ Valid = $false; Reason = 'JSON 결과 프레임이 없습니다.' } }
    foreach ($property in @('stage', 'ok', 'skipped', 'reason', 'duration_ms')) {
        if ($Frame.PSObject.Properties.Name -notcontains $property) { return [pscustomobject]@{ Valid = $false; Reason = "결과 프레임에 '$property' 필드가 없습니다." } }
    }
    if ([string]$Frame.stage -ne $ExpectedStage) { return [pscustomobject]@{ Valid = $false; Reason = '결과 단계 이름이 요청과 다릅니다.' } }
    if ($Frame.ok -isnot [bool] -or $Frame.skipped -isnot [bool]) { return [pscustomobject]@{ Valid = $false; Reason = 'ok/skipped 필드가 Boolean이 아닙니다.' } }
    try { if ([int64]$Frame.duration_ms -lt 0) { throw 'negative' } } catch { return [pscustomobject]@{ Valid = $false; Reason = 'duration_ms가 올바르지 않습니다.' } }
    return [pscustomobject]@{ Valid = $true; Reason = $null }
}

function Test-HermesGitCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [switch]$RequireValidSignature
    )

    try {
        if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) { return $null }
        $fullPath = [System.IO.Path]::GetFullPath($LiteralPath)
        $safety = Test-HermesSafeTargetPath -LiteralPath $fullPath -Label 'Git 검증 실행 파일'
        if (-not $safety.Safe) { return $null }
        $item = Get-Item -LiteralPath $fullPath -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
        if ($RequireValidSignature) {
            $directory = Split-Path -Parent $fullPath
            foreach ($extension in @('.com', '.cmd', '.bat', '.ps1')) {
                if (Test-Path -LiteralPath (Join-Path $directory ('git' + $extension)) -PathType Leaf) { return $null }
            }
            $signature = Get-HermesAuthenticodeSignature -LiteralPath $fullPath
            if ([string]$signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) { return $null }
            $simpleName = $signature.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
            $subject = [string]$signature.SignerCertificate.Subject
            if ($simpleName -cne 'Johannes Schindelin' -or $subject -notmatch '(?i)(?:^|,\s*)O=Johannes Schindelin(?:\s*,|$)') { return $null }
        }
        return $fullPath
    } catch {
        return $null
    }
}

function Get-HermesVerificationGitPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$HermesHome
    )

    $seen = @{}
    $programFolders = @(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    )
    foreach ($folder in $programFolders) {
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }
        foreach ($relativePath in @('Git\cmd\git.exe', 'Git\bin\git.exe')) {
            $candidate = Join-Path $folder $relativePath
            $key = [System.IO.Path]::GetFullPath($candidate).ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $trusted = Test-HermesGitCandidate -LiteralPath $candidate -RequireValidSignature
            if ($trusted) { return $trusted }
        }
    }

    return $null
}

function Test-HermesRegistryGitResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TrustedGitPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowNull()][string[]]$PathValues
    )

    $failure = {
        param([string]$Reason, [AllowNull()][string]$ResolvedPath)
        return [pscustomobject]@{ Valid = $false; Reason = $Reason; ResolvedPath = $ResolvedPath }
    }
    try {
        $trusted = Test-HermesGitCandidate -LiteralPath $TrustedGitPath -RequireValidSignature
        if ([string]::IsNullOrWhiteSpace($trusted)) { return & $failure 'trusted Git candidate rejected' $null }
        $trustedFull = [System.IO.Path]::GetFullPath($trusted)
        $candidateNames = @('git', 'git.com', 'git.exe', 'git.bat', 'git.cmd', 'git.ps1')
        $seenDirectories = @{}
        foreach ($pathValue in @($PathValues)) {
            if ($null -eq $pathValue) { return & $failure 'missing registry PATH value rejected' $null }
            foreach ($entry in @(([string]$pathValue).Split([char]';'))) {
                if ([string]::IsNullOrWhiteSpace($entry)) { return & $failure 'empty registry PATH entry rejected' $null }
                $directory = ConvertTo-HermesComparablePathEntry -PathEntry ([string]$entry)
                if ([string]::IsNullOrWhiteSpace($directory)) { return & $failure 'invalid registry PATH entry rejected' $null }
                $directoryKey = $directory.ToLowerInvariant()
                if ($seenDirectories.ContainsKey($directoryKey)) { continue }
                $seenDirectories[$directoryKey] = $true
                foreach ($name in $candidateNames) {
                    $candidate = Join-Path $directory $name
                    if (-not (Test-Path -LiteralPath $candidate)) { continue }
                    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return & $failure 'non-file Git command candidate rejected' $candidate }
                    $candidateItem = Get-Item -LiteralPath $candidate -Force
                    if (($candidateItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return & $failure 'reparse Git command candidate rejected' $candidate }
                    $candidateFull = [System.IO.Path]::GetFullPath($candidate)
                    if (-not [string]::Equals($candidateFull, $trustedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                        return & $failure 'registry PATH resolves Git to an untrusted candidate' $candidateFull
                    }
                    $validated = Test-HermesGitCandidate -LiteralPath $candidateFull -RequireValidSignature
                    if ([string]::IsNullOrWhiteSpace($validated) -or
                        -not [string]::Equals([System.IO.Path]::GetFullPath($validated), $trustedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                        return & $failure 'registry PATH Git candidate validation failed' $candidateFull
                    }
                    return [pscustomobject]@{ Valid = $true; Reason = $null; ResolvedPath = $candidateFull }
                }
            }
        }
        return & $failure 'registry PATH does not resolve the trusted Git' $null
    } catch {
        return & $failure 'registry PATH Git resolution inspection failed' $null
    }
}

function Get-HermesTrustedGitBashPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TrustedGitPath)

    try {
        $gitPath = [System.IO.Path]::GetFullPath($TrustedGitPath)
        $gitDirectory = Split-Path -Parent $gitPath
        $gitRoot = Split-Path -Parent $gitDirectory
        foreach ($relativePath in @('bin\bash.exe', 'usr\bin\bash.exe')) {
            $candidate = [System.IO.Path]::GetFullPath((Join-Path $gitRoot $relativePath))
            if ((Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath $candidate -RootPath $gitRoot) -and
                (Test-HermesPortableExecutableHeader -LiteralPath $candidate -MaximumLength 128MB)) {
                return $candidate
            }
        }
    } catch {}
    return $null
}

function Test-HermesTrustedGitBashCompatibility {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BashPath)

    try {
        $environment = Get-HermesCuratedProcessEnvironment
        $environment['BASH_ENV'] = $null
        $environment['ENV'] = $null
        $result = Invoke-HermesProcess -FilePath $BashPath -ArgumentList @(
            '--noprofile', '--norc', '-c', '/usr/bin/true; /usr/bin/cat --version >/dev/null'
        ) -Environment $environment -TimeoutSeconds 15
        return ($result.Started -and -not $result.TimedOut -and $result.ExitCode -eq 0)
    } catch {
        return $false
    }
}

function Test-HermesOrdinaryCommandPathUnderRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$RootPath
    )

    try {
        $candidateFull = [System.IO.Path]::GetFullPath($LiteralPath)
        $rootFull = ConvertTo-HermesComparablePathEntry -PathEntry $RootPath
        if ([string]::IsNullOrWhiteSpace($rootFull) -or -not (Test-Path -LiteralPath $candidateFull -PathType Leaf)) { return $false }
        $rootPrefix = $rootFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if (-not $candidateFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }

        $cursor = $candidateFull
        while ($true) {
            if (-not (Test-Path -LiteralPath $cursor)) { return $false }
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            if ([string]::Equals($cursor.TrimEnd('\', '/'), $rootFull.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            $parent = Split-Path -Parent $cursor
            if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent, $cursor, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
            if (-not [string]::Equals($parent.TrimEnd('\', '/'), $rootFull.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase) -and
                -not $parent.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
            $cursor = $parent
        }
    } catch {
        return $false
    }
}

function Test-HermesOrdinaryDirectoryPathUnderRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$RootPath
    )

    try {
        $candidateFull = [System.IO.Path]::GetFullPath($LiteralPath).TrimEnd('\', '/')
        $rootFull = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\', '/')
        $rootPrefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
        if (-not $candidateFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $candidateFull -PathType Container)) { return $false }
        $cursor = $candidateFull
        while ($true) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (-not [bool]$item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            if ([string]::Equals($cursor, $rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            $parent = [System.IO.Path]::GetFullPath((Split-Path -Parent $cursor)).TrimEnd('\', '/')
            if (-not [string]::Equals($parent, $rootFull, [System.StringComparison]::OrdinalIgnoreCase) -and
                -not $parent.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
            $cursor = $parent
        }
    } catch {
        return $false
    }
}

function Test-HermesAuthenticodePublisher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$PublisherPattern
    )

    try {
        $signature = Get-HermesAuthenticodeSignature -LiteralPath $LiteralPath
        if ([string]$signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) { return $false }
        $identity = [string]$signature.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) + ' ' + [string]$signature.SignerCertificate.Subject
        return ($identity -match $PublisherPattern)
    } catch {
        return $false
    }
}

function Get-HermesReparseTag {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    try {
        if (-not ([System.Management.Automation.PSTypeName]'HermesEasySetup.ReparsePointInspector').Type) {
            $source = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace HermesEasySetup {
    public static class ReparsePointInspector {
        private const uint FileShareRead = 1;
        private const uint FileShareWrite = 2;
        private const uint FileShareDelete = 4;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FsctlGetReparsePoint = 0x000900A8;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(IntPtr device, uint controlCode, IntPtr inBuffer, uint inSize, byte[] outBuffer, uint outSize, out uint bytesReturned, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static uint GetTag(string path) {
            IntPtr handle = CreateFileW(path, 0, FileShareRead | FileShareWrite | FileShareDelete, IntPtr.Zero, OpenExisting, FileFlagBackupSemantics | FileFlagOpenReparsePoint, IntPtr.Zero);
            if (handle == new IntPtr(-1)) return 0;
            try {
                byte[] buffer = new byte[16384];
                uint returned;
                if (!DeviceIoControl(handle, FsctlGetReparsePoint, IntPtr.Zero, 0, buffer, (uint)buffer.Length, out returned, IntPtr.Zero) || returned < 8) return 0;
                return BitConverter.ToUInt32(buffer, 0);
            } finally {
                CloseHandle(handle);
            }
        }

        public static string[] GetAppExecLinkStrings(string path) {
            IntPtr handle = CreateFileW(path, 0, FileShareRead | FileShareWrite | FileShareDelete, IntPtr.Zero, OpenExisting, FileFlagBackupSemantics | FileFlagOpenReparsePoint, IntPtr.Zero);
            if (handle == new IntPtr(-1)) return new string[0];
            try {
                byte[] buffer = new byte[16384];
                uint returned;
                if (!DeviceIoControl(handle, FsctlGetReparsePoint, IntPtr.Zero, 0, buffer, (uint)buffer.Length, out returned, IntPtr.Zero) || returned < 14) return new string[0];
                if (BitConverter.ToUInt32(buffer, 0) != 0x8000001B) return new string[0];
                int dataLength = BitConverter.ToUInt16(buffer, 4);
                if (dataLength < 6 || dataLength > returned - 8 || BitConverter.ToUInt32(buffer, 8) != 3) return new string[0];
                string payload = Encoding.Unicode.GetString(buffer, 12, dataLength - 4);
                return payload.Split(new char[] { '\0' }, StringSplitOptions.RemoveEmptyEntries);
            } finally {
                CloseHandle(handle);
            }
        }
    }
}
"@
            Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
        }
        return [uint32][HermesEasySetup.ReparsePointInspector]::GetTag([System.IO.Path]::GetFullPath($LiteralPath))
    } catch {
        return [uint32]0
    }
}

function Test-HermesWindowsAppExecutionAlias {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$ExpectedName
    )

    try {
        $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($localAppData)) { return $false }
        $expected = [System.IO.Path]::GetFullPath((Join-Path $localAppData (Join-Path 'Microsoft\WindowsApps' $ExpectedName)))
        $fullPath = [System.IO.Path]::GetFullPath($LiteralPath)
        if (-not [string]::Equals($fullPath, $expected, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return $false }
        $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if ($item.Length -ne 0 -or
            ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -or
            (Get-HermesReparseTag -LiteralPath $fullPath) -ne [uint32]2147483675) { return $false }
        $strings = @([HermesEasySetup.ReparsePointInspector]::GetAppExecLinkStrings($fullPath))
        if ($strings.Count -lt 3) { return $false }
        $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
        $windowsApps = [System.IO.Path]::GetFullPath((Join-Path $programFiles 'WindowsApps')).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $target = [System.IO.Path]::GetFullPath([string]$strings[2])
        if (-not $target.StartsWith($windowsApps, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ($ExpectedName -ceq 'winget.exe') {
            return ([string]$strings[0] -ceq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -and
                [string]$strings[1] -ceq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe!winget' -and
                $target -match '(?i)\\Microsoft\.DesktopAppInstaller_[^\\]+__8wekyb3d8bbwe\\winget\.exe$')
        }
        if ($ExpectedName -ceq 'python.exe') {
            return ([string]$strings[0] -match '^PythonSoftwareFoundation\.Python\.3\.[0-9]+_qbz5n2kfra8p0$' -and
                [string]$strings[1] -match '^PythonSoftwareFoundation\.Python\.3\.[0-9]+_qbz5n2kfra8p0!Python$' -and
                $target -match '(?i)\\PythonSoftwareFoundation\.Python\.3\.[0-9]+_[^\\]+__qbz5n2kfra8p0\\python3\.[0-9]+\.exe$')
        }
        return $false
    } catch {
        return $false
    }
}

function Get-HermesTrustedWindowsCommandPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('cmd', 'schtasks', 'taskkill', 'icacls', 'ie4uinit', 'ssh')][string]$CommandName)

    try {
        $windows = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
        if ([string]::IsNullOrWhiteSpace($windows)) { return $null }
        $relativePath = $(if ($CommandName -eq 'ssh') { 'System32\OpenSSH\ssh.exe' } else { Join-Path 'System32' ($CommandName + '.exe') })
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $windows $relativePath))
        if (-not (Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath $candidate -RootPath $windows) -or
            -not (Test-HermesPortableExecutableHeader -LiteralPath $candidate -MaximumLength 256MB) -or
            -not (Test-HermesAuthenticodePublisher -LiteralPath $candidate -PublisherPattern '(?i)Microsoft')) { return $null }
        return $candidate
    } catch {
        return $null
    }
}

function Get-HermesRegistryBareCommandCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9-]+$')][string]$CommandName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()][string[]]$PathValues
    )

    try {
        if (@($PathValues).Count -eq 0) {
            return [pscustomobject]@{ Valid = $false; Absent = $false; Reason = 'missing registry PATH value rejected'; Candidates = @() }
        }
        foreach ($pathValue in @($PathValues)) {
            if ($null -eq $pathValue) {
                return [pscustomobject]@{ Valid = $false; Absent = $false; Reason = 'missing registry PATH value rejected'; Candidates = @() }
            }
            foreach ($entry in @(([string]$pathValue).Split([char]';'))) {
                if ([string]::IsNullOrWhiteSpace($entry)) {
                    return [pscustomobject]@{ Valid = $false; Absent = $false; Reason = 'empty registry PATH entry rejected'; Candidates = @() }
                }
                $directory = ConvertTo-HermesComparablePathEntry -PathEntry ([string]$entry)
                if ([string]::IsNullOrWhiteSpace($directory)) {
                    return [pscustomobject]@{ Valid = $false; Absent = $false; Reason = 'invalid registry PATH entry rejected'; Candidates = @() }
                }
                $candidates = New-Object 'System.Collections.Generic.List[string]'
                foreach ($extension in $script:HermesBareCommandExtensions) {
                    $candidate = Join-Path $directory ($CommandName + $extension)
                    if (-not (Test-Path -LiteralPath $candidate)) { continue }
                    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                        return [pscustomobject]@{ Valid = $false; Absent = $false; Reason = 'non-file command candidate rejected'; Candidates = @() }
                    }
                    $candidates.Add([System.IO.Path]::GetFullPath($candidate))
                }
                if ($candidates.Count -gt 0) {
                    return [pscustomobject]@{ Valid = $true; Absent = $false; Reason = $null; Candidates = $candidates.ToArray() }
                }
            }
        }
        return [pscustomobject]@{ Valid = $true; Absent = $true; Reason = $null; Candidates = @() }
    } catch {
        return [pscustomobject]@{ Valid = $false; Absent = $false; Reason = 'registry PATH command inspection failed'; Candidates = @() }
    }
}

function Get-HermesManagedCommandProofKey {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    return [System.IO.Path]::GetFullPath($LiteralPath).ToUpperInvariant()
}

function Test-HermesManagedCommandRecordPathPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string]$LiteralPath
    )

    try {
        $candidate = [System.IO.Path]::GetFullPath($LiteralPath)
        $leaf = Split-Path -Leaf $candidate
        switch ($CommandName) {
            'uv' {
                return [string]::Equals($candidate, [System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.HermesHome) 'bin\uv.exe')), [System.StringComparison]::OrdinalIgnoreCase)
            }
            'node' {
                return [string]::Equals($candidate, [System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.HermesHome) 'node\node.exe')), [System.StringComparison]::OrdinalIgnoreCase)
            }
            'npm' {
                $directory = [System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.HermesHome) 'node'))
                return ([string]::Equals((Split-Path -Parent $candidate), $directory, [System.StringComparison]::OrdinalIgnoreCase) -and $leaf -match '(?i)^npm\.(cmd|ps1)$')
            }
            'npx' {
                $directory = [System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.HermesHome) 'node'))
                return ([string]::Equals((Split-Path -Parent $candidate), $directory, [System.StringComparison]::OrdinalIgnoreCase) -and $leaf -match '(?i)^npx\.(cmd|ps1)$')
            }
            'browser-use' {
                return [string]::Equals($candidate, [System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.HermesHome) 'bin\browser-use.exe')), [System.StringComparison]::OrdinalIgnoreCase)
            }
            'cua-driver' {
                return ($leaf -match '(?i)^cua-driver\.(exe|cmd|ps1)$')
            }
            default { return $false }
        }
    } catch {
        return $false
    }
}

function New-HermesManagedCommandProofRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string]$LiteralPath
    )

    $candidate = [System.IO.Path]::GetFullPath($LiteralPath)
    if (-not (Test-HermesManagedCommandRecordPathPolicy -Plan $Plan -CommandName $CommandName -LiteralPath $candidate) -or
        -not (Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath $candidate -RootPath ([System.IO.Path]::GetPathRoot($candidate)))) {
        throw 'Managed command path rejected'
    }
    $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
    if ([bool]$item.PSIsContainer -or $item.Length -le 0 -or $item.Length -gt 512MB) { throw 'Managed command file rejected' }
    if ([System.IO.Path]::GetExtension($candidate) -ieq '.exe' -and
        -not (Test-HermesPortableExecutableHeader -LiteralPath $candidate -MaximumLength 512MB)) { throw 'Managed command executable header rejected' }
    return [pscustomobject][ordered]@{
        command = $CommandName.ToLowerInvariant()
        path = $candidate
        length = [int64]$item.Length
        sha256 = (ConvertTo-HermesSha256 -LiteralPath $candidate).ToUpperInvariant()
    }
}

function Test-HermesManagedCommandProofRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [AllowNull()]$ManagedCommandProof,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string]$LiteralPath
    )

    try {
        if ($null -eq $ManagedCommandProof) { return $false }
        $key = Get-HermesManagedCommandProofKey -LiteralPath $LiteralPath
        if (-not $ManagedCommandProof.ContainsKey($key)) { return $false }
        $record = $ManagedCommandProof[$key]
        if ([string]$record.command -cne $CommandName.ToLowerInvariant() -or
            -not [string]::Equals([string]$record.path, [System.IO.Path]::GetFullPath($LiteralPath), [System.StringComparison]::OrdinalIgnoreCase) -or
            [int64]$record.length -le 0 -or [int64]$record.length -gt 512MB -or
            [string]$record.sha256 -notmatch '^[0-9A-F]{64}$' -or
            -not (Test-HermesManagedCommandRecordPathPolicy -Plan $Plan -CommandName $CommandName -LiteralPath ([string]$record.path)) -or
            -not (Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath ([string]$record.path) -RootPath ([System.IO.Path]::GetPathRoot([string]$record.path)))) { return $false }
        $item = Get-Item -LiteralPath ([string]$record.path) -Force -ErrorAction Stop
        return ($item.Length -eq [int64]$record.length -and
            [string]::Equals((ConvertTo-HermesSha256 -LiteralPath ([string]$record.path)), [string]$record.sha256, [System.StringComparison]::OrdinalIgnoreCase))
    } catch {
        return $false
    }
}

function Add-HermesManagedCommandProofRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][hashtable]$ManagedCommandProof,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string]$LiteralPath
    )

    $record = New-HermesManagedCommandProofRecord -Plan $Plan -CommandName $CommandName -LiteralPath $LiteralPath
    $ManagedCommandProof[(Get-HermesManagedCommandProofKey -LiteralPath ([string]$record.path))] = $record
    return $record
}

function Assert-HermesFreshManagedCommandSeed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowNull()][string[]]$PathValues
    )

    foreach ($path in @(
        (Join-Path ([string]$Plan.HermesHome) 'bin\uv.exe'),
        (Join-Path ([string]$Plan.HermesHome) 'bin\browser-use.exe'),
        (Join-Path ([string]$Plan.HermesHome) 'node\node.exe'),
        (Join-Path ([string]$Plan.HermesHome) 'node\npm.cmd'),
        (Join-Path ([string]$Plan.HermesHome) 'node\npm.ps1'),
        (Join-Path ([string]$Plan.HermesHome) 'node\npx.cmd'),
        (Join-Path ([string]$Plan.HermesHome) 'node\npx.ps1'),
        (Join-Path ([string]$Plan.HermesHome) 'python'),
        (Join-Path ([string]$Plan.HermesHome) 'uv-tools'),
        (Join-Path ([string]$Plan.HermesHome) 'git\bin\bash.exe'),
        (Join-Path ([string]$Plan.HermesHome) 'git\usr\bin\bash.exe')
    )) {
        if (Test-Path -LiteralPath $path) { throw 'Pre-existing managed command path rejected for a fresh install' }
    }
    if (-not ($Plan.PSObject.Properties.Name -contains 'SkipComputerUse' -and [bool]$Plan.SkipComputerUse)) {
        $cua = Get-HermesRegistryBareCommandCandidates -CommandName 'cua-driver' -PathValues $PathValues
        if (-not $cua.Valid -or -not [bool]$cua.Absent) { throw 'Pre-existing cua-driver command rejected for a fresh install' }
    }
}

function Move-HermesResumeManagedSeedToQuarantine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$State
    )

    if (-not (Test-HermesStateMatchesResumeEnvelope -State $State -Plan $Plan)) {
        throw 'Resume checkpoint envelope does not match the current plan'
    }
    $homeFull = [System.IO.Path]::GetFullPath([string]$Plan.HermesHome).TrimEnd('\', '/')
    $installFull = [System.IO.Path]::GetFullPath([string]$Plan.InstallDir).TrimEnd('\', '/')
    $runtimeFull = [System.IO.Path]::GetFullPath([string]$Plan.RuntimeRoot).TrimEnd('\', '/')
    $launcherAttestationFull = [System.IO.Path]::GetFullPath((Join-Path $runtimeFull 'state\launcher-attestation-v1.json'))
    $targets = @(
        [pscustomobject]@{ Name = 'install-dir'; Path = $installFull },
        [pscustomobject]@{ Name = 'uv.exe'; Path = (Join-Path $homeFull 'bin\uv.exe') },
        [pscustomobject]@{ Name = 'uvx.exe'; Path = (Join-Path $homeFull 'bin\uvx.exe') },
        [pscustomobject]@{ Name = 'browser-use.exe'; Path = (Join-Path $homeFull 'bin\browser-use.exe') },
        [pscustomobject]@{ Name = 'node'; Path = (Join-Path $homeFull 'node') },
        [pscustomobject]@{ Name = 'python'; Path = (Join-Path $homeFull 'python') },
        [pscustomobject]@{ Name = 'uv-tools'; Path = (Join-Path $homeFull 'uv-tools') },
        [pscustomobject]@{ Name = 'git'; Path = (Join-Path $homeFull 'git') },
        [pscustomobject]@{ Name = 'launcher-attestation-v1.json'; Path = $launcherAttestationFull }
    )
    $existing = @($targets | Where-Object { Test-Path -LiteralPath ([string]$_.Path) })
    if ($existing.Count -eq 0) {
        return [pscustomobject]@{ Changed = $false; Root = $null; Items = @() }
    }

    foreach ($target in $existing) {
        $sourceFull = [System.IO.Path]::GetFullPath([string]$target.Path).TrimEnd('\', '/')
        $underHome = $sourceFull.StartsWith($homeFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
        $isLauncherAttestation = [string]::Equals($sourceFull, $launcherAttestationFull, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $underHome -and -not [string]::Equals($sourceFull, $installFull, [System.StringComparison]::OrdinalIgnoreCase) -and -not $isLauncherAttestation) {
            throw 'Resume recovery target escaped the approved managed paths'
        }
        if ([string]::Equals($sourceFull, $homeFull, [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($sourceFull, $runtimeFull, [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($sourceFull, [System.IO.Path]::GetPathRoot($sourceFull), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Resume recovery target is too broad'
        }
        $parent = Split-Path -Parent $sourceFull
        if (-not (Test-HermesOrdinaryDirectoryPathUnderRoot -LiteralPath $parent -RootPath ([System.IO.Path]::GetPathRoot($parent)))) {
            throw 'Resume recovery target parent is not an ordinary directory path'
        }
    }

    $recoveryRoot = Join-Path $runtimeFull 'recovery'
    if (-not (Test-Path -LiteralPath $recoveryRoot -PathType Container)) { New-Item -ItemType Directory -Path $recoveryRoot -Force | Out-Null }
    $quarantineRoot = Join-Path $recoveryRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $quarantineRoot | Out-Null
    $moved = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($target in $existing) {
            $source = [System.IO.Path]::GetFullPath([string]$target.Path)
            $destination = Join-Path $quarantineRoot ([string]$target.Name)
            $item = Get-Item -LiteralPath $source -Force -ErrorAction Stop
            if ([bool]$item.PSIsContainer) { [System.IO.Directory]::Move($source, $destination) } else { [System.IO.File]::Move($source, $destination) }
            $moved.Add([pscustomobject]@{ Name = [string]$target.Name; Source = $source; Destination = $destination; Directory = [bool]$item.PSIsContainer })
        }
        $manifest = [pscustomobject][ordered]@{
            schema_version = 1
            created_at = (Get-Date).ToUniversalTime().ToString('o')
            plan_fingerprint = [string]$Plan.Fingerprint
            items = @($moved | ForEach-Object { [pscustomobject][ordered]@{ name = $_.Name; source = $_.Source; destination = $_.Destination } })
        }
        [System.IO.File]::WriteAllText((Join-Path $quarantineRoot 'recovery.json'), ($manifest | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
    } catch {
        $movedArray = $moved.ToArray()
        for ($index = $movedArray.Count - 1; $index -ge 0; $index--) {
            $entry = $movedArray[$index]
            try {
                if ([bool]$entry.Directory -and (Test-Path -LiteralPath ([string]$entry.Destination) -PathType Container)) { [System.IO.Directory]::Move([string]$entry.Destination, [string]$entry.Source) }
                elseif (Test-Path -LiteralPath ([string]$entry.Destination) -PathType Leaf) { [System.IO.File]::Move([string]$entry.Destination, [string]$entry.Source) }
            } catch {}
        }
        throw
    }
    return [pscustomobject]@{ Changed = $true; Root = $quarantineRoot; Items = $moved.ToArray() }
}

function Test-HermesManagedAbsoluteCommandBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][hashtable]$ManagedCommandProof
    )

    foreach ($record in @($ManagedCommandProof.Values)) {
        if (-not (Test-HermesManagedCommandProofRecord -Plan $Plan -ManagedCommandProof $ManagedCommandProof -CommandName ([string]$record.command) -LiteralPath ([string]$record.path))) {
            return [pscustomobject]@{ Valid = $false; Reason = 'Managed command proof record is missing or changed' }
        }
    }
    foreach ($bashPath in @(
        (Join-Path ([string]$Plan.HermesHome) 'git\bin\bash.exe'),
        (Join-Path ([string]$Plan.HermesHome) 'git\usr\bin\bash.exe')
    )) {
        if (Test-Path -LiteralPath $bashPath) {
            return [pscustomobject]@{ Valid = $false; Reason = 'HermesHome managed Git Bash is not trusted' }
        }
    }
    foreach ($specification in @(
        [pscustomobject]@{ Command = 'uv'; Path = (Join-Path ([string]$Plan.HermesHome) 'bin\uv.exe') },
        [pscustomobject]@{ Command = 'browser-use'; Path = (Join-Path ([string]$Plan.HermesHome) 'bin\browser-use.exe') },
        [pscustomobject]@{ Command = 'node'; Path = (Join-Path ([string]$Plan.HermesHome) 'node\node.exe') },
        [pscustomobject]@{ Command = 'npm'; Path = (Join-Path ([string]$Plan.HermesHome) 'node\npm.cmd') },
        [pscustomobject]@{ Command = 'npm'; Path = (Join-Path ([string]$Plan.HermesHome) 'node\npm.ps1') },
        [pscustomobject]@{ Command = 'npx'; Path = (Join-Path ([string]$Plan.HermesHome) 'node\npx.cmd') },
        [pscustomobject]@{ Command = 'npx'; Path = (Join-Path ([string]$Plan.HermesHome) 'node\npx.ps1') }
    )) {
        if ((Test-Path -LiteralPath ([string]$specification.Path)) -and
            -not (Test-HermesManagedCommandProofRecord -Plan $Plan -ManagedCommandProof $ManagedCommandProof -CommandName ([string]$specification.Command) -LiteralPath ([string]$specification.Path))) {
            return [pscustomobject]@{ Valid = $false; Reason = 'Managed command is not bound to same-run or attested bytes' }
        }
    }
    $browserUsePath = Join-Path ([string]$Plan.HermesHome) 'bin\browser-use.exe'
    if (Test-Path -LiteralPath $browserUsePath -PathType Leaf) {
        $toolDirectory = Join-Path ([string]$Plan.HermesHome) 'uv-tools'
        if (-not (Test-HermesOrdinaryDirectoryPathUnderRoot -LiteralPath $toolDirectory -RootPath ([string]$Plan.HermesHome))) {
            return [pscustomobject]@{ Valid = $false; Reason = 'Managed browser-use tool environment is missing or unsafe' }
        }
    }
    return [pscustomobject]@{ Valid = $true; Reason = $null }
}

function Update-HermesManagedCommandProofAfterStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][hashtable]$ManagedCommandProof,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowNull()][string[]]$PathValues
    )

    $specifications = @()
    if ($Stage -eq 'uv') {
        $specifications = @([pscustomobject]@{ Command = 'uv'; Path = (Join-Path ([string]$Plan.HermesHome) 'bin\uv.exe') })
    } elseif (@('node', 'desktop') -contains $Stage) {
        $specifications = @(
            [pscustomobject]@{ Command = 'node'; Path = (Join-Path ([string]$Plan.HermesHome) 'node\node.exe') },
            [pscustomobject]@{ Command = 'npm'; Path = (Join-Path ([string]$Plan.HermesHome) 'node\npm.cmd') },
            [pscustomobject]@{ Command = 'npm'; Path = (Join-Path ([string]$Plan.HermesHome) 'node\npm.ps1') },
            [pscustomobject]@{ Command = 'npx'; Path = (Join-Path ([string]$Plan.HermesHome) 'node\npx.cmd') },
            [pscustomobject]@{ Command = 'npx'; Path = (Join-Path ([string]$Plan.HermesHome) 'node\npx.ps1') }
        )
    } elseif ($Stage -eq 'node-deps') {
        $specifications = @(
            [pscustomobject]@{ Command = 'browser-use'; Path = (Join-Path ([string]$Plan.HermesHome) 'bin\browser-use.exe') }
        )
    }
    foreach ($specification in $specifications) {
        if (Test-Path -LiteralPath ([string]$specification.Path) -PathType Leaf) {
            [void](Add-HermesManagedCommandProofRecord -Plan $Plan -ManagedCommandProof $ManagedCommandProof -CommandName ([string]$specification.Command) -LiteralPath ([string]$specification.Path))
        }
    }
    if ($Stage -eq 'node-deps' -and -not ($Plan.PSObject.Properties.Name -contains 'SkipComputerUse' -and [bool]$Plan.SkipComputerUse)) {
        $cua = Get-HermesRegistryBareCommandCandidates -CommandName 'cua-driver' -PathValues $PathValues
        if (-not $cua.Valid) { throw 'Post-stage cua-driver resolution rejected' }
        foreach ($candidate in @($cua.Candidates)) {
            [void](Add-HermesManagedCommandProofRecord -Plan $Plan -ManagedCommandProof $ManagedCommandProof -CommandName 'cua-driver' -LiteralPath ([string]$candidate))
        }
    }
}

function Test-HermesTrustedBareCommandCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$TrustedGitPath,
        [AllowNull()]$ManagedCommandProof
    )

    try {
        $candidate = [System.IO.Path]::GetFullPath($LiteralPath)
        $leaf = Split-Path -Leaf $candidate
        $programRoots = @(
            [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
            [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }

        if ($CommandName -eq 'git') {
            $validated = Test-HermesGitCandidate -LiteralPath $candidate -RequireValidSignature
            return (-not [string]::IsNullOrWhiteSpace($validated) -and
                [string]::Equals([System.IO.Path]::GetFullPath($validated), [System.IO.Path]::GetFullPath($TrustedGitPath), [System.StringComparison]::OrdinalIgnoreCase))
        }

        if (@('cmd', 'schtasks', 'taskkill', 'icacls', 'ie4uinit') -contains $CommandName) {
            $trustedWindowsCommand = Get-HermesTrustedWindowsCommandPath -CommandName $CommandName
            return (-not [string]::IsNullOrWhiteSpace($trustedWindowsCommand) -and
                [string]::Equals($candidate, $trustedWindowsCommand, [System.StringComparison]::OrdinalIgnoreCase))
        }

        if ($CommandName -eq 'ssh') {
            $trustedWindowsSsh = Get-HermesTrustedWindowsCommandPath -CommandName 'ssh'
            if (-not [string]::IsNullOrWhiteSpace($trustedWindowsSsh) -and
                [string]::Equals($candidate, $trustedWindowsSsh, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            $gitDirectory = Split-Path -Parent $TrustedGitPath
            $gitRoot = Split-Path -Parent $gitDirectory
            $bundledSsh = [System.IO.Path]::GetFullPath((Join-Path $gitRoot 'usr\bin\ssh.exe'))
            return ([string]::Equals($candidate, $bundledSsh, [System.StringComparison]::OrdinalIgnoreCase) -and
                (Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath $candidate -RootPath $gitRoot) -and
                (Test-HermesPortableExecutableHeader -LiteralPath $candidate -MaximumLength 128MB))
        }

        if ($CommandName -eq 'winget') {
            return ($leaf -ieq 'winget.exe' -and (Test-HermesWindowsAppExecutionAlias -LiteralPath $candidate -ExpectedName 'winget.exe'))
        }

        if ($CommandName -eq 'python') {
            if ($leaf -ieq 'python.exe' -and (Test-HermesWindowsAppExecutionAlias -LiteralPath $candidate -ExpectedName 'python.exe')) { return $true }
            foreach ($root in $programRoots) {
                if ($leaf -ieq 'python.exe' -and
                    (Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath $candidate -RootPath $root) -and
                    (Test-HermesPortableExecutableHeader -LiteralPath $candidate -MaximumLength 256MB) -and
                    (Test-HermesAuthenticodePublisher -LiteralPath $candidate -PublisherPattern '(?i)Python Software Foundation')) { return $true }
            }
            return $false
        }

        if ($CommandName -eq 'uv') {
            $managedUv = [System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.HermesHome) 'bin\uv.exe'))
            if ([string]::Equals($candidate, $managedUv, [System.StringComparison]::OrdinalIgnoreCase)) {
                return ((Test-HermesManagedCommandProofRecord -Plan $Plan -ManagedCommandProof $ManagedCommandProof -CommandName 'uv' -LiteralPath $candidate) -and
                    (Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath $candidate -RootPath ([string]$Plan.HermesHome)) -and
                    (Test-HermesPortableExecutableHeader -LiteralPath $candidate -MaximumLength 256MB))
            }
            foreach ($root in $programRoots) {
                if ($leaf -ieq 'uv.exe' -and
                    (Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath $candidate -RootPath $root) -and
                    (Test-HermesPortableExecutableHeader -LiteralPath $candidate -MaximumLength 256MB)) { return $true }
            }
            return $false
        }

        if ($CommandName -eq 'node') {
            if ($leaf -ine 'node.exe') { return $false }
            $managedNode = [System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.HermesHome) 'node\node.exe'))
            $allowed = $false
            if ([string]::Equals($candidate, $managedNode, [System.StringComparison]::OrdinalIgnoreCase)) {
                $allowed = Test-HermesManagedCommandProofRecord -Plan $Plan -ManagedCommandProof $ManagedCommandProof -CommandName 'node' -LiteralPath $candidate
            }
            if (-not $allowed) {
                foreach ($root in $programRoots) {
                    if (Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath $candidate -RootPath $root) { $allowed = $true; break }
                }
            }
            return ($allowed -and
                (Test-HermesPortableExecutableHeader -LiteralPath $candidate -MaximumLength 512MB) -and
                (Test-HermesAuthenticodePublisher -LiteralPath $candidate -PublisherPattern '(?i)(OpenJS Foundation|Node\.js Foundation)'))
        }

        if (@('npm', 'npx') -contains $CommandName) {
            if ($leaf -notmatch ('(?i)^' + [regex]::Escape($CommandName) + '\.(cmd|ps1)$')) { return $false }
            $directory = Split-Path -Parent $candidate
            $candidateRoot = $null
            $managedNodeRoot = [System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.HermesHome) 'node'))
            if (Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath $candidate -RootPath $managedNodeRoot) {
                $candidateRoot = $managedNodeRoot
            } else {
                foreach ($root in $programRoots) {
                    if (Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath $candidate -RootPath $root) { $candidateRoot = $root; break }
                }
            }
            if ([string]::IsNullOrWhiteSpace($candidateRoot)) { return $false }
            $cmdSibling = Join-Path $directory ($CommandName + '.cmd')
            if (-not (Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath $cmdSibling -RootPath $candidateRoot)) { return $false }
            if ([string]::Equals($candidateRoot, $managedNodeRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
                (-not (Test-HermesManagedCommandProofRecord -Plan $Plan -ManagedCommandProof $ManagedCommandProof -CommandName $CommandName -LiteralPath $candidate) -or
                 -not (Test-HermesManagedCommandProofRecord -Plan $Plan -ManagedCommandProof $ManagedCommandProof -CommandName $CommandName -LiteralPath $cmdSibling))) { return $false }
            $nodePath = Join-Path $directory 'node.exe'
            return (Test-HermesTrustedBareCommandCandidate -Plan $Plan -CommandName 'node' -LiteralPath $nodePath -TrustedGitPath $TrustedGitPath -ManagedCommandProof $ManagedCommandProof)
        }

        if (@('rg', 'ffmpeg') -contains $CommandName) {
            if ($leaf -ine ($CommandName + '.exe')) { return $false }
            foreach ($root in $programRoots) {
                if ((Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath $candidate -RootPath $root) -and
                    (Test-HermesPortableExecutableHeader -LiteralPath $candidate -MaximumLength 512MB)) { return $true }
            }
            $chocolateyRoot = [System.IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'chocolatey\bin'))
            return ((Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath $candidate -RootPath $chocolateyRoot) -and
                (Test-HermesPortableExecutableHeader -LiteralPath $candidate -MaximumLength 512MB))
        }

        if ($CommandName -eq 'choco') {
            $chocoPath = [System.IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'chocolatey\bin\choco.exe'))
            return ($leaf -ieq 'choco.exe' -and
                [string]::Equals($candidate, $chocoPath, [System.StringComparison]::OrdinalIgnoreCase) -and
                (Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath $candidate -RootPath (Split-Path -Parent $chocoPath)) -and
                (Test-HermesPortableExecutableHeader -LiteralPath $candidate -MaximumLength 64MB))
        }

        if ($CommandName -eq 'cua-driver') {
            return (Test-HermesManagedCommandProofRecord -Plan $Plan -ManagedCommandProof $ManagedCommandProof -CommandName 'cua-driver' -LiteralPath $candidate)
        }
        if ($CommandName -eq 'scoop') { return $false }
        return $false
    } catch {
        return $false
    }
}

function Test-HermesStageBareCommandResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$TrustedGitPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowNull()][string[]]$PathValues,
        [AllowNull()]$ManagedCommandProof
    )

    if (-not $script:HermesStageBareCommandNames.ContainsKey($Stage)) {
        return [pscustomobject]@{ Valid = $false; Reason = 'unreviewed installer stage'; Command = $null; ResolvedPaths = @(); MissingCommands = @() }
    }
    $commands = @()
    $missingCommands = New-Object 'System.Collections.Generic.List[string]'
    $resolvedPaths = New-Object 'System.Collections.Generic.List[string]'
    $configuredCommands = $script:HermesStageBareCommandNames[$Stage]
    if ($null -ne $configuredCommands) { $commands = @($configuredCommands) }
    foreach ($commandName in $commands) {
        if ($commandName -eq 'cua-driver' -and $Plan.PSObject.Properties.Name -contains 'SkipComputerUse' -and [bool]$Plan.SkipComputerUse) { continue }
        $resolution = Get-HermesRegistryBareCommandCandidates -CommandName ([string]$commandName) -PathValues $PathValues
        if (-not $resolution.Valid) {
            return [pscustomobject]@{ Valid = $false; Reason = [string]$resolution.Reason; Command = [string]$commandName; ResolvedPaths = $resolvedPaths.ToArray(); MissingCommands = $missingCommands.ToArray() }
        }
        if ([bool]$resolution.Absent) {
            $missingCommands.Add([string]$commandName)
            continue
        }
        foreach ($candidate in @($resolution.Candidates)) {
            if (-not (Test-HermesTrustedBareCommandCandidate -Plan $Plan -CommandName ([string]$commandName) -LiteralPath ([string]$candidate) -TrustedGitPath $TrustedGitPath -ManagedCommandProof $ManagedCommandProof)) {
                return [pscustomobject]@{ Valid = $false; Reason = 'untrusted registry PATH command candidate'; Command = [string]$commandName; ResolvedPaths = $resolvedPaths.ToArray(); MissingCommands = $missingCommands.ToArray() }
            }
            $resolvedPaths.Add([string]$candidate)
        }
    }
    return [pscustomobject]@{ Valid = $true; Reason = $null; Command = $null; ResolvedPaths = $resolvedPaths.ToArray(); MissingCommands = $missingCommands.ToArray() }
}

function Read-HermesBootstrapMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallDir)

    $path = Join-Path $InstallDir '.hermes-bootstrap-complete'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]@{ Path = $path; Valid = $false; SchemaVersion = $null; PinnedCommit = $null; Reason = 'marker missing' } }
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 65536) {
            return [pscustomobject]@{ Path = $path; Valid = $false; SchemaVersion = $null; PinnedCommit = $null; Reason = 'marker file rejected' }
        }
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $marker = $strictUtf8.GetString([System.IO.File]::ReadAllBytes($path)) | ConvertFrom-Json
        $valid = ([int]$marker.schemaVersion -eq 1 -and [string]$marker.pinnedCommit -match '^[0-9a-fA-F]{40}$')
        return [pscustomobject]@{ Path = $path; Valid = $valid; SchemaVersion = [int]$marker.schemaVersion; PinnedCommit = [string]$marker.pinnedCommit; Reason = $(if ($valid) { $null } else { 'marker schema or commit invalid' }) }
    } catch {
        return [pscustomobject]@{ Path = $path; Valid = $false; SchemaVersion = $null; PinnedCommit = $null; Reason = 'marker JSON invalid' }
    }
}

function Get-HermesManagedLauncherExcludeState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallDir)

    $gitDirectory = Join-Path $InstallDir '.git'
    $infoDirectory = Join-Path $gitDirectory 'info'
    $excludePath = Join-Path $infoDirectory 'exclude'
    foreach ($directory in @($gitDirectory, $infoDirectory)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            return [pscustomobject]@{ Compatible = $false; Complete = $false; Reason = 'Git metadata directory missing'; ExcludePath = $excludePath; Exists = $false; OriginalBytes = [byte[]]@(); Text = ''; ActivePatterns = @() }
        }
        $item = Get-Item -LiteralPath $directory -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{ Compatible = $false; Complete = $false; Reason = 'Git metadata reparse point rejected'; ExcludePath = $excludePath; Exists = $false; OriginalBytes = [byte[]]@(); Text = ''; ActivePatterns = @() }
        }
    }

    $exists = Test-Path -LiteralPath $excludePath
    $bytes = [byte[]]@()
    $text = ''
    if ($exists) {
        if (-not (Test-Path -LiteralPath $excludePath -PathType Leaf)) {
            return [pscustomobject]@{ Compatible = $false; Complete = $false; Reason = 'Git exclude is not a regular file'; ExcludePath = $excludePath; Exists = $true; OriginalBytes = [byte[]]@(); Text = ''; ActivePatterns = @() }
        }
        $excludeItem = Get-Item -LiteralPath $excludePath -Force
        if (($excludeItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $excludeItem.Length -gt 1048576) {
            return [pscustomobject]@{ Compatible = $false; Complete = $false; Reason = 'Git exclude file rejected'; ExcludePath = $excludePath; Exists = $true; OriginalBytes = [byte[]]@(); Text = ''; ActivePatterns = @() }
        }
        try {
            $bytes = [System.IO.File]::ReadAllBytes($excludePath)
            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $text = $strictUtf8.GetString($bytes)
        } catch {
            return [pscustomobject]@{ Compatible = $false; Complete = $false; Reason = 'Git exclude is not strict UTF-8'; ExcludePath = $excludePath; Exists = $true; OriginalBytes = [byte[]]@(); Text = ''; ActivePatterns = @() }
        }
    }

    $active = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in @($text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        $active.Add($line)
    }
    $activeArray = @($active.ToArray())
    $unique = @($activeArray | Select-Object -Unique)
    $compatible = ($unique.Count -eq $activeArray.Count)
    foreach ($pattern in $activeArray) {
        if ($script:HermesManagedLauncherPatterns -cnotcontains $pattern) { $compatible = $false }
    }
    $complete = ($compatible -and $activeArray.Count -eq $script:HermesManagedLauncherPatterns.Count)
    return [pscustomobject]@{
        Compatible = $compatible
        Complete = $complete
        Reason = $(if ($compatible) { $null } else { 'Unexpected active Git exclude pattern' })
        ExcludePath = $excludePath
        Exists = $exists
        OriginalBytes = $bytes
        Text = $text
        ActivePatterns = $activeArray
    }
}

function Test-HermesPortableExecutableHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [ValidateRange(65536, 1073741824)][int64]$MaximumLength = 16MB
    )

    try {
        if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) { return $false }
        $item = Get-Item -LiteralPath $LiteralPath -Force
        if ([bool]$item.PSIsContainer -or
            ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $item.Length -lt 64 -or $item.Length -gt $MaximumLength) { return $false }
        $stream = [System.IO.File]::Open($LiteralPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $dosHeader = New-Object byte[] 64
            $offset = 0
            while ($offset -lt $dosHeader.Length) {
                $count = $stream.Read($dosHeader, $offset, $dosHeader.Length - $offset)
                if ($count -le 0) { return $false }
                $offset += $count
            }
            if ($dosHeader[0] -ne 0x4D -or $dosHeader[1] -ne 0x5A) { return $false }
            $peOffset = [int64][BitConverter]::ToUInt32($dosHeader, 0x3C)
            if ($peOffset -lt 0x40 -or $peOffset -gt ($stream.Length - 26)) { return $false }
            [void]$stream.Seek($peOffset, [System.IO.SeekOrigin]::Begin)
            $peHeader = New-Object byte[] 26
            $offset = 0
            while ($offset -lt $peHeader.Length) {
                $count = $stream.Read($peHeader, $offset, $peHeader.Length - $offset)
                if ($count -le 0) { return $false }
                $offset += $count
            }
            if ($peHeader[0] -ne 0x50 -or $peHeader[1] -ne 0x45 -or $peHeader[2] -ne 0 -or $peHeader[3] -ne 0) { return $false }
            $machine = [BitConverter]::ToUInt16($peHeader, 4)
            $sectionCount = [BitConverter]::ToUInt16($peHeader, 6)
            $optionalHeaderSize = [BitConverter]::ToUInt16($peHeader, 20)
            $characteristics = [BitConverter]::ToUInt16($peHeader, 22)
            $optionalMagic = [BitConverter]::ToUInt16($peHeader, 24)
            if (@(0x014C, 0x8664, 0xAA64) -notcontains [int]$machine -or
                $sectionCount -lt 1 -or $sectionCount -gt 96 -or
                $optionalHeaderSize -lt 96 -or $optionalHeaderSize -gt 512 -or
                ($characteristics -band 0x0002) -eq 0 -or
                @(0x010B, 0x020B) -notcontains [int]$optionalMagic -or
                ($peOffset + 24 + $optionalHeaderSize) -gt $stream.Length) { return $false }
            return $true
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $false
    }
}

function Test-HermesManagedLauncherSources {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallDir)

    $sourceDirectory = Join-Path $InstallDir 'venv\Scripts'
    $safety = Test-HermesSafeTargetPath -LiteralPath $sourceDirectory -Label 'Hermes launcher source'
    if (-not $safety.Safe -or -not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
        return [pscustomobject]@{ Valid = $false; Reason = 'Managed launcher source directory missing or unsafe'; Files = @() }
    }
    $directoryItem = Get-Item -LiteralPath $sourceDirectory -Force
    if (($directoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [pscustomobject]@{ Valid = $false; Reason = 'Managed launcher source directory is a reparse point'; Files = @() }
    }

    $files = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $script:HermesManagedLauncherNames) {
        $path = Join-Path $sourceDirectory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return [pscustomobject]@{ Valid = $false; Reason = "Managed launcher source missing: $name"; Files = @() }
        }
        $item = Get-Item -LiteralPath $path -Force
        if (-not (Test-HermesPortableExecutableHeader -LiteralPath $path)) {
            return [pscustomobject]@{ Valid = $false; Reason = "Managed launcher source metadata rejected: $name"; Files = @() }
        }
        $files.Add([pscustomobject]@{ Name = $name; Length = [int64]$item.Length; Sha256 = (ConvertTo-HermesSha256 -LiteralPath $path) })
    }
    return [pscustomobject]@{ Valid = $true; Reason = $null; Files = $files.ToArray() }
}

function Test-HermesManagedLaunchers {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallDir)

    $launcherDirectory = Join-Path $InstallDir 'bin'
    $sourceDirectory = Join-Path $InstallDir 'venv\Scripts'
    foreach ($path in @($launcherDirectory, $sourceDirectory)) {
        $safety = Test-HermesSafeTargetPath -LiteralPath $path -Label 'Hermes launcher'
        if (-not $safety.Safe -or -not (Test-Path -LiteralPath $path -PathType Container)) {
            return [pscustomobject]@{ Valid = $false; Reason = 'Managed launcher directory missing or unsafe'; LauncherDirectory = $launcherDirectory; Files = @() }
        }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{ Valid = $false; Reason = 'Managed launcher directory is a reparse point'; LauncherDirectory = $launcherDirectory; Files = @() }
        }
    }

    $children = @(Get-ChildItem -LiteralPath $launcherDirectory -Force -ErrorAction Stop)
    if ($children.Count -ne $script:HermesManagedLauncherNames.Count) {
        return [pscustomobject]@{ Valid = $false; Reason = 'Managed launcher directory has unexpected entries'; LauncherDirectory = $launcherDirectory; Files = @() }
    }

    $verifiedFiles = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $script:HermesManagedLauncherNames) {
        $targetMatches = @($children | Where-Object { [string]$_.Name -ceq $name })
        $targetPath = Join-Path $launcherDirectory $name
        $sourcePath = Join-Path $sourceDirectory $name
        if ($targetMatches.Count -ne 1 -or -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            return [pscustomobject]@{ Valid = $false; Reason = "Managed launcher missing: $name"; LauncherDirectory = $launcherDirectory; Files = @() }
        }
        $target = $targetMatches[0]
        $source = Get-Item -LiteralPath $sourcePath -Force
        if ([bool]$target.PSIsContainer -or [bool]$source.PSIsContainer -or
            ($target.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($source.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not (Test-HermesPortableExecutableHeader -LiteralPath $targetPath) -or
            -not (Test-HermesPortableExecutableHeader -LiteralPath $sourcePath) -or
            $target.Length -ne $source.Length) {
            return [pscustomobject]@{ Valid = $false; Reason = "Managed launcher metadata mismatch: $name"; LauncherDirectory = $launcherDirectory; Files = @() }
        }
        $targetHash = ConvertTo-HermesSha256 -LiteralPath $targetPath
        $sourceHash = ConvertTo-HermesSha256 -LiteralPath $sourcePath
        if (-not $targetHash.Equals($sourceHash, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Valid = $false; Reason = "Managed launcher hash mismatch: $name"; LauncherDirectory = $launcherDirectory; Files = @() }
        }
        $verifiedFiles.Add([pscustomobject]@{ Name = $name; Length = [int64]$target.Length; Sha256 = $targetHash })
    }

    return [pscustomobject]@{ Valid = $true; Reason = $null; LauncherDirectory = $launcherDirectory; Files = $verifiedFiles.ToArray() }
}

function Test-HermesExactPropertyNames {
    [CmdletBinding()]
    param([AllowNull()]$InputObject, [Parameter(Mandatory = $true)][string[]]$Names)

    if ($null -eq $InputObject) { return $false }
    $actual = @($InputObject.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count) { return $false }
    for ($index = 0; $index -lt $Names.Count; $index++) {
        if ([string]$actual[$index] -cne [string]$Names[$index]) { return $false }
    }
    return $true
}

function Get-HermesLauncherPathBindingSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)

    $parts = @(
        [System.IO.Path]::GetFullPath([string]$Plan.HermesHome).TrimEnd('\', '/').ToUpperInvariant(),
        [System.IO.Path]::GetFullPath([string]$Plan.InstallDir).TrimEnd('\', '/').ToUpperInvariant(),
        [System.IO.Path]::GetFullPath([string]$Plan.RuntimeRoot).TrimEnd('\', '/').ToUpperInvariant()
    )
    return ConvertTo-HermesSha256 -Text ($parts -join ([char]0))
}

function ConvertTo-HermesLauncherAttestationBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Attestation)

    $managedCommands = @($Attestation.managedCommands | ForEach-Object {
        [pscustomobject][ordered]@{
            command = ([string]$_.command).ToLowerInvariant()
            path = [System.IO.Path]::GetFullPath([string]$_.path)
            length = [int64]$_.length
            sha256 = ([string]$_.sha256).ToUpperInvariant()
        }
    })
    $launchers = @($Attestation.launchers | ForEach-Object {
        [pscustomobject][ordered]@{
            name = [string]$_.name
            length = [int64]$_.length
            sha256 = ([string]$_.sha256).ToUpperInvariant()
        }
    })
    $canonical = [pscustomobject][ordered]@{
        schemaVersion = 1
        contract = 'hermes-managed-launchers-and-commands-v1'
        pathBindingSha256 = ([string]$Attestation.pathBindingSha256).ToUpperInvariant()
        expectedCommit = ([string]$Attestation.expectedCommit).ToLowerInvariant()
        installerSha256 = ([string]$Attestation.installerSha256).ToUpperInvariant()
        managedCommands = $managedCommands
        launchers = $launchers
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    return $utf8.GetBytes(($canonical | ConvertTo-Json -Depth 6 -Compress))
}

function Test-HermesLauncherAttestationStorage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Paths)

    try {
        $runtimeFull = [System.IO.Path]::GetFullPath([string]$Paths.RuntimeRoot)
        $stateFull = [System.IO.Path]::GetFullPath([string]$Paths.StateDir)
        $fileFull = [System.IO.Path]::GetFullPath([string]$Paths.LauncherAttestationFile)
        if (-not [string]::Equals((Split-Path -Parent $fileFull), $stateFull, [System.StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $fileFull) -cne 'launcher-attestation-v1.json') { return $false }
        foreach ($directory in @($runtimeFull, $stateFull)) {
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return $false }
            $item = Get-Item -LiteralPath $directory -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        $safety = Test-HermesSafeTargetPath -LiteralPath $fileFull -Label 'launcher attestation'
        return [bool]$safety.Safe
    } catch { return $false }
}

function Read-HermesLauncherAttestation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Paths)

    $path = [string]$Paths.LauncherAttestationFile
    $failure = {
        param([string]$Reason, [bool]$Exists)
        return [pscustomobject]@{ Valid = $false; Reason = $Reason; Exists = $Exists; Path = $path; Bytes = [byte[]]@(); Attestation = $null }
    }
    if (-not (Test-HermesLauncherAttestationStorage -Paths $Paths)) { return & $failure 'attestation storage rejected' $false }
    if (-not (Test-Path -LiteralPath $path)) { return & $failure 'attestation missing' $false }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return & $failure 'attestation is not a file' $true }

    try {
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -le 0 -or $item.Length -gt 65536) {
            return & $failure 'attestation file rejected' $true
        }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $attestation = $strictUtf8.GetString($bytes) | ConvertFrom-Json
        if (-not (Test-HermesExactPropertyNames -InputObject $attestation -Names @('schemaVersion', 'contract', 'pathBindingSha256', 'expectedCommit', 'installerSha256', 'managedCommands', 'launchers')) -or
            [int]$attestation.schemaVersion -ne 1 -or
            [string]$attestation.contract -cne 'hermes-managed-launchers-and-commands-v1' -or
            [string]$attestation.pathBindingSha256 -notmatch '^[0-9A-F]{64}$' -or
            [string]$attestation.expectedCommit -notmatch '^[0-9a-f]{40}$' -or
            [string]$attestation.installerSha256 -notmatch '^[0-9A-F]{64}$') {
            return & $failure 'attestation schema rejected' $true
        }
        $managedRecords = @($attestation.managedCommands)
        if ($managedRecords.Count -gt 16) { return & $failure 'attestation managed command count rejected' $true }
        $seenManagedPaths = @{}
        foreach ($managedRecord in $managedRecords) {
            if (-not (Test-HermesExactPropertyNames -InputObject $managedRecord -Names @('command', 'path', 'length', 'sha256')) -or
                [string]$managedRecord.command -notmatch '^(uv|node|npm|npx|browser-use|cua-driver)$' -or
                [string]$managedRecord.path -notmatch '^[A-Za-z]:[\\/]' -or
                [int64]$managedRecord.length -le 0 -or [int64]$managedRecord.length -gt 512MB -or
                [string]$managedRecord.sha256 -notmatch '^[0-9A-F]{64}$') {
                return & $failure 'attestation managed command record rejected' $true
            }
            $managedKey = [System.IO.Path]::GetFullPath([string]$managedRecord.path).ToUpperInvariant()
            if ($seenManagedPaths.ContainsKey($managedKey)) { return & $failure 'attestation duplicate managed command path rejected' $true }
            $seenManagedPaths[$managedKey] = $true
        }
        $records = @($attestation.launchers)
        if ($records.Count -ne $script:HermesManagedLauncherNames.Count) { return & $failure 'attestation launcher count rejected' $true }
        for ($index = 0; $index -lt $records.Count; $index++) {
            $record = $records[$index]
            if (-not (Test-HermesExactPropertyNames -InputObject $record -Names @('name', 'length', 'sha256')) -or
                [string]$record.name -cne [string]$script:HermesManagedLauncherNames[$index] -or
                [int64]$record.length -lt 64 -or [int64]$record.length -gt 16MB -or
                [string]$record.sha256 -notmatch '^[0-9A-F]{64}$') {
                return & $failure 'attestation launcher record rejected' $true
            }
        }
        $canonicalBytes = ConvertTo-HermesLauncherAttestationBytes -Attestation $attestation
        if ([Convert]::ToBase64String($canonicalBytes) -cne [Convert]::ToBase64String($bytes)) {
            return & $failure 'attestation is not canonical' $true
        }
        return [pscustomobject]@{ Valid = $true; Reason = $null; Exists = $true; Path = $path; Bytes = $bytes; Attestation = $attestation }
    } catch {
        return & $failure 'attestation JSON rejected' $true
    }
}

function New-HermesLauncherAttestation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$InstallerSha256,
        [Parameter(Mandatory = $true)]$FreshCheckoutProof,
        [AllowNull()]$ManagedCommandProof
    )

    if ($ExpectedCommit -notmatch '^[0-9a-fA-F]{40}$' -or $InstallerSha256 -notmatch '^[0-9a-fA-F]{64}$' -or
        $FreshCheckoutProof.PSObject.Properties.Name -notcontains 'InstallDir' -or
        $FreshCheckoutProof.PSObject.Properties.Name -notcontains 'ExpectedCommit' -or
        -not [string]::Equals([System.IO.Path]::GetFullPath([string]$FreshCheckoutProof.InstallDir), [System.IO.Path]::GetFullPath([string]$Plan.InstallDir), [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$FreshCheckoutProof.ExpectedCommit, $ExpectedCommit, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Fresh checkout proof cannot authorize launcher attestation'
    }
    $launchers = Test-HermesManagedLaunchers -InstallDir ([string]$Plan.InstallDir)
    if (-not $launchers.Valid) { throw [string]$launchers.Reason }
    $records = @($launchers.Files | ForEach-Object {
        [pscustomobject][ordered]@{
            name = [string]$_.Name
            length = [int64]$_.Length
            sha256 = ([string]$_.Sha256).ToUpperInvariant()
        }
    })
    $managedRecords = @()
    if ($null -ne $ManagedCommandProof) {
        $managedRecords = @($ManagedCommandProof.Values | Sort-Object @{ Expression = { [string]$_.command } }, @{ Expression = { [string]$_.path } } | ForEach-Object {
            if (-not (Test-HermesManagedCommandProofRecord -Plan $Plan -ManagedCommandProof $ManagedCommandProof -CommandName ([string]$_.command) -LiteralPath ([string]$_.path))) {
                throw 'Managed command proof changed before attestation'
            }
            [pscustomobject][ordered]@{
                command = ([string]$_.command).ToLowerInvariant()
                path = [System.IO.Path]::GetFullPath([string]$_.path)
                length = [int64]$_.length
                sha256 = ([string]$_.sha256).ToUpperInvariant()
            }
        })
    }
    $proofForBoundary = $(if ($null -eq $ManagedCommandProof) { @{} } else { $ManagedCommandProof })
    $managedBoundary = Test-HermesManagedAbsoluteCommandBoundary -Plan $Plan -ManagedCommandProof $proofForBoundary
    if (-not $managedBoundary.Valid) { throw [string]$managedBoundary.Reason }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        contract = 'hermes-managed-launchers-and-commands-v1'
        pathBindingSha256 = Get-HermesLauncherPathBindingSha256 -Plan $Plan
        expectedCommit = $ExpectedCommit.ToLowerInvariant()
        installerSha256 = $InstallerSha256.ToUpperInvariant()
        managedCommands = $managedRecords
        launchers = $records
    }
}

function Set-HermesLauncherAttestation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Paths, [Parameter(Mandatory = $true)]$Attestation)

    if (-not (Test-HermesLauncherAttestationStorage -Paths $Paths)) { throw 'Launcher attestation storage rejected' }
    $bytes = ConvertTo-HermesLauncherAttestationBytes -Attestation $Attestation
    $existing = Read-HermesLauncherAttestation -Paths $Paths
    if ($existing.Exists) {
        if ($existing.Valid -and [Convert]::ToBase64String([byte[]]$existing.Bytes) -ceq [Convert]::ToBase64String($bytes)) {
            return [pscustomobject]@{ Changed = $false; Path = [string]$Paths.LauncherAttestationFile; Bytes = $bytes }
        }
        throw 'Existing launcher attestation cannot be replaced'
    }

    $temporary = Join-Path ([string]$Paths.StateDir) ('.launcher-attestation-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $published = $false
    try {
        Write-HermesExclusiveFile -LiteralPath $temporary -Bytes $bytes
        $temporaryItem = Get-Item -LiteralPath $temporary -Force
        if (($temporaryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($temporary)) -cne [Convert]::ToBase64String($bytes)) {
            throw 'Launcher attestation temporary file rejected'
        }
        if (-not (Test-HermesLauncherAttestationStorage -Paths $Paths) -or (Test-Path -LiteralPath ([string]$Paths.LauncherAttestationFile))) {
            throw 'Launcher attestation target changed before publish'
        }
        [System.IO.File]::Move($temporary, [string]$Paths.LauncherAttestationFile)
        $published = $true
        $roundTrip = Read-HermesLauncherAttestation -Paths $Paths
        if (-not $roundTrip.Valid -or [Convert]::ToBase64String([byte[]]$roundTrip.Bytes) -cne [Convert]::ToBase64String($bytes)) {
            throw 'Launcher attestation publish verification failed'
        }
        return [pscustomobject]@{ Changed = $true; Path = [string]$Paths.LauncherAttestationFile; Bytes = $bytes }
    } catch {
        if ($published -and (Test-Path -LiteralPath ([string]$Paths.LauncherAttestationFile) -PathType Leaf)) {
            $currentItem = Get-Item -LiteralPath ([string]$Paths.LauncherAttestationFile) -Force
            $currentBytes = [System.IO.File]::ReadAllBytes([string]$Paths.LauncherAttestationFile)
            if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and
                [Convert]::ToBase64String($currentBytes) -ceq [Convert]::ToBase64String($bytes)) {
                Remove-Item -LiteralPath ([string]$Paths.LauncherAttestationFile) -Force
            }
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Remove-HermesLauncherAttestationIfWritten {
    [CmdletBinding()]
    param([AllowNull()]$WriteResult, [Parameter(Mandatory = $true)]$Paths)

    if ($null -eq $WriteResult -or -not [bool]$WriteResult.Changed) { return $false }
    $path = [string]$Paths.LauncherAttestationFile
    if (-not (Test-HermesLauncherAttestationStorage -Paths $Paths) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $path -Force
    $current = [System.IO.File]::ReadAllBytes($path)
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        [Convert]::ToBase64String($current) -cne [Convert]::ToBase64String([byte[]]$WriteResult.Bytes)) { return $false }
    Remove-Item -LiteralPath $path -Force
    return $true
}

function Test-HermesLauncherAttestation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)][string]$InstallerSha256
    )

    try {
        $paths = Get-HermesDefaultPaths -HermesHome ([string]$Plan.HermesHome) -InstallDir ([string]$Plan.InstallDir) -RuntimeRoot ([string]$Plan.RuntimeRoot)
        $read = Read-HermesLauncherAttestation -Paths $paths
        if (-not $read.Valid) { return [pscustomobject]@{ Valid = $false; Reason = [string]$read.Reason } }
        $attestation = $read.Attestation
        if (-not [string]::Equals([string]$attestation.pathBindingSha256, (Get-HermesLauncherPathBindingSha256 -Plan $Plan), [System.StringComparison]::Ordinal) -or
            -not [string]::Equals([string]$attestation.expectedCommit, $ExpectedCommit, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$attestation.installerSha256, $InstallerSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Valid = $false; Reason = 'attestation binding mismatch' }
        }
        $launchers = Test-HermesManagedLaunchers -InstallDir ([string]$Plan.InstallDir)
        if (-not $launchers.Valid) { return [pscustomobject]@{ Valid = $false; Reason = [string]$launchers.Reason } }
        $facts = @($launchers.Files)
        $records = @($attestation.launchers)
        for ($index = 0; $index -lt $facts.Count; $index++) {
            if ([string]$facts[$index].Name -cne [string]$records[$index].name -or
                [int64]$facts[$index].Length -ne [int64]$records[$index].length -or
                -not [string]::Equals([string]$facts[$index].Sha256, [string]$records[$index].sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ Valid = $false; Reason = 'attested launcher mismatch' }
            }
        }
        $managedCommandProof = @{}
        foreach ($managedRecord in @($attestation.managedCommands)) {
            if (-not (Test-HermesManagedCommandRecordPathPolicy -Plan $Plan -CommandName ([string]$managedRecord.command) -LiteralPath ([string]$managedRecord.path))) {
                return [pscustomobject]@{ Valid = $false; Reason = 'attested managed command path rejected' }
            }
            $key = Get-HermesManagedCommandProofKey -LiteralPath ([string]$managedRecord.path)
            $managedCommandProof[$key] = [pscustomobject][ordered]@{
                command = [string]$managedRecord.command
                path = [System.IO.Path]::GetFullPath([string]$managedRecord.path)
                length = [int64]$managedRecord.length
                sha256 = [string]$managedRecord.sha256
            }
        }
        foreach ($managedRecord in @($managedCommandProof.Values)) {
            if (-not (Test-HermesManagedCommandProofRecord -Plan $Plan -ManagedCommandProof $managedCommandProof -CommandName ([string]$managedRecord.command) -LiteralPath ([string]$managedRecord.path))) {
                return [pscustomobject]@{ Valid = $false; Reason = 'attested managed command mismatch' }
            }
        }
        $managedBoundary = Test-HermesManagedAbsoluteCommandBoundary -Plan $Plan -ManagedCommandProof $managedCommandProof
        if (-not $managedBoundary.Valid) {
            return [pscustomobject]@{ Valid = $false; Reason = 'attested managed command set is incomplete' }
        }
        return [pscustomobject]@{ Valid = $true; Reason = $null; ManagedCommandProof = $managedCommandProof }
    } catch {
        return [pscustomobject]@{ Valid = $false; Reason = 'attestation validation failed' }
    }
}

function Test-HermesInactiveGitMetadataFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath, [switch]$AllowComments)

    if (-not (Test-Path -LiteralPath $LiteralPath)) { return $true }
    try {
        if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) { return $false }
        $item = Get-Item -LiteralPath $LiteralPath -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 1048576) { return $false }
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $strictUtf8.GetString([System.IO.File]::ReadAllBytes($LiteralPath))
        foreach ($line in @([System.Text.RegularExpressions.Regex]::Split($text, '\r?\n'))) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrEmpty($trimmed)) { continue }
            if ($AllowComments -and ($trimmed.StartsWith('#') -or $trimmed.StartsWith(';'))) { continue }
            return $false
        }
        return $true
    } catch { return $false }
}

function Test-HermesRepositoryMetadataSafety {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallDir)

    $failure = {
        param([string]$Reason)
        return [pscustomobject]@{ Valid = $false; Reason = $Reason; ConfigPath = $null }
    }
    try {
        $installFull = [System.IO.Path]::GetFullPath($InstallDir)
        $gitDirectory = Join-Path $installFull '.git'
        if (-not (Test-Path -LiteralPath $gitDirectory -PathType Container)) { return & $failure 'Git metadata directory missing' }
        $gitItem = Get-Item -LiteralPath $gitDirectory -Force
        if (($gitItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return & $failure 'Git metadata reparse point rejected' }

        foreach ($relative in @('commondir', 'config.worktree')) {
            if (Test-Path -LiteralPath (Join-Path $gitDirectory $relative)) { return & $failure 'Git metadata redirection rejected' }
        }
        if (-not (Test-HermesInactiveGitMetadataFile -LiteralPath (Join-Path $gitDirectory 'info\attributes') -AllowComments) -or
            -not (Test-HermesInactiveGitMetadataFile -LiteralPath (Join-Path $gitDirectory 'objects\info\alternates'))) {
            return & $failure 'Active Git metadata override rejected'
        }

        $configPath = Join-Path $gitDirectory 'config'
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return & $failure 'Git config missing' }
        $configItem = Get-Item -LiteralPath $configPath -Force
        if (($configItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $configItem.Length -le 0 -or $configItem.Length -gt 1048576) {
            return & $failure 'Git config file rejected'
        }
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $configText = $strictUtf8.GetString([System.IO.File]::ReadAllBytes($configPath))
        if ($configText.IndexOf([char]0) -ge 0) { return & $failure 'Git config NUL rejected' }

        $section = $null
        $subsection = $null
        $seenRequired = @{}
        $seenEntries = @{}
        foreach ($line in @([System.Text.RegularExpressions.Regex]::Split($configText, '\r?\n'))) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrEmpty($trimmed) -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) { continue }
            if ($trimmed.StartsWith('[')) {
                if ($trimmed -notmatch '^\[(?<Section>[A-Za-z0-9-]+)(?:\s+"(?<Subsection>[A-Za-z0-9._/-]+)")?\]$') {
                    return & $failure 'Git config section rejected'
                }
                $section = ([string]$Matches['Section']).ToLowerInvariant()
                $subsection = $(if ($Matches['Subsection']) { ([string]$Matches['Subsection']).ToLowerInvariant() } else { $null })
                continue
            }
            if ([string]::IsNullOrWhiteSpace($section) -or $trimmed -notmatch '^(?<Key>[A-Za-z][A-Za-z0-9-]*)\s*=\s*(?<Value>.*)$') {
                return & $failure 'Git config entry rejected'
            }
            $key = ([string]$Matches['Key']).ToLowerInvariant()
            $value = ([string]$Matches['Value']).Trim()
            $identity = $section + '|' + [string]$subsection + '|' + $key
            if ($seenEntries.ContainsKey($identity)) { return & $failure 'Duplicate Git config entry rejected' }
            $seenEntries[$identity] = $true
            $allowed = $false
            if ($section -eq 'core' -and [string]::IsNullOrWhiteSpace($subsection) -and
                @('repositoryformatversion', 'filemode', 'bare', 'logallrefupdates', 'symlinks', 'ignorecase', 'autocrlf') -contains $key) {
                $allowed = $true
                if (($key -eq 'repositoryformatversion' -and $value -cne '0') -or
                    ($key -eq 'bare' -and $value -cne 'false') -or
                    ($key -eq 'autocrlf' -and $value -cne 'false')) {
                    return & $failure 'Git core config value rejected'
                }
            } elseif ($section -eq 'remote' -and $subsection -eq 'origin' -and @('url', 'fetch') -contains $key) {
                $allowed = $true
            } elseif ($section -eq 'branch' -and -not [string]::IsNullOrWhiteSpace($subsection) -and @('remote', 'merge') -contains $key) {
                $allowed = $true
            } elseif ($section -eq 'windows' -and [string]::IsNullOrWhiteSpace($subsection) -and
                $key -eq 'appendatomically' -and $value -ceq 'false') {
                $allowed = $true
            }
            if (-not $allowed) { return & $failure 'Git config key or value rejected' }
            $seenRequired["$section.$key"] = $true
        }
        foreach ($required in @('core.repositoryformatversion', 'core.bare', 'remote.url')) {
            if (-not $seenRequired.ContainsKey($required)) { return & $failure 'Git config required key missing' }
        }
        return [pscustomobject]@{ Valid = $true; Reason = $null; ConfigPath = $configPath }
    } catch {
        return & $failure 'Git metadata inspection failed'
    }
}

function Get-HermesManagedCheckoutStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GitPath,
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][hashtable]$Environment,
        [Parameter(Mandatory = $true)][string]$ExternalExcludesPath
    )

    $result = Invoke-HermesProcess -FilePath $GitPath -ArgumentList @(
        '-c', ("core.excludesFile={0}" -f $ExternalExcludesPath), '-c', 'core.fsmonitor=false', '-C', $InstallDir,
        'status', '--porcelain=v1', '-z', '--untracked-files=all', '--ignore-submodules=all'
    ) -Environment $Environment -TimeoutSeconds 60
    $entries = @()
    if (-not [string]::IsNullOrEmpty($result.StdOut)) {
        $entries = @($result.StdOut.Split([char]0) | Where-Object { -not [string]::IsNullOrEmpty($_) })
    }
    return [pscustomobject]@{ ExitCode = $result.ExitCode; TimedOut = $result.TimedOut; Entries = $entries; ProcessResult = $result }
}

function Get-HermesFreshCheckoutSeed {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallDir)

    $fullPath = [System.IO.Path]::GetFullPath($InstallDir)
    $safety = Test-HermesSafeTargetPath -LiteralPath $fullPath -Label 'fresh Hermes checkout'
    if (-not $safety.Safe) {
        return [pscustomobject]@{ Eligible = $false; InstallDir = $fullPath; Reason = [string]$safety.Reason }
    }

    if (Test-Path -LiteralPath $fullPath) {
        if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
            return [pscustomobject]@{ Eligible = $false; InstallDir = $fullPath; Reason = 'InstallDir is not a directory' }
        }
        try {
            $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
            $firstChild = Get-ChildItem -LiteralPath $fullPath -Force -ErrorAction Stop | Select-Object -First 1
        } catch {
            return [pscustomobject]@{ Eligible = $false; InstallDir = $fullPath; Reason = 'InstallDir could not be inspected safely' }
        }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $firstChild) {
            return [pscustomobject]@{ Eligible = $false; InstallDir = $fullPath; Reason = 'InstallDir is not an empty ordinary directory' }
        }
    }

    return [pscustomobject]@{ Eligible = $true; InstallDir = $fullPath; Reason = $null }
}

function New-HermesFreshRepositoryProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Seed,
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit
    )

    $installFull = [System.IO.Path]::GetFullPath([string]$Plan.InstallDir)
    if (-not [bool]$Seed.Eligible -or
        -not [string]::Equals([string]$Seed.InstallDir, $installFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Fresh checkout seed is missing or does not match InstallDir'
    }
    if (Test-Path -LiteralPath (Join-Path $installFull 'bin')) {
        throw 'Fresh repository unexpectedly contains a launcher directory'
    }

    $excludeState = Get-HermesManagedLauncherExcludeState -InstallDir $installFull
    if (-not $excludeState.Compatible -or $excludeState.ActivePatterns.Count -ne 0) {
        throw 'Fresh repository has active local exclude patterns'
    }

    $repositoryMetadata = Test-HermesRepositoryMetadataSafety -InstallDir $installFull
    if (-not $repositoryMetadata.Valid) { throw [string]$repositoryMetadata.Reason }
    $git = Get-HermesVerificationGitPath -HermesHome ([string]$Plan.HermesHome)
    if ([string]::IsNullOrWhiteSpace($git)) { throw 'Trusted Git unavailable for fresh repository proof' }
    $environment = New-HermesStageEnvironment -Plan $Plan -Stage 'repository' -IsolatedGitVerification
    try {
        $externalExcludeResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('config', '--global', '--path', '--get', 'core.excludesFile') -Environment $environment -TimeoutSeconds 30
        $externalExcludesPath = $externalExcludeResult.StdOut.Trim()
        if ($externalExcludeResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($externalExcludesPath) -or -not (Test-Path -LiteralPath $externalExcludesPath -PathType Leaf)) {
            throw 'Managed empty external excludes file unavailable'
        }
        $externalExcludesItem = Get-Item -LiteralPath $externalExcludesPath -Force
        if (($externalExcludesItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $externalExcludesItem.Length -ne 0) {
            throw 'Managed external excludes file rejected'
        }

        $gitConfigPath = Join-Path $installFull '.git\config'
        $headResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', 'core.fsmonitor=false', '-C', $installFull, 'rev-parse', '--verify', 'HEAD') -Environment $environment -TimeoutSeconds 30
        $topLevelResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', 'core.fsmonitor=false', '-C', $installFull, 'rev-parse', '--show-toplevel') -Environment $environment -TimeoutSeconds 30
        $gitDirectoryResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', 'core.fsmonitor=false', '-C', $installFull, 'rev-parse', '--absolute-git-dir') -Environment $environment -TimeoutSeconds 30
        $originResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('config', '--no-includes', '--file', $gitConfigPath, '--get-all', 'remote.origin.url') -Environment $environment -TimeoutSeconds 30
        $dangerousConfigResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('config', '--no-includes', '--file', $gitConfigPath, '--name-only', '--get-regexp', '^(core\.(worktree|excludesfile|fsmonitor|attributesfile)|include\.path|includeif\..*\.path)$') -Environment $environment -TimeoutSeconds 30
        $localExcludeResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-C', $installFull, 'config', '--local', '--get-all', 'core.excludesFile') -Environment $environment -TimeoutSeconds 30
        $expectedTreeResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', 'core.fsmonitor=false', '-C', $installFull, 'rev-parse', ($ExpectedCommit + '^{tree}')) -Environment $environment -TimeoutSeconds 30
        $indexTreeResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', 'core.fsmonitor=false', '-C', $installFull, 'write-tree') -Environment $environment -TimeoutSeconds 30
        $indexFlagsResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', 'core.fsmonitor=false', '-C', $installFull, 'ls-files', '-v', '-z') -Environment $environment -TimeoutSeconds 30
        $indexStageResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', 'core.fsmonitor=false', '-C', $installFull, 'ls-files', '--stage', '-z') -Environment $environment -TimeoutSeconds 30
        $status = Get-HermesManagedCheckoutStatus -GitPath $git -InstallDir $installFull -Environment $environment -ExternalExcludesPath $externalExcludesPath
        $head = $headResult.StdOut.Trim()
        $originValues = @($originResult.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $origin = $(if ($originValues.Count -eq 1) { [string]$originValues[0] } else { $null })
        $officialOrigins = @('https://github.com/NousResearch/hermes-agent.git', 'git@github.com:NousResearch/hermes-agent.git')
        $layoutValid = $false
        if ($topLevelResult.ExitCode -eq 0 -and $gitDirectoryResult.ExitCode -eq 0) {
            try {
                $layoutValid = (
                    [string]::Equals([System.IO.Path]::GetFullPath($topLevelResult.StdOut.Trim()), $installFull, [System.StringComparison]::OrdinalIgnoreCase) -and
                    [string]::Equals([System.IO.Path]::GetFullPath($gitDirectoryResult.StdOut.Trim()), [System.IO.Path]::GetFullPath((Join-Path $installFull '.git')), [System.StringComparison]::OrdinalIgnoreCase)
                )
            } catch { $layoutValid = $false }
        }
        $indexFlagEntries = @($indexFlagsResult.StdOut.Split([char]0) | Where-Object { -not [string]::IsNullOrEmpty($_) })
        $indexFlagsClean = ($indexFlagsResult.ExitCode -eq 0 -and $indexFlagEntries.Count -gt 0)
        foreach ($entry in $indexFlagEntries) { if (-not ([string]$entry).StartsWith('H ', [System.StringComparison]::Ordinal)) { $indexFlagsClean = $false } }
        $indexStageEntries = @($indexStageResult.StdOut.Split([char]0) | Where-Object { -not [string]::IsNullOrEmpty($_) })
        $noGitLinks = ($indexStageResult.ExitCode -eq 0)
        foreach ($entry in $indexStageEntries) { if ([string]$entry -match '^160000 ') { $noGitLinks = $false } }
        $indexTreeMatches = ($expectedTreeResult.ExitCode -eq 0 -and $indexTreeResult.ExitCode -eq 0 -and
            [string]::Equals($expectedTreeResult.StdOut.Trim(), $indexTreeResult.StdOut.Trim(), [System.StringComparison]::OrdinalIgnoreCase))
        $localConfigSafe = ($dangerousConfigResult.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($dangerousConfigResult.StdOut))
        if ($headResult.ExitCode -ne 0 -or -not $head.Equals($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase) -or
            $originResult.ExitCode -ne 0 -or $originValues.Count -ne 1 -or $officialOrigins -notcontains $origin -or
            -not $layoutValid -or -not $indexFlagsClean -or -not $noGitLinks -or -not $indexTreeMatches -or -not $localConfigSafe -or
            ($localExcludeResult.ExitCode -ne 1 -or -not [string]::IsNullOrWhiteSpace($localExcludeResult.StdOut)) -or
            $status.ExitCode -ne 0 -or $status.Entries.Count -ne 0) {
            throw 'Fresh repository provenance proof failed'
        }

        return [pscustomobject]@{
            InstallDir = $installFull
            ExpectedCommit = $ExpectedCommit.ToLowerInvariant()
            ExcludePath = [System.IO.Path]::GetFullPath([string]$excludeState.ExcludePath)
            ExcludeExists = [bool]$excludeState.Exists
            ExcludeBytes = [byte[]]$excludeState.OriginalBytes
        }
    } finally {
        Remove-HermesStageEnvironmentArtifacts -Environment $environment -Plan $Plan
    }
}

function ConvertTo-HermesComparablePathEntry {
    [CmdletBinding()]
    param([AllowNull()][string]$PathEntry)

    try {
        if ([string]::IsNullOrWhiteSpace($PathEntry)) { return $null }
        $candidate = $PathEntry.Trim()
        if ($candidate.Length -ge 2 -and $candidate[0] -eq [char]34 -and $candidate[$candidate.Length - 1] -eq [char]34) {
            $candidate = $candidate.Substring(1, $candidate.Length - 2).Trim()
        }
        $candidate = [Environment]::ExpandEnvironmentVariables($candidate)
        if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate.Contains('%') -or
            $candidate -notmatch '^[A-Za-z]:[\\/]' -or
            $candidate.StartsWith('\\', [System.StringComparison]::Ordinal) -or
            $candidate.StartsWith('\\?\', [System.StringComparison]::Ordinal) -or
            $candidate.StartsWith('\??\', [System.StringComparison]::Ordinal)) { return $null }
        $fullPath = [System.IO.Path]::GetFullPath($candidate)
        $root = [System.IO.Path]::GetPathRoot($fullPath)
        if ([string]::Equals($fullPath, $root, [System.StringComparison]::OrdinalIgnoreCase)) { return $root }
        return $fullPath.TrimEnd('\', '/')
    } catch { return $null }
}

function Test-HermesPathContainsDirectory {
    [CmdletBinding()]
    param([AllowNull()][string[]]$PathValues, [Parameter(Mandatory = $true)][string]$Directory)

    $expected = ConvertTo-HermesComparablePathEntry -PathEntry $Directory
    if ([string]::IsNullOrWhiteSpace($expected)) { return $false }
    foreach ($pathValue in @($PathValues)) {
        foreach ($entry in @(([string]$pathValue) -split ';')) {
            $candidate = ConvertTo-HermesComparablePathEntry -PathEntry ([string]$entry)
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and
                [string]::Equals($candidate, $expected, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

function Get-HermesPathStageEnvironmentSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$TrustedGitBashPath
    )

    $userPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
    $machinePath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    $userHermesHome = [Environment]::GetEnvironmentVariable('HERMES_HOME', [EnvironmentVariableTarget]::User)
    $userGitBashPath = [Environment]::GetEnvironmentVariable('HERMES_GIT_BASH_PATH', [EnvironmentVariableTarget]::User)
    $launcherDirectory = [System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.InstallDir) 'bin'))

    return [pscustomobject]@{
        UserPath = $userPath
        UserHermesHome = $userHermesHome
        UserGitBashPath = $userGitBashPath
        ExpectedPath = $userPath
        ExpectedHermesHome = $userHermesHome
        ExpectedGitBashPath = $userGitBashPath
        TrustedGitBashPath = [System.IO.Path]::GetFullPath($TrustedGitBashPath)
        PathBeforeNode = $null
        ManagedNodePathCandidate = $null
        PathStageApplied = $false
        LauncherDirectory = $launcherDirectory
        LauncherEntryPresent = (Test-HermesPathContainsDirectory -PathValues @($userPath, $machinePath) -Directory $launcherDirectory)
    }
}

function Test-HermesEnvironmentValueExact {
    [CmdletBinding()]
    param([AllowNull()]$Left, [AllowNull()]$Right)

    if ($null -eq $Left -or $null -eq $Right) { return ($null -eq $Left -and $null -eq $Right) }
    return [string]::Equals([string]$Left, [string]$Right, [System.StringComparison]::Ordinal)
}

function Get-HermesUpstreamManagedNodePathValue {
    [CmdletBinding()]
    param([AllowNull()]$UserPath, [Parameter(Mandatory = $true)][string]$NodeDirectory)

    $items = $(if ($UserPath) { @(([string]$UserPath) -split ';') } else { @() })
    $rest = @($items | Where-Object { $_ -ne $NodeDirectory })
    $updated = (@($NodeDirectory) + $rest) -join ';'
    return $(if ($updated -ne $UserPath) { $updated } else { $UserPath })
}

function Get-HermesUpstreamPathStageValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [AllowNull()]$UserPath,
        [AllowNull()]$UserHermesHome
    )

    $currentPath = $UserPath
    $legacyDirectory = [System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.InstallDir) 'venv\Scripts'))
    $launcherDirectory = [System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.InstallDir) 'bin'))
    if ($currentPath -like "*$legacyDirectory*") {
        $currentPath = (([string]$currentPath) -split ';' | Where-Object { $_ -and $_ -ne $legacyDirectory }) -join ';'
    }
    if ($currentPath -notlike "*$launcherDirectory*") {
        $currentPath = "$launcherDirectory;$currentPath"
    }

    $currentHermesHome = $UserHermesHome
    if (-not $currentHermesHome -or $currentHermesHome -ne [string]$Plan.HermesHome) {
        $currentHermesHome = [string]$Plan.HermesHome
    }
    return [pscustomobject]@{ UserPath = $currentPath; UserHermesHome = $currentHermesHome }
}

function Set-HermesPersistentEnvironmentStageExpectation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$Stage
    )

    if ($Stage -eq 'git') {
        $Snapshot.ExpectedGitBashPath = [string]$Snapshot.TrustedGitBashPath
    } elseif (@('node', 'desktop') -contains $Stage) {
        $Snapshot.PathBeforeNode = $Snapshot.ExpectedPath
        $Snapshot.ManagedNodePathCandidate = Get-HermesUpstreamManagedNodePathValue -UserPath $Snapshot.ExpectedPath -NodeDirectory ([System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.HermesHome) 'node')))
        $Snapshot.ExpectedPath = $Snapshot.ManagedNodePathCandidate
    } elseif ($Stage -eq 'path') {
        $values = Get-HermesUpstreamPathStageValues -Plan $Plan -UserPath $Snapshot.ExpectedPath -UserHermesHome $Snapshot.ExpectedHermesHome
        $Snapshot.ExpectedPath = $values.UserPath
        $Snapshot.ExpectedHermesHome = $values.UserHermesHome
        $Snapshot.PathStageApplied = $true
    }
}

function Complete-HermesPersistentEnvironmentStageExpectation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][hashtable]$ManagedCommandProof
    )

    if ($Stage -eq 'git') {
        $actualGitBashPath = [Environment]::GetEnvironmentVariable('HERMES_GIT_BASH_PATH', [EnvironmentVariableTarget]::User)
        if (-not [string]::IsNullOrWhiteSpace([string]$actualGitBashPath) -and
            [string]::Equals([System.IO.Path]::GetFullPath([string]$actualGitBashPath), [System.IO.Path]::GetFullPath([string]$Snapshot.TrustedGitBashPath), [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath ([string]$actualGitBashPath) -RootPath (Split-Path -Parent (Split-Path -Parent ([string]$Snapshot.TrustedGitBashPath))))) {
            $Snapshot.ExpectedGitBashPath = [string]$actualGitBashPath
        }
        return
    }
    if (@('node', 'desktop') -notcontains $Stage) { return }
    $nodePath = [System.IO.Path]::GetFullPath((Join-Path ([string]$Plan.HermesHome) 'node\node.exe'))
    if (-not (Test-HermesManagedCommandProofRecord -Plan $Plan -ManagedCommandProof $ManagedCommandProof -CommandName 'node' -LiteralPath $nodePath)) {
        $Snapshot.ExpectedPath = $Snapshot.PathBeforeNode
    }
}

function Test-HermesPersistentEnvironmentPostcondition {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Snapshot, [Parameter(Mandatory = $true)]$Plan)

    $actualPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
    $actualHermesHome = [Environment]::GetEnvironmentVariable('HERMES_HOME', [EnvironmentVariableTarget]::User)
    $actualGitBashPath = [Environment]::GetEnvironmentVariable('HERMES_GIT_BASH_PATH', [EnvironmentVariableTarget]::User)
    $pathExact = Test-HermesEnvironmentValueExact -Left $actualPath -Right $Snapshot.ExpectedPath
    $homeExact = Test-HermesEnvironmentValueExact -Left $actualHermesHome -Right $Snapshot.ExpectedHermesHome
    $gitBashExact = Test-HermesEnvironmentValueExact -Left $actualGitBashPath -Right $Snapshot.ExpectedGitBashPath
    $launcherPresent = (-not [bool]$Snapshot.PathStageApplied -or
        (Test-HermesPathContainsDirectory -PathValues @($actualPath) -Directory ([string]$Snapshot.LauncherDirectory)))
    return [pscustomobject]@{
        Valid = ($pathExact -and $homeExact -and $gitBashExact -and $launcherPresent)
        PathValid = ($pathExact -and $launcherPresent)
        HermesHomeValid = $homeExact
        GitBashPathValid = $gitBashExact
    }
}

function Test-HermesPathStagePostcondition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$Snapshot,
        [AllowNull()][string]$UserPath,
        [AllowNull()][string]$UserHermesHome
    )

    $pathValid = ((Test-HermesEnvironmentValueExact -Left $UserPath -Right $Snapshot.ExpectedPath) -and
        (Test-HermesPathContainsDirectory -PathValues @($UserPath) -Directory ([string]$Snapshot.LauncherDirectory)) )
    $homeValid = $false
    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$UserHermesHome)) {
            $actualHome = [System.IO.Path]::GetFullPath($UserHermesHome)
            $expectedHome = [System.IO.Path]::GetFullPath([string]$Plan.HermesHome)
            $homeValid = [string]::Equals($actualHome.TrimEnd('\', '/'), $expectedHome.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)
        }
    } catch { $homeValid = $false }
    return [pscustomobject]@{ Valid = ($pathValid -and $homeValid); PathValid = $pathValid; HermesHomeValid = $homeValid }
}

function Restore-HermesRejectedUserPathExposure {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Snapshot, [Parameter(Mandatory = $true)]$Plan)

    $currentPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
    if (Test-HermesEnvironmentValueExact -Left $currentPath -Right $Snapshot.UserPath) { return $true }
    if (Test-HermesEnvironmentValueExact -Left $currentPath -Right $Snapshot.ExpectedPath) {
        [Environment]::SetEnvironmentVariable('Path', $Snapshot.UserPath, [EnvironmentVariableTarget]::User)
        return $true
    }
    return $false
}

function Restore-HermesRejectedHermesHomeExposure {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Snapshot, [Parameter(Mandatory = $true)]$Plan)

    $currentHermesHome = [Environment]::GetEnvironmentVariable('HERMES_HOME', [EnvironmentVariableTarget]::User)
    if (Test-HermesEnvironmentValueExact -Left $currentHermesHome -Right $Snapshot.UserHermesHome) { return $true }
    if (Test-HermesEnvironmentValueExact -Left $currentHermesHome -Right $Snapshot.ExpectedHermesHome) {
        [Environment]::SetEnvironmentVariable('HERMES_HOME', $Snapshot.UserHermesHome, [EnvironmentVariableTarget]::User)
        return $true
    }
    return $false
}

function Restore-HermesRejectedGitBashExposure {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Snapshot)

    $current = [Environment]::GetEnvironmentVariable('HERMES_GIT_BASH_PATH', [EnvironmentVariableTarget]::User)
    if (Test-HermesEnvironmentValueExact -Left $current -Right $Snapshot.UserGitBashPath) { return $true }
    $trustedEquivalent = $false
    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$current) -and
            -not [string]::IsNullOrWhiteSpace([string]$Snapshot.TrustedGitBashPath)) {
            $trustedFull = [System.IO.Path]::GetFullPath([string]$Snapshot.TrustedGitBashPath)
            $binDirectory = Split-Path -Parent $trustedFull
            $candidateRoot = Split-Path -Parent $binDirectory
            if ((Split-Path -Leaf $candidateRoot) -ieq 'usr') { $candidateRoot = Split-Path -Parent $candidateRoot }
            $trustedEquivalent = ([string]::Equals([System.IO.Path]::GetFullPath([string]$current), $trustedFull, [System.StringComparison]::OrdinalIgnoreCase) -and
                (Test-HermesOrdinaryCommandPathUnderRoot -LiteralPath ([string]$current) -RootPath $candidateRoot))
        }
    } catch { $trustedEquivalent = $false }
    if ((Test-HermesEnvironmentValueExact -Left $current -Right $Snapshot.ExpectedGitBashPath) -or $trustedEquivalent) {
        [Environment]::SetEnvironmentVariable('HERMES_GIT_BASH_PATH', $Snapshot.UserGitBashPath, [EnvironmentVariableTarget]::User)
        return $true
    }
    return $false
}

function Restore-HermesRejectedPathStageExposure {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Snapshot, [Parameter(Mandatory = $true)]$Plan)

    $pathRestored = Restore-HermesRejectedUserPathExposure -Snapshot $Snapshot -Plan $Plan
    $homeRestored = Restore-HermesRejectedHermesHomeExposure -Snapshot $Snapshot -Plan $Plan
    $gitBashRestored = Restore-HermesRejectedGitBashExposure -Snapshot $Snapshot
    return [pscustomobject]@{ PathRestored = [bool]$pathRestored; HermesHomeRestored = [bool]$homeRestored; GitBashPathRestored = [bool]$gitBashRestored }
}

function Assert-HermesManagedExcludeMutationPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ExcludePath)

    $fullPath = [System.IO.Path]::GetFullPath($ExcludePath)
    $infoDirectory = Split-Path -Parent $fullPath
    $gitDirectory = Split-Path -Parent $infoDirectory
    if ((Split-Path -Leaf $fullPath) -cne 'exclude' -or (Split-Path -Leaf $infoDirectory) -cne 'info' -or (Split-Path -Leaf $gitDirectory) -cne '.git') {
        throw 'Managed exclude path shape rejected'
    }
    foreach ($directory in @($gitDirectory, $infoDirectory)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'Managed exclude parent directory missing' }
        $item = Get-Item -LiteralPath $directory -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Managed exclude parent reparse point rejected' }
    }
    $safety = Test-HermesSafeTargetPath -LiteralPath $fullPath -Label 'managed Git exclude'
    if (-not $safety.Safe) { throw [string]$safety.Reason }
    return $fullPath
}

function Set-HermesManagedLauncherExcludeFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$MissingPatterns
    )

    if ($MissingPatterns.Count -eq 0) {
        return [pscustomobject]@{ Changed = $false; Bytes = $State.OriginalBytes }
    }
    [void](Assert-HermesManagedExcludeMutationPath -ExcludePath ([string]$State.ExcludePath))
    $prefix = $(if ([string]::IsNullOrEmpty([string]$State.Text) -or [string]$State.Text -match "(`r|`n)$") { '' } else { "`n" })
    $addition = $prefix + '# hermes-easy-setup managed launcher exclusions' + "`n" + (($MissingPatterns -join "`n") + "`n")
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $newBytes = $utf8.GetBytes(([string]$State.Text) + $addition)
    $parent = Split-Path -Parent ([string]$State.ExcludePath)
    $temporary = Join-Path $parent ('.exclude-hermes-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        Write-HermesExclusiveFile -LiteralPath $temporary -Bytes $newBytes
        $temporaryItem = Get-Item -LiteralPath $temporary -Force
        $roundTrip = [System.IO.File]::ReadAllBytes($temporary)
        if ([bool]$temporaryItem.PSIsContainer -or
            ($temporaryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            [Convert]::ToBase64String($roundTrip) -cne [Convert]::ToBase64String($newBytes)) {
            throw 'Managed exclude temporary file verification failed'
        }
        [void](Assert-HermesManagedExcludeMutationPath -ExcludePath ([string]$State.ExcludePath))
        if ([bool]$State.Exists) {
            if (-not (Test-Path -LiteralPath ([string]$State.ExcludePath) -PathType Leaf)) { throw 'Git exclude changed before managed replace' }
            $currentItem = Get-Item -LiteralPath ([string]$State.ExcludePath) -Force
            $currentBytes = [System.IO.File]::ReadAllBytes([string]$State.ExcludePath)
            if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
                [Convert]::ToBase64String($currentBytes) -cne [Convert]::ToBase64String([byte[]]$State.OriginalBytes)) {
                throw 'Git exclude changed before managed replace'
            }
            [System.IO.File]::Replace($temporary, [string]$State.ExcludePath, [System.Management.Automation.Language.NullString]::Value, $true)
        } else {
            if (Test-Path -LiteralPath ([string]$State.ExcludePath)) { throw 'Git exclude appeared before managed create' }
            [System.IO.File]::Move($temporary, [string]$State.ExcludePath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
    return [pscustomobject]@{ Changed = $true; Bytes = $newBytes }
}

function Restore-HermesManagedLauncherExcludeFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][byte[]]$WrittenBytes
    )

    $path = [string]$State.ExcludePath
    [void](Assert-HermesManagedExcludeMutationPath -ExcludePath $path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    $current = [System.IO.File]::ReadAllBytes($path)
    if ([Convert]::ToBase64String($current) -cne [Convert]::ToBase64String($WrittenBytes)) { return $false }

    if (-not [bool]$State.Exists) {
        $removeItem = Get-Item -LiteralPath $path -Force
        $removeBytes = [System.IO.File]::ReadAllBytes($path)
        if (($removeItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and
            [Convert]::ToBase64String($removeBytes) -ceq [Convert]::ToBase64String($WrittenBytes)) {
            [void](Assert-HermesManagedExcludeMutationPath -ExcludePath $path)
            Remove-Item -LiteralPath $path -Force
            return $true
        }
        return $false
    }
    $parent = Split-Path -Parent $path
    $temporary = Join-Path $parent ('.exclude-hermes-restore-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        Write-HermesExclusiveFile -LiteralPath $temporary -Bytes ([byte[]]$State.OriginalBytes)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        $replaceItem = Get-Item -LiteralPath $path -Force
        $replaceBytes = [System.IO.File]::ReadAllBytes($path)
        if (($replaceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            [Convert]::ToBase64String($replaceBytes) -cne [Convert]::ToBase64String($WrittenBytes)) { return $false }
        [void](Assert-HermesManagedExcludeMutationPath -ExcludePath $path)
        [System.IO.File]::Replace($temporary, $path, [System.Management.Automation.Language.NullString]::Value, $true)
        return $true
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Remove-HermesRejectedFreshLaunchers {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)

    $launcherDirectory = Join-Path ([string]$Plan.InstallDir) 'bin'
    $sourceDirectory = Join-Path ([string]$Plan.InstallDir) 'venv\Scripts'
    if (-not (Test-Path -LiteralPath $launcherDirectory -PathType Container)) {
        return [pscustomobject]@{ Removed = @(); DirectoryRemoved = $false }
    }
    $directoryItem = Get-Item -LiteralPath $launcherDirectory -Force
    if (($directoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [pscustomobject]@{ Removed = @(); DirectoryRemoved = $false }
    }

    $removed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $script:HermesManagedLauncherNames) {
        $targetPath = Join-Path $launcherDirectory $name
        $sourcePath = Join-Path $sourceDirectory $name
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf) -or -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { continue }
        $target = Get-Item -LiteralPath $targetPath -Force
        $source = Get-Item -LiteralPath $sourcePath -Force
        if (($target.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($source.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $target.Length -le 0 -or $target.Length -ne $source.Length) { continue }
        if ((ConvertTo-HermesSha256 -LiteralPath $targetPath) -cne (ConvertTo-HermesSha256 -LiteralPath $sourcePath)) { continue }
        Remove-Item -LiteralPath $targetPath -Force
        $removed.Add($name)
    }

    $directoryRemoved = $false
    if ((Get-ChildItem -LiteralPath $launcherDirectory -Force -ErrorAction Stop | Select-Object -First 1) -eq $null) {
        Remove-Item -LiteralPath $launcherDirectory -Force
        $directoryRemoved = $true
    }
    return [pscustomobject]@{ Removed = $removed.ToArray(); DirectoryRemoved = $directoryRemoved }
}

function Invoke-HermesExposureRollback {
    [CmdletBinding()]
    param(
        [AllowNull()]$Snapshot,
        [Parameter(Mandatory = $true)]$Plan,
        [AllowNull()]$FreshRepositoryProof,
        [AllowNull()]$LauncherExcludeWrite,
        [AllowNull()]$LauncherAttestationWrite,
        [Parameter(Mandatory = $true)]$Paths,
        [AllowNull()][string]$LogPath,
        [string]$Context = 'failed install exposure'
    )

    $errors = New-Object 'System.Collections.Generic.List[string]'
    $pathRestored = $false
    $homeRestored = $false
    $gitBashRestored = $false
    $excludeRestored = $false
    $launcherResult = $null
    $attestationRemoved = $false

    if ($null -ne $Snapshot) {
        try {
            $pathRestored = [bool](Restore-HermesRejectedUserPathExposure -Snapshot $Snapshot -Plan $Plan)
        } catch {
            $errors.Add('path: ' + (Protect-HermesLogText $_.Exception.Message))
        }
        try {
            $homeRestored = [bool](Restore-HermesRejectedHermesHomeExposure -Snapshot $Snapshot -Plan $Plan)
        } catch {
            $errors.Add('home: ' + (Protect-HermesLogText $_.Exception.Message))
        }
        try {
            $gitBashRestored = [bool](Restore-HermesRejectedGitBashExposure -Snapshot $Snapshot)
        } catch {
            $errors.Add('git-bash: ' + (Protect-HermesLogText $_.Exception.Message))
        }
    }
    if ($null -ne $LauncherExcludeWrite -and [bool]$LauncherExcludeWrite.Changed) {
        try {
            $excludeRestored = [bool](Restore-HermesManagedLauncherExcludeFile -State $LauncherExcludeWrite.State -WrittenBytes ([byte[]]$LauncherExcludeWrite.Bytes))
        } catch {
            $errors.Add('exclude: ' + (Protect-HermesLogText $_.Exception.Message))
        }
    }
    if ($null -ne $FreshRepositoryProof) {
        try {
            $launcherResult = Remove-HermesRejectedFreshLaunchers -Plan $Plan
        } catch {
            $errors.Add('launchers: ' + (Protect-HermesLogText $_.Exception.Message))
        }
    }
    if ($null -ne $LauncherAttestationWrite) {
        try {
            $attestationRemoved = [bool](Remove-HermesLauncherAttestationIfWritten -WriteResult $LauncherAttestationWrite -Paths $Paths)
        } catch {
            $errors.Add('attestation: ' + (Protect-HermesLogText $_.Exception.Message))
        }
    }

    $removedLaunchers = $(if ($null -eq $launcherResult) { @() } else { @($launcherResult.Removed) })
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        try {
            $errorSummary = $(if ($errors.Count -eq 0) { 'none' } else { $errors -join '; ' })
            Write-HermesEasySetupLog -LiteralPath $LogPath -Message "$Context 복구: path=$pathRestored, home=$homeRestored, git-bash=$gitBashRestored, exclude=$excludeRestored, launchers=$($removedLaunchers.Count), attestation=$attestationRemoved, errors=$errorSummary"
        } catch {}
    }
    return [pscustomobject]@{
        PathRestored = $pathRestored
        HermesHomeRestored = $homeRestored
        GitBashPathRestored = $gitBashRestored
        ExcludeRestored = $excludeRestored
        RemovedLaunchers = $removedLaunchers
        AttestationRemoved = $attestationRemoved
        Errors = $errors.ToArray()
    }
}

function Initialize-HermesManagedLauncherExclusions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit,
        [Parameter(Mandatory = $true)]$FreshCheckoutProof
    )

    $installFull = [System.IO.Path]::GetFullPath([string]$Plan.InstallDir)
    foreach ($property in @('InstallDir', 'ExpectedCommit', 'ExcludePath', 'ExcludeExists', 'ExcludeBytes')) {
        if ($FreshCheckoutProof.PSObject.Properties.Name -notcontains $property) { throw 'Fresh checkout proof is incomplete' }
    }
    if (-not [string]::Equals([string]$FreshCheckoutProof.InstallDir, $installFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$FreshCheckoutProof.ExpectedCommit, $ExpectedCommit, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Fresh checkout proof does not match the normalization target'
    }

    $launcherValidation = Test-HermesManagedLaunchers -InstallDir ([string]$Plan.InstallDir)
    if (-not $launcherValidation.Valid) { throw [string]$launcherValidation.Reason }

    $repositoryMetadata = Test-HermesRepositoryMetadataSafety -InstallDir ([string]$Plan.InstallDir)
    if (-not $repositoryMetadata.Valid) { throw [string]$repositoryMetadata.Reason }
    $git = Get-HermesVerificationGitPath -HermesHome ([string]$Plan.HermesHome)
    if ([string]::IsNullOrWhiteSpace($git)) { throw 'Trusted Git unavailable for launcher normalization' }
    $environment = New-HermesStageEnvironment -Plan $Plan -Stage 'repository' -IsolatedGitVerification
    $excludeState = $null
    $writeResult = $null
    try {
        $externalExcludeResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('config', '--global', '--path', '--get', 'core.excludesFile') -Environment $environment -TimeoutSeconds 30
        $externalExcludesPath = $externalExcludeResult.StdOut.Trim()
        if ($externalExcludeResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($externalExcludesPath) -or -not (Test-Path -LiteralPath $externalExcludesPath -PathType Leaf)) {
            throw 'Managed empty external excludes file unavailable'
        }
        $externalExcludesItem = Get-Item -LiteralPath $externalExcludesPath -Force
        if (($externalExcludesItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $externalExcludesItem.Length -ne 0) {
            throw 'Managed external excludes file rejected'
        }

        $headResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-C', [string]$Plan.InstallDir, 'rev-parse', 'HEAD') -Environment $environment -TimeoutSeconds 30
        $originResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-C', [string]$Plan.InstallDir, 'remote', 'get-url', 'origin') -Environment $environment -TimeoutSeconds 30
        $localExcludeResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-C', [string]$Plan.InstallDir, 'config', '--local', '--get-all', 'core.excludesFile') -Environment $environment -TimeoutSeconds 30
        $head = $headResult.StdOut.Trim()
        $origin = $originResult.StdOut.Trim()
        $officialOrigins = @('https://github.com/NousResearch/hermes-agent.git', 'git@github.com:NousResearch/hermes-agent.git')
        if ($headResult.ExitCode -ne 0 -or -not $head.Equals($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase) -or
            $originResult.ExitCode -ne 0 -or $officialOrigins -notcontains $origin -or
            ($localExcludeResult.ExitCode -ne 1 -or -not [string]::IsNullOrWhiteSpace($localExcludeResult.StdOut))) {
            throw 'Checkout provenance rejected before launcher normalization'
        }

        $excludeState = Get-HermesManagedLauncherExcludeState -InstallDir ([string]$Plan.InstallDir)
        if (-not $excludeState.Compatible -or $excludeState.ActivePatterns.Count -ne 0 -or
            [bool]$excludeState.Exists -ne [bool]$FreshCheckoutProof.ExcludeExists -or
            -not [string]::Equals([System.IO.Path]::GetFullPath([string]$excludeState.ExcludePath), [System.IO.Path]::GetFullPath([string]$FreshCheckoutProof.ExcludePath), [System.StringComparison]::OrdinalIgnoreCase) -or
            [Convert]::ToBase64String([byte[]]$excludeState.OriginalBytes) -cne [Convert]::ToBase64String([byte[]]$FreshCheckoutProof.ExcludeBytes)) {
            throw 'Fresh repository exclude snapshot changed before normalization'
        }
        $missingPatterns = @($script:HermesManagedLauncherPatterns | Where-Object { $excludeState.ActivePatterns -cnotcontains $_ })
        $expectedEntries = @($missingPatterns | ForEach-Object { '?? ' + $_.Substring(1) })
        $statusBefore = Get-HermesManagedCheckoutStatus -GitPath $git -InstallDir ([string]$Plan.InstallDir) -Environment $environment -ExternalExcludesPath $externalExcludesPath
        $actualEntries = @($statusBefore.Entries)
        $entriesMatch = ($actualEntries.Count -eq $expectedEntries.Count)
        foreach ($entry in $expectedEntries) {
            if ($actualEntries -cnotcontains $entry) { $entriesMatch = $false }
        }
        if ($statusBefore.ExitCode -ne 0 -or -not $entriesMatch) {
            throw 'Checkout has unexpected changes before launcher normalization'
        }

        $writeResult = Set-HermesManagedLauncherExcludeFile -State $excludeState -MissingPatterns $missingPatterns
        $excludeWrite = [pscustomobject]@{
            Changed = [bool]$writeResult.Changed
            State = $excludeState
            Bytes = [byte[]]$writeResult.Bytes
        }
        $postState = Get-HermesManagedLauncherExcludeState -InstallDir ([string]$Plan.InstallDir)
        if (-not $postState.Complete) { throw 'Managed launcher exclude contract did not persist' }
        foreach ($pattern in $script:HermesManagedLauncherPatterns) {
            $relative = $pattern.Substring(1)
            $ignored = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', ("core.excludesFile={0}" -f $externalExcludesPath), '-C', [string]$Plan.InstallDir, 'check-ignore', '-q', '--no-index', '--', $relative) -Environment $environment -TimeoutSeconds 30
            if ($ignored.ExitCode -ne 0) { throw "Managed launcher is not ignored: $relative" }
        }
        $sentinel = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', ("core.excludesFile={0}" -f $externalExcludesPath), '-C', [string]$Plan.InstallDir, 'check-ignore', '-q', '--no-index', '--', 'bin/unexpected.exe') -Environment $environment -TimeoutSeconds 30
        if ($sentinel.ExitCode -ne 1) { throw 'Unexpected launcher path is ignored' }
        $statusAfter = Get-HermesManagedCheckoutStatus -GitPath $git -InstallDir ([string]$Plan.InstallDir) -Environment $environment -ExternalExcludesPath $externalExcludesPath
        if ($statusAfter.ExitCode -ne 0 -or $statusAfter.Entries.Count -ne 0) { throw 'Checkout is not clean after launcher normalization' }
        return [pscustomobject]@{ Valid = $true; Changed = [bool]$writeResult.Changed; Launchers = $launcherValidation.Files; Patterns = @($script:HermesManagedLauncherPatterns); ExcludeWrite = $excludeWrite }
    } catch {
        $caughtException = $_.Exception
        if ($null -ne $writeResult -and [bool]$writeResult.Changed -and $null -ne $excludeState) {
            $restored = $false
            try { $restored = [bool](Restore-HermesManagedLauncherExcludeFile -State $excludeState -WrittenBytes ([byte[]]$writeResult.Bytes)) } catch {}
            if (-not $restored -and $null -ne $excludeWrite) {
                $caughtException.Data['HermesLauncherExcludeWrite'] = $excludeWrite
            }
        }
        throw
    } finally {
        Remove-HermesStageEnvironmentArtifacts -Environment $environment -Plan $Plan
    }
}

function Test-HermesManagedLauncherExclusions {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstallDir)

    $state = Get-HermesManagedLauncherExcludeState -InstallDir $InstallDir
    return [pscustomobject]@{ Valid = [bool]$state.Complete; Reason = $state.Reason; ActivePatterns = @($state.ActivePatterns) }
}

function Test-HermesInstallation {
    [CmdletBinding()]
    param(
        [string]$HermesHome,
        [string]$InstallDir,
        [string]$RuntimeRoot,
        [string]$ExpectedCommit,
        [string]$ExpectedInstallerSha256,
        [switch]$StaticOnly,
        [string]$LogPath,
        [AllowNull()][scriptblock]$ProgressCallback
    )

    $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    $verificationSource = Get-HermesSourceConfig
    if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) { $ExpectedCommit = [string]$verificationSource.hermes.commitSha }
    if ([string]::IsNullOrWhiteSpace($ExpectedInstallerSha256)) { $ExpectedInstallerSha256 = [string]$verificationSource.installer.sha256 }
    if ($ExpectedCommit -notmatch '^[0-9a-fA-F]{40}$' -or $ExpectedInstallerSha256 -notmatch '^[0-9a-fA-F]{64}$') { Throw-HermesEasySetupError -Message '검증할 peeled commit 또는 설치기 digest가 올바르지 않습니다.' -ExitCode 50 -Category 'Verification' }
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        if (-not (Test-Path -LiteralPath $paths.LogDir -PathType Container)) { New-Item -ItemType Directory -Path $paths.LogDir -Force | Out-Null }
        $LogPath = Join-Path $paths.LogDir ("verify-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')).log")
    }

    $managedLaunchers = Test-HermesManagedLaunchers -InstallDir $paths.InstallDir
    $managedLauncherExclusions = Test-HermesManagedLauncherExclusions -InstallDir $paths.InstallDir
    $venvPython = Join-Path $paths.InstallDir 'venv\Scripts\python.exe'
    $marker = Read-HermesBootstrapMarker -InstallDir $paths.InstallDir
    $checkoutPresent = Test-Path -LiteralPath (Join-Path $paths.InstallDir '.git') -PathType Container
    $repositoryMetadata = Test-HermesRepositoryMetadataSafety -InstallDir $paths.InstallDir
    $attestationPlan = [pscustomobject]@{ HermesHome = $paths.HermesHome; InstallDir = $paths.InstallDir; RuntimeRoot = $paths.RuntimeRoot }
    $launcherAttestation = Test-HermesLauncherAttestation -Plan $attestationPlan -ExpectedCommit $ExpectedCommit -InstallerSha256 $ExpectedInstallerSha256

    $head = $null
    $origin = $null
    $clean = $false
    $checkoutStatus = $null
    $checkoutStatusTruncated = $false
    $gitStatusExitCode = $null
    $gitExcludesIsolated = $false
    $localExcludeOverrideAbsent = $false
    $checkoutLayoutValid = $false
    $indexMatchesExpectedTree = $false
    $indexFlagsClean = $false
    $localGitConfigSafe = $false
    $noGitLinks = $false
    $git = Get-HermesVerificationGitPath -HermesHome $paths.HermesHome
    if ($checkoutPresent -and $git -and $repositoryMetadata.Valid) {
        $verificationPlan = [pscustomobject]@{ HermesHome = $paths.HermesHome; RuntimeRoot = $paths.RuntimeRoot }
        $gitEnvironment = New-HermesStageEnvironment -Plan $verificationPlan -Stage 'repository' -IsolatedGitVerification
        try {
            $gitConfigPath = Join-Path $paths.InstallDir '.git\config'
            $headResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', 'core.fsmonitor=false', '-C', $paths.InstallDir, 'rev-parse', '--verify', 'HEAD') -Environment $gitEnvironment -TimeoutSeconds 30
            if ($headResult.ExitCode -eq 0 -and $headResult.StdOut.Trim() -match '^[0-9a-fA-F]{40}$') { $head = $headResult.StdOut.Trim() }
            $topLevelResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', 'core.fsmonitor=false', '-C', $paths.InstallDir, 'rev-parse', '--show-toplevel') -Environment $gitEnvironment -TimeoutSeconds 30
            $gitDirectoryResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', 'core.fsmonitor=false', '-C', $paths.InstallDir, 'rev-parse', '--absolute-git-dir') -Environment $gitEnvironment -TimeoutSeconds 30
            if ($topLevelResult.ExitCode -eq 0 -and $gitDirectoryResult.ExitCode -eq 0) {
                try {
                    $checkoutLayoutValid = (
                        [string]::Equals([System.IO.Path]::GetFullPath($topLevelResult.StdOut.Trim()), [System.IO.Path]::GetFullPath($paths.InstallDir), [System.StringComparison]::OrdinalIgnoreCase) -and
                        [string]::Equals([System.IO.Path]::GetFullPath($gitDirectoryResult.StdOut.Trim()), [System.IO.Path]::GetFullPath((Join-Path $paths.InstallDir '.git')), [System.StringComparison]::OrdinalIgnoreCase)
                    )
                } catch { $checkoutLayoutValid = $false }
            }
            $originResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('config', '--no-includes', '--file', $gitConfigPath, '--get-all', 'remote.origin.url') -Environment $gitEnvironment -TimeoutSeconds 30
            $originValues = @($originResult.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($originResult.ExitCode -eq 0 -and $originValues.Count -eq 1) { $origin = [string]$originValues[0] }
            $dangerousConfigResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('config', '--no-includes', '--file', $gitConfigPath, '--name-only', '--get-regexp', '^(core\.(worktree|excludesfile|fsmonitor|attributesfile)|include\.path|includeif\..*\.path)$') -Environment $gitEnvironment -TimeoutSeconds 30
            $localGitConfigSafe = ($dangerousConfigResult.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($dangerousConfigResult.StdOut))
            $expectedTreeResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', 'core.fsmonitor=false', '-C', $paths.InstallDir, 'rev-parse', ($ExpectedCommit + '^{tree}')) -Environment $gitEnvironment -TimeoutSeconds 30
            $indexTreeResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', 'core.fsmonitor=false', '-C', $paths.InstallDir, 'write-tree') -Environment $gitEnvironment -TimeoutSeconds 30
            $indexMatchesExpectedTree = ($expectedTreeResult.ExitCode -eq 0 -and $indexTreeResult.ExitCode -eq 0 -and
                [string]::Equals($expectedTreeResult.StdOut.Trim(), $indexTreeResult.StdOut.Trim(), [System.StringComparison]::OrdinalIgnoreCase))
            $indexFlagsResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', 'core.fsmonitor=false', '-C', $paths.InstallDir, 'ls-files', '-v', '-z') -Environment $gitEnvironment -TimeoutSeconds 30
            $indexFlagEntries = @($indexFlagsResult.StdOut.Split([char]0) | Where-Object { -not [string]::IsNullOrEmpty($_) })
            $indexFlagsClean = ($indexFlagsResult.ExitCode -eq 0 -and $indexFlagEntries.Count -gt 0)
            foreach ($entry in $indexFlagEntries) { if (-not ([string]$entry).StartsWith('H ', [System.StringComparison]::Ordinal)) { $indexFlagsClean = $false } }
            $indexStageResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', 'core.fsmonitor=false', '-C', $paths.InstallDir, 'ls-files', '--stage', '-z') -Environment $gitEnvironment -TimeoutSeconds 30
            $indexStageEntries = @($indexStageResult.StdOut.Split([char]0) | Where-Object { -not [string]::IsNullOrEmpty($_) })
            $noGitLinks = ($indexStageResult.ExitCode -eq 0)
            foreach ($entry in $indexStageEntries) { if ([string]$entry -match '^160000 ') { $noGitLinks = $false } }
            $externalExcludeResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('config', '--global', '--path', '--get', 'core.excludesFile') -Environment $gitEnvironment -TimeoutSeconds 30
            $externalExcludesPath = $externalExcludeResult.StdOut.Trim()
            if ($externalExcludeResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($externalExcludesPath) -and (Test-Path -LiteralPath $externalExcludesPath -PathType Leaf)) {
                $externalExcludesItem = Get-Item -LiteralPath $externalExcludesPath -Force
                $gitExcludesIsolated = (($externalExcludesItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and $externalExcludesItem.Length -eq 0)
            }
            $localExcludeResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-C', $paths.InstallDir, 'config', '--local', '--get-all', 'core.excludesFile') -Environment $gitEnvironment -TimeoutSeconds 30
            $localExcludeOverrideAbsent = ($localExcludeResult.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($localExcludeResult.StdOut))
            if ($gitExcludesIsolated) {
                $statusResult = Invoke-HermesProcess -FilePath $git -ArgumentList @('-c', ("core.excludesFile={0}" -f $externalExcludesPath), '-c', 'core.fsmonitor=false', '-C', $paths.InstallDir, 'status', '--porcelain=v1', '--untracked-files=all', '--ignore-submodules=all') -Environment $gitEnvironment -TimeoutSeconds 60
            } else {
                $statusResult = [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = 'managed excludes unavailable'; TimedOut = $false }
            }
            $gitStatusExitCode = [int]$statusResult.ExitCode
            $statusCandidates = @($statusResult.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 21)
            $statusLines = @($statusCandidates | Select-Object -First 20)
            $checkoutStatusTruncated = ($statusCandidates.Count -gt 20)
            $checkoutStatus = Protect-HermesLogText (($statusLines -join '; ').Trim())
            if ($checkoutStatus.Length -gt 4096) {
                $checkoutStatus = $checkoutStatus.Substring(0, 4096)
                $checkoutStatusTruncated = $true
            }
            if ($statusResult.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($checkoutStatus)) { $checkoutStatus = "git status exit $($statusResult.ExitCode)" }
            $clean = ($statusResult.ExitCode -eq 0 -and $statusLines.Count -eq 0)
        } finally {
            Remove-HermesStageEnvironmentArtifacts -Environment $gitEnvironment -Plan $verificationPlan
        }
    }
    $officialOrigins = @('https://github.com/NousResearch/hermes-agent.git', 'git@github.com:NousResearch/hermes-agent.git')
    $originOfficial = ($officialOrigins -contains $origin)
    $originOutput = $(if ($originOfficial) { $origin } elseif ([string]::IsNullOrWhiteSpace($origin)) { $null } else { '[NON-OFFICIAL-REDACTED]' })
    $headMatches = (-not [string]::IsNullOrWhiteSpace($head) -and $head.Equals($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase))
    $markerMatches = ($marker.Valid -and $marker.PinnedCommit.Equals($ExpectedCommit, [StringComparison]::OrdinalIgnoreCase))
    $venvPresent = $false
    if (Test-Path -LiteralPath $venvPython -PathType Leaf) {
        $venvPresent = Test-HermesPortableExecutableHeader -LiteralPath $venvPython
    }
    $staticChecks = [ordered]@{
        VenvPythonPresent = $venvPresent
        CheckoutPresent = $checkoutPresent
        TrustedGitAvailable = (-not [string]::IsNullOrWhiteSpace($git))
        CheckoutHeadMatches = $headMatches
        OriginOfficial = $originOfficial
        CheckoutClean = $clean
        CheckoutLayoutValid = $checkoutLayoutValid
        IndexMatchesExpectedTree = $indexMatchesExpectedTree
        IndexFlagsClean = $indexFlagsClean
        LocalGitConfigSafe = $localGitConfigSafe
        RepositoryMetadataSafe = [bool]$repositoryMetadata.Valid
        NoGitLinks = $noGitLinks
        GitExcludesIsolated = $gitExcludesIsolated
        LocalExcludeOverrideAbsent = $localExcludeOverrideAbsent
        ManagedLaunchersValid = [bool]$managedLaunchers.Valid
        ManagedLauncherExclusionsValid = [bool]$managedLauncherExclusions.Valid
        LauncherAttestationValid = [bool]$launcherAttestation.Valid
        MarkerMatches = $markerMatches
    }
    $staticFailures = @($staticChecks.Keys | Where-Object { -not [bool]$staticChecks[$_] })
    $staticProvenanceValid = ($staticFailures.Count -eq 0)
    $executionEnvironment = @{
        HERMES_HOME = $paths.HermesHome
        VIRTUAL_ENV = (Join-Path $paths.InstallDir 'venv')
        PYTHONHOME = $null
        PYTHONPATH = $null
        PYTHONUSERBASE = $null
        PYTHONSTARTUP = $null
        PYTHONINSPECT = $null
        __PYVENV_LAUNCHER__ = $null
        PYTHONNOUSERSITE = '1'
        PYTHONSAFEPATH = '1'
    }
    $commandPath = $(if ($staticProvenanceValid -and -not $StaticOnly) { Join-Path $paths.InstallDir 'bin\hermes.exe' } else { $null })
    $versionResult = $null
    $versionText = $null
    $versionStartFailed = $false
    $commandWorks = $false
    if ($commandPath) {
        $executionLaunchers = Test-HermesManagedLaunchers -InstallDir $paths.InstallDir
        $executionAttestation = Test-HermesLauncherAttestation -Plan $attestationPlan -ExpectedCommit $ExpectedCommit -InstallerSha256 $ExpectedInstallerSha256
        if ($executionLaunchers.Valid -and $executionAttestation.Valid) {
            try {
                $versionResult = Invoke-HermesProcess -FilePath $commandPath -ArgumentList @('--version') -Environment $executionEnvironment -TimeoutSeconds 90
                $versionStartFailed = ($versionResult.PSObject.Properties.Name -contains 'Started' -and -not [bool]$versionResult.Started)
                Write-HermesCapturedOutput -ProcessResult $versionResult -LogPath $LogPath -Stage 'verify-version' -Callback $ProgressCallback
                $combinedVersionOutput = $versionResult.StdOut + [Environment]::NewLine + $versionResult.StdErr
                $versionText = ([System.Text.RegularExpressions.Regex]::Split($combinedVersionOutput.Trim(), '\r?\n') | Select-Object -First 1)
                $commandWorks = ($versionResult.ExitCode -eq 0 -and -not $versionStartFailed -and -not [string]::IsNullOrWhiteSpace($versionText))
            } catch {
                $versionStartFailed = $true
                $commandWorks = $false
            }
        }
    }

    $verificationChecks = [ordered]@{}
    if (-not $StaticOnly) { $verificationChecks['CommandWorks'] = $commandWorks }
    foreach ($key in $staticChecks.Keys) { $verificationChecks[$key] = [bool]$staticChecks[$key] }
    $failedChecks = @($verificationChecks.Keys | Where-Object { -not [bool]$verificationChecks[$_] })
    $verified = (-not $StaticOnly -and $failedChecks.Count -eq 0)

    $doctorResult = $null
    if ($commandWorks) {
        try {
            $doctorResult = Invoke-HermesProcess -FilePath $commandPath -ArgumentList @('doctor') -Environment $executionEnvironment -TimeoutSeconds 240
            Write-HermesCapturedOutput -ProcessResult $doctorResult -LogPath $LogPath -Stage 'verify-doctor' -Callback $ProgressCallback
        } catch {
            $doctorResult = $null
        }
    }
    $doctorHealthy = ($null -ne $doctorResult -and $doctorResult.ExitCode -eq 0)

    return [pscustomobject]@{
        Installed = $verified
        Verified = $verified
        StaticProvenanceValid = $staticProvenanceValid
        CommandWorks = $commandWorks
        VersionStartFailed = $versionStartFailed
        CommandPath = $commandPath
        Version = Protect-HermesLogText $versionText
        VersionExitCode = $(if ($null -eq $versionResult) { $null } else { $versionResult.ExitCode })
        DoctorHealthy = $doctorHealthy
        DoctorExitCode = $(if ($null -eq $doctorResult) { $null } else { $doctorResult.ExitCode })
        DoctorSummary = $(if ($null -eq $doctorResult) { 'doctor를 실행하지 않았습니다.' } elseif ($doctorHealthy) { 'hermes doctor 통과' } else { '공급자 설정 전에는 doctor 경고가 정상일 수 있습니다.' })
        ExpectedCommit = $ExpectedCommit
        CheckoutPresent = $checkoutPresent
        CheckoutHead = $head
        CheckoutHeadMatches = $headMatches
        CheckoutClean = $clean
        CheckoutLayoutValid = $checkoutLayoutValid
        IndexMatchesExpectedTree = $indexMatchesExpectedTree
        IndexFlagsClean = $indexFlagsClean
        LocalGitConfigSafe = $localGitConfigSafe
        RepositoryMetadataSafe = [bool]$repositoryMetadata.Valid
        NoGitLinks = $noGitLinks
        CheckoutStatus = $checkoutStatus
        CheckoutStatusTruncated = $checkoutStatusTruncated
        GitStatusExitCode = $gitStatusExitCode
        GitPath = $git
        TrustedGitAvailable = (-not [string]::IsNullOrWhiteSpace($git))
        GitExcludesIsolated = $gitExcludesIsolated
        LocalExcludeOverrideAbsent = $localExcludeOverrideAbsent
        ManagedLaunchersValid = [bool]$managedLaunchers.Valid
        ManagedLauncherExclusionsValid = [bool]$managedLauncherExclusions.Valid
        LauncherAttestationValid = [bool]$launcherAttestation.Valid
        Origin = $originOutput
        OriginOfficial = $originOfficial
        VenvPythonPresent = $venvPresent
        BootstrapMarker = $marker.Valid
        MarkerPinnedCommit = $marker.PinnedCommit
        MarkerMatches = $markerMatches
        FailedChecks = @($failedChecks)
        LogPath = $LogPath
    }
}

function Invoke-HermesInstall {
    [CmdletBinding()]
    param(
        [string]$HermesHome,
        [string]$InstallDir,
        [string]$RuntimeRoot,
        [switch]$IncludeDesktop,
        [switch]$SkipComputerUse,
        [ValidateSet('Later', 'Portal', 'Full')][string]$SetupMode = 'Portal',
        [switch]$Resume,
        [switch]$ForceDownload,
        [string]$ExpectedPlanFingerprint,
        [string]$SourceConfigPath,
        [AllowNull()][scriptblock]$Downloader,
        [AllowNull()][scriptblock]$ProgressCallback
    )

    if ([string]::IsNullOrWhiteSpace($SourceConfigPath)) { $SourceConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\hermes-source.json' }
    $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    $sourceConfig = Get-HermesSourceConfig -LiteralPath $SourceConfigPath
    $plan = New-HermesInstallPlan -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -IncludeDesktop:$IncludeDesktop -SkipComputerUse:$SkipComputerUse -SetupMode $SetupMode -SourceConfigPath $SourceConfigPath
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -and -not $plan.Fingerprint.Equals($ExpectedPlanFingerprint, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-HermesEasySetupError -Message '승인한 설치 계획과 현재 실행 계획이 다릅니다. 계획을 다시 검토하고 승인하세요.' -ExitCode 2 -Category 'PlanApproval'
    }
    if (-not [bool]$SkipComputerUse) {
        Throw-HermesEasySetupError -Message 'v0.1.2는 격리 프로필 밖에 PATH·작업 스케줄러 변경을 남기는 상류 Computer Use bootstrap을 자동 실행하지 않습니다. -SkipComputerUse를 지정하고 설치 후 Hermes의 공식 도구 설정에서 별도로 검토하세요.' -ExitCode 10 -Category 'Preflight'
    }
    if ([bool]$IncludeDesktop) {
        Throw-HermesEasySetupError -Message 'v0.1.2 초기판은 기본 Hermes CLI 설치만 지원합니다. Desktop 자동 빌드는 후속 버전에서 별도 검증 후 제공할 예정입니다.' -ExitCode 10 -Category 'Preflight'
    }
    [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'plan' -State 'ready' -Message "검증 릴리스 $($plan.SourceTag), peeled commit $($plan.SourceCommit.Substring(0, 12))" -Percent 1 -Data $plan)

    $preflight = Get-HermesPreflight -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -IncludeDesktop:$IncludeDesktop
    if (-not $preflight.Ready) {
        $details = @($preflight.BlockingChecks | ForEach-Object { "$($_.Name): $($_.Detail)" }) -join '; '
        Throw-HermesEasySetupError -Message "사전 점검을 통과하지 못했습니다: $details" -ExitCode 10 -Category 'Preflight'
    }
    $trustedGit = Get-HermesVerificationGitPath -HermesHome $paths.HermesHome
    if ([string]::IsNullOrWhiteSpace($trustedGit)) {
        Throw-HermesEasySetupError -Message 'Program Files에 유효하게 서명된 Git for Windows가 필요합니다. 공식 Git for Windows를 먼저 설치한 뒤 다시 실행하세요.' -ExitCode 10 -Category 'Preflight'
    }
    $initialRegistryPathValues = @(
        [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User),
        [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    )
    $initialRegistryGit = Test-HermesRegistryGitResolution -TrustedGitPath $trustedGit -PathValues $initialRegistryPathValues
    if (-not $initialRegistryGit.Valid) {
        Throw-HermesEasySetupError -Message '공식 설치기가 다시 읽는 User/Machine PATH에서 서명된 Program Files Git이 첫 git 명령이어야 합니다.' -ExitCode 10 -Category 'Preflight'
    }
    $trustedGitBash = Get-HermesTrustedGitBashPath -TrustedGitPath ([string]$initialRegistryGit.ResolvedPath)
    if ([string]::IsNullOrWhiteSpace($trustedGitBash) -or -not (Test-HermesTrustedGitBashCompatibility -BashPath $trustedGitBash)) {
        Throw-HermesEasySetupError -Message 'Program Files Git Bash가 필수 MSYS 자식 프로세스를 실행하지 못합니다. Git for Windows 또는 Windows 프로세스 완화 정책을 복구한 뒤 다시 실행하세요.' -ExitCode 10 -Category 'Preflight'
    }
    $managedCommandProof = @{}
    if (-not [bool]$preflight.ExistingCheckout -and -not [bool]$Resume) {
        try {
            Assert-HermesFreshManagedCommandSeed -Plan $plan -PathValues $initialRegistryPathValues
        } catch {
            Throw-HermesEasySetupError -Message "fresh 설치의 managed command 경계가 깨끗하지 않습니다: $(Protect-HermesLogText $_.Exception.Message)" -ExitCode 10 -Category 'Preflight'
        }
    }
    $pathExposureSnapshot = Get-HermesPathStageEnvironmentSnapshot -Plan $plan -TrustedGitBashPath $trustedGitBash

    foreach ($directory in @($paths.RuntimeRoot, $paths.LogDir, $paths.StateDir)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    }
    $logPath = Join-Path $paths.LogDir ("install-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')).log")
    Write-HermesEasySetupLog -LiteralPath $logPath -Message "설치 시작: fingerprint=$($plan.Fingerprint), home=$($paths.HermesHome), install=$($paths.InstallDir)"

    $lock = $null
    $state = $null
    $freshRepositorySeed = $null
    $freshRepositoryProof = $null
    $launcherExcludeWrite = $null
    $launcherAttestationWrite = $null
    $resumeQuarantine = $null
    $useExistingCheckout = [bool]$preflight.ExistingCheckout
    $freshPlan = $plan
    try {
        $lock = Enter-HermesInstallLock -RuntimeRoot $paths.RuntimeRoot
        $prior = Read-HermesInstallState -LiteralPath $paths.StateFile
        if ($Resume -and -not (Test-HermesStateMatchesResumeEnvelope -State $prior -Plan $plan)) {
            Throw-HermesEasySetupError -Message '재개 상태의 계획·소스·경로가 현재 승인 계획과 다릅니다.' -ExitCode 2 -Category 'Resume'
        }
        if ($useExistingCheckout) {
            if (-not $Resume) {
                Throw-HermesEasySetupError -Message '기존 checkout은 launcher attestation v1이 있는 실패 상태의 -Resume만 허용합니다. 새 빈 InstallDir에서 다시 설치하세요.' -ExitCode 10 -Category 'Preflight'
            }
            $existingGate = Test-HermesInstallation -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -ExpectedCommit ([string]$sourceConfig.hermes.commitSha) -ExpectedInstallerSha256 ([string]$sourceConfig.installer.sha256) -StaticOnly -LogPath $logPath
            $existingAttestationGate = Test-HermesLauncherAttestation -Plan $plan -ExpectedCommit ([string]$sourceConfig.hermes.commitSha) -InstallerSha256 ([string]$sourceConfig.installer.sha256)
            if ($existingGate.StaticProvenanceValid -and $existingAttestationGate.Valid) {
                $managedCommandProof = $existingAttestationGate.ManagedCommandProof
            } else {
                try {
                    $resumeQuarantine = Move-HermesResumeManagedSeedToQuarantine -Plan $plan -State $prior
                    Assert-HermesFreshManagedCommandSeed -Plan $plan -PathValues $initialRegistryPathValues
                    $useExistingCheckout = $false
                } catch {
                    Throw-HermesEasySetupError -Message "증명되지 않은 미완성 checkout을 복구 격리하지 못했습니다: $(Protect-HermesLogText $_.Exception.Message)" -ExitCode 10 -Category 'Preflight'
                }
            }
        } elseif ($Resume) {
            try {
                $resumeQuarantine = Move-HermesResumeManagedSeedToQuarantine -Plan $plan -State $prior
                Assert-HermesFreshManagedCommandSeed -Plan $plan -PathValues $initialRegistryPathValues
            } catch {
                Throw-HermesEasySetupError -Message "실패 설치의 관리 경로를 복구 격리하지 못했습니다: $(Protect-HermesLogText $_.Exception.Message)" -ExitCode 10 -Category 'Preflight'
            }
        }
        $installer = Get-HermesVerifiedInstaller -SourceConfig $sourceConfig -Paths $paths -ForceDownload:$ForceDownload -Downloader $Downloader -ProgressCallback $ProgressCallback -LogPath $logPath
        $manifest = Get-HermesInstallerManifest -InstallerPath $installer.Path -Plan $plan -SourceConfig $sourceConfig -LogPath $logPath -ProgressCallback $ProgressCallback

        $freshPlan = New-HermesInstallPlan -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -IncludeDesktop:$IncludeDesktop -SkipComputerUse:$SkipComputerUse -SetupMode $SetupMode -SourceConfigPath $SourceConfigPath
        if (-not $freshPlan.Fingerprint.Equals($plan.Fingerprint, [StringComparison]::OrdinalIgnoreCase) -or (-not [string]::IsNullOrWhiteSpace($ExpectedPlanFingerprint) -and -not $freshPlan.Fingerprint.Equals($ExpectedPlanFingerprint, [StringComparison]::OrdinalIgnoreCase))) {
            Throw-HermesEasySetupError -Message '첫 변경 직전 계획 freshness 검사에 실패했습니다. 다시 진단하고 승인하세요.' -ExitCode 2 -Category 'PlanApproval'
        }

        $prior = Read-HermesInstallState -LiteralPath $paths.StateFile
        if ($Resume) {
            if (-not (Test-HermesStateCanResume -State $prior -Plan $freshPlan -Manifest $manifest)) {
                Throw-HermesEasySetupError -Message '재개 상태가 없거나 현재 계획·manifest와 다릅니다. -Resume 없이 새 계획으로 시작하세요.' -ExitCode 2 -Category 'Resume'
            }
            $state = Reset-HermesStateForSafeResume -State $prior
            $resumeMessage = $(if ($null -ne $resumeQuarantine -and [bool]$resumeQuarantine.Changed) { '체크포인트를 확인하고 이전 관리 파일을 복구 폴더로 격리했습니다. 자동 단계를 안전하게 다시 적용합니다.' } else { '체크포인트를 확인했습니다. 손상 복구를 위해 자동 단계를 안전하게 다시 적용합니다.' })
            [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'resume' -State 'accepted' -Message $resumeMessage -Percent 11)
        } else {
            $state = New-HermesInstallState -Plan $freshPlan -Manifest $manifest
        }
        [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)

        $powershell = Get-HermesPowerShellExecutable
        $commonArgs = @(Get-HermesStageArguments -Plan $freshPlan -SourceConfig $sourceConfig)
        $stageList = @($manifest.stages)
        for ($index = 0; $index -lt $stageList.Count; $index++) {
            $stage = $stageList[$index]
            $name = [string]$stage.name
            $percentStart = 12 + [int](($index / [math]::Max(1, $stageList.Count)) * 72)
            $percentEnd = 12 + [int]((($index + 1) / [math]::Max(1, $stageList.Count)) * 72)
            if ([bool]$stage.needs_user_input) {
                $state = Set-HermesStageRecord -State $state -Name $name -Status 'Skipped' -Reason '공식 대화형 설정으로 별도 실행합니다.' -InstallerSha256 $installer.Sha256
                [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
                [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage $name -State 'skipped' -Message "$($stage.title): 설치 후 별도 설정" -Percent $percentEnd)
                continue
            }
            $policySkipReason = Get-HermesMvpPolicyStageSkipReason -Stage $name
            if (-not [string]::IsNullOrWhiteSpace($policySkipReason)) {
                $state = Set-HermesStageRecord -State $state -Name $name -Status 'Skipped' -Reason $policySkipReason -InstallerSha256 $installer.Sha256
                [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
                [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage $name -State 'skipped' -Message $policySkipReason -Percent $percentEnd)
                Write-HermesEasySetupLog -LiteralPath $logPath -Message "단계 정책 건너뜀: $name / $policySkipReason"
                continue
            }

            $stageRegistryPathValues = @(
                [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User),
                [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
            )
            $absoluteCommandBoundary = Test-HermesManagedAbsoluteCommandBoundary -Plan $freshPlan -ManagedCommandProof $managedCommandProof
            if (-not $absoluteCommandBoundary.Valid) {
                Throw-HermesEasySetupError -Message "단계 '$name' 직전 managed command 경계가 attestation과 다릅니다." -ExitCode 10 -Category 'Preflight'
            }
            $stageRegistryGit = Test-HermesRegistryGitResolution -TrustedGitPath $trustedGit -PathValues $stageRegistryPathValues
            if (-not $stageRegistryGit.Valid) {
                Throw-HermesEasySetupError -Message "단계 '$name' 직전 User/Machine PATH의 git 해석이 신뢰 경계를 벗어났습니다." -ExitCode 10 -Category 'Preflight'
            }
            $stageBareCommands = Test-HermesStageBareCommandResolution -Plan $freshPlan -Stage $name -TrustedGitPath $trustedGit -PathValues $stageRegistryPathValues -ManagedCommandProof $managedCommandProof
            if (-not $stageBareCommands.Valid) {
                Throw-HermesEasySetupError -Message "단계 '$name' 직전 command '$($stageBareCommands.Command)'의 registry PATH 해석이 신뢰 경계를 벗어났습니다." -ExitCode 10 -Category 'Preflight'
            }
            if ($name -eq 'system-packages') {
                $missingOptionalPackages = @($stageBareCommands.MissingCommands | Where-Object { $_ -eq 'rg' -or $_ -eq 'ffmpeg' })
                if ($missingOptionalPackages.Count -gt 0) {
                    $reason = '사용자 package-manager 설정을 통한 실행을 막기 위해 없는 선택 패키지는 자동 설치하지 않습니다: ' + ($missingOptionalPackages -join ', ')
                    $state = Set-HermesStageRecord -State $state -Name $name -Status 'Skipped' -Reason $reason -InstallerSha256 $installer.Sha256
                    [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
                    [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage $name -State 'skipped' -Message $reason -Percent $percentEnd)
                    Write-HermesEasySetupLog -LiteralPath $logPath -Message "단계 건너뜀: $name / $reason"
                    continue
                }
            }
            Assert-HermesInstallerIntegrity -LiteralPath $installer.Path -SourceConfig $sourceConfig
            $state = Set-HermesStageRecord -State $state -Name $name -Status 'Running' -InstallerSha256 $installer.Sha256
            [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
            [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage $name -State 'running' -Message ([string]$stage.title) -Percent $percentStart)
            Write-HermesEasySetupLog -LiteralPath $logPath -Message "단계 시작: $name / $($stage.title)"

            $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer.Path, '-Stage', $name) + $commonArgs
            $timeout = Get-HermesStageTimeoutSeconds -Stage $name
            $freshRepositoryIntended = (-not [bool]$useExistingCheckout)
            if ($name -eq 'repository' -and $freshRepositoryIntended) {
                $freshRepositorySeed = Get-HermesFreshCheckoutSeed -InstallDir ([string]$freshPlan.InstallDir)
                if (-not $freshRepositorySeed.Eligible) {
                    $reason = "fresh checkout 경계 검사에 실패했습니다: $(Protect-HermesLogText ([string]$freshRepositorySeed.Reason))"
                    $state = Set-HermesStageRecord -State $state -Name $name -Status 'Failed' -Reason $reason -InstallerSha256 $installer.Sha256
                    $state.status = 'Failed'
                    [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
                    [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage $name -State 'failed' -Message $reason -Percent $percentStart)
                    Throw-HermesEasySetupError -Message "Hermes 설치 단계 'repository' 실패: $reason" -ExitCode 40 -Category 'InstallStage'
                }
            }
            if ($name -eq 'path' -and $null -ne $freshRepositoryProof) {
                try {
                    if ([bool]$pathExposureSnapshot.LauncherEntryPresent) {
                        throw 'Fresh checkout launcher path is already present in the user PATH'
                    }
                    $prePathProof = New-HermesFreshRepositoryProof -Seed $freshRepositorySeed -Plan $freshPlan -ExpectedCommit ([string]$sourceConfig.hermes.commitSha)
                    if ([Convert]::ToBase64String([byte[]]$prePathProof.ExcludeBytes) -cne [Convert]::ToBase64String([byte[]]$freshRepositoryProof.ExcludeBytes)) {
                        throw 'Fresh repository exclude snapshot changed before path stage'
                    }
                    $sourceValidation = Test-HermesManagedLauncherSources -InstallDir ([string]$freshPlan.InstallDir)
                    if (-not $sourceValidation.Valid) { throw [string]$sourceValidation.Reason }
                } catch {
                    $reason = "path 실행 전 fresh checkout 검증에 실패했습니다: $(Protect-HermesLogText $_.Exception.Message)"
                    $state = Set-HermesStageRecord -State $state -Name $name -Status 'Failed' -Reason $reason -InstallerSha256 $installer.Sha256
                    $state.status = 'Failed'
                    [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
                    [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage $name -State 'failed' -Message $reason -Percent $percentStart)
                    Throw-HermesEasySetupError -Message "Hermes 설치 단계 'path' 실패: $reason" -ExitCode 40 -Category 'InstallStage'
                }
            }
            $persistentPrecondition = Test-HermesPersistentEnvironmentPostcondition -Snapshot $pathExposureSnapshot -Plan $freshPlan
            if (-not $persistentPrecondition.Valid) {
                Throw-HermesEasySetupError -Message "단계 '$name' 직전 User 환경 변수가 승인된 전이와 다릅니다." -ExitCode 10 -Category 'Preflight'
            }
            Set-HermesPersistentEnvironmentStageExpectation -Snapshot $pathExposureSnapshot -Plan $freshPlan -Stage $name
            $stageEnvironment = New-HermesStageEnvironment -Plan $freshPlan -Stage $name -ExistingCheckout:$useExistingCheckout
            try {
                $result = Invoke-HermesProcess -FilePath $powershell -ArgumentList $arguments -Environment $stageEnvironment -TimeoutSeconds $timeout
                if ($name -ceq 'python' -and $result.Started -and -not $result.TimedOut) {
                    $initialPythonFrame = ConvertFrom-HermesJsonFrame -Text $result.StdOut -RequiredProperty 'stage'
                    $initialPythonFailed = ($result.ExitCode -ne 0 -or $null -eq $initialPythonFrame -or -not [bool]$initialPythonFrame.ok)
                    if ($initialPythonFailed) {
                        $pythonRepair = Convert-HermesBrokenUvPythonMinorJunction -Plan $freshPlan -PythonVersion '3.11'
                        if ([bool]$pythonRepair.Changed) {
                            Write-HermesCapturedOutput -ProcessResult $result -LogPath $logPath -Stage 'python-initial' -Callback $null
                            [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'log' -Stage 'python' -State 'running' -Message 'Windows uv Python 링크 문제를 자동 복구하고 검증을 다시 실행합니다.' -Percent $percentStart)
                            $result = Invoke-HermesProcess -FilePath $powershell -ArgumentList $arguments -Environment $stageEnvironment -TimeoutSeconds $timeout
                        }
                    }
                }
            } finally {
                Remove-HermesStageEnvironmentArtifacts -Environment $stageEnvironment -Plan $freshPlan
            }
            Write-HermesCapturedOutput -ProcessResult $result -LogPath $logPath -Stage $name -Callback $ProgressCallback
            $frame = ConvertFrom-HermesJsonFrame -Text $result.StdOut -RequiredProperty 'stage'
            $frameValidation = Test-HermesStageFrame -Frame $frame -ExpectedStage $name
            if (-not $frameValidation.Valid -or $result.ExitCode -ne 0 -or -not [bool]$frame.ok) {
                $reason = $(if ($result.TimedOut) { "단계 제한 시간 ${timeout}초를 초과해 프로세스 트리를 종료했습니다." } elseif (-not $frameValidation.Valid) { $frameValidation.Reason } elseif ($null -ne $frame -and -not [string]::IsNullOrWhiteSpace([string]$frame.reason)) { [string]$frame.reason } else { "공식 설치기 종료 코드 $($result.ExitCode)" })
                $duration = $(if ($null -ne $frame -and $frame.PSObject.Properties.Name -contains 'duration_ms') { [int]$frame.duration_ms } else { [int]$result.DurationMs })
                $state = Set-HermesStageRecord -State $state -Name $name -Status 'Failed' -Reason $reason -DurationMs $duration -InstallerSha256 $installer.Sha256
                $state.status = 'Failed'
                [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
                [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage $name -State 'failed' -Message (Protect-HermesLogText $reason) -Percent $percentStart)
                Throw-HermesEasySetupError -Message "Hermes 설치 단계 '$name' 실패: $(Protect-HermesLogText $reason)" -ExitCode 40 -Category 'InstallStage'
            }
            try {
                $postStageRegistryPathValues = @(
                    [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User),
                    [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
                )
                Update-HermesManagedCommandProofAfterStage -Plan $freshPlan -ManagedCommandProof $managedCommandProof -Stage $name -PathValues $postStageRegistryPathValues
                $postStageAbsoluteBoundary = Test-HermesManagedAbsoluteCommandBoundary -Plan $freshPlan -ManagedCommandProof $managedCommandProof
                if (-not $postStageAbsoluteBoundary.Valid) { throw [string]$postStageAbsoluteBoundary.Reason }
                Complete-HermesPersistentEnvironmentStageExpectation -Snapshot $pathExposureSnapshot -Plan $freshPlan -Stage $name -ManagedCommandProof $managedCommandProof
                $persistentPostcondition = Test-HermesPersistentEnvironmentPostcondition -Snapshot $pathExposureSnapshot -Plan $freshPlan
                if (-not $persistentPostcondition.Valid) { throw 'Persistent User environment changed outside the reviewed upstream transition' }
            } catch {
                $reason = "managed command 또는 User 환경 post-stage 검증에 실패했습니다: $(Protect-HermesLogText $_.Exception.Message)"
                $state = Set-HermesStageRecord -State $state -Name $name -Status 'Failed' -Reason $reason -DurationMs ([int]$frame.duration_ms) -InstallerSha256 $installer.Sha256
                $state.status = 'Failed'
                [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
                [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage $name -State 'failed' -Message $reason -Percent $percentStart)
                Throw-HermesEasySetupError -Message "Hermes 설치 단계 '$name' 실패: $reason" -ExitCode 40 -Category 'InstallStage'
            }
            if ($name -eq 'repository' -and $freshRepositoryIntended) {
                try {
                    if ([bool]$frame.skipped) { throw 'Fresh repository stage was unexpectedly skipped' }
                    $freshRepositoryProof = New-HermesFreshRepositoryProof -Seed $freshRepositorySeed -Plan $freshPlan -ExpectedCommit ([string]$sourceConfig.hermes.commitSha)
                } catch {
                    $reason = "fresh repository provenance 검증에 실패했습니다: $(Protect-HermesLogText $_.Exception.Message)"
                    $state = Set-HermesStageRecord -State $state -Name $name -Status 'Failed' -Reason $reason -DurationMs ([int]$frame.duration_ms) -InstallerSha256 $installer.Sha256
                    $state.status = 'Failed'
                    [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
                    [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage $name -State 'failed' -Message $reason -Percent $percentStart)
                    Throw-HermesEasySetupError -Message "Hermes 설치 단계 'repository' 실패: $reason" -ExitCode 40 -Category 'InstallStage'
                }
            } elseif ($name -eq 'repository' -and [bool]$useExistingCheckout) {
                $existingPostRepositoryGate = Test-HermesInstallation -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -ExpectedCommit ([string]$sourceConfig.hermes.commitSha) -ExpectedInstallerSha256 ([string]$sourceConfig.installer.sha256) -StaticOnly -LogPath $logPath
                if (-not $existingPostRepositoryGate.StaticProvenanceValid) {
                    $reason = 'repository 단계 후 기존 checkout provenance 검증에 실패했습니다.'
                    $state = Set-HermesStageRecord -State $state -Name $name -Status 'Failed' -Reason $reason -DurationMs ([int]$frame.duration_ms) -InstallerSha256 $installer.Sha256
                    $state.status = 'Failed'
                    [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
                    Throw-HermesEasySetupError -Message "Hermes 설치 단계 'repository' 실패: $reason" -ExitCode 40 -Category 'InstallStage'
                }
            }
            if ($name -eq 'path') {
                try {
                    if ([bool]$frame.skipped) { throw 'The path stage was unexpectedly skipped' }
                    $postUserPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
                    $postUserHermesHome = [Environment]::GetEnvironmentVariable('HERMES_HOME', [EnvironmentVariableTarget]::User)
                    $pathPostcondition = Test-HermesPathStagePostcondition -Plan $freshPlan -Snapshot $pathExposureSnapshot -UserPath $postUserPath -UserHermesHome $postUserHermesHome
                    if (-not $pathPostcondition.Valid) { throw 'User PATH or HERMES_HOME did not reach the exact postcondition' }
                    if ($null -ne $freshRepositoryProof) {
                        $launcherNormalization = Initialize-HermesManagedLauncherExclusions -Plan $freshPlan -ExpectedCommit ([string]$sourceConfig.hermes.commitSha) -FreshCheckoutProof $freshRepositoryProof
                        $launcherExcludeWrite = $launcherNormalization.ExcludeWrite
                        $attestation = New-HermesLauncherAttestation -Plan $freshPlan -ExpectedCommit ([string]$sourceConfig.hermes.commitSha) -InstallerSha256 ([string]$installer.Sha256) -FreshCheckoutProof $freshRepositoryProof -ManagedCommandProof $managedCommandProof
                        $launcherAttestationWrite = Set-HermesLauncherAttestation -Paths $paths -Attestation $attestation
                    } else {
                        $existingLaunchers = Test-HermesManagedLaunchers -InstallDir ([string]$freshPlan.InstallDir)
                        $existingExclusions = Test-HermesManagedLauncherExclusions -InstallDir ([string]$freshPlan.InstallDir)
                        $existingAttestation = Test-HermesLauncherAttestation -Plan $freshPlan -ExpectedCommit ([string]$sourceConfig.hermes.commitSha) -InstallerSha256 ([string]$installer.Sha256)
                        if (-not $existingLaunchers.Valid -or -not $existingExclusions.Valid -or -not $existingAttestation.Valid) {
                            throw 'Existing or resumed checkout is read-only and does not already satisfy the attested launcher contract'
                        }
                    }
                    $postPathAttestation = Test-HermesLauncherAttestation -Plan $freshPlan -ExpectedCommit ([string]$sourceConfig.hermes.commitSha) -InstallerSha256 ([string]$installer.Sha256)
                    if (-not $postPathAttestation.Valid) { throw [string]$postPathAttestation.Reason }
                } catch {
                    $pendingExcludeWrite = $_.Exception.Data['HermesLauncherExcludeWrite']
                    if ($null -eq $launcherExcludeWrite -and $null -ne $pendingExcludeWrite) { $launcherExcludeWrite = $pendingExcludeWrite }
                    $reason = "공식 launcher 검증 및 checkout 정상화에 실패했습니다: $(Protect-HermesLogText $_.Exception.Message)"
                    $state = Set-HermesStageRecord -State $state -Name $name -Status 'Failed' -Reason $reason -DurationMs ([int]$frame.duration_ms) -InstallerSha256 $installer.Sha256
                    $state.status = 'Failed'
                    [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
                    [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage $name -State 'failed' -Message $reason -Percent $percentStart)
                    Throw-HermesEasySetupError -Message "Hermes 설치 단계 'path' 실패: $reason" -ExitCode 40 -Category 'InstallStage'
                }
            }
            $stageStatus = $(if ([bool]$frame.skipped) { 'Skipped' } else { 'Succeeded' })
            $state = Set-HermesStageRecord -State $state -Name $name -Status $stageStatus -Reason ([string]$frame.reason) -DurationMs ([int]$frame.duration_ms) -InstallerSha256 $installer.Sha256
            [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
            [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage $name -State $stageStatus.ToLowerInvariant() -Message ([string]$stage.title) -Percent $percentEnd)
        }

        [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'verify' -State 'running' -Message '대상 launcher, venv, origin, checkout, marker를 검증하는 중입니다.' -Percent 88)
        $verification = Test-HermesInstallation -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -ExpectedCommit ([string]$sourceConfig.hermes.commitSha) -ExpectedInstallerSha256 ([string]$installer.Sha256) -LogPath $logPath -ProgressCallback $ProgressCallback
        $state.verification = [pscustomobject]@{
            verified = [bool]$verification.Verified
            version = [string]$verification.Version
            doctor_healthy = [bool]$verification.DoctorHealthy
            checkout_head = [string]$verification.CheckoutHead
            origin = [string]$verification.Origin
            marker_commit = [string]$verification.MarkerPinnedCommit
            failed_checks = @($verification.FailedChecks)
            checkout_status = [string]$verification.CheckoutStatus
            managed_launchers_valid = [bool]$verification.ManagedLaunchersValid
            managed_launcher_exclusions_valid = [bool]$verification.ManagedLauncherExclusionsValid
            launcher_attestation_valid = [bool]$verification.LauncherAttestationValid
            repository_metadata_safe = [bool]$verification.RepositoryMetadataSafe
        }
        if (-not $verification.Verified) {
            $state.status = 'Failed'
            [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
            $failedCheckText = @($verification.FailedChecks) -join ', '
            Throw-HermesEasySetupError -Message "공식 단계는 끝났지만 최종 검증에 실패했습니다: $failedCheckText" -ExitCode 50 -Category 'Verification'
        }

        $state.status = 'Completed'
        $state.completed_at = (Get-Date).ToUniversalTime().ToString('o')
        $state.updated_at = $state.completed_at
        [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state)
        [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'complete' -State 'succeeded' -Message "Hermes 설치 완료: $($verification.Version)" -Percent 100 -Data $verification)
        Write-HermesEasySetupLog -LiteralPath $logPath -Message "설치 완료: version=$($verification.Version), commit=$($verification.CheckoutHead), doctor=$($verification.DoctorHealthy)"
        return [pscustomobject]@{ Succeeded = $true; Plan = $freshPlan; Verification = $verification; SetupMode = $SetupMode; StatePath = $paths.StateFile; LogPath = $logPath }
    } catch {
        if ($null -ne $pathExposureSnapshot) {
            [void](Invoke-HermesExposureRollback -Snapshot $pathExposureSnapshot -Plan $freshPlan -FreshRepositoryProof $freshRepositoryProof -LauncherExcludeWrite $launcherExcludeWrite -LauncherAttestationWrite $launcherAttestationWrite -Paths $paths -LogPath $logPath -Context '실패 설치 노출')
        }
        if ($null -ne $state -and [string]$state.status -ne 'Completed') {
            $state.status = 'Failed'
            $state.updated_at = (Get-Date).ToUniversalTime().ToString('o')
            try { [void](Save-HermesInstallState -LiteralPath $paths.StateFile -State $state) } catch {}
        }
        Write-HermesEasySetupLog -LiteralPath $logPath -Message $_.Exception.Message -Level 'ERROR'
        throw
    } finally {
        Exit-HermesInstallLock -Lock $lock
    }
}

function Start-HermesOfficialSetup {
    [CmdletBinding()]
    param(
        [string]$HermesHome,
        [string]$InstallDir,
        [string]$RuntimeRoot,
        [ValidateSet('Later', 'Portal', 'Full')][string]$Mode = 'Portal',
        [switch]$Wait
    )

    if ($Mode -eq 'Later') {
        return [pscustomobject]@{
            Started = $false
            Exited = $false
            ExitCode = $null
            ProcessId = $null
            Mode = 'Later'
            Command = $null
            Reason = 'Later'
        }
    }
    $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    $verification = Test-HermesInstallation -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot
    if (-not $verification.Verified -or [string]::IsNullOrWhiteSpace([string]$verification.CommandPath)) {
        $failed = @($verification.FailedChecks) -join ', '
        Throw-HermesEasySetupError -Message "정적 provenance와 실행 검증을 통과하지 못해 설정을 열 수 없습니다: $failed" -ExitCode 50 -Category 'Setup'
    }
    $command = [string]$verification.CommandPath
    $arguments = @('setup')
    if ($Mode -eq 'Portal') { $arguments += '--portal' }
    $setupEnvironment = @{
        HERMES_HOME = $paths.HermesHome
        VIRTUAL_ENV = (Join-Path $paths.InstallDir 'venv')
        PYTHONHOME = $null
        PYTHONPATH = $null
        PYTHONUSERBASE = $null
        PYTHONSTARTUP = $null
        PYTHONINSPECT = $null
        __PYVENV_LAUNCHER__ = $null
        PYTHONNOUSERSITE = '1'
        PYTHONSAFEPATH = '1'
    }
    $previousEnvironment = @{}
    try {
        foreach ($name in $setupEnvironment.Keys) {
            $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable($name, $setupEnvironment[$name], [EnvironmentVariableTarget]::Process)
        }
        $process = $null
        try {
            # Do not redirect the official child's streams: prompts and credentials stay
            # exclusively in its visible console. Cache the process handle before waiting
            # so Windows PowerShell 5.1 can read ExitCode reliably after process exit.
            $process = Start-Process -FilePath $command -ArgumentList $arguments -PassThru -WindowStyle Normal
            $processId = [int]$process.Id
            [void]$process.Handle
            $exited = $false
            $exitCode = $null
            if ($Wait) {
                $process.WaitForExit()
                $exited = $true
                $exitCode = [int]$process.ExitCode
            }
            return [pscustomobject]@{
                Started = $true
                Exited = $exited
                ExitCode = $exitCode
                ProcessId = $processId
                Mode = $Mode
                Command = $command
            }
        } finally {
            if ($null -ne $process) { $process.Dispose() }
        }
    } finally {
        foreach ($name in $previousEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], [EnvironmentVariableTarget]::Process)
        }
    }
}

Export-ModuleMember -Function @(
    'Get-HermesStageArguments', 'New-HermesStageEnvironment', 'Remove-HermesStageEnvironmentArtifacts',
    'Get-HermesStageTimeoutSeconds', 'Test-HermesStageFrame', 'Convert-HermesBrokenUvPythonMinorJunction',
    'Get-HermesVerificationGitPath',
    'Read-HermesBootstrapMarker', 'Test-HermesInstallation', 'Invoke-HermesInstall',
    'Start-HermesOfficialSetup'
)
