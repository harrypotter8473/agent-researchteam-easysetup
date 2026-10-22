Set-StrictMode -Version 2.0

$script:HermesExistingOfficialOrigins = @(
    'https://github.com/NousResearch/hermes-agent.git',
    'git@github.com:NousResearch/hermes-agent.git'
)

function Stop-HermesExistingRuntimeValidation {
    param([Parameter(Mandatory = $true)][string]$Message)
    Throw-HermesEasySetupError -Message $Message -ExitCode 50 -Category 'ExistingRuntime'
}

function Assert-HermesExistingAbsoluteLocalPath {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($LiteralPath) -or
        $LiteralPath -notmatch '^[A-Za-z]:[\\/]' -or
        $LiteralPath.StartsWith('\\') -or
        $LiteralPath.StartsWith('\\?\') -or
        $LiteralPath.StartsWith('\\.\')) {
        Stop-HermesExistingRuntimeValidation -Message "$Label 경로는 로컬 드라이브의 절대 경로여야 합니다."
    }
}

function Assert-HermesExistingSafePath {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $validation = Test-HermesSafeTargetPath -LiteralPath $LiteralPath -Label $Label
    if (-not [bool]$validation.Safe) {
        Stop-HermesExistingRuntimeValidation -Message ([string]$validation.Reason)
    }
}

function Assert-HermesExistingDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$AllowMissing
    )
    Assert-HermesExistingSafePath -LiteralPath $LiteralPath -Label $Label
    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        if ($AllowMissing) { return }
        Stop-HermesExistingRuntimeValidation -Message "$Label 폴더를 찾을 수 없습니다."
    }
    try {
        $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    } catch {
        Stop-HermesExistingRuntimeValidation -Message "$Label 폴더의 메타데이터를 확인할 수 없습니다."
    }
    if (-not [bool]$item.PSIsContainer -or
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-HermesExistingRuntimeValidation -Message "$Label 경로는 일반 로컬 폴더여야 합니다."
    }
}

function Get-HermesExistingRegularFile {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Label,
        [ValidateRange(1, 1073741824)][int64]$MaximumLength
    )
    Assert-HermesExistingSafePath -LiteralPath $LiteralPath -Label $Label
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        Stop-HermesExistingRuntimeValidation -Message "$Label 파일을 찾을 수 없습니다."
    }
    try {
        $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    } catch {
        Stop-HermesExistingRuntimeValidation -Message "$Label 파일의 메타데이터를 확인할 수 없습니다."
    }
    if ([bool]$item.PSIsContainer -or
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -lt 1 -or $item.Length -gt $MaximumLength) {
        Stop-HermesExistingRuntimeValidation -Message "$Label 파일의 형식 또는 크기가 허용 범위를 벗어났습니다."
    }
    return $item
}

function Read-HermesExistingUtf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Label,
        [ValidateRange(1, 16777216)][int64]$MaximumLength
    )
    [void](Get-HermesExistingRegularFile -LiteralPath $LiteralPath -Label $Label -MaximumLength $MaximumLength)
    try {
        [byte[]]$bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $utf8.GetString($bytes)
    } catch {
        Stop-HermesExistingRuntimeValidation -Message "$Label 파일은 올바른 UTF-8 텍스트여야 합니다."
    }
    if ($text.IndexOf([char]0) -ge 0) {
        Stop-HermesExistingRuntimeValidation -Message "$Label 파일에 허용되지 않는 NUL 문자가 있습니다."
    }
    return $text
}

