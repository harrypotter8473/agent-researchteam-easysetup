[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Loader.psm1') -Force
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Docker.psm1') -Force
& (Get-Module HermesEasySetup.Docker) {
    $script:passed = 0
    function Assert { param($Ok, $Name) if (-not $Ok) { throw $Name }; $script:passed++; Write-Host "PASS $Name" }
    function Reject { param([scriptblock]$Block, $Name) $rejected = $false; try { & $Block | Out-Null } catch { $rejected = $true }; Assert $rejected $Name }
    $script:fixture = Join-Path ([IO.Path]::GetTempPath()) ('hermes-docker-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:fixture | Out-Null
    $script:caseRoot = Join-Path $script:fixture 'initial'
    $script:registryEvidence = $false; $script:badSignature = $false; $script:unsafePath = ''; $script:desktopRunning = $false
    $script:engineWorks = $false; $script:engineOS = 'linux'; $script:engineArch = 'amd64'; $script:composeWorks = $true
    $script:rawSecret = 'fixture-private-engine-output'
    $script:commands = New-Object System.Collections.Generic.List[object]
    $script:launches = New-Object System.Collections.Generic.List[object]
    $script:downloadCount = 0; $script:downloadArguments = $null
    $script:cancelLaunch = $false
    $script:installerProcesses = New-Object System.Collections.Generic.List[object]
    $script:outcome = [pscustomobject]@{ Completed = $true; ExitCode = 0 }
    $script:payload = [Text.Encoding]::UTF8.GetBytes('Fixture installer bytes, never executable.')
    $script:pin = [pscustomobject]@{ schema = 1; version = '4.94.0'; architecture = 'x64'; url = 'https://desktop.docker.com/win/main/amd64/241994/Docker%20Desktop%20Installer.exe'; sha256 = ''; publisher = 'Docker Inc' }
    $script:payloadFile = Join-Path $script:fixture 'payload.bin'
    [IO.File]::WriteAllBytes($script:payloadFile, $script:payload)
    $script:pin.sha256 = ConvertTo-HermesSha256 -LiteralPath $script:payloadFile
    $script:facts = [pscustomobject]@{ Windows = $true; Architecture = 'x64'; ProductType = 1; Build = 22631; MemoryBytes = [int64]8GB; Virtualization = $true; HypervisorPresent = $false }
    $script:wsl = [pscustomobject]@{ State = 'Pass'; Version = '2.6.3.0'; Summary = 'Fixture WSL version OK' }
    $script:realDockerPathCheck = ${function:Test-HermesDockerExecutablePath}
    $script:realWSLVersionCheck = ${function:Get-HermesDockerWSLVersion}
    function script:Test-HermesDockerExecutablePath {
        param($LiteralPath)
        if ($script:unsafePath -and $LiteralPath.StartsWith($script:unsafePath, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        return & $script:realDockerPathCheck -LiteralPath $LiteralPath
    }
    function script:Get-HermesDockerKnownRoots { return @([pscustomobject]@{ Root = Join-Path $script:caseRoot 'per-user'; Kind = 'PerUser' }, [pscustomobject]@{ Root = Join-Path $script:caseRoot 'all-users'; Kind = 'AllUsers' }) }
    function script:Test-HermesDockerRegistryEvidence { return $script:registryEvidence }
    function script:Get-HermesDockerHostFacts { return $script:facts }
    function script:Get-HermesDockerWSLVersion { return $script:wsl }
    function script:Get-HermesAuthenticodeSignature {
        param($LiteralPath)
        $subject = $(if ($LiteralPath.EndsWith('\System32\wsl.exe', [StringComparison]::OrdinalIgnoreCase)) { 'CN=Microsoft Windows, O=Microsoft Corporation, C=US' } else { 'CN=Docker Inc, O=Docker Inc, C=US' })
        return [pscustomobject]@{ Status = $(if ($script:badSignature) { 'NotSigned' } else { 'Valid' }); SignerCertificate = [pscustomobject]@{ Subject = $subject } }
    }
    function script:Test-HermesSafeTargetPath {
        param($LiteralPath, $Label)
        if ($script:unsafePath -and $LiteralPath.StartsWith($script:unsafePath, [StringComparison]::OrdinalIgnoreCase)) { return [pscustomobject]@{ Safe = $false } }
        return HermesEasySetup.Core\Test-HermesSafeTargetPath -LiteralPath $LiteralPath
    }
    function script:Get-HermesDockerDesktopProcessState { return $(if ($script:desktopRunning) { 'Running' } else { 'Stopped' }) }
    function script:Invoke-HermesProcess {
        param($FilePath, $ArgumentList, $WorkingDirectory, $Environment, $TimeoutSeconds)
        $script:commands.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = @($ArgumentList); Environment = $Environment; TimeoutSeconds = $TimeoutSeconds })
        if ($FilePath.EndsWith('\System32\wsl.exe', [StringComparison]::OrdinalIgnoreCase)) { return [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = 0; StdOut = 'WSL 버전: 2.6.3.0'; StdErr = '' } }
        if ($FilePath.EndsWith('docker-compose.exe')) { return [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = $(if ($script:composeWorks) { 0 } else { 1 }); StdOut = '2.39.0'; StdErr = $script:rawSecret } }
        return [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = $(if ($script:engineWorks) { 0 } else { 1 }); StdOut = (@{ OSType = $script:engineOS; Architecture = $script:engineArch; Private = $script:rawSecret } | ConvertTo-Json -Compress); StdErr = $script:rawSecret }
    }
    function script:Get-HermesDockerInstallerPin { return $script:pin }
    function script:Invoke-HermesDockerInstallerDownload {
        param($Uri, $Destination, $MaximumBytes, $TimeoutSeconds)
        $script:downloadCount++; $script:downloadArguments = $PSBoundParameters
        [IO.File]::WriteAllBytes($Destination, $script:payload)
    }
    function New-FixtureInstallation {
        param([string]$Kind = 'PerUser', [switch]$Incomplete)
        $directory = Join-Path $script:caseRoot $(if ($Kind -ceq 'PerUser') { 'per-user' } else { 'all-users' })
        foreach ($relative in @('Docker Desktop.exe', 'resources\bin\docker.exe', 'resources\cli-plugins\docker-compose.exe')) {
            if ($Incomplete -and $relative -cne 'Docker Desktop.exe') { continue }
            $path = Join-Path $directory $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [IO.File]::WriteAllBytes($path, $script:payload)
        }
    }
    function script:Start-Process {
        param($FilePath, $ArgumentList, [switch]$PassThru, $WindowStyle, $ErrorAction)
        $script:launches.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = $ArgumentList; WindowStyle = $WindowStyle })
    }
    $script:realWaitInstaller = ${function:Wait-HermesDockerInstaller}
    function script:Start-HermesDockerInstaller {
        param($InstallerPath)
        if ($script:cancelLaunch) { throw (New-Object ComponentModel.Win32Exception(1223)) }
        $info = Get-HermesDockerInstallerStartInfo -InstallerPath $InstallerPath
        $script:launches.Add([pscustomobject]@{ FilePath = $info.FileName; Arguments = $info.Arguments; WindowStyle = [string]$info.WindowStyle; UseShellExecute = $info.UseShellExecute })
        New-FixtureInstallation
        $process = [pscustomobject]@{ Id = 1234; Disposed = $false }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed = $true }
        $script:installerProcesses.Add($process)
        return $process
    }
    function script:Wait-HermesDockerInstaller { param($Process, $ProgressCallback, $TimeoutSeconds) Assert ($TimeoutSeconds -eq 1800) 'Installer waiting is bounded to 30 minutes'; return $script:outcome }
    function New-Case { param([string]$Name) $script:caseRoot = Join-Path $script:fixture $Name; $script:registryEvidence = $false; $script:badSignature = $false; $script:unsafePath = ''; $script:engineWorks = $false; $script:desktopRunning = $false; $script:engineOS = 'linux'; $script:engineArch = 'amd64'; $script:composeWorks = $true }
    try {
        $systemCommand = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\cmd.exe'
        Assert (& $script:realDockerPathCheck -LiteralPath $systemCommand) 'Read-only executable validation permits an actual non-reparse System32 path without execution'
        $systemWSL = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\wsl.exe'
        if (Test-Path -LiteralPath $systemWSL -PathType Leaf) {
            $wslProbe = & $script:realWSLVersionCheck
            Assert ($wslProbe.State -ceq 'Pass' -and $wslProbe.Version -ceq '2.6.3.0') 'System32 WSL passes path validation and localized version parsing with signature and execution mocked'
        }
        $missing = Get-HermesDockerDesktopStatus
        Assert (-not $missing.Installed -and $missing.CanInstall -and $missing.StatusCode -ceq 'Missing') 'Missing Desktop is separated from an installed but stopped Desktop'
        Assert ($missing.Prerequisites -is [array] -and $missing.Prerequisites[0].PSObject.Properties['Name'] -and $missing.Prerequisites[0].PSObject.Properties['Message'] -and $missing.Alternatives.Count -gt 0) 'GUI gets prerequisite entries and actionable alternatives'
        foreach ($name in @('Installed', 'Ready', 'CanInstall', 'CanOpen')) { Assert ($missing.$name -is [bool]) 'Status decision fields are booleans' }
        $script:registryEvidence = $true
        $unknown = Get-HermesDockerDesktopStatus
        Assert ($unknown.Installed -and -not $unknown.CanInstall -and $unknown.StatusCode -ceq 'UnknownLocation') 'Registry install evidence prevents false missing and duplicate installation'
        $script:registryEvidence = $false
        New-FixtureInstallation
        $installation = Get-HermesDockerDesktopInstallation
        Assert ($installation.Installed -and $installation.Kind -ceq 'PerUser' -and $installation.Trusted -and $installation.Root.EndsWith('per-user')) 'Per-user Desktop is found independently of PATH'
        $stopped = Get-HermesDockerDesktopStatus
        Assert ($stopped.StatusCode -ceq 'Stopped' -and $stopped.CanOpen -and -not $stopped.CanInstall) 'Signed installed but stopped Desktop can be opened without reinstall'
        $script:desktopRunning = $true
        Assert ((Get-HermesDockerDesktopStatus).StatusCode -ceq 'EngineUnavailable') 'Running Desktop with unavailable Linux pipe gets a separate status'
        $script:engineWorks = $true
        $ready = Get-HermesDockerDesktopStatus
        Assert ($ready.Ready -and $ready.StatusCode -ceq 'Ready' -and $ready.ComposeVersion -ceq '2.39.0') 'Linux AMD64 engine plus Compose establishes readiness'
        Assert (-not ($ready | ConvertTo-Json -Depth 12).Contains($script:rawSecret)) 'Status never exposes raw info, stderr or engine private fields'
        $infoCommand = @($script:commands | Where-Object { $_.FilePath.EndsWith('docker.exe') })[-1]
        Assert ($infoCommand.Arguments[0] -ceq '--host' -and $infoCommand.Arguments[1] -ceq $script:DockerLinuxHost -and $infoCommand.Environment.DOCKER_HOST -ceq $script:DockerLinuxHost) 'Docker command is fixed to the local Desktop Linux pipe'
        $script:facts.MemoryBytes = [int64]1GB; $script:wsl.State = 'Unknown'; $script:facts.Virtualization = $false
        Assert ((Get-HermesDockerDesktopStatus).Ready) 'Working engine takes precedence over failed or unknown host probes'
        $script:facts.MemoryBytes = [int64]8GB; $script:facts.Virtualization = $true; $script:wsl.State = 'Pass'
        $script:engineOS = 'windows'
        Assert ((Get-HermesDockerDesktopStatus).StatusCode -ceq 'UnsupportedEngine') 'Non-Linux engine is rejected'
        $script:engineOS = 'linux'; $script:engineArch = 'arm64'
        Assert ((Get-HermesDockerDesktopStatus).StatusCode -ceq 'UnsupportedEngine') 'Non-AMD64 engine is rejected'
        $script:engineArch = 'amd64'; $script:composeWorks = $false
        Assert ((Get-HermesDockerDesktopStatus).StatusCode -ceq 'ComposeUnavailable') 'Compose failure is distinct from stopped engine'
        $script:composeWorks = $true; $script:badSignature = $true
        $beforeCommands = $script:commands.Count
        Assert ((Get-HermesDockerDesktopStatus).StatusCode -ceq 'Untrusted') 'Unsigned executables are never treated as ready'
        Reject { Invoke-HermesDockerDesktopCommand -Arguments @('info') } 'Unsigned CLI cannot execute'
        Reject { Open-HermesDockerDesktop } 'Unsigned Desktop cannot open'
        Assert ($script:commands.Count -eq $beforeCommands) 'Signature rejection occurs before process launch'
        $script:badSignature = $false; $script:unsafePath = $installation.Root
        Assert (-not (Get-HermesDockerDesktopInstallation).Trusted) 'Unsafe or reparse installation path is rejected'
        $script:unsafePath = ''
        $opened = Open-HermesDockerDesktop
        Assert ($opened.Opened -and $script:launches[-1].WindowStyle -ceq 'Hidden') 'Opening verified Desktop does not launch an elevated helper'

        New-Case 'all-user'
        New-FixtureInstallation -Kind AllUsers
        Assert ((Get-HermesDockerDesktopInstallation).Kind -ceq 'AllUsers') 'All-users ProgramFiles installation is supported'
        New-Case 'incomplete'
        New-FixtureInstallation -Incomplete
        Assert ((Get-HermesDockerDesktopStatus).StatusCode -ceq 'Incomplete' -and -not (Get-HermesDockerDesktopStatus).CanInstall) 'Partial installation blocks automatic reinstall'
        New-Case 'prerequisites'
        $script:facts.Virtualization = $false; $script:facts.HypervisorPresent = $true
        Assert (@((Get-HermesDockerPrerequisites).Checks | Where-Object { $_.Name -ceq 'Virtualization' })[0].State -ceq 'Pass') 'Existing hypervisor overrides firmware virtualization false'
        $script:facts.HypervisorPresent = $false
        Assert ((Get-HermesDockerDesktopStatus).StatusCode -ceq 'PrerequisitesNotMet' -and -not (Get-HermesDockerDesktopStatus).CanInstall) 'Known unmet prerequisites block installation without changing Windows'
        $script:facts.Virtualization = $true; $script:facts.ProductType = 3
        Assert ((Get-HermesDockerDesktopStatus).StatusCode -ceq 'PrerequisitesNotMet') 'Windows Server is unsupported'
        $script:facts.ProductType = 1; $script:facts.Build = 22000
        Assert (-not (Get-HermesDockerDesktopStatus).CanInstall) 'Windows 11 before build 22631 is unsupported'
        $script:facts.Build = 19045
        Assert ((Get-HermesDockerDesktopStatus).CanInstall) 'Windows 10 build 19045 meets the reviewed threshold'
        $script:facts.Build = $null; $script:facts.MemoryBytes = $null; $script:facts.Architecture = 'Unknown'; $script:facts.Virtualization = $null; $script:wsl.State = 'Unknown'
        $uncertain = Get-HermesDockerPrerequisites
        Assert ($uncertain.Unknown -gt 0 -and $uncertain.Failed -eq 0) 'Unavailable CIM or WSL probes remain Unknown, not fabricated failures'
        $unknownHost = Get-HermesDockerDesktopStatus
        Assert (-not $unknownHost.CanInstall -and $unknownHost.StatusCode -ceq 'PrerequisitesUnknown') 'Unknown host prerequisites require direct verification before installation'
        $script:facts.Build = 22631; $script:facts.MemoryBytes = [int64]8GB; $script:facts.Architecture = 'x64'; $script:facts.Virtualization = $true; $script:wsl.State = 'Pass'

        New-Case 'install'
        $runtime = Join-Path $script:caseRoot 'runtime'
        Reject { Install-HermesDockerDesktop -RuntimeRoot $runtime } 'Installer requires explicit Apply authorization'
        Reject { Install-HermesDockerDesktop -RuntimeRoot 'relative-runtime' -Apply } 'Installer rejects relative RuntimeRoot before creating any cache'
        Reject { Install-HermesDockerDesktop -RuntimeRoot 'C:relative-runtime' -Apply } 'Installer rejects drive-relative RuntimeRoot'
        Assert (-not (Test-Path -LiteralPath $runtime)) 'Unapproved install creates no cache'
        $script:engineWorks = $true
        $installed = Install-HermesDockerDesktop -RuntimeRoot $runtime -Apply
        Assert ($installed.Installed -and $installed.Ready -and -not $installed.RebootRequired -and $installed.InstallerExitCode -eq 0) 'Approved verified installation rechecks actual engine status'
        foreach ($name in @('Installed', 'Ready', 'CanInstall', 'CanOpen', 'RebootRequired')) { Assert ($installed.$name -is [bool]) 'Install decision fields are booleans' }
        $launch = $script:launches[-1]
        Assert ($launch.Arguments -ceq 'install --user --backend=wsl-2' -and $launch.WindowStyle -ceq 'Normal' -and $launch.UseShellExecute) 'Installer uses shell execution with interactive per-user WSL2 arguments and no automatic license acceptance or elevation'
        Assert ($script:installerProcesses[-1].Disposed) 'Installer process handle is disposed after completion'
        $exitProbe = [pscustomobject]@{ HasExited = $true; ExitCode = $null }
        $exitProbe | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $true }
        $exitProbe | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
        Reject { & $script:realWaitInstaller -Process $exitProbe -TimeoutSeconds 1 } 'Null installer ExitCode cannot be converted into success'
        $exitProbe.ExitCode = 1641
        Assert ((& $script:realWaitInstaller -Process $exitProbe -TimeoutSeconds 1).ExitCode -eq 1641) 'Confirmed native installer ExitCode is preserved'
        Assert ($script:downloadArguments.Uri -ceq $script:pin.url -and $script:downloadArguments.TimeoutSeconds -eq 600 -and $script:downloadArguments.MaximumBytes -eq $script:DockerDownloadMaximumBytes) 'Only the pinned official URL receives bounded download parameters'
        $beforeLaunches = $script:launches.Count
        Reject { Install-HermesDockerDesktop -RuntimeRoot $runtime -Apply } 'Existing installation is never updated or reinstalled'
        Assert ($script:launches.Count -eq $beforeLaunches) 'Existing-install rejection never launches installer'
        $beforeDownloads = $script:downloadCount
        $cached = Get-HermesVerifiedDockerInstaller -RuntimeRoot $runtime -Pin $script:pin
        Assert ((Test-Path -LiteralPath $cached) -and $script:downloadCount -eq $beforeDownloads) 'Verified cache is reused after repeat hash and publisher checks'
        $script:badSignature = $true
        Reject { Get-HermesVerifiedDockerInstaller -RuntimeRoot $runtime -Pin $script:pin } 'Cached executable with invalid signature is never reused'
        $script:badSignature = $false
        foreach ($exit in @(3010, 1641)) {
            New-Case ('reboot-' + $exit)
            $script:outcome = [pscustomobject]@{ Completed = $true; ExitCode = $exit }; $script:engineWorks = $true
            $reboot = Install-HermesDockerDesktop -RuntimeRoot (Join-Path $script:caseRoot 'runtime') -Apply
            Assert ($reboot.RebootRequired -and -not $reboot.Ready -and $reboot.StatusCode -ceq 'RebootRequired') 'Installer reboot codes are reported without claiming readiness or restarting Windows'
        }
        New-Case 'timeout'
        $script:outcome = [pscustomobject]@{ Completed = $false; ExitCode = $null }
        $timeout = Install-HermesDockerDesktop -RuntimeRoot (Join-Path $script:caseRoot 'runtime') -Apply
        Assert ($timeout.StatusCode -ceq 'InstallerStillRunning' -and -not $timeout.Ready) 'Timed-out interactive installer is left running and never reported ready'
        Assert ($script:installerProcesses[-1].Disposed) 'Timeout releases the process handle without killing the installer'
        foreach ($exit in @(1223, 1602)) {
            New-Case ('cancelled-' + $exit)
            $script:outcome = [pscustomobject]@{ Completed = $true; ExitCode = $exit }
            $cancelled = Install-HermesDockerDesktop -RuntimeRoot (Join-Path $script:caseRoot 'runtime') -Apply
            Assert ($cancelled.StatusCode -ceq 'Cancelled' -and -not $cancelled.Ready) 'User cancellation exit codes are distinct from installation failure'
        }
        New-Case 'cancelled-launch'; $script:cancelLaunch = $true
        $cancelledLaunch = Install-HermesDockerDesktop -RuntimeRoot (Join-Path $script:caseRoot 'runtime') -Apply
        Assert ($cancelledLaunch.StatusCode -ceq 'Cancelled' -and $cancelledLaunch.InstallerExitCode -eq 1223) 'Native shell cancellation is reported without reflecting raw errors'
        $script:cancelLaunch = $false
        New-Case 'hash-failure'
        $originalHash = $script:pin.sha256; $script:pin.sha256 = '0' * 64
        $rejectedRuntime = Join-Path $script:caseRoot 'runtime'
        Reject { Install-HermesDockerDesktop -RuntimeRoot $rejectedRuntime -Apply } 'Downloaded bytes with a wrong hash are never launched'
        Assert (@(Get-ChildItem -LiteralPath (Join-Path $rejectedRuntime 'docker\cache') -Filter '*.tmp' -File).Count -eq 0) 'Failure cleans up only the newly-owned download temporary file'
        $script:pin.sha256 = $originalHash
        Write-Host ('Docker tests passed: ' + $script:passed)
    } finally {
        $resolved = [IO.Path]::GetFullPath($script:fixture); $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'hermes-docker-tests-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}
