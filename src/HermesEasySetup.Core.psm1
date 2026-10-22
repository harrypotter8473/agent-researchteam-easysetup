Set-StrictMode -Version 2.0

$script:ModuleRoot = Split-Path -Parent $PSCommandPath
$script:ProjectRoot = Split-Path -Parent $script:ModuleRoot
$script:ExitCodes = [ordered]@{
    Success            = 0
    InvalidArguments   = 2
    PreflightFailed    = 10
    SourceValidation   = 20
    ProtocolMismatch   = 30
    InstallStageFailed = 40
    VerificationFailed = 50
    UnexpectedFailure  = 70
}

function New-HermesEasySetupException {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [string]$Category = 'HermesEasySetup'
    )

    $exception = New-Object System.Exception $Message
    $exception.Data['ExitCode'] = $ExitCode
    $exception.Data['Category'] = $Category
    return $exception
}

function Throw-HermesEasySetupError {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [string]$Category = 'HermesEasySetup'
    )

    throw (New-HermesEasySetupException -Message $Message -ExitCode $ExitCode -Category $Category)
}

function Get-HermesEasySetupExitCodes {
    [CmdletBinding()]
    param()
    return [pscustomobject]$script:ExitCodes
}

function ConvertTo-HermesCanonicalDirectoryPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    if ($LiteralPath -match '(?i)(?:^|[\\/])[^\\/]*~[0-9]+(?:\.[^\\/]*)?(?:[\\/]|$)') {
        Throw-HermesEasySetupError -Message 'DOS 8.3 짧은 경로 표기는 지원하지 않습니다. 긴 절대 경로를 지정하세요.' -ExitCode 10 -Category 'PathSafety'
    }
    $fullPath = [System.IO.Path]::GetFullPath($LiteralPath)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::Equals($fullPath, $rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath
    }
    return $fullPath.TrimEnd('\', '/')
}

function Get-HermesDefaultPaths {
    [CmdletBinding()]
    param(
        [string]$HermesHome,
        [string]$InstallDir,
        [string]$RuntimeRoot
    )

    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    if ([string]::IsNullOrWhiteSpace($localAppData)) { $localAppData = $env:LOCALAPPDATA }
    if ([string]::IsNullOrWhiteSpace($localAppData)) { $localAppData = [System.IO.Path]::GetTempPath() }

    if ([string]::IsNullOrWhiteSpace($HermesHome)) {
        $HermesHome = $(if ([string]::IsNullOrWhiteSpace($env:HERMES_HOME)) { Join-Path $localAppData 'hermes' } else { $env:HERMES_HOME })
    }
    if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = Join-Path $HermesHome 'hermes-agent' }
    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { $RuntimeRoot = Join-Path $localAppData 'HermesEasySetup' }

    $fullHome = ConvertTo-HermesCanonicalDirectoryPath -LiteralPath $HermesHome
    $fullInstall = ConvertTo-HermesCanonicalDirectoryPath -LiteralPath $InstallDir
    $fullRuntime = ConvertTo-HermesCanonicalDirectoryPath -LiteralPath $RuntimeRoot
    return [pscustomobject]@{
        HermesHome  = $fullHome
        InstallDir  = $fullInstall
        RuntimeRoot = $fullRuntime
        CacheDir    = [System.IO.Path]::GetFullPath((Join-Path $fullRuntime 'cache'))
        LogDir      = [System.IO.Path]::GetFullPath((Join-Path $fullRuntime 'logs'))
        StateDir    = [System.IO.Path]::GetFullPath((Join-Path $fullRuntime 'state'))
        StateFile   = [System.IO.Path]::GetFullPath((Join-Path $fullRuntime 'state\install-state.json'))
        LauncherAttestationFile = [System.IO.Path]::GetFullPath((Join-Path $fullRuntime 'state\launcher-attestation-v1.json'))
    }
}

