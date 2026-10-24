[CmdletBinding()]
param([string]$OfficialInstallerPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$source=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $source 'src\HermesEasySetup.Loader.psm1') -Force
$id=[guid]::NewGuid().ToString('N')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('nst-env-recovery-'+$id)
$keyName='Software\NST.InstallRecovery.Tests\'+$id
New-Item -ItemType Directory -Path $fixture | Out-Null
$key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($keyName);$key.Dispose()
try {
    & (Get-Module HermesEasySetup.InstallEngine) {
        param($fixture,$keyName,$source,$official)
        function Assert-Recovery {param($Ok,$Message) if(-not $Ok){throw $Message};$script:recoveryAssertions++;Write-Host ('PASS environment recovery: '+$Message)}
        $script:recoveryAssertions=0
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'tests\fixtures\upstream-path-stage.ps1'),[ref]$tokens,[ref]$errors)
        $upstream=@($ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq 'Set-PathVariable'},$true))[0].Extent.Text.Replace("`r`n","`n")
        $sha=[Security.Cryptography.SHA256]::Create()
        $digest=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($upstream)))).Replace('-','').ToLowerInvariant()
        Assert-Recovery ($digest -ceq '397bbaee6c434d6527eeb11125ab2b19ed89c89ae5890475d72d71fab110997e') 'test helper is byte-bound to the reviewed upstream path function'
        if($official){
            Assert-Recovery ((Get-FileHash -LiteralPath $official -Algorithm SHA256).Hash -ceq '74225BF244253BFA5BC2B1D16FA3BB8618E199A53D1C0344B37AB9930696D3BA') 'full official installer hash matches the production pin'
            $a=[Management.Automation.Language.Parser]::ParseFile($official,[ref]$tokens,[ref]$errors)
            $actual=@($a.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Set-PathVariable'},$true))[0].Extent.Text.Replace("`r`n","`n")
            Assert-Recovery ($actual -ceq $upstream) 'fixture exactly matches the function in the full verified installer'
        }
        $names=@('Get-HermesRegistryPathValues','Set-HermesUserPathValue','Get-HermesUserEnvironmentRecord','Set-HermesUserEnvironmentRecord','Get-HermesMachinePathRecord','Get-HermesUserEnvironmentValue','Get-HermesInstallRecoveryProcesses')
        $originals=@{};foreach($n in $names){$originals[$n]=(Get-Command $n -CommandType Function).ScriptBlock}
        $script:recoveryKey=$keyName
        $script:recoveryMachine=[pscustomobject]@{Exists=$true;Kind='String';Value='C:\Windows\System32'}
        $script:recoveryProcesses=@()
        function Read-FixtureRecord {param($Name) $k=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:recoveryKey);try{if(@($k.GetValueNames()) -notcontains $Name){return [pscustomobject]@{Exists=$false;Kind=$null;Value=$null}};return [pscustomobject]@{Exists=$true;Kind=[string]$k.GetValueKind($Name);Value=[string]$k.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}}finally{$k.Dispose()}}
        function Write-FixtureRecord {param($Name,$Record) $k=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:recoveryKey,$true);try{if($Record.Exists){$k.SetValue($Name,[string]$Record.Value,[Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$Record.Kind))}else{$k.DeleteValue($Name,$false)}}finally{$k.Dispose()}}
        function Set-FixturePath {param($Value,$Kind='String') Write-FixtureRecord Path ([pscustomobject]@{Exists=($null -ne $Value);Kind=$Kind;Value=$Value})}
        function script:Get-HermesUserEnvironmentRecord {param($Name) Read-FixtureRecord $Name}
        function script:Set-HermesUserEnvironmentRecord {param($Name,$Record) Write-FixtureRecord $Name $Record}
        function script:Get-HermesMachinePathRecord {return $script:recoveryMachine}
        function script:Get-HermesUserEnvironmentValue {param($Name) $k=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:recoveryKey);try{return $k.GetValue($Name)}finally{$k.Dispose()}}
        function script:Get-HermesRegistryPathValues {return ,@((Get-HermesUserEnvironmentValue Path),[string]$script:recoveryMachine.Value)}
        function script:Set-HermesUserPathValue {param($Value) Set-FixturePath $Value}
        function script:Get-HermesInstallRecoveryProcesses {return $script:recoveryProcesses}
        $environment=$null
        try {
            $home=Join-Path $fixture '한글 작업\home';$install=Join-Path $home 'hermes-agent';$runtime=Join-Path $fixture 'runtime';$upstreamRepo=Join-Path $fixture 'source-repository'
            New-Item -ItemType Directory -Path $home,$runtime,$upstreamRepo -Force | Out-Null
            $plan=[pscustomobject]@{HermesHome=$home;InstallDir=$install;RuntimeRoot=$runtime;Fingerprint=('A'*64);SourceCommit=('b'*40);IncludeDesktop=$false;SkipComputerUse=$true}
            $git=Get-HermesVerificationGitPath -HermesHome $home
            if(-not $git){throw 'Signed Program Files Git required'}
            $gitDir=Split-Path -Parent $git
            $bash=Get-HermesTrustedGitBashPath $git
            $environment=New-HermesStageEnvironment -Plan $plan -Stage repository -IsolatedGitVerification
            function Run-Git {param([string[]]$Arguments) $r=Invoke-HermesProcess -FilePath $git -ArgumentList $Arguments -Environment $environment -TimeoutSeconds 60;if($r.ExitCode -ne 0){throw ('Fixture Git failed: '+$r.StdErr)};return $r.StdOut.Trim()}
            Run-Git @('-C',$upstreamRepo,'init','-q') | Out-Null
            [IO.File]::WriteAllText((Join-Path $upstreamRepo '.gitignore'),"venv/`n")
            [IO.File]::WriteAllText((Join-Path $upstreamRepo 'fixture.txt'),'local offline proof fixture')
            Run-Git @('-C',$upstreamRepo,'add','--all') | Out-Null
            Run-Git @('-C',$upstreamRepo,'-c','user.name=NST Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture') | Out-Null
            $plan.SourceCommit=Run-Git @('-C',$upstreamRepo,'rev-parse','HEAD')
            $environment['GIT_ALLOW_PROTOCOL']='file'
            Run-Git @('clone','--no-hardlinks','--',$upstreamRepo,$install) | Out-Null
            $environment['GIT_ALLOW_PROTOCOL']='https:ssh'
            Run-Git @('-C',$install,'remote','set-url','origin','https://github.com/NousResearch/hermes-agent.git') | Out-Null
            $seed=Get-HermesFreshCheckoutSeed -InstallDir (Join-Path $fixture 'not-yet-created')
            $seed.InstallDir=$install
            $proof=New-HermesFreshRepositoryProof -Seed $seed -Plan $plan -ExpectedCommit $plan.SourceCommit
            $venv=Join-Path $install 'venv\Scripts';New-Item -ItemType Directory -Path $venv -Force | Out-Null
            foreach($n in @('hermes.exe','hermes-acp.exe')){Copy-Item -LiteralPath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Destination (Join-Path $venv $n)}
            $profile=Join-Path $home 'profiles\default';New-Item -ItemType Directory -Path $profile -Force | Out-Null
            $personal=Join-Path $profile 'config.yaml';[IO.File]::WriteAllText($personal,'fixture personal data, never executed')
            $personalHash=(Get-FileHash -LiteralPath $personal).Hash
            $raw=$gitDir+';%USERPROFILE%\Apps\bin;%LOCALAPPDATA%\Microsoft\WindowsApps;;C:\Windows\System32'
            Set-FixturePath $raw ExpandString
            $initial=Get-HermesUserEnvironmentRecord Path
            $legacy=Get-HermesPathStageEnvironmentSnapshot -Plan $plan -TrustedGitBashPath $bash
            Set-HermesPersistentEnvironmentStageExpectation -Snapshot $legacy -Plan $plan -Stage path
            $runner=Join-Path $source 'tests\fixtures\Invoke-PathStageRegistryFixture.ps1'
            $child=New-HermesStageEnvironment -Plan $plan -Stage path
            try {
                $contextBlocked=$false;try{Assert-HermesStagePathExpansionContext -Environment $child}catch{$contextBlocked=$true}
                Assert-Recovery $contextBlocked 'actual child expansion mismatch is blocked before executing the installer'
                $result=Invoke-HermesProcess -FilePath (Get-HermesPowerShellExecutable) -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-RegistrySubKey',$keyName,'-HermesHome',$home,'-InstallDir',$install) -Environment $child -TimeoutSeconds 60
                Assert-Recovery ($result.ExitCode -eq 0 -and $result.StdOut.Contains('true')) 'upstream helper succeeds while writing only the isolated test registry'
                $failed=Test-HermesPersistentEnvironmentPostcondition -Snapshot $legacy -Plan $plan
                $diagnostic=Format-HermesPersistentEnvironmentDifference -Snapshot $legacy -Result $failed
                Assert-Recovery (-not $failed.Valid -and -not $failed.PathValid -and $failed.ActualPath.Contains('stage-profile-')) 'original REG_EXPAND_SZ mismatch is reproduced, not guessed'
                Assert-Recovery ($diagnostic.Contains('User PATH 항목') -and $diagnostic.Contains('예상=') -and $diagnostic.Contains('실제=') -and $diagnostic.Contains('stage-profile-')) 'diagnostic identifies exact differing PATH entries'
            } finally {Remove-HermesStageEnvironmentArtifacts -Environment $child -Plan $plan}
            $rollback=Invoke-HermesExposureRollback -Snapshot $legacy -Plan $plan -FreshRepositoryProof $proof -LauncherExcludeWrite $null -LauncherAttestationWrite $null -Paths (Get-HermesDefaultPaths -HermesHome $home -InstallDir $install -RuntimeRoot $runtime) -LogPath $null
            Assert-Recovery (-not $rollback.PathRestored) 'unknown changed PATH is not blindly overwritten during rollback'
            $verification=Test-HermesInstallation -HermesHome $home -InstallDir $install -RuntimeRoot $runtime -ExpectedCommit $plan.SourceCommit -StaticOnly
            $manifest=[pscustomobject]@{stages=@(@{name='repository';title='Repository';category='install';needs_user_input=$false},@{name='dependencies';title='Dependencies';category='install';needs_user_input=$false},@{name='path';title='Path';category='finalize';needs_user_input=$false})}
            $state=New-HermesInstallState -Plan $plan -Manifest $manifest
            $hash='74225BF244253BFA5BC2B1D16FA3BB8618E199A53D1C0344B37AB9930696D3BA'
            foreach($n in @('repository','dependencies')){Set-HermesStageRecord -State $state -Name $n -Status Succeeded -InstallerSha256 $hash | Out-Null}
            Set-HermesStageRecord -State $state -Name path -Status Failed -InstallerSha256 $hash | Out-Null
            $state.status='Failed'
            $values=Get-HermesRegistryPathValues
            $cleanup=Get-HermesFailedLauncherPathRecovery -Plan $plan -State $state -Verification $verification -InstallerSha256 $hash -PathValues $values
            Assert-Recovery ($cleanup.Changed -and $cleanup.After -ceq (($values[0] -split ';' | Select-Object -Skip 1) -join ';')) 'legacy failed residue removes only the exact owned launcher entry'
            foreach($case in @('plan','source','hash','completed','dirty','marker','attestation','machine')){
                $s=$state | ConvertTo-Json -Depth 12 | ConvertFrom-Json;$v=$verification | ConvertTo-Json -Depth 8 | ConvertFrom-Json;$p=@($values[0],$values[1]);$h=$hash
                switch($case){plan{$s.plan_fingerprint='wrong'} source{$s.source_commit=('f'*40)} hash{$h=('F'*64)} completed{$s.status='Completed'} dirty{$v.CheckoutClean=$false} marker{$v.MarkerMatches=$true} attestation{$v.LauncherAttestationValid=$true} machine{$p[1]=$values[1]+';'+$cleanup.Launcher}}
                $blocked=$false;try{Get-HermesFailedLauncherPathRecovery -Plan $plan -State $s -Verification $v -InstallerSha256 $h -PathValues $p | Out-Null}catch{$blocked=$true}
                Assert-Recovery $blocked ('ownership/source guard remains fail-closed: '+$case)
            }
            $script:recoveryProcesses=@([pscustomobject]@{ProcessId=999999;ExecutablePath=(Join-Path $install 'venv\Scripts\python.exe');CommandLine='fixture'})
            $blocked=$false;try{Invoke-HermesFailedLauncherPathRecovery -Preparation $cleanup -Plan $plan -State $state | Out-Null}catch{$blocked=$true}
            Assert-Recovery ($blocked -and (Get-HermesUserEnvironmentValue Path) -ceq $values[0]) 'active runtime blocks recovery without stopping any process or changing PATH'
            $script:recoveryProcesses=@([pscustomobject]@{ProcessId=999999;ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';CommandLine=('fixture -InstallDir "'+$install+'"')})
            $blocked=$false;try{Assert-HermesFailedInstallNotInUse -Plan $plan}catch{$blocked=$true}
            Assert-Recovery $blocked 'active exact InstallDir argument is protected even without a trailing separator'
            $script:recoveryProcesses=@()
            $journal=Invoke-HermesFailedLauncherPathRecovery -Preparation $cleanup -Plan $plan -State $state
            Assert-Recovery ((Test-Path -LiteralPath $journal) -and -not (Test-HermesPathContainsDirectory -PathValues @((Get-HermesUserEnvironmentValue Path)) -Directory $cleanup.Launcher)) 'owned failed PATH is journaled and removed before the fresh-install guard'
            $record=[IO.File]::ReadAllText($journal,[Text.Encoding]::UTF8) | ConvertFrom-Json
            Assert-Recovery ($record.checkpoint.status -ceq 'Failed' -and $record.before.Value -ceq $values[0]) 'previous failure and original registry representation remain recoverable'
            $escape=Join-Path $fixture 'must-not-receive-recovery';New-Item -ItemType Directory -Path $escape|Out-Null
            $link=Join-Path $runtime 'recovery';New-Item -ItemType Junction -Path $link -Target $escape|Out-Null
            try {
                $blocked=$false;try{Move-HermesResumeManagedSeedToQuarantine -Plan $plan -State $state|Out-Null}catch{$blocked=$true}
                Assert-Recovery ($blocked -and (Test-Path -LiteralPath $install) -and @(Get-ChildItem -LiteralPath $escape -Force).Count -eq 0) 'reparse recovery destination cannot move files outside RuntimeRoot'
            } finally {
                if([IO.Path]::GetFullPath($link) -ceq [IO.Path]::GetFullPath((Join-Path $runtime 'recovery')) -and ((Get-Item -LiteralPath $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){[IO.Directory]::Delete($link,$false)}
            }
            $moved=Move-HermesResumeManagedSeedToQuarantine -Plan $plan -State $state
            Assert-Recovery ($moved.Changed -and (Get-HermesFreshCheckoutSeed -InstallDir $install).Eligible) 'unattested failed code is quarantined, not reused as trusted code'
            Assert-Recovery ((Get-FileHash -LiteralPath $personal).Hash -ceq $personalHash) 'personal profile data survives failed-install quarantine byte-for-byte'
            $environment['GIT_ALLOW_PROTOCOL']='file';Run-Git @('clone','--no-hardlinks','--',$upstreamRepo,$install)|Out-Null;$environment['GIT_ALLOW_PROTOCOL']='https:ssh'
            Run-Git @('-C',$install,'remote','set-url','origin','https://github.com/NousResearch/hermes-agent.git')|Out-Null
            New-Item -ItemType Directory -Path (Join-Path $install 'venv\Scripts') -Force | Out-Null
            Set-FixturePath $raw ExpandString
            $snapshot=Get-HermesPathStageEnvironmentSnapshot -Plan $plan -TrustedGitBashPath $bash
            $prepare=New-HermesGitPathPreparation -TrustedGitPath $git -PathValues (Get-HermesRegistryPathValues)
            $prepare=Add-HermesPathMaterializationPreparation -Preparation $prepare -Snapshot $snapshot
            Assert-Recovery ($prepare.Changed -and $prepare.MaterializesUserPath -and -not $snapshot.LauncherEntryPresent) 'same valid Git plus expandable User PATH now requests only safe materialization'
            Set-HermesPreparedGitPath -Preparation $prepare -Snapshot $snapshot -RuntimeRoot $runtime -TrustedGitPath $git | Out-Null
            Assert-Recovery ((Get-HermesUserEnvironmentRecord Path).Kind -ceq 'String' -and (Get-HermesUserEnvironmentValue Path) -ceq $snapshot.UserPath) 'normalization preserves real-user paths and order while blocking child-profile reinterpretation'
            Set-HermesPersistentEnvironmentStageExpectation -Snapshot $snapshot -Plan $plan -Stage path
            $child=New-HermesStageEnvironment -Plan $plan -Stage path
            try{Assert-HermesStagePathExpansionContext -Environment $child;$result=Invoke-HermesProcess -FilePath (Get-HermesPowerShellExecutable) -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-RegistrySubKey',$keyName,'-HermesHome',$home,'-InstallDir',$install) -Environment $child -TimeoutSeconds 60}finally{Remove-HermesStageEnvironmentArtifacts -Environment $child -Plan $plan}
            $passed=Test-HermesPersistentEnvironmentPostcondition -Snapshot $snapshot -Plan $plan
            Assert-Recovery ($result.ExitCode -eq 0 -and $passed.Valid -and -not $passed.ActualPath.Contains('stage-profile-')) 'retry reaches successful upstream path helper AND the unchanged strict postcondition'
            Save-HermesInstallEnvironmentCheckpoint -State $state -Plan $plan -Snapshot $snapshot -InstallerSha256 $hash
            Assert-Recovery ($state.environment_checkpoint.original.UserPath.Kind -ceq 'ExpandString' -and $state.environment_checkpoint.expected.UserPath -ceq $snapshot.ExpectedPath) 'durable checkpoint binds original type and expected value to source and plan'
            Assert-Recovery (Restore-HermesRejectedUserPathExposure -Snapshot $snapshot -Plan $plan) 'known failed write restores original raw value and REG_EXPAND_SZ type'
            Assert-Recovery (Test-HermesEnvironmentRecordExact (Get-HermesUserEnvironmentRecord Path) $initial) 'rollback restores the full original representation, not an expanded approximation'
            foreach($field in @(@('HERMES_HOME','UserHome','ExpectedHermesHome'),@('HERMES_GIT_BASH_PATH','UserGitBash','ExpectedGitBashPath'))){
                $before=[pscustomobject]@{Exists=$true;Kind='ExpandString';Value='%USERPROFILE%\original-fixture'}
                $snapshot.OriginalEnvironmentRecords.($field[1])=$before
                $expected='C:\fixture-approved-value';$snapshot.($field[2])=$expected
                Write-FixtureRecord $field[0] ([pscustomobject]@{Exists=$true;Kind='String';Value=$expected})
                Assert-Recovery (Restore-HermesOriginalEnvironmentRecord -Snapshot $snapshot -Name $field[0] -RecordProperty $field[1] -ExpectedValue $expected) ('raw value/type conditional rollback also covers '+$field[0])
            }
            Set-FixturePath ($snapshot.ExpectedPath+';C:\ForeignChange')
            Assert-Recovery (-not (Restore-HermesRejectedUserPathExposure -Snapshot $snapshot -Plan $plan) -and (Get-HermesUserEnvironmentValue Path).EndsWith('C:\ForeignChange')) 'concurrent unrelated PATH edit is preserved rather than blindly rolled back'
            foreach($case in @('HERMES_HOME','HERMES_GIT_BASH_PATH')){
                $result=[pscustomobject]@{PathValid=$true;HermesHomeValid=($case -ne 'HERMES_HOME');GitBashPathValid=($case -ne 'HERMES_GIT_BASH_PATH');ActualHermesHome='C:\unexpected-home';ActualGitBashPath='C:\unexpected-bash'}
                Assert-Recovery ((Format-HermesPersistentEnvironmentDifference -Snapshot $snapshot -Result $result).Contains($case)) ('non-PATH diagnostic identifies exact field: '+$case)
            }
            $script:recoveryMachine=[pscustomobject]@{Exists=$true;Kind='ExpandString';Value='%USERPROFILE%\MachineAlias'}
            $snapshot.OriginalEnvironmentRecords.MachinePath=$script:recoveryMachine
            $blocked=$false;try{Add-HermesPathMaterializationPreparation -Preparation $prepare -Snapshot $snapshot|Out-Null}catch{$blocked=$true}
            Assert-Recovery $blocked 'unsafe Machine PATH expansion is explained without editing system settings'
            $script:recoveryMachine=[pscustomobject]@{Exists=$true;Kind='ExpandString';Value='%SystemRoot%\System32'}
            $e=Get-HermesCuratedProcessEnvironment;$e['SystemRoot']=([Environment]::GetEnvironmentVariable('SystemRoot')).ToUpperInvariant()
            Set-FixturePath 'C:\Windows\System32'
            Assert-HermesStagePathExpansionContext -Environment $e
            Assert-Recovery $true 'normal Windows root casing does not falsely block equivalent expansion contexts'
            Assert-Recovery ((Get-FileHash -LiteralPath $personal).Hash -ceq $personalHash) 'profile preservation remains true after recovery and retry'
            Write-Host ("PASS $script:recoveryAssertions environment recovery assertions; real User/Machine Environment keys untouched, no live server/model calls")
        } finally {
            if($null -ne $environment){Remove-HermesStageEnvironmentArtifacts -Environment $environment -Plan $plan}
            foreach($n in $names){Set-Item -Path ('Function:script:'+$n) -Value $originals[$n]}
            Remove-Variable recoveryKey,recoveryMachine,recoveryProcesses,recoveryAssertions -Scope Script -ErrorAction SilentlyContinue
        }
    } $fixture $keyName $source $OfficialInstallerPath
} finally {
    if($keyName -cmatch '^Software\\NST\.InstallRecovery\.Tests\\[0-9a-f]{32}$'){[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($keyName,$false)}
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if([IO.Path]::GetFullPath($fixture).StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $fixture) -cmatch '^nst-env-recovery-[0-9a-f]{32}$'){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
exit 0
