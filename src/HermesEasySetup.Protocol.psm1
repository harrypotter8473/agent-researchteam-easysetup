Set-StrictMode -Version 2.0

$script:HermesInstallerHardMaxBytes = 1MB

function Assert-HermesInstallerSourceContract {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$SourceConfig)

    $errors = New-Object System.Collections.Generic.List[string]
    try {
        $repository = [string]$SourceConfig.hermes.repository
        $commit = [string]$SourceConfig.hermes.commitSha
        $installerPath = [string]$SourceConfig.installer.path
        $rawUri = [string]$SourceConfig.installer.uri
        $blobSha = [string]$SourceConfig.installer.gitBlobSha
        $fallbackUri = [string]$SourceConfig.installer.apiFallbackUri
        $expectedSize = [int64]$SourceConfig.installer.sizeBytes
        $configuredMax = [int64]$SourceConfig.installer.maxBytes
        $expectedSha256 = [string]$SourceConfig.installer.sha256

        if ($repository -cne 'NousResearch/hermes-agent') {
            $errors.Add('공식 NousResearch/hermes-agent 저장소만 허용됩니다.')
        }
        if ($commit -notmatch '^[0-9a-f]{40}$') {
            $errors.Add('hermes.commitSha는 소문자 40자리 peeled commit SHA여야 합니다.')
        }
        if ($installerPath -cne 'scripts/install.ps1') {
            $errors.Add('공식 scripts/install.ps1 경로만 허용됩니다.')
        }
        if ($blobSha -notmatch '^[0-9a-f]{40}$') {
            $errors.Add('installer.gitBlobSha는 소문자 40자리 Git blob SHA여야 합니다.')
        }
        if ($expectedSha256 -notmatch '^[0-9a-fA-F]{64}$') {
            $errors.Add('installer.sha256은 64자리 SHA-256이어야 합니다.')
        }
        if ($configuredMax -le 0 -or $configuredMax -gt $script:HermesInstallerHardMaxBytes) {
            $errors.Add('installer.maxBytes는 1 이상 1 MiB 이하여야 합니다.')
        }
        if ($expectedSize -le 0 -or $expectedSize -gt $configuredMax -or $expectedSize -gt $script:HermesInstallerHardMaxBytes) {
            $errors.Add('installer.sizeBytes는 양수이며 maxBytes와 1 MiB 상한 이하여야 합니다.')
        }

        if ($commit -match '^[0-9a-f]{40}$') {
            $expectedRawUri = 'https://raw.githubusercontent.com/NousResearch/hermes-agent/{0}/scripts/install.ps1' -f $commit
            if ($rawUri -cne $expectedRawUri) {
                $errors.Add('installer.uri가 peeled commit의 정확한 공식 raw URL과 다릅니다.')
            }
        }
        if ($blobSha -match '^[0-9a-f]{40}$') {
            $expectedFallbackUri = 'https://api.github.com/repos/NousResearch/hermes-agent/git/blobs/{0}' -f $blobSha
            if ($fallbackUri -cne $expectedFallbackUri) {
                $errors.Add('installer.apiFallbackUri가 정확한 공식 Git blob URL과 다릅니다.')
            }
        }

        $allowedHosts = @($SourceConfig.allowedDownloadHosts | ForEach-Object { ([string]$_).ToLowerInvariant() })
        if ($allowedHosts.Count -ne 2 -or
            $allowedHosts -notcontains 'raw.githubusercontent.com' -or
            $allowedHosts -notcontains 'api.github.com') {
            $errors.Add('allowedDownloadHosts는 raw.githubusercontent.com과 api.github.com만 포함해야 합니다.')
        }
    } catch {
        $errors.Add("설치기 소스 계약 필드가 없거나 잘못되었습니다: $($_.Exception.Message)")
    }

    if ($errors.Count -gt 0) {
        Throw-HermesEasySetupError -Message ('설치기 소스 계약이 올바르지 않습니다: ' + ($errors -join '; ')) -ExitCode 20 -Category 'InstallerSourceContract'
    }
}