function ConvertTo-HermesSha256 {
    [CmdletBinding(DefaultParameterSetName = 'Text')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Text')][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true, ParameterSetName = 'File')][string]$LiteralPath
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        if ($PSCmdlet.ParameterSetName -eq 'File') {
            $stream = [System.IO.File]::OpenRead($LiteralPath)
            try { $hash = $sha.ComputeHash($stream) } finally { $stream.Dispose() }
        } else {
            $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        }
        return (-join ($hash | ForEach-Object { $_.ToString('x2') })).ToUpperInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Protect-HermesLogText {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { return $null }
    $protected = $Text
    $protected = [regex]::Replace($protected, '(?i)\b(https?://)[^/\s:@]+(?::[^@/\s]*)?@', '$1[REDACTED]@')
    $protected = [regex]::Replace($protected, '(?is)-----BEGIN [^-\r\n]*PRIVATE KEY-----.*?-----END [^-\r\n]*PRIVATE KEY-----', '[REDACTED-PRIVATE-KEY]')
    $protected = [regex]::Replace($protected, '(?i)(Authorization\s*:\s*Bearer\s+)[A-Za-z0-9._~+\-/=]+', '$1[REDACTED]')
    $protected = [regex]::Replace($protected, '(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|secret)\s*[=:]\s*)[^\s,;]+', '$1[REDACTED]')
    $protected = [regex]::Replace($protected, '(?i)("(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|secret)"\s*:\s*")[^"]*(")', '$1[REDACTED]$2')
    $protected = [regex]::Replace($protected, '(?i)([?&](?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|key|secret)=)[^&#\s"]+', '$1[REDACTED]')
    $protected = [regex]::Replace($protected, '(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{12,}', '[REDACTED-KEY]')
    $protected = [regex]::Replace($protected, '(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}(?![A-Za-z0-9_-])', '[REDACTED-JWT]')
    return $protected
}

function Write-HermesEasySetupLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )

    $parent = Split-Path -Parent $LiteralPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $line = '{0} [{1}] {2}' -f (Get-Date).ToUniversalTime().ToString('o'), $Level, (Protect-HermesLogText $Message)
    [System.IO.File]::AppendAllText($LiteralPath, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding $false))
}

function Get-HermesSourceConfig {
    [CmdletBinding()]
    param([string]$LiteralPath = (Join-Path $script:ProjectRoot 'config\hermes-source.json'))

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        Throw-HermesEasySetupError -Message "소스 고정 파일을 찾을 수 없습니다: $LiteralPath" -ExitCode $script:ExitCodes.SourceValidation -Category 'SourceConfig'
    }
    try {
        $config = [System.IO.File]::ReadAllText($LiteralPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        Throw-HermesEasySetupError -Message "소스 고정 파일을 읽을 수 없습니다: $($_.Exception.Message)" -ExitCode $script:ExitCodes.SourceValidation -Category 'SourceConfig'
    }
    $validation = Test-HermesSourceConfig -Config $config
    if (-not $validation.Valid) {
        Throw-HermesEasySetupError -Message ("소스 고정 파일이 안전 계약을 충족하지 않습니다: " + ($validation.Errors -join '; ')) -ExitCode $script:ExitCodes.SourceValidation -Category 'SourceConfig'
    }
    return $config
}

