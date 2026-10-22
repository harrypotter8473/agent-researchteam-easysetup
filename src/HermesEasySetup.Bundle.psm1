Set-StrictMode -Version 2.0

function Protect-HermesDiagnosticText {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)]$Paths
    )

    if ($null -eq $Text) { return $null }
    $protected = Protect-HermesLogText $Text
    $replacements = @(
        [pscustomobject]@{ Value = [string]$Paths.InstallDir; Token = '%HERMES_INSTALL_DIR%' },
        [pscustomobject]@{ Value = [string]$Paths.RuntimeRoot; Token = '%HERMES_EASY_SETUP_RUNTIME%' },
        [pscustomobject]@{ Value = [string]$Paths.HermesHome; Token = '%HERMES_HOME%' },
        [pscustomobject]@{ Value = [Environment]::GetFolderPath('UserProfile'); Token = '%USERPROFILE%' },
        [pscustomobject]@{ Value = [Environment]::GetFolderPath('LocalApplicationData'); Token = '%LOCALAPPDATA%' },
        [pscustomobject]@{ Value = [System.IO.Path]::GetTempPath().TrimEnd('\'); Token = '%TEMP%' }
    ) | Sort-Object { ([string]$_.Value).Length } -Descending
    foreach ($replacement in $replacements) {
        if ([string]::IsNullOrWhiteSpace([string]$replacement.Value)) { continue }
        $protected = [regex]::Replace($protected, [regex]::Escape([string]$replacement.Value), [string]$replacement.Token, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    $protected = [regex]::Replace($protected, '(?i)\\Users\\[^\\\s"/]+', '\Users\%USERNAME%')
    return $protected
}

function Export-HermesDiagnosticBundle {
    [CmdletBinding()]
    param(
        [string]$HermesHome,
        [string]$InstallDir,
        [string]$RuntimeRoot,
        [string]$DestinationPath,
        [string]$SourceConfigPath
    )

    $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    if ([string]::IsNullOrWhiteSpace($SourceConfigPath)) { $SourceConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config\hermes-source.json' }
    $bundleRoot = Join-Path $paths.RuntimeRoot 'diagnostics'
    if (-not (Test-Path -LiteralPath $bundleRoot -PathType Container)) { New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null }
    if ([string]::IsNullOrWhiteSpace($DestinationPath)) { $DestinationPath = Join-Path $bundleRoot ("hermes-easy-setup-diagnostics-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')).zip") }
    $DestinationPath = [System.IO.Path]::GetFullPath($DestinationPath)
    $staging = [System.IO.Path]::GetFullPath((Join-Path $bundleRoot ('bundle-' + [guid]::NewGuid().ToString('N'))))
    $bundlePrefix = [System.IO.Path]::GetFullPath($bundleRoot).TrimEnd('\') + '\'
    if (-not $staging.StartsWith($bundlePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw '진단 임시 경로가 안전 범위를 벗어났습니다.' }

    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $encoding = New-Object System.Text.UTF8Encoding $false
    try {
        $preflight = Get-HermesPreflight -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot
        $preflightText = Protect-HermesDiagnosticText -Text ($preflight | ConvertTo-Json -Depth 10) -Paths $paths
        [System.IO.File]::WriteAllText((Join-Path $staging 'preflight.json'), $preflightText, $encoding)

        $source = Get-HermesSourceConfig -LiteralPath $SourceConfigPath
        $sourceSummary = [ordered]@{
            reviewed_on = [string]$source.reviewedOn
            release_tag = [string]$source.hermes.releaseTag
            tag_object_sha = [string]$source.hermes.tagObjectSha
            peeled_commit_sha = [string]$source.hermes.commitSha
            installer_blob_sha = [string]$source.installer.gitBlobSha
            installer_sha256 = [string]$source.installer.sha256
            protocol_version = [int]$source.installer.stageProtocolVersion
        }
        [System.IO.File]::WriteAllText((Join-Path $staging 'source-summary.json'), ($sourceSummary | ConvertTo-Json), $encoding)

        $state = Read-HermesInstallState -LiteralPath $paths.StateFile
        if ($null -ne $state) {
            $stateText = Protect-HermesDiagnosticText -Text ($state | ConvertTo-Json -Depth 14) -Paths $paths
            [System.IO.File]::WriteAllText((Join-Path $staging 'install-state.json'), $stateText, $encoding)
        }
        if (Test-Path -LiteralPath $paths.LogDir -PathType Container) {
            $logOutput = Join-Path $staging 'logs'
            New-Item -ItemType Directory -Path $logOutput -Force | Out-Null
            foreach ($log in @(Get-ChildItem -LiteralPath $paths.LogDir -Filter '*.log' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 3)) {
                $redacted = Protect-HermesDiagnosticText -Text ([System.IO.File]::ReadAllText($log.FullName, [System.Text.Encoding]::UTF8)) -Paths $paths
                [System.IO.File]::WriteAllText((Join-Path $logOutput $log.Name), $redacted, $encoding)
            }
        }
        $notice = @'
Hermes Easy Setup diagnostic bundle

- This archive is created locally and is never uploaded automatically.
- It excludes HERMES_HOME/.env, config.yaml, auth data, skills, sessions,
  memories, messages, and every other Hermes user-data file.
- Secrets and known local paths are redacted on a best-effort basis.
- Review every file yourself before sharing. Delete the ZIP when no longer needed.
'@
        [System.IO.File]::WriteAllText((Join-Path $staging 'README.txt'), $notice, $encoding)

        $destinationParent = Split-Path -Parent $DestinationPath
        if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) { New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null }
        if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) { throw "진단 ZIP이 이미 있습니다: $DestinationPath" }
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $DestinationPath -CompressionLevel Optimal
        return [pscustomobject]@{ Created = $true; Path = $DestinationPath; Uploaded = $false; Redaction = 'best-effort' }
    } finally {
        if (Test-Path -LiteralPath $staging -PathType Container) {
            $resolved = [System.IO.Path]::GetFullPath($staging)
            if ($resolved.StartsWith($bundlePrefix, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'bundle-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
        }
    }
}

Export-ModuleMember -Function 'Protect-HermesDiagnosticText', 'Export-HermesDiagnosticBundle'