function Test-HermesInstallerFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)]$SourceConfig
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $sha256 = $null
    $sizeBytes = [int64]0
    $configuredMax = [int64]0
    $expectedSize = [int64]0
    $expectedSha256 = ''

    try {
        $configuredMax = [int64]$SourceConfig.installer.maxBytes
        $expectedSize = [int64]$SourceConfig.installer.sizeBytes
        $expectedSha256 = ([string]$SourceConfig.installer.sha256).ToUpperInvariant()
        if ($configuredMax -le 0 -or $configuredMax -gt $script:HermesInstallerHardMaxBytes) {
            $errors.Add('설치기 최대 크기 계약이 1 MiB 상한을 벗어납니다.')
        }
        if ($expectedSize -le 0 -or $expectedSize -gt $configuredMax -or $expectedSize -gt $script:HermesInstallerHardMaxBytes) {
            $errors.Add('설치기 고정 크기 계약이 올바르지 않습니다.')
        }
        if ($expectedSha256 -notmatch '^[0-9A-F]{64}$') {
            $errors.Add('설치기 SHA-256 계약이 올바르지 않습니다.')
        }
    } catch {
        $errors.Add("설치기 무결성 계약을 읽지 못했습니다: $($_.Exception.Message)")
    }

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        $errors.Add('파일이 없습니다.')
        return [pscustomobject]@{
            Valid = $false; Errors = @($errors); Sha256 = $null; SizeBytes = [int64]0
        }
    }

    try {
        $item = Get-Item -LiteralPath $LiteralPath -ErrorAction Stop
        $sizeBytes = [int64]$item.Length
    } catch {
        $errors.Add("파일 정보를 읽지 못했습니다: $($_.Exception.Message)")
        return [pscustomobject]@{
            Valid = $false; Errors = @($errors); Sha256 = $null; SizeBytes = [int64]0
        }
    }

    if ($sizeBytes -gt $script:HermesInstallerHardMaxBytes) {
        $errors.Add('파일이 절대 상한 1 MiB를 초과합니다.')
    }
    if ($configuredMax -gt 0 -and $sizeBytes -gt $configuredMax) {
        $errors.Add('파일이 허용된 최대 크기를 초과합니다.')
    }
    if ($expectedSize -gt 0 -and $sizeBytes -ne $expectedSize) {
        $errors.Add("파일 크기가 고정 값과 다릅니다: $sizeBytes")
    }

    if ($sizeBytes -le $script:HermesInstallerHardMaxBytes -and
        $configuredMax -gt 0 -and $configuredMax -le $script:HermesInstallerHardMaxBytes -and
        $sizeBytes -le $configuredMax) {
        try {
            $sha256 = ConvertTo-HermesSha256 -LiteralPath $LiteralPath
            if ($expectedSha256 -match '^[0-9A-F]{64}$' -and $sha256 -cne $expectedSha256) {
                $errors.Add('SHA-256이 고정 값과 일치하지 않습니다.')
            }
        } catch {
            $errors.Add("SHA-256을 계산하지 못했습니다: $($_.Exception.Message)")
        }

        $tokens = $null
        $parseErrors = $null
        try {
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                $LiteralPath,
                [ref]$tokens,
                [ref]$parseErrors
            )
            if (@($parseErrors).Count -gt 0) {
                $errors.Add("PowerShell 구문 오류가 있습니다: $($parseErrors[0].Message)")
            }
        } catch {
            $errors.Add("PowerShell AST 검사에 실패했습니다: $($_.Exception.Message)")
        }
    }

    return [pscustomobject]@{
        Valid     = ($errors.Count -eq 0)
        Errors    = @($errors)
        Sha256    = $sha256
        SizeBytes = $sizeBytes
    }
}

function Assert-HermesInstallerIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)]$SourceConfig
    )

    $validation = Test-HermesInstallerFile -LiteralPath $LiteralPath -SourceConfig $SourceConfig
    if (-not $validation.Valid) {
        Throw-HermesEasySetupError -Message ('공식 설치기 무결성 검증 실패: ' + ($validation.Errors -join '; ')) -ExitCode 20 -Category 'InstallerIntegrity'
    }
    return $validation
}

