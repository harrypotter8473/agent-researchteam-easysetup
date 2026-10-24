[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\HermesEasySetup.Loader.psm1') -Force
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('nst-git-path-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    & (Get-Module HermesEasySetup.InstallEngine) {
        param($fixture)
        function Assert-GitPath { param($Condition, $Message) if (-not $Condition) { throw $Message }; Write-Host ('PASS Git PATH: ' + $Message) }
        $installBody=(Get-Command Invoke-HermesInstall).ScriptBlock.ToString()
        Assert-GitPath ($installBody.IndexOf('$freshPlan = New-HermesInstallPlan') -lt $installBody.IndexOf('$gitPathJournal = Set-HermesPreparedGitPath') -and $installBody.IndexOf('$installer = Get-HermesVerifiedInstaller') -lt $installBody.IndexOf('$gitPathJournal = Set-HermesPreparedGitPath')) 'PATH write occurs only after verified installer and plan freshness gates'
        $git = Get-HermesVerificationGitPath -HermesHome (Join-Path $fixture 'home')
        if (-not $git) { throw 'This Windows security test requires a signed Program Files Git for Windows.' }
        $directory = Split-Path -Parent $git
        $root = Split-Path -Parent $directory
        $trusted = Get-HermesProgramFilesGitValidation $git
        Assert-GitPath $trusted.Valid 'actual Program Files Git passes independent path and signer validation'
        foreach ($relative in @('cmd\git.exe', 'bin\git.exe')) {
            $alternative = Join-Path $root $relative
            if (-not (Test-Path -LiteralPath $alternative)) { continue }
            $resolution = Test-HermesRegistryGitResolution -TrustedGitPath $git -PathValues @((Split-Path -Parent $alternative))
            Assert-GitPath $resolution.Valid ('signed normal layout accepted: ' + $relative)
        }
        $empty = Join-Path $fixture 'empty'; New-Item -ItemType Directory -Path $empty | Out-Null
        foreach ($values in @(@($null, $directory), @('', $directory), @(($empty + ';;'), ($directory + ';')))) {
            $preparation = New-HermesGitPathPreparation -TrustedGitPath $git -PathValues $values
            Assert-GitPath ($preparation.Valid -and -not $preparation.Changed) 'missing User PATH or empty segments do not require a registry rewrite'
        }
        foreach ($bad in @('relative\bin', '\\server\share', '%NST_UNDEFINED_PATH%')) {
            $badResult = New-HermesGitPathPreparation -TrustedGitPath $git -PathValues @($bad, $directory)
            $message = Format-HermesGitResolutionFailure $badResult
            Assert-GitPath (-not $badResult.Valid -and $message.Contains($bad) -and $message.Contains($badResult.Reason)) 'unsafe PATH is blocked with exact entry and reason, not silently removed'
        }
        $hostile = Join-Path $fixture 'hostile'; New-Item -ItemType Directory -Path $hostile | Out-Null
        $marker = Join-Path $fixture 'executed.txt'
        [IO.File]::WriteAllText((Join-Path $hostile 'git.cmd'), ('@echo executed > "' + $marker + '"'))
        $before = @(($hostile + ';' + $empty + ';'), $directory)
        $repair = New-HermesGitPathPreparation -TrustedGitPath $git -PathValues $before
        Assert-GitPath ($repair.Valid -and $repair.Changed -and $repair.PathValues[0] -ceq ($directory + ';' + $before[0]) -and $repair.PathValues[1] -ceq $before[1]) 'proposal prepends only trusted Git and preserves all original User/Machine entries'
        Assert-GitPath ($repair.OriginalResolution.ResolvedPath -ceq (Join-Path $hostile 'git.cmd') -and $repair.OriginalResolution.Reason.Contains('GitLocationNotAllowed')) 'shadow candidate is identified without being executed'
        Assert-GitPath (-not (Test-Path -LiteralPath $marker)) 'untrusted Git was not executed'
        $second = New-HermesGitPathPreparation -TrustedGitPath $git -PathValues $repair.PathValues
        Assert-GitPath ($second.Valid -and -not $second.Changed) 'repair is idempotent, not repeatedly prepended'
        foreach ($decorated in @(('"' + $directory + '"'), (' ' + $directory + ' '), '%ProgramFiles%\Git\cmd')) {
            $decoratedRepair = New-HermesGitPathPreparation -TrustedGitPath $git -PathValues @($decorated, $empty)
            Assert-GitPath ($decoratedRepair.Valid -and $decoratedRepair.Changed -and $decoratedRepair.PathValues[0].StartsWith($directory+';')) 'quoted, padded or raw-variable Git PATH gets a literal trusted prefix, not a false pass'
        }
        $missing = New-HermesGitPathPreparation -TrustedGitPath $git -PathValues @($empty, $null)
        Assert-GitPath ($missing.Valid -and $missing.Changed) 'installed signed Git absent from registry PATH can be connected'
        $copy = Join-Path $fixture 'git.exe'; Copy-Item -LiteralPath $git -Destination $copy
        Assert-GitPath (-not (Get-HermesProgramFilesGitValidation $copy).Valid) 'even a correctly signed copy outside Program Files stays untrusted'
        $unsigned = Get-HermesProgramFilesGitValidation (Join-Path $root 'cmd\absent.exe')
        Assert-GitPath (-not $unsigned.Valid -and $unsigned.Reason) 'missing or wrong executable reports a reason'
        $plan = [pscustomobject]@{ HermesHome=(Join-Path $fixture 'home'); SkipComputerUse=$true }
        $command = Test-HermesStageBareCommandResolution -Plan $plan -Stage git -TrustedGitPath $git -PathValues $repair.PathValues
        Assert-GitPath $command.Valid 'the actual stage validator uses the repaired first Git'
        [IO.File]::WriteAllText((Join-Path $hostile 'uv.cmd'), '@exit /b 91')
        $other = Test-HermesStageBareCommandResolution -Plan $plan -Stage uv -TrustedGitPath $git -PathValues $repair.PathValues
        Assert-GitPath (-not $other.Valid -and $other.BlockedPath -ceq (Join-Path $hostile 'uv.cmd')) 'Git repair does not bless an unrelated untrusted uv command'
        $quotedOther = Get-HermesRegistryBareCommandCandidates -CommandName uv -PathValues @(('"' + $hostile + '"'), $empty)
        Assert-GitPath (-not $quotedOther.Valid -and $quotedOther.BlockedPath.Contains($hostile)) 'quoted command candidate cannot mask later command precedence'

        # Only these registry adapters are mocked. Real candidate/signature,
        # file journal and stage validation still run. No real PATH is written.
        $getOriginal = (Get-Command Get-HermesRegistryPathValues -CommandType Function).ScriptBlock
        $setOriginal = (Get-Command Set-HermesUserPathValue -CommandType Function).ScriptBlock
        try {
            $script:gitTestValues = $before.Clone(); $script:gitTestWrites = 0
            function script:Get-HermesRegistryPathValues { return ,$script:gitTestValues }
            function script:Set-HermesUserPathValue { param($Value) $script:gitTestWrites++; $script:gitTestValues[0] = $Value }
            $snapshot = [pscustomobject]@{ ExpectedPath=$before[0]; UserPath=$before[0] }
            $journal = Set-HermesPreparedGitPath -Preparation $repair -Snapshot $snapshot -RuntimeRoot $fixture -TrustedGitPath $git
            $record = Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
            Assert-GitPath ($script:gitTestWrites -eq 1 -and $script:gitTestValues[0] -ceq $repair.PathValues[0] -and $snapshot.ExpectedPath -ceq $repair.PathValues[0]) 'write is bounded to User PATH and updates rollback expectation'
            Assert-GitPath ($record.userPathBefore -ceq $before[0] -and $record.userPathExpected -ceq $repair.PathValues[0]) 'exclusive recovery journal records exact original and proposed values'
            $restored = Restore-HermesRejectedUserPathExposure -Snapshot $snapshot -Plan $plan
            Assert-GitPath ($restored -and $script:gitTestValues[0] -ceq $before[0]) 'failed installation restores exact original User PATH'
            $nullBefore = @($null, $empty)
            $nullRepair = New-HermesGitPathPreparation -TrustedGitPath $git -PathValues $nullBefore
            $script:gitTestValues = $nullBefore.Clone()
            $nullSnapshot = [pscustomobject]@{ ExpectedPath=$null; UserPath=$null }
            Set-HermesPreparedGitPath -Preparation $nullRepair -Snapshot $nullSnapshot -RuntimeRoot $fixture -TrustedGitPath $git | Out-Null
            Assert-GitPath ($null -eq $nullRepair.OriginalPathValues[0] -and $script:gitTestValues[0] -ceq $directory) 'missing User PATH preserves null identity and can actually be repaired'
            Assert-GitPath (Restore-HermesRejectedUserPathExposure -Snapshot $nullSnapshot -Plan $plan) 'rollback also handles originally absent User PATH'
            $script:gitTestValues = @('C:\ConcurrentChange', $before[1]); $script:gitTestWrites=0
            $caught=$false
            try { Set-HermesPreparedGitPath -Preparation $repair -Snapshot $snapshot -RuntimeRoot $fixture -TrustedGitPath $git | Out-Null } catch { $caught=$true }
            Assert-GitPath ($caught -and $script:gitTestWrites -eq 0) 'concurrent PATH change aborts before writing'
            Assert-GitPath (-not (Restore-HermesRejectedUserPathExposure -Snapshot $snapshot -Plan $plan) -and $script:gitTestWrites -eq 0) 'rollback refuses to overwrite a concurrent User PATH change'
            $snapshot.ExpectedPath=$before[0]; $script:gitTestValues=$before.Clone()
            function script:Set-HermesUserPathValue { param($Value) $script:gitTestWrites++; $script:gitTestValues[0]=$Value; throw 'injected error after registry write' }
            $caught=$false
            try { Set-HermesPreparedGitPath -Preparation $repair -Snapshot $snapshot -RuntimeRoot $fixture -TrustedGitPath $git | Out-Null } catch { $caught=$true }
            Assert-GitPath ($caught -and $snapshot.ExpectedPath -ceq $repair.PathValues[0] -and $script:gitTestValues[0] -ceq $repair.PathValues[0]) 'write-then-throw still leaves a correct rollback expectation'
            function script:Set-HermesUserPathValue { param($Value) $script:gitTestValues[0]=$Value }
            Assert-GitPath ((Restore-HermesRejectedUserPathExposure -Snapshot $snapshot -Plan $plan) -and $script:gitTestValues[0] -ceq $before[0]) 'write-then-throw is recoverable without resetting unrelated environment'
        } finally {
            Set-Item Function:script:Get-HermesRegistryPathValues $getOriginal
            Set-Item Function:script:Set-HermesUserPathValue $setOriginal
            Remove-Variable gitTestValues,gitTestWrites -Scope Script -ErrorAction SilentlyContinue
        }
        # Real isolated PowerShell lookup: an empty PATH entry must not cause
        # the malicious cwd git.cmd to win. No registry modification is needed.
        $environment = Get-HermesCuratedProcessEnvironment
        $environment['PATH'] = ';' + $directory + ';;'
        $result = Invoke-HermesProcess -FilePath (Get-HermesPowerShellExecutable) -ArgumentList @('-NoLogo','-NoProfile','-Command','(Get-Command git -CommandType Application).Source; git --version') -Environment $environment -WorkingDirectory $hostile -TimeoutSeconds 60
        Assert-GitPath ($result.ExitCode -eq 0 -and $result.StdOut.Contains($git) -and -not (Test-Path -LiteralPath $marker)) 'actual child PowerShell ignores empty PATH segments and never resolves cwd Git'
        $environment['PATH'] = $decoratedRepair.PathValues -join ';'
        $literalResult = Invoke-HermesProcess -FilePath (Get-HermesPowerShellExecutable) -ArgumentList @('-NoLogo','-NoProfile','-Command','(Get-Command git -CommandType Application).Source; git --version') -Environment $environment -WorkingDirectory $hostile -TimeoutSeconds 60
        Assert-GitPath ($literalResult.ExitCode -eq 0 -and $literalResult.StdOut.Contains($git) -and -not (Test-Path -LiteralPath $marker)) 'repaired literal PATH really executes signed Git in a child shell'
    } $fixture
} finally {
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ([IO.Path]::GetFullPath($fixture).StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $fixture) -like 'nst-git-path-*') { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
Write-Host 'PASS Git PATH compatibility; no installed server, profile or real registry PATH changed'
exit 0
