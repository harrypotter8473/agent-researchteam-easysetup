[CmdletBinding()]
param(
    [switch]$IncludeDesktop,
    [switch]$Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$tempBase = [System.IO.Path]::GetTempPath()
$smokeRoot = [System.IO.Path]::GetFullPath((Join-Path $tempBase ('hermes-easy-setup-upstream-' + [guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Path $smokeRoot -Force | Out-Null

try {
    Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Loader.psm1') -Force
    $source = Get-HermesSourceConfig
    $headers = @{ 'User-Agent' = 'HermesEasySetup-contract-smoke'; 'Accept' = 'application/vnd.github+json' }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) { $headers['Authorization'] = 'Bearer ' + $env:GITHUB_TOKEN }

    $tag = [string]$source.hermes.releaseTag
    $tagObjectSha = [string]$source.hermes.tagObjectSha
    $commitSha = [string]$source.hermes.commitSha
    $blobSha = [string]$source.installer.gitBlobSha
    $apiRoot = 'https://api.github.com/repos/NousResearch/hermes-agent'
    $tagRef = Invoke-RestMethod -UseBasicParsing -Uri "$apiRoot/git/ref/tags/$([Uri]::EscapeDataString($tag))" -Headers $headers
    if ([string]$tagRef.object.type -ne 'tag' -or [string]$tagRef.object.sha -ne $tagObjectSha) {
        throw 'Release tag does not resolve to the reviewed annotated tag object.'
    }
    $tagObject = Invoke-RestMethod -UseBasicParsing -Uri "$apiRoot/git/tags/$tagObjectSha" -Headers $headers
    if ([string]$tagObject.object.type -ne 'commit' -or [string]$tagObject.object.sha -ne $commitSha) {
        throw 'Annotated tag does not peel to the reviewed release commit.'
    }

    $commit = Invoke-RestMethod -UseBasicParsing -Uri "$apiRoot/git/commits/$commitSha" -Headers $headers
    $tree = Invoke-RestMethod -UseBasicParsing -Uri ($commit.tree.url + '?recursive=1') -Headers $headers
    $installerEntry = @($tree.tree | Where-Object { [string]$_.path -eq 'scripts/install.ps1' -and [string]$_.type -eq 'blob' })
    if ($installerEntry.Count -ne 1 -or [string]$installerEntry[0].sha -ne $blobSha -or [int64]$installerEntry[0].size -ne [int64]$source.installer.sizeBytes) {
        throw 'Release commit tree does not contain the reviewed installer blob and size.'
    }

    $hermesHome = Join-Path $smokeRoot 'hermes-home'
    $installDir = Join-Path $hermesHome 'hermes-agent'
    $runtimeRoot = Join-Path $smokeRoot 'runtime'
    $paths = Get-HermesDefaultPaths -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot
    New-Item -ItemType Directory -Path $paths.LogDir -Force | Out-Null
    $logPath = Join-Path $paths.LogDir 'upstream-contract.log'
    $installer = Get-HermesVerifiedInstaller -SourceConfig $source -Paths $paths -ForceDownload -LogPath $logPath
    $plan = New-HermesInstallPlan -HermesHome $hermesHome -InstallDir $installDir -RuntimeRoot $runtimeRoot -IncludeDesktop:$IncludeDesktop -SkipComputerUse
    $manifest = Get-HermesInstallerManifest -InstallerPath $installer.Path -Plan $plan -SourceConfig $source -LogPath $logPath
    $result = [pscustomobject]@{
        Repository = [string]$source.hermes.repository
        ReleaseTag = $tag
        TagObject = $tagObjectSha
        PeeledCommit = $commitSha
        InstallerBlob = $blobSha
        InstallerSha256 = [string]$installer.Sha256
        ProtocolVersion = [int]$manifest.protocol_version
        StageCount = @($manifest.stages).Count
        FirstStage = [string]$manifest.stages[0].name
        LastStage = [string]$manifest.stages[-1].name
        InstallStagesExecuted = 0
    }
    if ($Json) { $result | ConvertTo-Json -Compress } else { $result | Format-List }
} finally {
    if (Test-Path -LiteralPath $smokeRoot -PathType Container) {
        $tempPrefix = [System.IO.Path]::GetFullPath($tempBase)
        if ($smokeRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $smokeRoot) -like 'hermes-easy-setup-upstream-*') {
            Remove-Item -LiteralPath $smokeRoot -Recurse -Force
        }
    }
}
exit 0