function Test-HermesSourceConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config)

    $errors = New-Object System.Collections.Generic.List[string]
    try {
        if ([int]$Config.schemaVersion -ne 1) { $errors.Add('schemaVersion은 1이어야 합니다.') }
        if ([string]$Config.channel -ne 'verified-release') { $errors.Add('기본 채널은 verified-release여야 합니다.') }
        if ([string]$Config.hermes.repository -ne 'NousResearch/hermes-agent') { $errors.Add('공식 NousResearch/hermes-agent 저장소만 허용됩니다.') }
        if ([string]$Config.reviewedOn -notmatch '^20\d{2}-\d{2}-\d{2}$') { $errors.Add('reviewedOn 형식이 올바르지 않습니다.') }

        $tag = [string]$Config.hermes.releaseTag
        $tagObject = [string]$Config.hermes.tagObjectSha
        $commit = [string]$Config.hermes.commitSha
        if ($tag -notmatch '^v[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}(?:\.[0-9]+)?$') { $errors.Add('releaseTag 형식이 올바르지 않습니다.') }
        if ($tagObject -notmatch '^[0-9a-fA-F]{40}$') { $errors.Add('tagObjectSha는 40자리 Git 객체여야 합니다.') }
        if ($commit -notmatch '^[0-9a-fA-F]{40}$') { $errors.Add('commitSha는 peeled 40자리 Git 커밋이어야 합니다.') }
        if ($tagObject -eq $commit) { $errors.Add('annotated tag 객체와 peeled commit을 구분해야 합니다.') }

        $hash = [string]$Config.installer.sha256
        $blobSha = [string]$Config.installer.gitBlobSha
        if ($hash -notmatch '^[0-9a-fA-F]{64}$') { $errors.Add('installer.sha256은 64자리 SHA-256이어야 합니다.') }
        if ($blobSha -notmatch '^[0-9a-fA-F]{40}$') { $errors.Add('installer.gitBlobSha는 40자리 Git blob이어야 합니다.') }
        if ([int64]$Config.installer.sizeBytes -le 0) { $errors.Add('installer.sizeBytes는 양수여야 합니다.') }
        if ([int64]$Config.installer.maxBytes -lt [int64]$Config.installer.sizeBytes) { $errors.Add('installer.maxBytes가 고정 크기보다 작습니다.') }
        if ([int64]$Config.installer.maxBytes -gt 1048576) { $errors.Add('installer.maxBytes 상한은 1 MiB입니다.') }
        if ([int]$Config.installer.stageProtocolVersion -ne 1) { $errors.Add('지원하는 stage protocol은 v1뿐입니다.') }
        if ([string]$Config.installer.path -ne 'scripts/install.ps1') { $errors.Add('공식 scripts/install.ps1 경로만 허용됩니다.') }

        $allowedHosts = @($Config.allowedDownloadHosts | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
        if ($allowedHosts.Count -ne 2 -or $allowedHosts[0] -ne 'api.github.com' -or $allowedHosts[1] -ne 'raw.githubusercontent.com') {
            $errors.Add('허용 다운로드 호스트는 raw.githubusercontent.com과 api.github.com만 가능합니다.')
        }
        $rawUri = New-Object System.Uri ([string]$Config.installer.uri)
        $expectedRawPath = '/NousResearch/hermes-agent/{0}/scripts/install.ps1' -f $commit
        if ($rawUri.Scheme -ne 'https' -or $rawUri.DnsSafeHost.ToLowerInvariant() -ne 'raw.githubusercontent.com' -or $rawUri.AbsolutePath -cne $expectedRawPath) {
            $errors.Add('설치 URL이 peeled commit의 공식 raw 경로와 일치하지 않습니다.')
        }
        $apiUri = New-Object System.Uri ([string]$Config.installer.apiFallbackUri)
        $expectedApiPath = '/repos/NousResearch/hermes-agent/git/blobs/{0}' -f $blobSha
        if ($apiUri.Scheme -ne 'https' -or $apiUri.DnsSafeHost.ToLowerInvariant() -ne 'api.github.com' -or $apiUri.AbsolutePath -cne $expectedApiPath) {
            $errors.Add('GitHub API fallback이 고정 blob 경로와 일치하지 않습니다.')
        }
    } catch {
        $errors.Add("필수 소스 필드가 없거나 잘못되었습니다: $($_.Exception.Message)")
    }
    return [pscustomobject]@{ Valid = ($errors.Count -eq 0); Errors = $errors.ToArray() }
}

function Get-HermesArchitecture {
    [CmdletBinding()]
    param()

    try {
        $processor = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        switch ([int]$processor.Architecture) {
            12 { return 'arm64' }
            9 { return 'x64' }
            0 { return 'x86' }
        }
    } catch {}
    $raw = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($raw) {
        '^(AMD64|x86_64)$' { return 'x64' }
        '^(ARM64|AARCH64)$' { return 'arm64' }
        '^(x86|i[3-6]86)$' { return 'x86' }
        default { return $(if ([string]::IsNullOrWhiteSpace($raw)) { 'unknown' } else { $raw.ToLowerInvariant() }) }
    }
}

