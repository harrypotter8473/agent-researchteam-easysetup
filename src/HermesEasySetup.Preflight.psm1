Set-StrictMode -Version 2.0

$script:HermesPeeledCommitSha = 'fcbd1076a93841fa88855acce810e342a5b78101'
$script:HermesTagObjectSha = 'b05e680e63d39d5a8e3ec0f5842a41d1c4209c03'
$script:HermesOfficialHttpsOrigin = 'https://github.com/NousResearch/hermes-agent.git'
$script:HermesOfficialSshOrigin = 'git@github.com:NousResearch/hermes-agent.git'

function ConvertTo-HermesPreflightPathKey {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    return ([System.IO.Path]::GetFullPath($LiteralPath)).TrimEnd([char[]]@('\', '/'))
}

function Test-HermesPreflightPathOverlap {
    param(
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $true)][string]$Second
    )

    $firstKey = ConvertTo-HermesPreflightPathKey -LiteralPath $First
    $secondKey = ConvertTo-HermesPreflightPathKey -LiteralPath $Second
    if ([string]::Equals($firstKey, $secondKey, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $separator = [System.IO.Path]::DirectorySeparatorChar
    return ($firstKey.StartsWith($secondKey + $separator, [System.StringComparison]::OrdinalIgnoreCase) -or $secondKey.StartsWith($firstKey + $separator, [System.StringComparison]::OrdinalIgnoreCase))
}

function Get-HermesOriginFromGitConfig {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $urls = New-Object 'System.Collections.Generic.List[string]'
    $inOrigin = $false
    foreach ($line in [System.IO.File]::ReadAllLines($ConfigPath, [System.Text.Encoding]::UTF8)) {
        if ($line -match '^\s*\[(?<section>[^\]]+)\]\s*(?:[#;].*)?$') {
            $inOrigin = ([string]$Matches['section'] -match '(?i)^remote\s+"origin"$')
            continue
        }
        if ($inOrigin -and $line -match '^\s*url\s*=\s*(?<url>.*?)\s*$') {
            $url = [string]$Matches['url']
            if (-not [string]::IsNullOrWhiteSpace($url)) {
                $urls.Add($url.Trim())
            }
        }
    }

    return $urls.ToArray()
}

function Test-HermesOfficialGitOrigin {
    param([AllowNull()][AllowEmptyString()][string]$OriginUrl)

    if ([string]::IsNullOrWhiteSpace($OriginUrl)) { return $false }
    return ([string]::Equals($OriginUrl, $script:HermesOfficialHttpsOrigin, [System.StringComparison]::Ordinal) -or [string]::Equals($OriginUrl, $script:HermesOfficialSshOrigin, [System.StringComparison]::Ordinal))
}

function Add-HermesFingerprintField {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Value
    )

    if ($null -eq $Value) { $Value = '' }
    $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($Value)
    [void]$Builder.Append($Name)
    [void]$Builder.Append(':')
    [void]$Builder.Append($byteCount.ToString([System.Globalization.CultureInfo]::InvariantCulture))
    [void]$Builder.Append(':')
    [void]$Builder.Append($Value)
    [void]$Builder.Append("`n")
}

function Get-HermesCommandPath {
    [CmdletBinding()]
    param(
        [string]$HermesHome,
        [Parameter(Mandatory = $true)][string]$InstallDir
    )

    $installRoot = [System.IO.Path]::GetFullPath($InstallDir)
    $candidates = @(
        (Join-Path $installRoot 'bin\hermes.exe'),
        (Join-Path $installRoot 'venv\Scripts\hermes.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    return $null
}

function Get-HermesPreflight {
    [CmdletBinding()]
    param(
        [string]$HermesHome,
        [string]$InstallDir,
        [string]$RuntimeRoot,
        [switch]$IncludeDesktop
    )

    $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    $checks = New-Object 'System.Collections.Generic.List[object]'
    $isWindows = ($env:OS -eq 'Windows_NT')
    $checks.Add([pscustomobject]@{
        Name = 'Windows'; Required = $true; Status = $(if ($isWindows) { 'Pass' } else { 'Fail' })
        Detail = $(if ($isWindows) { 'Windows 네이티브 환경' } else { 'MVP는 Windows 10/11 네이티브 전용입니다.' })
    })

    $osVersion = [Environment]::OSVersion.Version
    $supportedWindows = $isWindows -and ($osVersion.Major -ge 10)
    $checks.Add([pscustomobject]@{
        Name = 'WindowsVersion'; Required = $true; Status = $(if ($supportedWindows) { 'Pass' } else { 'Fail' })
        Detail = "감지 버전: $($osVersion.ToString())"
    })

    $psVersion = $PSVersionTable.PSVersion
    $psSupported = ($psVersion.Major -gt 5) -or (($psVersion.Major -eq 5) -and ($psVersion.Minor -ge 1))
    $checks.Add([pscustomobject]@{
        Name = 'PowerShell'; Required = $true; Status = $(if ($psSupported) { 'Pass' } else { 'Fail' })
        Detail = "PowerShell $psVersion (최소 5.1)"
    })

    $architecture = Get-HermesArchitecture
    $architectureSupported = @('x64', 'arm64') -contains $architecture
    $checks.Add([pscustomobject]@{
        Name = 'Architecture'; Required = $true; Status = $(if ($architectureSupported) { 'Pass' } else { 'Fail' })
        Detail = "감지 아키텍처: $architecture (지원: x64, arm64)"
    })

    # Core owns target and reparse-point policy. Call it for every mutable root.
    $homeSafety = Test-HermesSafeTargetPath -LiteralPath $paths.HermesHome -Label 'HERMES_HOME'
    $installSafety = Test-HermesSafeTargetPath -LiteralPath $paths.InstallDir -Label '설치'
    $runtimeSafety = Test-HermesSafeTargetPath -LiteralPath $paths.RuntimeRoot -Label '런타임'
    $allTargetsSafe = $homeSafety.Safe -and $installSafety.Safe -and $runtimeSafety.Safe
    $targetDetail = if (-not $homeSafety.Safe) {
        $homeSafety.Reason
    } elseif (-not $installSafety.Safe) {
        $installSafety.Reason
    } elseif (-not $runtimeSafety.Safe) {
        $runtimeSafety.Reason
    } else {
        "데이터: $($paths.HermesHome), 코드: $($paths.InstallDir), 런타임: $($paths.RuntimeRoot)"
    }
    $checks.Add([pscustomobject]@{
        Name = 'TargetPaths'; Required = $true; Status = $(if ($allTargetsSafe) { 'Pass' } else { 'Fail' }); Detail = $targetDetail
    })

    $expectedInstallDir = [System.IO.Path]::GetFullPath((Join-Path $paths.HermesHome 'hermes-agent'))
    $layoutValid = [string]::Equals(
        (ConvertTo-HermesPreflightPathKey -LiteralPath $paths.InstallDir),
        (ConvertTo-HermesPreflightPathKey -LiteralPath $expectedInstallDir),
        [System.StringComparison]::OrdinalIgnoreCase
    )
    $checks.Add([pscustomobject]@{
        Name = 'InstallLayout'; Required = $true; Status = $(if ($layoutValid) { 'Pass' } else { 'Fail' })
        Detail = $(if ($layoutValid) { "고정 설치 경로: $expectedInstallDir" } else { "InstallDir은 정확히 다음 경로여야 합니다: $expectedInstallDir" })
    })

    $runtimeIsolated = -not (Test-HermesPreflightPathOverlap -First $paths.RuntimeRoot -Second $paths.HermesHome)
    if ($runtimeIsolated) {
        $runtimeIsolated = -not (Test-HermesPreflightPathOverlap -First $paths.RuntimeRoot -Second $paths.InstallDir)
    }
    $checks.Add([pscustomobject]@{
        Name = 'RuntimeIsolation'; Required = $true; Status = $(if ($runtimeIsolated) { 'Pass' } else { 'Fail' })
        Detail = $(if ($runtimeIsolated) { '런타임 경로가 Hermes 데이터 및 설치 경로와 분리되어 있습니다.' } else { 'RuntimeRoot는 HermesHome 또는 InstallDir과 같거나 서로 포함할 수 없습니다.' })
    })

    $installExists = Test-Path -LiteralPath $paths.InstallDir
    $installIsDirectory = $false
    $installNonEmpty = $false
    $existingCheckout = $false
    $originUrl = $null
    $installDirectorySafe = $true
    $installDirectoryDetail = '새 설치 경로입니다.'
    $gitOriginSafe = $true
    $gitOriginDetail = '기존 Git checkout이 없습니다.'

    if ($installExists) {
        $installItem = Get-Item -LiteralPath $paths.InstallDir -Force -ErrorAction SilentlyContinue
        $installIsDirectory = ($null -ne $installItem -and [bool]$installItem.PSIsContainer)
        if (-not $installIsDirectory) {
            $installDirectorySafe = $false
            $installDirectoryDetail = 'InstallDir 경로에 디렉터리가 아닌 항목이 존재합니다.'
        } else {
            $firstChild = Get-ChildItem -LiteralPath $paths.InstallDir -Force -ErrorAction SilentlyContinue | Select-Object -First 1
            $installNonEmpty = ($null -ne $firstChild)
            if (-not $installNonEmpty) {
                $installDirectoryDetail = '기존 설치 디렉터리가 비어 있습니다.'
            } else {
                $gitPath = Join-Path $paths.InstallDir '.git'
                $existingCheckout = Test-Path -LiteralPath $gitPath -PathType Container
                if (-not $existingCheckout) {
                    $installDirectorySafe = $false
                    $installDirectoryDetail = '비어 있지 않은 InstallDir은 공식 Hermes Git checkout이어야 합니다.'
                } else {
                    $gitSafety = Test-HermesSafeTargetPath -LiteralPath $gitPath -Label 'Git 메타데이터'
                    if (-not $gitSafety.Safe) {
                        $installDirectorySafe = $false
                        $gitOriginSafe = $false
                        $installDirectoryDetail = $gitSafety.Reason
                        $gitOriginDetail = $gitSafety.Reason
                    } else {
                        $gitConfigPath = Join-Path $gitPath 'config'
                        if (-not (Test-Path -LiteralPath $gitConfigPath -PathType Leaf)) {
                            $installDirectorySafe = $false
                            $gitOriginSafe = $false
                            $installDirectoryDetail = '기존 checkout의 .git/config를 찾을 수 없습니다.'
                            $gitOriginDetail = $installDirectoryDetail
                        } else {
                            try {
                                $originUrls = @(Get-HermesOriginFromGitConfig -ConfigPath $gitConfigPath)
                                if ($originUrls.Count -eq 1) { $originUrl = [string]$originUrls[0] }
                                $gitOriginSafe = ($originUrls.Count -eq 1) -and (Test-HermesOfficialGitOrigin -OriginUrl $originUrl)
                            } catch {
                                $gitOriginSafe = $false
                            }
                            if ($gitOriginSafe) {
                                $installDirectoryDetail = '공식 Hermes checkout을 확인했습니다.'
                                $gitOriginDetail = "공식 origin: $originUrl"
                            } else {
                                $installDirectorySafe = $false
                                $installDirectoryDetail = '기존 InstallDir의 Git origin이 공식 NousResearch/hermes-agent 저장소가 아닙니다.'
                                $gitOriginDetail = $(if ([string]::IsNullOrWhiteSpace($originUrl)) { 'origin을 하나로 확인할 수 없습니다.' } else { '허용되지 않은 origin입니다. 원문은 노출하지 않습니다.' })
                            }
                        }
                    }
                }
            }
        }
    }

    $checks.Add([pscustomobject]@{
        Name = 'InstallDirectory'; Required = $true; Status = $(if ($installDirectorySafe) { 'Pass' } else { 'Fail' }); Detail = $installDirectoryDetail
    })
    $checks.Add([pscustomobject]@{
        Name = 'GitOrigin'; Required = $true; Status = $(if ($gitOriginSafe) { 'Pass' } else { 'Fail' }); Detail = $gitOriginDetail
    })

    $requiredGb = $(if ($IncludeDesktop) { 8 } else { 4 })
    $freeGb = $null
    $diskStatus = 'Warn'
    try {
        $root = [System.IO.Path]::GetPathRoot($paths.InstallDir).TrimEnd('\')
        $drive = Get-PSDrive -Name $root.TrimEnd(':') -ErrorAction Stop
        if ($null -ne $drive.Free) {
            $freeGb = [math]::Round(([double]$drive.Free / 1GB), 2)
            $diskStatus = $(if ($freeGb -ge $requiredGb) { 'Pass' } else { 'Fail' })
        }
    } catch {
        $diskStatus = 'Warn'
    }
    $checks.Add([pscustomobject]@{
        Name = 'DiskSpace'; Required = $true; Status = $diskStatus
        Detail = $(if ($null -eq $freeGb) { "여유 공간을 확인하지 못했습니다. 권장: ${requiredGb}GB 이상" } else { "여유 공간: ${freeGb}GB / 권장: ${requiredGb}GB 이상" })
    })

    $existingCommand = Get-HermesCommandPath -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir
    $existingDetail = if ($existingCommand) {
        "대상 내부 Hermes 명령 감지: $existingCommand"
    } elseif ($existingCheckout) {
        "공식 기존 checkout 감지: $($paths.InstallDir)"
    } else {
        '기존 설치를 찾지 못했습니다.'
    }
    $checks.Add([pscustomobject]@{
        Name = 'ExistingInstall'; Required = $false; Status = $(if ($existingCommand -or $existingCheckout) { 'Info' } else { 'Pass' }); Detail = $existingDetail
    })

    $checkArray = $checks.ToArray()
    $blocking = New-Object 'System.Collections.Generic.List[object]'
    foreach ($check in $checkArray) {
        if ([bool]$check.Required -and [string]$check.Status -eq 'Fail') {
            $blocking.Add($check)
        }
    }

    return [pscustomobject]@{
        Ready            = ($blocking.Count -eq 0)
        Architecture     = $architecture
        PowerShell       = $psVersion.ToString()
        OsVersion        = $osVersion.ToString()
        ExistingCommand  = $existingCommand
        ExistingCheckout = [bool]$existingCheckout
        ExistingOrigin   = $(if ($gitOriginSafe -and -not [string]::IsNullOrWhiteSpace($originUrl)) { $originUrl } elseif ([string]::IsNullOrWhiteSpace($originUrl)) { $null } else { '[NON-OFFICIAL-REDACTED]' })
        Paths            = $paths
        Checks           = $checkArray
        BlockingChecks   = $blocking.ToArray()
    }
}

function Test-HermesCompletedInstallForSetup {
    [CmdletBinding()]
    param(
        [AllowNull()]$Diagnosis,
        [AllowNull()]$State,
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$ExpectedCommit
    )

    $newResult = {
        param([bool]$Eligible, [string]$Reason)
        return [pscustomobject]@{ Eligible = $Eligible; Reason = $Reason }
    }
    if ($null -eq $Diagnosis -or $null -eq $State -or $null -eq $Paths) {
        return (& $newResult $false 'MissingEvidence')
    }

    try {
        $diagnosisProperties = @($Diagnosis.PSObject.Properties.Name)
        $pathProperties = @($Paths.PSObject.Properties.Name)
        $stateProperties = @($State.PSObject.Properties.Name)
        if (@('Ready', 'ExistingCheckout', 'ExistingCommand', 'ExistingOrigin', 'Paths') |
            Where-Object { $diagnosisProperties -notcontains $_ }) {
            return (& $newResult $false 'InvalidDiagnosis')
        }
        if (@('HermesHome', 'InstallDir', 'RuntimeRoot') | Where-Object { $pathProperties -notcontains $_ }) {
            return (& $newResult $false 'InvalidPaths')
        }
        if (($Diagnosis.Ready -isnot [bool]) -or -not [bool]$Diagnosis.Ready -or
            ($Diagnosis.ExistingCheckout -isnot [bool]) -or -not [bool]$Diagnosis.ExistingCheckout) {
            return (& $newResult $false 'DiagnosisNotReady')
        }
        if (-not (Test-HermesOfficialGitOrigin -OriginUrl ([string]$Diagnosis.ExistingOrigin))) {
            return (& $newResult $false 'OriginNotOfficial')
        }

        $normalizeDirectory = {
            param([Parameter(Mandatory = $true)][string]$LiteralPath)
            return ([System.IO.Path]::GetFullPath($LiteralPath)).TrimEnd([char[]]@('\', '/'))
        }
        $expectedHome = & $normalizeDirectory ([string]$Paths.HermesHome)
        $expectedInstall = & $normalizeDirectory ([string]$Paths.InstallDir)
        $expectedRuntime = & $normalizeDirectory ([string]$Paths.RuntimeRoot)
        $diagnosisPaths = $Diagnosis.Paths
        if ($null -eq $diagnosisPaths) { return (& $newResult $false 'InvalidDiagnosisPaths') }
        $diagnosisPathProperties = @($diagnosisPaths.PSObject.Properties.Name)
        if (@('HermesHome', 'InstallDir', 'RuntimeRoot') | Where-Object { $diagnosisPathProperties -notcontains $_ }) {
            return (& $newResult $false 'InvalidDiagnosisPaths')
        }
        $diagnosisPathsMatch = (
            [string]::Equals((& $normalizeDirectory ([string]$diagnosisPaths.HermesHome)), $expectedHome, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals((& $normalizeDirectory ([string]$diagnosisPaths.InstallDir)), $expectedInstall, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals((& $normalizeDirectory ([string]$diagnosisPaths.RuntimeRoot)), $expectedRuntime, [StringComparison]::OrdinalIgnoreCase)
        )
        if (-not $diagnosisPathsMatch) { return (& $newResult $false 'DiagnosisPathMismatch') }

        $expectedCommand = [System.IO.Path]::GetFullPath((Join-Path ([string]$Paths.InstallDir) 'bin\hermes.exe'))
        $diagnosedCommand = [System.IO.Path]::GetFullPath([string]$Diagnosis.ExistingCommand)
        if (-not [string]::Equals($diagnosedCommand, $expectedCommand, [StringComparison]::OrdinalIgnoreCase)) {
            return (& $newResult $false 'CommandPathMismatch')
        }

        $requiredStateProperties = @(
            'schema_version', 'status', 'source_commit', 'hermes_home',
            'install_dir', 'runtime_root', 'verification'
        )
        if ($requiredStateProperties | Where-Object { $stateProperties -notcontains $_ }) {
            return (& $newResult $false 'InvalidState')
        }
        if ([int]$State.schema_version -ne 2 -or [string]$State.status -cne 'Completed' -or
            -not [string]::Equals([string]$State.source_commit, $ExpectedCommit, [StringComparison]::OrdinalIgnoreCase)) {
            return (& $newResult $false 'StateNotCompleted')
        }
        $statePathsMatch = (
            [string]::Equals((& $normalizeDirectory ([string]$State.hermes_home)), $expectedHome, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals((& $normalizeDirectory ([string]$State.install_dir)), $expectedInstall, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals((& $normalizeDirectory ([string]$State.runtime_root)), $expectedRuntime, [StringComparison]::OrdinalIgnoreCase)
        )
        if (-not $statePathsMatch) { return (& $newResult $false 'StatePathMismatch') }

        $verification = $State.verification
        if ($null -eq $verification) { return (& $newResult $false 'InvalidVerification') }
        $verificationProperties = @($verification.PSObject.Properties.Name)
        if ($verificationProperties -notcontains 'verified' -or $verificationProperties -notcontains 'failed_checks' -or
            ($verification.verified -isnot [bool]) -or -not [bool]$verification.verified -or
            $null -eq $verification.failed_checks -or @($verification.failed_checks).Count -ne 0) {
            return (& $newResult $false 'InvalidVerification')
        }
    } catch {
        return (& $newResult $false 'MalformedEvidence')
    }
    return (& $newResult $true 'Eligible')
}

function New-HermesInstallPlan {
    [CmdletBinding()]
    param(
        [string]$HermesHome,
        [string]$InstallDir,
        [string]$RuntimeRoot,
        [switch]$IncludeDesktop,
        [switch]$SkipComputerUse,
        [ValidateSet('Later', 'Portal', 'Full')][string]$SetupMode = 'Portal',
        [string]$SourceConfigPath,
        [string]$ManifestContractPath
    )

    $projectRoot = Split-Path -Parent $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($SourceConfigPath)) {
        $SourceConfigPath = Join-Path $projectRoot 'config\hermes-source.json'
    }
    if ([string]::IsNullOrWhiteSpace($ManifestContractPath)) {
        $ManifestContractPath = Join-Path $projectRoot 'config\hermes-manifest.json'
    }

    $config = Get-HermesSourceConfig -LiteralPath $SourceConfigPath
    if (-not (Test-Path -LiteralPath $ManifestContractPath -PathType Leaf)) {
        Throw-HermesEasySetupError -Message "manifest 계약 파일을 찾을 수 없습니다: $ManifestContractPath" -ExitCode 20 -Category 'ManifestContract'
    }
    $manifestContractSha256 = (ConvertTo-HermesSha256 -LiteralPath $ManifestContractPath).ToUpperInvariant()
    $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot

    $configCommit = [string]$config.hermes.commitSha
    $peeledProperty = $config.hermes.PSObject.Properties['peeledCommitSha']
    if ($null -ne $peeledProperty -and -not [string]::Equals([string]$peeledProperty.Value, $script:HermesPeeledCommitSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-HermesEasySetupError -Message '소스 설정의 peeled commit이 검토된 Hermes release commit과 다릅니다.' -ExitCode 20 -Category 'SourceConfig'
    }
    if (-not [string]::Equals($configCommit, $script:HermesPeeledCommitSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-HermesEasySetupError -Message '소스 설정의 commitSha는 검토된 Hermes peeled commit이어야 합니다.' -ExitCode 20 -Category 'SourceConfig'
    }

    $tagObjectSha = $script:HermesTagObjectSha
    $tagProperty = $config.hermes.PSObject.Properties['tagObjectSha']
    if ($null -ne $tagProperty -and -not [string]::IsNullOrWhiteSpace([string]$tagProperty.Value)) {
        $tagObjectSha = [string]$tagProperty.Value
    }

    $releaseTag = [string]$config.hermes.releaseTag
    $installerUri = [string]$config.installer.uri
    $installerApiUri = [string]$config.installer.apiFallbackUri
    $installerBlobSha = [string]$config.installer.gitBlobSha
    $installerSha256 = ([string]$config.installer.sha256).ToUpperInvariant()
    $installerSizeBytes = [int64]$config.installer.sizeBytes
    $installerMaxBytes = [int64]$config.installer.maxBytes
    $protocolVersion = [int]$config.installer.stageProtocolVersion

    $material = New-Object System.Text.StringBuilder
    Add-HermesFingerprintField -Builder $material -Name 'releaseTag' -Value $releaseTag
    Add-HermesFingerprintField -Builder $material -Name 'tagObjectSha' -Value $tagObjectSha.ToLowerInvariant()
    Add-HermesFingerprintField -Builder $material -Name 'peeledCommitSha' -Value $script:HermesPeeledCommitSha
    Add-HermesFingerprintField -Builder $material -Name 'installerUri' -Value $installerUri
    Add-HermesFingerprintField -Builder $material -Name 'installerApiFallbackUri' -Value $installerApiUri
    Add-HermesFingerprintField -Builder $material -Name 'installerGitBlobSha' -Value $installerBlobSha.ToLowerInvariant()
    Add-HermesFingerprintField -Builder $material -Name 'installerSha256' -Value $installerSha256
    Add-HermesFingerprintField -Builder $material -Name 'installerSizeBytes' -Value $installerSizeBytes.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    Add-HermesFingerprintField -Builder $material -Name 'installerMaxBytes' -Value $installerMaxBytes.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    Add-HermesFingerprintField -Builder $material -Name 'stageProtocolVersion' -Value $protocolVersion.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    Add-HermesFingerprintField -Builder $material -Name 'manifestContractSha256' -Value $manifestContractSha256
    Add-HermesFingerprintField -Builder $material -Name 'hermesHome' -Value $paths.HermesHome.ToLowerInvariant()
    Add-HermesFingerprintField -Builder $material -Name 'installDir' -Value $paths.InstallDir.ToLowerInvariant()
    Add-HermesFingerprintField -Builder $material -Name 'runtimeRoot' -Value $paths.RuntimeRoot.ToLowerInvariant()
    Add-HermesFingerprintField -Builder $material -Name 'includeDesktop' -Value ([bool]$IncludeDesktop).ToString().ToLowerInvariant()
    Add-HermesFingerprintField -Builder $material -Name 'skipComputerUse' -Value ([bool]$SkipComputerUse).ToString().ToLowerInvariant()
    Add-HermesFingerprintField -Builder $material -Name 'setupMode' -Value $SetupMode
    $fingerprint = ConvertTo-HermesSha256 -Text $material.ToString()

    $setupDetail = switch ($SetupMode) {
        'Portal' { '마법사에서 OpenAI Codex OAuth와 모델 선택' }
        'Full' { 'hermes setup 열기' }
        default { '나중에 사용자가 직접 설정' }
    }
    $actions = New-Object 'System.Collections.Generic.List[object]'
    $actions.Add([pscustomobject]@{ Order = 1; Name = '진단'; Detail = 'Windows, PowerShell, 아키텍처, 경로, 여유 공간 확인'; Mutates = $false })
    $actions.Add([pscustomobject]@{ Order = 2; Name = '소스 검증'; Detail = "공식 설치기와 manifest 계약 SHA-256 확인 ($releaseTag)"; Mutates = $true })
    $actions.Add([pscustomobject]@{ Order = 3; Name = '공식 단계 실행'; Detail = "stage protocol v${protocolVersion}을 통해 의존성 및 Hermes 설치"; Mutates = $true })
    $actions.Add([pscustomobject]@{ Order = 4; Name = '검증'; Detail = '대상 내부 hermes --version 및 hermes doctor 실행'; Mutates = $false })
    $actions.Add([pscustomobject]@{ Order = 5; Name = '설치 후 설정'; Detail = $setupDetail; Mutates = ($SetupMode -ne 'Later') })

    return [pscustomobject]@{
        SchemaVersion             = 1
        Fingerprint               = $fingerprint
        SourceTag                 = $releaseTag
        SourceCommit              = $script:HermesPeeledCommitSha
        PeeledCommitSha           = $script:HermesPeeledCommitSha
        TagObjectSha              = $tagObjectSha
        SourceSha256              = $installerSha256
        InstallerUri              = $installerUri
        InstallerApiFallbackUri   = $installerApiUri
        InstallerGitBlobSha       = $installerBlobSha
        InstallerSizeBytes        = $installerSizeBytes
        InstallerMaxBytes         = $installerMaxBytes
        StageProtocolVersion       = $protocolVersion
        ManifestContractSha256    = $manifestContractSha256
        HermesHome                = $paths.HermesHome
        InstallDir                = $paths.InstallDir
        RuntimeRoot               = $paths.RuntimeRoot
        IncludeDesktop            = [bool]$IncludeDesktop
        SkipComputerUse           = [bool]$SkipComputerUse
        SetupMode                 = $SetupMode
        Actions                   = $actions.ToArray()
    }
}

function Find-HermesInstallPlanOptionsByFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Fingerprint,
        [string]$HermesHome,
        [string]$InstallDir,
        [string]$RuntimeRoot,
        [string]$SourceConfigPath,
        [string]$ManifestContractPath
    )

    if ($Fingerprint -cnotmatch '^[0-9A-F]{64}$') { return $null }
    foreach ($setupMode in @('Portal', 'Full', 'Later')) {
        foreach ($includeDesktop in @($false, $true)) {
            foreach ($skipComputerUse in @($false, $true)) {
                $arguments = @{
                    HermesHome = $HermesHome
                    InstallDir = $InstallDir
                    RuntimeRoot = $RuntimeRoot
                    IncludeDesktop = $includeDesktop
                    SkipComputerUse = $skipComputerUse
                    SetupMode = $setupMode
                }
                if (-not [string]::IsNullOrWhiteSpace($SourceConfigPath)) { $arguments.SourceConfigPath = $SourceConfigPath }
                if (-not [string]::IsNullOrWhiteSpace($ManifestContractPath)) { $arguments.ManifestContractPath = $ManifestContractPath }
                $plan = New-HermesInstallPlan @arguments
                if ([string]$plan.Fingerprint -ceq $Fingerprint) {
                    return [pscustomobject]@{
                        IncludeDesktop = [bool]$includeDesktop
                        SkipComputerUse = [bool]$skipComputerUse
                        SetupMode = [string]$setupMode
                        Fingerprint = [string]$plan.Fingerprint
                    }
                }
            }
        }
    }
    return $null
}

Export-ModuleMember -Function 'Get-HermesCommandPath', 'Get-HermesPreflight',
    'Test-HermesCompletedInstallForSetup', 'New-HermesInstallPlan',
    'Find-HermesInstallPlanOptionsByFingerprint'
