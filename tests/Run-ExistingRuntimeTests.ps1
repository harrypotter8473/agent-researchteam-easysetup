[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Core.psm1') -Force
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Execution.psm1') -Force
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Existing.psm1') -Force
$existingModule = Get-Module 'HermesEasySetup.Existing'

function Assert-ExistingRuntime {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Name)
    if (-not $Condition) { throw "FAIL $Name" }
    Write-Host "PASS $Name" -ForegroundColor Green
}

function Assert-ExistingRuntimeRejected {
    param([Parameter(Mandatory = $true)][scriptblock]$Action, [Parameter(Mandatory = $true)][string]$Name)
    try {
        & $Action | Out-Null
    } catch {
        Write-Host "PASS $Name" -ForegroundColor Green
        return $_
    }
    throw "FAIL $Name"
}

function Write-ExistingRuntimeUtf8 {
    param([Parameter(Mandatory = $true)][string]$LiteralPath, [Parameter(Mandatory = $true)][string]$Text)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($LiteralPath, $Text, $utf8)
}

function New-ExistingRuntimePortableExecutableBytes {
    param([Parameter(Mandatory = $true)][string]$Seed)
    $payload = [System.Text.Encoding]::ASCII.GetBytes($Seed)
    $bytes = New-Object byte[] (512 + $payload.Length)
    $bytes[0] = 0x4D
    $bytes[1] = 0x5A
    [BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3C)
    $bytes[0x80] = 0x50
    $bytes[0x81] = 0x45
    $bytes[0x82] = 0
    $bytes[0x83] = 0
    [BitConverter]::GetBytes([uint16]0x8664).CopyTo($bytes, 0x84)
    [BitConverter]::GetBytes([uint16]1).CopyTo($bytes, 0x86)
    [BitConverter]::GetBytes([uint16]0xF0).CopyTo($bytes, 0x94)
    [BitConverter]::GetBytes([uint16]0x22).CopyTo($bytes, 0x96)
    [BitConverter]::GetBytes([uint16]0x20B).CopyTo($bytes, 0x98)
    $payload.CopyTo($bytes, 0x1A0)
    return ,$bytes
}

function Write-ExistingRuntimePortableExecutable {
    param([Parameter(Mandatory = $true)][string]$LiteralPath, [Parameter(Mandatory = $true)][string]$Seed)
    [System.IO.File]::WriteAllBytes($LiteralPath, [byte[]](New-ExistingRuntimePortableExecutableBytes -Seed $Seed))
}