function Invoke-HermesRawInstallerDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][int64]$MaxBytes,
        [AllowNull()][scriptblock]$Downloader
    )

    if ($null -ne $Downloader) {
        & $Downloader $Uri $Destination $MaxBytes | Out-Null
        if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
            throw '사용자 지정 downloader가 설치기 파일을 만들지 않았습니다.'
        }
        return
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $oldProgress = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination -MaximumRedirection 0 `
            -Headers @{ 'User-Agent' = 'HermesEasySetup/0.1' } -ErrorAction Stop | Out-Null
    } finally {
        $ProgressPreference = $oldProgress
    }

    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw 'raw 다운로드가 설치기 파일을 만들지 않았습니다.'
    }
}

function Invoke-HermesBlobInstallerDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$SourceConfig,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $fallbackUri = [string]$SourceConfig.installer.apiFallbackUri
    $expectedBlobSha = [string]$SourceConfig.installer.gitBlobSha
    $configuredMax = [int64]$SourceConfig.installer.maxBytes
    $effectiveMax = [math]::Min($configuredMax, [int64]$script:HermesInstallerHardMaxBytes)

    $blob = Invoke-RestMethod -UseBasicParsing -Uri $fallbackUri -Headers @{
        'User-Agent' = 'HermesEasySetup/0.1'
        'Accept' = 'application/vnd.github+json'
    } -MaximumRedirection 0 -ErrorAction Stop

    if ([string]$blob.sha -cne $expectedBlobSha) {
        throw 'GitHub API가 요청한 고정 blob SHA를 반환하지 않았습니다.'
    }
    if ([string]$blob.encoding -cne 'base64') {
        throw 'GitHub API blob 인코딩이 base64가 아닙니다.'
    }
    if ($blob.PSObject.Properties.Name -notcontains 'content' -or [string]::IsNullOrWhiteSpace([string]$blob.content)) {
        throw 'GitHub API blob 응답에 content가 없습니다.'
    }

    try {
        $bytes = [Convert]::FromBase64String(([string]$blob.content -replace '\s', ''))
    } catch {
        throw "GitHub API blob의 base64 content를 해석하지 못했습니다: $($_.Exception.Message)"
    }
    if ($bytes.Length -gt $effectiveMax -or $bytes.Length -gt $script:HermesInstallerHardMaxBytes) {
        throw 'GitHub blob이 허용된 최대 크기를 초과합니다.'
    }
    if ($bytes.Length -ne [int64]$SourceConfig.installer.sizeBytes) {
        throw 'GitHub blob 크기가 고정 값과 다릅니다.'
    }
    [System.IO.File]::WriteAllBytes($Destination, $bytes)
}

function Get-HermesVerifiedInstaller {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$SourceConfig,
        [Parameter(Mandatory = $true)]$Paths,
        [switch]$ForceDownload,
        [AllowNull()][scriptblock]$Downloader,
        [AllowNull()][scriptblock]$ProgressCallback,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    Assert-HermesInstallerSourceContract -SourceConfig $SourceConfig

    if (-not (Test-Path -LiteralPath $Paths.CacheDir -PathType Container)) {
        New-Item -ItemType Directory -Path $Paths.CacheDir -Force -ErrorAction Stop | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Paths.CacheDir -PathType Container)) {
        Throw-HermesEasySetupError -Message '설치기 캐시 폴더를 준비하지 못했습니다.' -ExitCode 20 -Category 'InstallerCache'
    }

    $commit = [string]$SourceConfig.hermes.commitSha
    $cachePath = Join-Path $Paths.CacheDir ("install-$commit.ps1")
    if ((-not $ForceDownload) -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        $cached = Test-HermesInstallerFile -LiteralPath $cachePath -SourceConfig $SourceConfig
        if ($cached.Valid) {
            Write-HermesEasySetupLog -LiteralPath $LogPath -Message "검증된 캐시 설치기 사용: $cachePath"
            [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'source' -State 'verified-cache' -Message '검증된 공식 설치기 캐시를 사용합니다.' -Percent 6)
            return [pscustomobject]@{
                Path = $cachePath; Source = 'cache'; Sha256 = $cached.Sha256; Commit = $commit
            }
        }

        $quarantine = '{0}.rejected-{1}-{2}' -f $cachePath, (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'), ([guid]::NewGuid().ToString('N'))
        Move-Item -LiteralPath $cachePath -Destination $quarantine -ErrorAction Stop
        Write-HermesEasySetupLog -LiteralPath $LogPath -Message "검증 실패 캐시 격리: $quarantine" -Level 'WARN'
    }

    $temporary = Join-Path $Paths.CacheDir ('.download-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $rawUri = [string]$SourceConfig.installer.uri
    $maxBytes = [int64]$SourceConfig.installer.maxBytes
    [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'source' -State 'downloading' -Message "공식 설치기를 내려받는 중: $([string]$SourceConfig.hermes.releaseTag)" -Percent 4)
    Write-HermesEasySetupLog -LiteralPath $LogPath -Message "설치기 raw 다운로드: $rawUri"

    try {
        $rawFailure = $null
        try {
            Invoke-HermesRawInstallerDownload -Uri $rawUri -Destination $temporary -MaxBytes $maxBytes -Downloader $Downloader
        } catch {
            $rawFailure = $_.Exception.Message
            if (Test-Path -LiteralPath $temporary -PathType Leaf) {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop
            }
        }

        if ($null -eq $rawFailure) {
            # An integrity mismatch is not an availability failure. Do not hide a
            # raw/blob inconsistency by silently accepting the fallback source.
            [void](Assert-HermesInstallerIntegrity -LiteralPath $temporary -SourceConfig $SourceConfig)
        } else {
            Write-HermesEasySetupLog -LiteralPath $LogPath -Message "raw 다운로드 실패 후 고정 Git blob API fallback 사용: $rawFailure" -Level 'WARN'
            Invoke-HermesBlobInstallerDownload -SourceConfig $SourceConfig -Destination $temporary
            [void](Assert-HermesInstallerIntegrity -LiteralPath $temporary -SourceConfig $SourceConfig)
        }

        if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
            $previous = '{0}.previous-{1}-{2}' -f $cachePath, (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'), ([guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $cachePath -Destination $previous -ErrorAction Stop
        }
        Move-Item -LiteralPath $temporary -Destination $cachePath -ErrorAction Stop

        # Re-open the final cache path. This catches replacement/truncation
        # between validation and the atomic same-directory move.
        $validation = Assert-HermesInstallerIntegrity -LiteralPath $cachePath -SourceConfig $SourceConfig
        Write-HermesEasySetupLog -LiteralPath $LogPath -Message "설치기 검증 완료: SHA256=$($validation.Sha256), bytes=$($validation.SizeBytes)"
        [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'source' -State 'verified' -Message '공식 설치기 커밋·크기·SHA-256·구문 검증이 끝났습니다.' -Percent 8)
        return [pscustomobject]@{
            Path = $cachePath; Source = 'download'; Sha256 = $validation.Sha256; Commit = $commit
        }
    } catch {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if ($_.Exception.Data.Contains('ExitCode')) { throw }
        Throw-HermesEasySetupError -Message "공식 설치기를 가져오지 못했습니다: $($_.Exception.Message)" -ExitCode 20 -Category 'InstallerDownload'
    }
}

function Get-HermesInstallerArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$SourceConfig,
        [switch]$IncludeNonInteractive
    )

    $arguments = @(
        '-Commit', [string]$SourceConfig.hermes.commitSha,
        '-HermesHome', [string]$Plan.HermesHome,
        '-InstallDir', [string]$Plan.InstallDir,
        '-SkipSetup'
    )
    if ([bool]$Plan.IncludeDesktop) { $arguments += '-IncludeDesktop' }
    if ([bool]$Plan.SkipComputerUse) { $arguments += '-SkipComputerUse' }
    if ($IncludeNonInteractive) { $arguments += @('-NonInteractive', '-Json') }

    # Intentionally enumerate the string array. Callers receive a flat argv,
    # including when they wrap this function in @(...).
    return $arguments
}

function Get-HermesExpectedStageCategory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    if (@('uv', 'python', 'git', 'node', 'system-packages') -contains $Name) { return 'prereqs' }
    if (@('repository', 'venv', 'dependencies', 'node-deps', 'desktop') -contains $Name) { return 'install' }
    if (@('path', 'config-templates', 'platform-sdks', 'bootstrap-marker') -contains $Name) { return 'finalize' }
    if (@('configure', 'gateway') -contains $Name) { return 'post-install' }
    return $null
}

function Test-HermesInstallerManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][bool]$IncludeDesktop,
        [string]$ContractPath
    )

    if ([string]::IsNullOrWhiteSpace($ContractPath)) {
        $ContractPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\hermes-manifest.json'
    }

    $errors = New-Object System.Collections.Generic.List[string]
    try {
        $contract = [System.IO.File]::ReadAllText($ContractPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ([int]$contract.schemaVersion -ne 1) {
            $errors.Add('검토된 manifest 계약 schemaVersion은 1이어야 합니다.')
        }

        $topLevelProperties = @($Manifest.PSObject.Properties | ForEach-Object { [string]$_.Name })
        foreach ($required in @('protocol_version', 'stages')) {
            if ($topLevelProperties -notcontains $required) { $errors.Add("manifest 필수 필드가 없습니다: $required") }
        }
        foreach ($property in $topLevelProperties) {
            if (@('protocol_version', 'stages') -notcontains $property) { $errors.Add("manifest에 예상하지 못한 필드가 있습니다: $property") }
        }

        if ([int]$Manifest.protocol_version -ne [int]$contract.protocolVersion) {
            $errors.Add('stage protocol 버전이 검토된 계약과 다릅니다.')
        }

        $baseStages = @($contract.baseStages | ForEach-Object { [string]$_ })
        $interactiveStages = @($contract.interactiveStages | ForEach-Object { [string]$_ })
        $allowedCategories = @($contract.allowedCategories | ForEach-Object { [string]$_ })
        if (($baseStages | Select-Object -Unique).Count -ne $baseStages.Count) { $errors.Add('검토된 계약에 중복 base stage가 있습니다.') }
        if (($interactiveStages | Select-Object -Unique).Count -ne $interactiveStages.Count) { $errors.Add('검토된 계약에 중복 interactive stage가 있습니다.') }
        if (($allowedCategories | Select-Object -Unique).Count -ne $allowedCategories.Count) { $errors.Add('검토된 계약에 중복 category가 있습니다.') }
        if (($allowedCategories -join ',') -cne 'prereqs,install,finalize,post-install') {
            $errors.Add('검토된 계약의 category 집합 또는 순서가 v2026.8.19 계약과 다릅니다.')
        }

        $expected = New-Object System.Collections.Generic.List[string]
        $desktopInserted = $false
        foreach ($name in $baseStages) {
            $expected.Add($name)
            if ($IncludeDesktop -and $name -ceq [string]$contract.desktopStage.after) {
                $expected.Add([string]$contract.desktopStage.name)
                $desktopInserted = $true
            }
        }
        if ($IncludeDesktop -and -not $desktopInserted) {
            $errors.Add('검토된 계약에서 desktop stage 삽입 위치를 찾지 못했습니다.')
        }

        $actualStages = @($Manifest.stages)
        $actualNames = @($actualStages | ForEach-Object { [string]$_.name })
        if ($actualNames.Count -ne $expected.Count) {
            $errors.Add("단계 수가 검토된 계약과 다릅니다. 예상=$($expected.Count), 실제=$($actualNames.Count)")
        } else {
            for ($i = 0; $i -lt $actualNames.Count; $i++) {
                if ($actualNames[$i] -cne $expected[$i]) {
                    $errors.Add("단계 순서가 다릅니다: 위치 $i, 예상=$($expected[$i]), 실제=$($actualNames[$i])")
                }
            }
        }
        if (($actualNames | Select-Object -Unique).Count -ne $actualNames.Count) {
            $errors.Add('manifest에 중복 단계가 있습니다.')
        }

        foreach ($stage in $actualStages) {
            $stageProperties = @($stage.PSObject.Properties | ForEach-Object { [string]$_.Name })
            foreach ($required in @('name', 'title', 'category', 'needs_user_input')) {
                if ($stageProperties -notcontains $required) { $errors.Add("stage 필수 필드가 없습니다: $([string]$stage.name)/$required") }
            }
            foreach ($property in $stageProperties) {
                if (@('name', 'title', 'category', 'needs_user_input') -notcontains $property) {
                    $errors.Add("stage에 예상하지 못한 필드가 있습니다: $([string]$stage.name)/$property")
                }
            }

            $name = [string]$stage.name
            if ($name -notmatch '^[a-z0-9-]+$') { $errors.Add("허용되지 않은 단계 이름입니다: $name") }
            if ([string]::IsNullOrWhiteSpace([string]$stage.title)) { $errors.Add("단계 제목이 비어 있습니다: $name") }

            $expectedCategory = Get-HermesExpectedStageCategory -Name $name
            if ([string]::IsNullOrWhiteSpace($expectedCategory)) {
                $errors.Add("category 계약이 없는 단계입니다: $name")
            } elseif ([string]$stage.category -cne $expectedCategory) {
                $errors.Add("단계 category가 계약과 다릅니다: $name, 예상=$expectedCategory, 실제=$([string]$stage.category)")
            }
            if ($allowedCategories -notcontains [string]$stage.category) {
                $errors.Add("허용되지 않은 단계 category입니다: $name/$([string]$stage.category)")
            }

            $needsInputProperty = $stage.PSObject.Properties['needs_user_input']
            if ($null -eq $needsInputProperty -or -not ($needsInputProperty.Value -is [bool])) {
                $errors.Add("needs_user_input이 boolean이 아닙니다: $name")
            } else {
                $expectedInteractive = $interactiveStages -contains $name
                if ([bool]$needsInputProperty.Value -ne $expectedInteractive) {
                    $errors.Add("대화형 단계 플래그가 계약과 다릅니다: $name")
                }
            }
        }
    } catch {
        $errors.Add("manifest 계약을 검사하지 못했습니다: $($_.Exception.Message)")
    }

    return [pscustomobject]@{
        Valid = ($errors.Count -eq 0)
        Errors = @($errors)
    }
}

function Get-HermesInstallerManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$SourceConfig,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [AllowNull()][scriptblock]$ProgressCallback
    )

    $powershell = Get-HermesPowerShellExecutable
    $common = @(Get-HermesInstallerArguments -Plan $Plan -SourceConfig $SourceConfig)
    $environment = Get-HermesCuratedProcessEnvironment
    $environment['HERMES_HOME'] = [string]$Plan.HermesHome

    # Validate immediately before each executable boundary. The same public
    # assertion is available to the stage driver for every -Stage invocation.
    [void](Assert-HermesInstallerIntegrity -LiteralPath $InstallerPath -SourceConfig $SourceConfig)
    $protocolArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $InstallerPath, '-ProtocolVersion') + $common
    $protocolResult = Invoke-HermesProcess -FilePath $powershell -ArgumentList $protocolArgs -Environment $environment -TimeoutSeconds 120
    Write-HermesCapturedOutput -ProcessResult $protocolResult -LogPath $LogPath -Stage 'protocol' -Callback $ProgressCallback
    $protocolText = ([string]$protocolResult.StdOut).Trim()
    if ($protocolResult.ExitCode -ne 0 -or $protocolText -notmatch '^\d+$' -or [int]$protocolText -ne [int]$SourceConfig.installer.stageProtocolVersion) {
        Throw-HermesEasySetupError -Message '공식 설치기의 stage protocol 버전이 맞지 않습니다.' -ExitCode 30 -Category 'StageProtocol'
    }

    [void](Assert-HermesInstallerIntegrity -LiteralPath $InstallerPath -SourceConfig $SourceConfig)
    $manifestArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $InstallerPath, '-Manifest') + $common
    $manifestResult = Invoke-HermesProcess -FilePath $powershell -ArgumentList $manifestArgs -Environment $environment -TimeoutSeconds 120
    Write-HermesCapturedOutput -ProcessResult $manifestResult -LogPath $LogPath -Stage 'manifest' -Callback $ProgressCallback
    $manifestText = ([string]$manifestResult.StdOut).Trim()
    $manifest = $null
    if ($manifestResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($manifestText)) {
        try { $manifest = $manifestText | ConvertFrom-Json -ErrorAction Stop } catch { $manifest = $null }
    }
    if ($manifestResult.ExitCode -ne 0 -or $null -eq $manifest) {
        Throw-HermesEasySetupError -Message '공식 설치기의 단계 manifest를 읽지 못했습니다.' -ExitCode 30 -Category 'StageManifest'
    }

    $validation = Test-HermesInstallerManifest -Manifest $manifest -IncludeDesktop ([bool]$Plan.IncludeDesktop)
    if (-not $validation.Valid) {
        Throw-HermesEasySetupError -Message ('공식 설치기의 단계 manifest가 검토된 계약과 다릅니다: ' + ($validation.Errors -join '; ')) -ExitCode 30 -Category 'StageManifest'
    }
    [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'manifest' -State 'verified' -Message "설치 단계 $(@($manifest.stages).Count)개를 검증했습니다." -Percent 10 -Data $manifest)
    return $manifest
}

Export-ModuleMember -Function @(
    'Test-HermesInstallerFile',
    'Assert-HermesInstallerIntegrity',
    'Get-HermesVerifiedInstaller',
    'Get-HermesInstallerArguments',
    'Test-HermesInstallerManifest',
    'Get-HermesInstallerManifest'
)