function Test-HermesExistingPortableExecutableHeader {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [ValidateRange(65536, 1073741824)][int64]$MaximumLength
    )
    try {
        [void](Get-HermesExistingRegularFile -LiteralPath $LiteralPath -Label 'native executable' -MaximumLength $MaximumLength)
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
            if ($peHeader[0] -ne 0x50 -or $peHeader[1] -ne 0x45 -or
                $peHeader[2] -ne 0 -or $peHeader[3] -ne 0) { return $false }
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

function Get-HermesExistingGitOrigin {
    param([Parameter(Mandatory = $true)][string]$GitDirectory)
    $configPath = Join-Path $GitDirectory 'config'
    $text = Read-HermesExistingUtf8Text -LiteralPath $configPath -Label 'Git config' -MaximumLength 1MB
    $originUrls = New-Object System.Collections.Generic.List[string]
    $insideOrigin = $false
    foreach ($line in @($text -split "`r?`n")) {
        if ($line -match '^\s*\[') {
            $insideOrigin = [bool]($line -match '^\s*\[\s*remote\s+"origin"\s*\]\s*(?:[#;].*)?$')
            continue
        }
        if (-not $insideOrigin -or $line -match '^\s*(?:$|[#;])') { continue }
        if ($line -match '^\s*url\s*=\s*(.*?)\s*$') {
            [void]$originUrls.Add([string]$Matches[1])
        }
    }
    if ($originUrls.Count -ne 1) {
        Stop-HermesExistingRuntimeValidation -Message 'Git origin은 로컬 config에 정확히 한 번 정의되어야 합니다.'
    }
    $origin = $originUrls[0]
    $official = $false
    foreach ($allowedOrigin in $script:HermesExistingOfficialOrigins) {
        if ([System.StringComparer]::Ordinal.Equals($origin, $allowedOrigin)) {
            $official = $true
            break
        }
    }
    if (-not $official) {
        Stop-HermesExistingRuntimeValidation -Message '선택한 저장소의 Git origin이 공식 Hermes 저장소와 일치하지 않습니다.'
    }
    return [pscustomobject]@{ Origin = $origin; ConfigPath = $configPath }
}

function Test-HermesExistingGitRefName {
    param([Parameter(Mandatory = $true)][string]$RefName)
    if ($RefName -notmatch '^refs/(?:heads|tags)/[A-Za-z0-9._/-]+$' -or
        $RefName.Contains('//') -or $RefName.EndsWith('/') -or
        $RefName.EndsWith('.lock', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    foreach ($segment in @($RefName.Split('/'))) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') { return $false }
    }
    return $true
}

function Get-HermesExistingGitCommit {
    param([Parameter(Mandatory = $true)][string]$GitDirectory)
    $headPath = Join-Path $GitDirectory 'HEAD'
    $headText = (Read-HermesExistingUtf8Text -LiteralPath $headPath -Label 'Git HEAD' -MaximumLength 4096).Trim()
    $evidencePaths = New-Object System.Collections.Generic.List[string]
    [void]$evidencePaths.Add($headPath)
    if ($headText -match '^[0-9A-Fa-f]{40}$') {
        return [pscustomobject]@{ Commit = $headText.ToLowerInvariant(); EvidencePaths = $evidencePaths.ToArray() }
    }
    if ($headText -notmatch '^ref:\s+(refs/.+)$') {
        Stop-HermesExistingRuntimeValidation -Message 'Git HEAD 형식이 올바르지 않습니다.'
    }
    $refName = [string]$Matches[1]
    if (-not (Test-HermesExistingGitRefName -RefName $refName)) {
        Stop-HermesExistingRuntimeValidation -Message 'Git HEAD 참조 이름이 안전하지 않습니다.'
    }
    $refPath = Join-Path $GitDirectory ($refName.Replace('/', '\'))
    $commit = $null
    if (Test-Path -LiteralPath $refPath -PathType Leaf) {
        $commit = (Read-HermesExistingUtf8Text -LiteralPath $refPath -Label 'Git ref' -MaximumLength 4096).Trim()
        [void]$evidencePaths.Add($refPath)
    } else {
        $packedRefsPath = Join-Path $GitDirectory 'packed-refs'
        $packedText = Read-HermesExistingUtf8Text -LiteralPath $packedRefsPath -Label 'Git packed refs' -MaximumLength 4MB
        [void]$evidencePaths.Add($packedRefsPath)
        $matchingCommits = New-Object System.Collections.Generic.List[string]
        foreach ($line in @($packedText -split "`r?`n")) {
            if ($line -match '^([0-9A-Fa-f]{40}) ([^ ]+)$' -and [string]$Matches[2] -ceq $refName) {
                [void]$matchingCommits.Add([string]$Matches[1])
            }
        }
        if ($matchingCommits.Count -ne 1) {
            Stop-HermesExistingRuntimeValidation -Message 'Git HEAD가 가리키는 commit을 안전하게 확인할 수 없습니다.'
        }
        $commit = $matchingCommits[0]
    }
    if ($commit -notmatch '^[0-9A-Fa-f]{40}$') {
        Stop-HermesExistingRuntimeValidation -Message 'Git HEAD가 가리키는 commit 형식이 올바르지 않습니다.'
    }
    return [pscustomobject]@{ Commit = $commit.ToLowerInvariant(); EvidencePaths = $evidencePaths.ToArray() }
}

function Get-HermesExistingRuntimeSnapshot {
    param([Parameter(Mandatory = $true)][string[]]$LiteralPaths)
    $seen = @{}
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($path in $LiteralPaths) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        $key = $fullPath.ToUpperInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $item = Get-HermesExistingRegularFile -LiteralPath $fullPath -Label 'existing runtime evidence' -MaximumLength 512MB
        [void]$records.Add([pscustomobject]@{
            Path = $fullPath
            Length = [int64]$item.Length
            LastWriteTimeUtcTicks = [int64]$item.LastWriteTimeUtc.Ticks
            Sha256 = ConvertTo-HermesSha256 -LiteralPath $fullPath
        })
    }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($record in @($records.ToArray() | Sort-Object Path)) {
        [void]$parts.Add(('{0}|{1}|{2}|{3}' -f $record.Path, $record.Length, $record.LastWriteTimeUtcTicks, $record.Sha256))
    }
    return [pscustomobject]@{
        Records = $records.ToArray()
        Fingerprint = ConvertTo-HermesSha256 -Text ($parts.ToArray() -join "`n")
    }
}

function Get-HermesExistingStaticVersion {
    param(
        [Parameter(Mandatory = $true)][string]$PyProjectPath,
        [Parameter(Mandatory = $true)][string]$Commit
    )

    $text = Read-HermesExistingUtf8Text -LiteralPath $PyProjectPath -Label 'Hermes pyproject' -MaximumLength 4MB
    $projectSection = $false
    $staticVersions = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($text -split "`r?`n")) {
        $sectionMatch = [regex]::Match($line, '^\s*\[([^\]]+)\]\s*(?:#.*)?$')
        if ($sectionMatch.Success) {
            $projectSection = [System.StringComparer]::Ordinal.Equals($sectionMatch.Groups[1].Value, 'project')
            continue
        }
        if (-not $projectSection) { continue }
        $versionMatch = [regex]::Match($line, '^\s*version\s*=\s*"([0-9A-Za-z][0-9A-Za-z._+-]{0,127})"\s*(?:#.*)?$')
        if ($versionMatch.Success) { [void]$staticVersions.Add($versionMatch.Groups[1].Value) }
    }
    $commitLabel = $Commit.Substring(0, 12)
    if ($staticVersions.Count -eq 1 -and
        -not [System.StringComparer]::Ordinal.Equals($staticVersions[0], '0.0.0')) {
        return 'Hermes static source version ' + $staticVersions[0] + ' (commit ' + $commitLabel + ')'
    }
    return 'Hermes existing source (commit ' + $commitLabel + ')'
}

function New-HermesExistingRuntimeEnvironment {
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$VenvScripts
    )
    $environment = Get-HermesCuratedProcessEnvironment
    foreach ($name in @(
        'ALL_PROXY', 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY',
        'CURL_CA_BUNDLE', 'NODE_EXTRA_CA_CERTS', 'REQUESTS_CA_BUNDLE',
        'SSL_CERT_DIR', 'SSL_CERT_FILE'
    )) { [void]$environment.Remove($name) }
    $systemRoot = [string]$environment['SystemRoot']
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        Stop-HermesExistingRuntimeValidation -Message '격리된 자식 프로세스 환경에서 Windows 경로를 확인할 수 없습니다.'
    }
    $environment['PATH'] = @(
        (Join-Path $Paths.InstallDir 'bin'),
        $VenvScripts,
        (Join-Path $systemRoot 'System32'),
        $systemRoot
    ) -join ';'
    $environment['PATHEXT'] = '.COM;.EXE;.BAT;.CMD'
    $environment['HERMES_HOME'] = $Paths.HermesHome
    $environment['VIRTUAL_ENV'] = Join-Path $Paths.InstallDir 'venv'
    $environment['PYTHONHOME'] = $null
    $environment['PYTHONPATH'] = $null
    $environment['PYTHONSTARTUP'] = $null
    $environment['PYTHONINSPECT'] = $null
    $environment['PYTHONNOUSERSITE'] = '1'
    $environment['PYTHONSAFEPATH'] = '1'
    $environment['PYTHONDONTWRITEBYTECODE'] = '1'
    $environment['PYTHONUTF8'] = '1'
    return $environment
}

