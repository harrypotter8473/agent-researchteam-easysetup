[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'src/HermesEasySetup.Loader.psm1') -Force
$engine = Get-Module HermesEasySetup.InstallEngine
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('nst-python-compat-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    & $engine {
        param($fixture, $root)
        $script:compatPassed = 0
        function Assert-Compat([bool]$Condition, [string]$Name) {
            if (-not $Condition) { throw ('FAIL Python compatibility: ' + $Name) }
            $script:compatPassed++; Write-Host ('PASS ' + $Name)
        }
        foreach ($publisher in @('qbz5n2kfra8p0','3847v3x7pw1km')) {
            $family = 'PythonSoftwareFoundation.PythonManager_' + $publisher
            $record = [pscustomobject]@{ Family=$family; Application=($family+'!Python.Exe'); Target=('C:\Program Files\WindowsApps\PythonSoftwareFoundation.PythonManager_25.2.0.0_x64__'+$publisher+'\python.exe') }
            Assert-Compat (Test-HermesPythonAppAliasBinding $record) ('new manager binding: ' + $publisher)
            $record.Application = $family + '!Unrelated.Exe'
            Assert-Compat (-not (Test-HermesPythonAppAliasBinding $record)) 'wrong manager application rejected'
            $record.Application = $family + '!Python.Exe'; $record.Target = $record.Target.Replace($publisher,'not-the-publisher')
            Assert-Compat (-not (Test-HermesPythonAppAliasBinding $record)) 'manager publisher/target mismatch rejected'
        }
        $legacy = [pscustomobject]@{ Family='PythonSoftwareFoundation.Python.3.11_qbz5n2kfra8p0'; Application='PythonSoftwareFoundation.Python.3.11_qbz5n2kfra8p0!Python'; Target='C:\Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.11_3.11.9.0_x64__qbz5n2kfra8p0\python3.11.exe' }
        Assert-Compat (Test-HermesPythonAppAliasBinding $legacy) 'legacy Store Python binding retained'
        $redirector = [pscustomobject]@{ Family='Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'; Application='Microsoft.DesktopAppInstaller_8wekyb3d8bbwe!PythonRedirector'; Target='C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.26.0.0_x64__8wekyb3d8bbwe\AppInstallerPythonRedirector.exe' }
        Assert-Compat ((Test-HermesPythonAppAliasBinding $redirector -StorePlaceholder) -and -not (Test-HermesPythonAppAliasBinding $redirector)) 'Store redirector recognized but not executable trust'
        $redirector.Application = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe!SomethingElse'
        Assert-Compat (-not (Test-HermesPythonAppAliasBinding $redirector -StorePlaceholder)) 'lookalike redirector rejected'
        $fakeAlias = Join-Path $fixture 'python.exe'
        [IO.File]::WriteAllText($fakeAlias,'not an OS alias')
        Assert-Compat ($null -eq (Get-HermesAppExecutionAliasRecord -LiteralPath $fakeAlias -ExpectedName 'python.exe')) 'ordinary file cannot impersonate an AppExecLink'

        # Dependency-isolated filesystem tests: only signature verification is mocked;
        # actual PE headers, paths, reparse rejection and sidecars are checked.
        $script:compatLocal = Join-Path $fixture 'AppData\Local'
        function Get-HermesPythonLocalAppData { return $script:compatLocal }
        function Test-HermesAuthenticodePublisher { param($LiteralPath,$PublisherPattern) return (-not $script:compatUnsigned) }
        $script:compatUnsigned = $false
        $runtime = Join-Path $script:compatLocal 'Programs\Python\Python311\python.exe'
        $managerRuntime = Join-Path $script:compatLocal 'Python\pythoncore-3.11-64\python.exe'
        $shim = Join-Path $script:compatLocal 'Python\bin\python.exe'
        foreach ($path in @($runtime,$managerRuntime,$shim)) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            Copy-Item -LiteralPath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Destination $path
        }
        Assert-Compat (Get-HermesPythonCandidateValidation $runtime).Valid 'signed traditional per-user Python accepted'
        Assert-Compat (Get-HermesPythonCandidateValidation $managerRuntime).Valid 'signed manager-owned per-user runtime accepted'
        $script:compatUnsigned = $true
        Assert-Compat (-not (Get-HermesPythonCandidateValidation $runtime).Valid) 'unsigned or wrong publisher remains blocked'
        $script:compatUnsigned = $false
        [IO.File]::WriteAllText(($shim+'.__target__'),$managerRuntime,(New-Object Text.UTF8Encoding($false)))
        Assert-Compat ((Get-HermesPythonCandidateValidation $shim).Kind -ceq 'PythonManagerAlias') 'signed manager shim requires a signed target'
        [IO.File]::WriteAllText(($shim+'.__target__'),(Join-Path $fixture 'outside\python.exe'))
        Assert-Compat (-not (Get-HermesPythonCandidateValidation $shim).Valid) 'manager shim cannot redirect outside approved Python roots'
        [IO.File]::WriteAllText(($shim+'.__target__'),$managerRuntime)
        [IO.File]::WriteAllText(($shim+'.__script__.py'),'raise RuntimeError("must not execute")')
        Assert-Compat (-not (Get-HermesPythonCandidateValidation $shim).Valid) 'manager shim with injected script rejected'
        Remove-Item -LiteralPath ($shim+'.__script__.py')
        [IO.File]::WriteAllText(($shim+'.__target__'),($managerRuntime+"`n--unsafe"))
        Assert-Compat (-not (Get-HermesPythonCandidateValidation $shim).Valid) 'newline or arguments in shim target rejected'

        $plan = [pscustomobject]@{ HermesHome=(Join-Path $fixture 'hermes'); SkipComputerUse=$true }
        $empty = Join-Path $fixture 'empty'; New-Item -ItemType Directory -Path $empty | Out-Null
        $absent = Test-HermesStageBareCommandResolution -Plan $plan -Stage python -TrustedGitPath 'C:\unused\git.exe' -PathValues @($empty) -ManagedCommandProof @{}
        Assert-Compat ($absent.Valid -and $absent.MissingCommands -contains 'python') 'missing Python is allowed through to official automatic installation'
        $blocked = Test-HermesStageBareCommandResolution -Plan $plan -Stage python -TrustedGitPath 'C:\unused\git.exe' -PathValues @($fixture) -ManagedCommandProof @{}
        $message = Format-HermesCommandResolutionFailure -Stage python -Result $blocked
        Assert-Compat (-not $blocked.Valid -and $blocked.BlockedPath -ceq $fakeAlias -and $message.Contains($fakeAlias) -and $message.Contains($blocked.Reason)) 'failure message includes actual blocked path and reason'
        $registryFailure = Format-HermesCommandResolutionFailure -Stage python -Result ([pscustomobject]@{ Command='python'; Reason='invalid registry PATH entry rejected' })
        Assert-Compat ($registryFailure.Contains('PATH') -and $registryFailure.Contains('invalid registry')) 'malformed PATH diagnostic retained'

        function Test-HermesPythonStorePlaceholder { param($LiteralPath) return ($LiteralPath -ceq $fakeAlias) }
        $placeholder = Test-HermesStageBareCommandResolution -Plan $plan -Stage python -TrustedGitPath 'C:\unused\git.exe' -PathValues @($fixture) -ManagedCommandProof @{}
        Assert-Compat ($placeholder.Valid -and $placeholder.IgnoredPythonPaths -contains $fakeAlias -and $placeholder.ResolvedPaths -notcontains $fakeAlias) 'verified Store placeholder is skipped, never added to executable paths'
        Assert-Compat (-not (Test-HermesTrustedBareCommandCandidate -Plan $plan -CommandName python -LiteralPath $fakeAlias -TrustedGitPath 'C:\unused\git.exe' -ManagedCommandProof @{})) 'placeholder exception does not grant bare Python execution trust'
        Write-Host ('PASS Python compatibility: ' + $script:compatPassed + ' assertions; mocks do not certify actual package signatures')
    } $fixture $root
} finally {
    # Only this newly-created, explicitly-contained test fixture is removed.
    if ([IO.Path]::GetFullPath($fixture).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $fixture) -match '^nst-python-compat-[0-9a-f]{32}$') { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