function Write-ExistingRuntimeGitConfig {
    param([Parameter(Mandatory = $true)][string]$LiteralPath, [Parameter(Mandatory = $true)][string]$Origin)
    $lines = @(
        '[core]',
        '    repositoryformatversion = 1',
        '    filemode = false',
        '[remote "origin"]',
        "    url = $Origin",
        '    fetch = +refs/heads/*:refs/remotes/origin/*',
        '[hermes-easy-setup-fixture]',
        '    extraLauncherAccepted = true'
    )
    Write-ExistingRuntimeUtf8 -LiteralPath $LiteralPath -Text ($lines -join [Environment]::NewLine)
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('hermes-existing-runtime-tests-' + [Guid]::NewGuid().ToString('N'))
$hermesHomePath = Join-Path $testRoot 'home'
$install = Join-Path $hermesHomePath 'hermes-agent'
$runtimeRoot = Join-Path $testRoot 'wizard-runtime'
$gitDirectory = Join-Path $install '.git'
$gitRefDirectory = Join-Path $gitDirectory 'refs\heads'
$binDirectory = Join-Path $install 'bin'
$venvDirectory = Join-Path $install 'venv'
$venvScripts = Join-Path $venvDirectory 'Scripts'
$cliDirectory = Join-Path $install 'hermes_cli'
$binHermes = Join-Path $binDirectory 'hermes.exe'
$venvHermes = Join-Path $venvScripts 'hermes.exe'
$python = Join-Path $venvScripts 'python.exe'
$pyProjectPath = Join-Path $install 'pyproject.toml'
$configPath = Join-Path $gitDirectory 'config'
$headPath = Join-Path $gitDirectory 'HEAD'
$refPath = Join-Path $gitRefDirectory 'main'
$packedRefsPath = Join-Path $gitDirectory 'packed-refs'
$commit = 'fcbd140344a0b2694fd6a585849a44ce9e9766c4'
$authTrap = Join-Path $hermesHomePath 'profiles\fixture\auth.json'

try {
    foreach ($directory in @(
        $gitRefDirectory, $binDirectory, $venvScripts, (Join-Path $venvDirectory 'Lib\site-packages'), $cliDirectory,
        (Split-Path -Parent $authTrap)
    )) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    Write-ExistingRuntimeUtf8 -LiteralPath $pyProjectPath -Text ('[project]' + [Environment]::NewLine + 'version = "0.1.0"')
    Write-ExistingRuntimeUtf8 -LiteralPath (Join-Path $venvDirectory 'pyvenv.cfg') -Text 'home = fixture'
    Write-ExistingRuntimeUtf8 -LiteralPath $headPath -Text 'ref: refs/heads/main'
    Write-ExistingRuntimeUtf8 -LiteralPath $refPath -Text $commit
    Write-ExistingRuntimeGitConfig -LiteralPath $configPath -Origin 'https://github.com/NousResearch/hermes-agent.git'
    Write-ExistingRuntimePortableExecutable -LiteralPath $binHermes -Seed 'bin hermes fixture'
    Write-ExistingRuntimePortableExecutable -LiteralPath $venvHermes -Seed 'venv hermes fixture'
    Write-ExistingRuntimePortableExecutable -LiteralPath $python -Seed 'python fixture'
    Write-ExistingRuntimeUtf8 -LiteralPath (Join-Path $binDirectory 'hermes.cmd') -Text '@rem accepted extra launcher'
    Write-ExistingRuntimeUtf8 -LiteralPath (Join-Path $binDirectory 'custom-launcher.exe') -Text 'extra file is ignored'
    Write-ExistingRuntimeUtf8 -LiteralPath $authTrap -Text '{"token":"fixture-do-not-read-or-change"}'

    $authHashBefore = ConvertTo-HermesSha256 -LiteralPath $authTrap
    $authWriteTimeBefore = (Get-Item -LiteralPath $authTrap).LastWriteTimeUtc.Ticks
    $processHermesHomeBefore = [Environment]::GetEnvironmentVariable('HERMES_HOME', [EnvironmentVariableTarget]::Process)

    & $existingModule {
        $script:ExistingRuntimeProcessCalls = 0
        $script:ExistingRuntimeMutationPath = $null
        $script:ExistingRuntimeOriginalStaticVersion = ${function:Get-HermesExistingStaticVersion}

        function script:Get-HermesCuratedProcessEnvironment {
            return @{
                SystemRoot = $env:SystemRoot
                WINDIR = $env:WINDIR
                ComSpec = $env:ComSpec
                TEMP = $env:TEMP
                TMP = $env:TMP
                PATH = 'C:\fixture-untrusted-path'
                HTTP_PROXY = 'http://fixture-proxy.invalid'
                '__HERMES_EASY_SETUP_REPLACE_ENVIRONMENT' = '1'
            }
        }

        function script:Invoke-HermesProcess {
            $script:ExistingRuntimeProcessCalls++
            throw 'The existing-runtime recognition path must never launch a process.'
        }

        function script:Test-HermesInstallation {
            throw 'The strict pinned-install verifier must not be called by the existing-runtime adapter.'
        }
    }

    $result = Get-HermesExistingRuntime -HermesHome $hermesHomePath -InstallDir $install -RuntimeRoot $runtimeRoot
    Assert-ExistingRuntime ($result -is [pscustomobject]) 'adapter emits only one runtime object'
    Assert-ExistingRuntime ($result.RuntimeKind -ceq 'Existing' -and -not $result.Attested) 'external runtime remains explicitly non-attested'
    Assert-ExistingRuntime ($result.TrustBoundary -ceq 'ExplicitExistingHermes') 'explicit opt-in trust boundary is returned'
    Assert-ExistingRuntime ($result.Command -ceq [System.IO.Path]::GetFullPath($binHermes)) 'native bin hermes.exe is preferred'
    Assert-ExistingRuntime ($result.Python -ceq [System.IO.Path]::GetFullPath($python)) 'venv python.exe is returned'
    Assert-ExistingRuntime ($result.Version -ceq 'Hermes static source version 0.1.0 (commit fcbd140344a0)' -and $result.Commit -ceq $commit) 'static source version is distinguished from runtime version and includes raw HEAD evidence'
    Assert-ExistingRuntime ($result.Paths.HermesHome -ceq [System.IO.Path]::GetFullPath($hermesHomePath)) 'canonical selected paths are returned'
    Assert-ExistingRuntime ($result.Environment['PYTHONDONTWRITEBYTECODE'] -ceq '1') 'returned runtime environment disables Python bytecode writes'
    Assert-ExistingRuntime (-not $result.Environment.ContainsKey('HTTP_PROXY')) 'returned runtime environment removes network proxy inheritance'
    Assert-ExistingRuntime ($result.Environment['PATH'].StartsWith((Join-Path $install 'bin') + ';', [System.StringComparison]::OrdinalIgnoreCase)) 'returned runtime PATH starts with selected runtime only'
    Assert-ExistingRuntime ($result.SnapshotSha256 -match '^[0-9A-F]{64}$') 'runtime evidence snapshot fingerprint is returned'

    Assert-ExistingRuntime ((& $existingModule { $script:ExistingRuntimeProcessCalls }) -eq 0) 'recognition launches no external process'
    Assert-ExistingRuntime (-not (Test-Path -LiteralPath $runtimeRoot)) 'adapter creates no wizard state or attestation'
    Assert-ExistingRuntime ((ConvertTo-HermesSha256 -LiteralPath $authTrap) -ceq $authHashBefore) 'profile auth fixture content is preserved'
    Assert-ExistingRuntime ((Get-Item -LiteralPath $authTrap).LastWriteTimeUtc.Ticks -eq $authWriteTimeBefore) 'profile auth fixture metadata is preserved'
    Assert-ExistingRuntime ([Environment]::GetEnvironmentVariable('HERMES_HOME', [EnvironmentVariableTarget]::Process) -ceq $processHermesHomeBefore) 'process environment is not permanently modified'

    Write-ExistingRuntimeGitConfig -LiteralPath $configPath -Origin 'git@github.com:NousResearch/hermes-agent.git'
    Remove-Item -LiteralPath $binHermes -Force
    $sshResult = Get-HermesExistingRuntime -HermesHome $hermesHomePath -InstallDir $install -RuntimeRoot $runtimeRoot
    Assert-ExistingRuntime ($sshResult.Command -ceq [System.IO.Path]::GetFullPath($venvHermes)) 'exact official SSH origin and venv native launcher are accepted'

    Remove-Item -LiteralPath $refPath -Force
    Write-ExistingRuntimeUtf8 -LiteralPath $packedRefsPath -Text ("# pack-refs with: peeled fully-peeled" + [Environment]::NewLine + "$commit refs/heads/main")
    $packedRefResult = Get-HermesExistingRuntime -HermesHome $hermesHomePath -InstallDir $install -RuntimeRoot $runtimeRoot
    Assert-ExistingRuntime ($packedRefResult.Commit -ceq $commit) 'packed-refs commit resolution avoids the PowerShell Matches automatic variable'
    Remove-Item -LiteralPath $packedRefsPath -Force
    Write-ExistingRuntimeUtf8 -LiteralPath $refPath -Text $commit

    Write-ExistingRuntimeGitConfig -LiteralPath $configPath -Origin 'https://evil.invalid/NousResearch/hermes-agent.git'
    $originError = Assert-ExistingRuntimeRejected {
        Get-HermesExistingRuntime -HermesHome $hermesHomePath -InstallDir $install -RuntimeRoot $runtimeRoot
    } 'non-official raw origin is rejected before execution'
    Assert-ExistingRuntime (-not $originError.Exception.Message.Contains('evil.invalid')) 'untrusted origin is not reflected in errors'
    Assert-ExistingRuntime ((& $existingModule { $script:ExistingRuntimeProcessCalls }) -eq 0) 'origin rejection launches no process'

    Write-ExistingRuntimeGitConfig -LiteralPath $configPath -Origin 'https://github.com/NousResearch/hermes-agent.git'
    $relativeError = Assert-ExistingRuntimeRejected {
        Get-HermesExistingRuntime -HermesHome 'relative\hermes' -InstallDir $install -RuntimeRoot $runtimeRoot
    } 'relative selected path is rejected'
    Assert-ExistingRuntime ($relativeError.Exception.Data['Category'] -ceq 'ExistingRuntime') 'validation failures keep the existing-runtime category'
    [void](Assert-ExistingRuntimeRejected {
        Get-HermesExistingRuntime -HermesHome $hermesHomePath -InstallDir $install -RuntimeRoot (Join-Path $hermesHomePath 'wizard-runtime')
    } 'runtime root may not overlap the selected Hermes home')

    Remove-Item -LiteralPath $venvHermes -Force
    [void](Assert-ExistingRuntimeRejected {
        Get-HermesExistingRuntime -HermesHome $hermesHomePath -InstallDir $install -RuntimeRoot $runtimeRoot
    } 'script-only launchers cannot replace a native hermes.exe')
    Assert-ExistingRuntime ((& $existingModule { $script:ExistingRuntimeProcessCalls }) -eq 0) 'missing native launcher never falls back to PATH'

    Write-ExistingRuntimePortableExecutable -LiteralPath $binHermes -Seed 'bin hermes restored for mutation test'
    Write-ExistingRuntimePortableExecutable -LiteralPath $venvHermes -Seed 'venv hermes restored for mutation test'
    & $existingModule {
        param($path)
        $script:ExistingRuntimeMutationPath = $path
        function script:Get-HermesExistingStaticVersion {
            param([string]$PyProjectPath, [string]$Commit)
            $value = & $script:ExistingRuntimeOriginalStaticVersion -PyProjectPath $PyProjectPath -Commit $Commit
            [System.IO.File]::AppendAllText($script:ExistingRuntimeMutationPath, 'changed-during-static-read')
            return $value
        }
    } $headPath
    $mutationError = Assert-ExistingRuntimeRejected {
        Get-HermesExistingRuntime -HermesHome $hermesHomePath -InstallDir $install -RuntimeRoot $runtimeRoot
    } 'runtime evidence changes during static inspection are rejected'
    Assert-ExistingRuntime ($mutationError.Exception.Message.Contains('변경')) 'snapshot guard reports a static-inspection change failure'
    & $existingModule {
        Set-Item -Path 'Function:script:Get-HermesExistingStaticVersion' -Value $script:ExistingRuntimeOriginalStaticVersion
        $script:ExistingRuntimeMutationPath = $null
    }
    Write-ExistingRuntimeUtf8 -LiteralPath $headPath -Text 'ref: refs/heads/main'

    Write-ExistingRuntimeUtf8 -LiteralPath $pyProjectPath -Text ('[project]' + [Environment]::NewLine + 'dynamic = ["version"]')
    $fallbackResult = Get-HermesExistingRuntime -HermesHome $hermesHomePath -InstallDir $install -RuntimeRoot $runtimeRoot
    Assert-ExistingRuntime ($fallbackResult.Version -ceq 'Hermes existing source (commit fcbd140344a0)') 'dynamic version falls back to the verified commit prefix'
    Write-ExistingRuntimeUtf8 -LiteralPath $pyProjectPath -Text ('[project]' + [Environment]::NewLine + 'version = "0.0.0"')
    $placeholderResult = Get-HermesExistingRuntime -HermesHome $hermesHomePath -InstallDir $install -RuntimeRoot $runtimeRoot
    Assert-ExistingRuntime ($placeholderResult.Version -ceq 'Hermes existing source (commit fcbd140344a0)') '0.0.0 source placeholder falls back to the verified commit prefix'
    Assert-ExistingRuntime ((& $existingModule { $script:ExistingRuntimeProcessCalls }) -eq 0) 'all recognition scenarios remain process-free'

    $exported = @(Get-Command -Module 'HermesEasySetup.Existing' -CommandType Function)
    Assert-ExistingRuntime ($exported.Count -eq 1 -and $exported[0].Name -ceq 'Get-HermesExistingRuntime') 'module exports only the opt-in adapter entry point'
    Write-Host 'PASS existing runtime adapter tests' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $fullTestRoot = [System.IO.Path]::GetFullPath($testRoot)
        $fullTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if (-not (Test-HermesPathContains -ParentPath $fullTempRoot -ChildPath $fullTestRoot)) {
            throw 'Refusing to remove a fixture outside the temporary directory.'
        }
        Remove-Item -LiteralPath $fullTestRoot -Recurse -Force
    }
}