function Get-HermesExistingRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$HermesHome,
        [Parameter(Mandatory = $true)][string]$InstallDir,
        [Parameter(Mandatory = $true)][string]$RuntimeRoot
    )
    Assert-HermesExistingAbsoluteLocalPath -LiteralPath $HermesHome -Label 'Hermes home'
    Assert-HermesExistingAbsoluteLocalPath -LiteralPath $InstallDir -Label 'Hermes install'
    Assert-HermesExistingAbsoluteLocalPath -LiteralPath $RuntimeRoot -Label 'wizard runtime'
    $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    Assert-HermesExistingSafePath -LiteralPath $paths.HermesHome -Label 'Hermes home'
    Assert-HermesExistingSafePath -LiteralPath $paths.InstallDir -Label 'Hermes install'
    Assert-HermesExistingSafePath -LiteralPath $paths.RuntimeRoot -Label 'wizard runtime'

    $expectedInstall = [System.IO.Path]::GetFullPath((Join-Path $paths.HermesHome 'hermes-agent')).TrimEnd('\', '/')
    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($expectedInstall, $paths.InstallDir)) {
        Stop-HermesExistingRuntimeValidation -Message '기존 Hermes 코드 폴더는 Hermes home 아래 hermes-agent여야 합니다.'
    }
    if ((Test-HermesPathContains -ParentPath $paths.HermesHome -ChildPath $paths.RuntimeRoot -AllowEqual) -or
        (Test-HermesPathContains -ParentPath $paths.RuntimeRoot -ChildPath $paths.HermesHome -AllowEqual) -or
        (Test-HermesPathContains -ParentPath $paths.InstallDir -ChildPath $paths.RuntimeRoot -AllowEqual) -or
        (Test-HermesPathContains -ParentPath $paths.RuntimeRoot -ChildPath $paths.InstallDir -AllowEqual)) {
        Stop-HermesExistingRuntimeValidation -Message 'wizard runtime 폴더는 기존 Hermes home 및 코드 폴더와 중첩될 수 없습니다.'
    }

    Assert-HermesExistingDirectory -LiteralPath $paths.HermesHome -Label 'Hermes home'
    Assert-HermesExistingDirectory -LiteralPath $paths.InstallDir -Label 'Hermes install'
    Assert-HermesExistingDirectory -LiteralPath $paths.RuntimeRoot -Label 'wizard runtime' -AllowMissing
    $gitDirectory = Join-Path $paths.InstallDir '.git'
    Assert-HermesExistingDirectory -LiteralPath $gitDirectory -Label 'Git metadata'
    $venvDirectory = Join-Path $paths.InstallDir 'venv'
    $venvScripts = Join-Path $venvDirectory 'Scripts'
    Assert-HermesExistingDirectory -LiteralPath $venvDirectory -Label 'Python virtual environment'
    Assert-HermesExistingDirectory -LiteralPath $venvScripts -Label 'Python virtual environment scripts'
    Assert-HermesExistingDirectory -LiteralPath (Join-Path $venvDirectory 'Lib\site-packages') -Label 'Python virtual environment packages'
    Assert-HermesExistingDirectory -LiteralPath (Join-Path $paths.InstallDir 'hermes_cli') -Label 'Hermes CLI package'

    $pyProjectPath = Join-Path $paths.InstallDir 'pyproject.toml'
    [void](Get-HermesExistingRegularFile -LiteralPath $pyProjectPath -Label 'Hermes pyproject' -MaximumLength 4MB)
    $venvConfigPath = Join-Path $venvDirectory 'pyvenv.cfg'
    [void](Get-HermesExistingRegularFile -LiteralPath $venvConfigPath -Label 'Python virtual environment config' -MaximumLength 1MB)
    $pythonPath = Join-Path $venvScripts 'python.exe'
    if (-not (Test-HermesExistingPortableExecutableHeader -LiteralPath $pythonPath -MaximumLength 256MB)) {
        Stop-HermesExistingRuntimeValidation -Message '기존 Hermes 가상환경의 python.exe가 안전한 native 실행 파일이 아닙니다.'
    }

    $command = $null
    foreach ($candidate in @(
        (Join-Path $paths.InstallDir 'bin\hermes.exe'),
        (Join-Path $venvScripts 'hermes.exe')
    )) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        if (-not (Test-HermesExistingPortableExecutableHeader -LiteralPath $candidate -MaximumLength 512MB)) {
            Stop-HermesExistingRuntimeValidation -Message '기존 Hermes의 hermes.exe가 안전한 native 실행 파일이 아닙니다.'
        }
        $command = [System.IO.Path]::GetFullPath($candidate)
        break
    }
    if ([string]::IsNullOrWhiteSpace($command)) {
        Stop-HermesExistingRuntimeValidation -Message '허용된 기존 설치 위치에서 native hermes.exe를 찾을 수 없습니다.'
    }

    $originResult = Get-HermesExistingGitOrigin -GitDirectory $gitDirectory
    $commitResult = Get-HermesExistingGitCommit -GitDirectory $gitDirectory
    $evidencePaths = New-Object System.Collections.Generic.List[string]
    foreach ($path in @(
        $command, $pythonPath, $pyProjectPath, $venvConfigPath, $originResult.ConfigPath
    )) { [void]$evidencePaths.Add([string]$path) }
    foreach ($path in @($commitResult.EvidencePaths)) { [void]$evidencePaths.Add([string]$path) }

    $before = Get-HermesExistingRuntimeSnapshot -LiteralPaths $evidencePaths.ToArray()
    $confirmedOriginResult = Get-HermesExistingGitOrigin -GitDirectory $gitDirectory
    $confirmedCommitResult = Get-HermesExistingGitCommit -GitDirectory $gitDirectory
    $initialCommitEvidence = @($commitResult.EvidencePaths | ForEach-Object { [System.IO.Path]::GetFullPath([string]$_) } | Sort-Object)
    $confirmedCommitEvidence = @($confirmedCommitResult.EvidencePaths | ForEach-Object { [System.IO.Path]::GetFullPath([string]$_) } | Sort-Object)
    if (-not [System.StringComparer]::Ordinal.Equals([string]$originResult.Origin, [string]$confirmedOriginResult.Origin) -or
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals([string]$commitResult.Commit, [string]$confirmedCommitResult.Commit) -or
        -not [System.StringComparer]::OrdinalIgnoreCase.Equals(($initialCommitEvidence -join "`n"), ($confirmedCommitEvidence -join "`n"))) {
        Stop-HermesExistingRuntimeValidation -Message '기존 Hermes 저장소 메타데이터가 정적 검증을 시작하는 동안 변경되었습니다.'
    }
    if (-not (Test-HermesExistingPortableExecutableHeader -LiteralPath $command -MaximumLength 512MB) -or
        -not (Test-HermesExistingPortableExecutableHeader -LiteralPath $pythonPath -MaximumLength 256MB)) {
        Stop-HermesExistingRuntimeValidation -Message '기존 Hermes native 실행 파일이 정적 검증을 시작하는 동안 변경되었습니다.'
    }
    $version = Get-HermesExistingStaticVersion -PyProjectPath $pyProjectPath -Commit $confirmedCommitResult.Commit
    $environment = New-HermesExistingRuntimeEnvironment -Paths $paths -VenvScripts $venvScripts
    $after = Get-HermesExistingRuntimeSnapshot -LiteralPaths $evidencePaths.ToArray()
    if (-not [System.StringComparer]::Ordinal.Equals($before.Fingerprint, $after.Fingerprint)) {
        Stop-HermesExistingRuntimeValidation -Message '기존 Hermes 실행 파일 또는 저장소 메타데이터가 정적 검증 중 변경되었습니다.'
    }

    return [pscustomobject][ordered]@{
        Paths = $paths
        Command = $command
        Python = [System.IO.Path]::GetFullPath($pythonPath)
        Environment = $environment
        Version = $version
        Commit = [string]$confirmedCommitResult.Commit
        RuntimeKind = 'Existing'
        TrustBoundary = 'ExplicitExistingHermes'
        Attested = $false
        SnapshotSha256 = [string]$after.Fingerprint
    }
}

Export-ModuleMember -Function 'Get-HermesExistingRuntime'