function Test-HermesPathContains {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ParentPath,
        [Parameter(Mandatory = $true)][string]$ChildPath,
        [switch]$AllowEqual
    )

    $parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\', '/')
    $child = [System.IO.Path]::GetFullPath($ChildPath).TrimEnd('\', '/')
    if ($AllowEqual -and $parent -eq $child) { return $true }
    return $child.StartsWith($parent + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Test-HermesSafeTargetPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [string]$Label = 'path'
    )

    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or $LiteralPath.IndexOfAny([char[]]'*?') -ge 0) {
        return [pscustomobject]@{ Safe = $false; Reason = "$Label 경로가 비어 있거나 wildcard를 포함합니다." }
    }
    if ($LiteralPath.StartsWith('\\?\') -or $LiteralPath.StartsWith('\\.\') -or $LiteralPath.StartsWith('\\')) {
        return [pscustomobject]@{ Safe = $false; Reason = "$Label 경로로 device/UNC 경로를 사용할 수 없습니다." }
    }
    if ($LiteralPath -match '(?i)(?:^|[\\/])[^\\/]*~[0-9]+(?:\.[^\\/]*)?(?:[\\/]|$)') {
        return [pscustomobject]@{ Safe = $false; Reason = "$Label 경로에 DOS 8.3 짧은 경로 표기를 사용할 수 없습니다. 긴 경로를 지정하세요." }
    }
    try { $full = [System.IO.Path]::GetFullPath($LiteralPath) } catch { return [pscustomobject]@{ Safe = $false; Reason = "$Label 경로가 올바르지 않습니다." } }
    if (-not [System.IO.Path]::IsPathRooted($full)) { return [pscustomobject]@{ Safe = $false; Reason = "$Label 경로는 절대 경로여야 합니다." } }
    if ($full -match '(?i)(?:^|[\\/])[^\\/]*~[0-9]+(?:\.[^\\/]*)?(?:[\\/]|$)') {
        return [pscustomobject]@{ Safe = $false; Reason = "$Label 경로에 DOS 8.3 짧은 경로 표기를 사용할 수 없습니다. 긴 경로를 지정하세요." }
    }
    $root = [System.IO.Path]::GetPathRoot($full).TrimEnd('\', '/')
    $trimmed = $full.TrimEnd('\', '/')
    if ($trimmed -eq $root) { return [pscustomobject]@{ Safe = $false; Reason = "$Label 경로로 드라이브 루트를 사용할 수 없습니다." } }

    foreach ($protectedRoot in @([Environment]::GetFolderPath('UserProfile'), [Environment]::GetFolderPath('Windows'))) {
        if ([string]::IsNullOrWhiteSpace($protectedRoot)) { continue }
        $protected = [System.IO.Path]::GetFullPath($protectedRoot).TrimEnd('\', '/')
        if ($trimmed -eq $protected -or ($protectedRoot -eq [Environment]::GetFolderPath('Windows') -and (Test-HermesPathContains -ParentPath $protected -ChildPath $trimmed))) {
            return [pscustomobject]@{ Safe = $false; Reason = "$Label 경로로 사용자 프로필 전체 또는 Windows 시스템 폴더를 사용할 수 없습니다." }
        }
    }

    $probe = $full
    while (-not [string]::IsNullOrWhiteSpace($probe)) {
        if (Test-Path -LiteralPath $probe) {
            try {
                $item = Get-Item -LiteralPath $probe -Force
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    return [pscustomobject]@{ Safe = $false; Reason = "$Label 경로 또는 기존 상위 경로가 reparse point입니다: $($item.FullName)" }
                }
            } catch { return [pscustomobject]@{ Safe = $false; Reason = "$Label 경로의 기존 상위 폴더를 확인할 수 없습니다." } }
        }
        $parent = Split-Path -Parent $probe
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $probe) { break }
        $probe = $parent
    }
    return [pscustomobject]@{ Safe = $true; Reason = $null; FullPath = $full }
}

Export-ModuleMember -Function @(
    'New-HermesEasySetupException', 'Throw-HermesEasySetupError', 'Get-HermesEasySetupExitCodes',
    'Get-HermesDefaultPaths', 'ConvertTo-HermesSha256', 'Protect-HermesLogText',
    'Write-HermesEasySetupLog', 'Get-HermesSourceConfig', 'Test-HermesSourceConfig',
    'Get-HermesArchitecture', 'Test-HermesPathContains', 'Test-HermesSafeTargetPath'
)
