[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Loader.psm1') -Force
& (Get-Module HermesEasySetup.ResearchRuntime) {
    $script:passed = 0
    function Assert-Migration {
        param([bool]$Condition,[string]$Name)
        if (-not $Condition) { throw $Name }
        $script:passed++; Write-Host ('PASS ' + $Name)
    }
    function Reject-Migration {
        param([scriptblock]$Action,[string]$Name)
        $rejected = $false
        try { & $Action | Out-Null } catch { $rejected = $true }
        Assert-Migration $rejected $Name
    }
    function New-TaskFixture {
        param($Plan,[string]$State = 'Running')
        return [pscustomobject]@{
            TaskName=$Plan.TaskName; State=$State; Enabled=$true; Description=$Plan.Description
            Principal=[pscustomobject]@{UserId=$Plan.OwnerSID;LogonType='Interactive';RunLevel='Limited'}
            Actions=@([pscustomobject]@{Execute=$Plan.Execute;Arguments=$Plan.Arguments})
        }
    }
    $script:fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('hermes-migration-tests-' + [guid]::NewGuid().ToString('N'))
    $paths = [pscustomobject]@{HermesHome=(Join-Path $script:fixtureRoot 'home');InstallDir=(Join-Path $script:fixtureRoot 'source');RuntimeRoot=(Join-Path $script:fixtureRoot 'runtime')}
    $owner = 'S-1-5-21-1234-5678-9012-1001'
    $prior = [pscustomobject]@{
        SchemaVersion=1;Manager='HermesEasySetup.Research.v1';RuntimeKind='Existing';OwnerSID=$owner;TeamID=('a'*32)
        Profiles=@('research-lead','research-scout','research-worker','research-reviewer' | ForEach-Object { [pscustomobject]@{ProfileName=$_;GatewayTask=$null;OwnsProfile=$true} })
    }
    $powershell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $brokerPlan = Get-HermesResearchTaskPlan -ProfileName 'governed-team' -HermesHome $paths.HermesHome -RuntimeRoot $paths.RuntimeRoot -OwnerSID $owner -TeamID $prior.TeamID -PowerShellPath $powershell -Manager $script:ResearchLegacyManager
    $script:taskFixtures = @{}
    $script:disabled = New-Object System.Collections.Generic.List[string]
    $script:stopped = New-Object System.Collections.Generic.List[string]
    $script:exports = New-Object System.Collections.Generic.List[string]
    $script:processResult = [pscustomobject]@{Started=$true;TimedOut=$false;ExitCode=0;StdOut='{}';StdErr=''}
    $script:processCheckResult = [pscustomobject]@{Started=$true;TimedOut=$false;ExitCode=0;StdOut='{"ready":false,"live_test_verified":false}';StdErr=''}
    $script:processCalls = New-Object System.Collections.Generic.List[object]
    $script:brokerSnapshotFixture = $null
    $script:killedBrokerIDs = New-Object System.Collections.Generic.List[int]
    function script:Get-HermesPowerShellExecutable { return 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
    function script:Get-ScheduledTask { param($TaskPath,$ErrorAction) return @($script:taskFixtures.Values) }
    function script:Disable-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction) $script:disabled.Add($TaskName); $script:taskFixtures[$TaskName].Enabled=$false }
    function script:Stop-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction) $script:stopped.Add($TaskName); $script:taskFixtures[$TaskName].State='Ready' }
    function script:Export-ScheduledTask { param($TaskName,$TaskPath,$ErrorAction) $script:exports.Add($TaskName); return '<Task>fixture</Task>' }
    function script:Invoke-HermesProcess {
        param($FilePath,$ArgumentList,$Environment,$TimeoutSeconds)
        $script:processCalls.Add([pscustomobject]@{FilePath=$FilePath;Arguments=@($ArgumentList);Environment=$Environment;Timeout=$TimeoutSeconds})
        if ($ArgumentList.Count -gt 4 -and $ArgumentList[4] -ceq 'check') { return $script:processCheckResult }
        return $script:processResult
    }
    function script:Get-HermesResearchBrokerProcessSnapshot {
        param([int]$ProcessID)
        if ($null -eq $script:brokerSnapshotFixture) { return $null }
        if ($ProcessID -ne $script:brokerSnapshotFixture.ProcessID) { throw 'UnexpectedFixturePID' }
        # Never expose or terminate a real OS process from these lifecycle tests.
        $fakeProcess = [pscustomobject]@{ID=$ProcessID}
        $fakeProcess | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        $fakeProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value { $script:killedBrokerIDs.Add($this.ID) }
        $fakeProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Timeout) return $true }
        return [pscustomobject]@{ProcessID=$ProcessID;CreationTicks=$script:brokerSnapshotFixture.CreationTicks;PhysicalPath=$script:brokerSnapshotFixture.PhysicalPath;CommandLine=$script:brokerSnapshotFixture.CommandLine;Process=$fakeProcess}
    }
    try {
        New-Item -ItemType Directory -Path (Join-Path $paths.RuntimeRoot 'research'),$paths.HermesHome -Force | Out-Null
        $identityRoot = Join-Path $script:fixtureRoot 'python-identity'
        New-Item -ItemType Directory -Path $identityRoot -Force | Out-Null
        $launcher = Join-Path $identityRoot 'venv-launcher.exe'
        $physical = Join-Path $identityRoot 'base-interpreter.exe'
        [IO.File]::WriteAllText($launcher,'fixture launcher - never executed')
        [IO.File]::WriteAllText($physical,'fixture interpreter - never executed')
        $script:processResult.StdOut = $physical + "`r`n"
        $resolved = Get-HermesResearchPythonProcessPath -Python $launcher
        Assert-Migration ($resolved -ceq $physical -and $resolved -cne $launcher) 'Selected venv launcher can resolve a physically different existing base interpreter path'
        $probe = $script:processCalls[$script:processCalls.Count - 1]
        Assert-Migration ($probe.FilePath -ceq $launcher -and ($probe.Arguments[0..3] -join ',') -ceq '-I,-S,-B,-c' -and $probe.Timeout -eq 15 -and $probe.Arguments[4].Contains('GetModuleFileNameW')) 'Identity probe runs only the exact selected interpreter with isolated bounded OS module inspection'
        Assert-Migration (@('PYTHONHOME','PYTHONPATH','PYTHONUSERBASE','PYTHONSTARTUP' | Where-Object { -not $probe.Environment.ContainsKey($_) -or $probe.Environment[$_] -cne '' }).Count -eq 0) 'Identity probe clears Python injection environment variables'
        foreach ($badOutput in @('not-a-path','base-interpreter.exe','',($physical+"`n"+$physical),('\\server\share\python.exe'),(Join-Path $identityRoot 'missing.exe'))) {
            $script:processResult.StdOut = $badOutput
            Reject-Migration { Get-HermesResearchPythonProcessPath -Python $launcher } 'Malformed relative missing or network interpreter identity fails closed'
        }
        $script:processResult.StdOut = $physical
        $script:processResult.ExitCode = 1
        Reject-Migration { Get-HermesResearchPythonProcessPath -Python $launcher } 'Nonzero interpreter identity probe cannot authorize a heartbeat'
        $script:processResult.ExitCode = 0; $script:processResult.TimedOut = $true
        Reject-Migration { Get-HermesResearchPythonProcessPath -Python $launcher } 'Timed out interpreter identity probe cannot authorize a heartbeat'
        $script:processResult.TimedOut = $false; $script:processResult.Started = $false
        Reject-Migration { Get-HermesResearchPythonProcessPath -Python $launcher } 'Unstarted interpreter identity probe cannot authorize a heartbeat'
        $script:processResult.Started = $true
        $processModule = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $script:processResult.StdOut = $processModule
        $heartbeatRoot = Join-Path $identityRoot 'heartbeat'
        New-Item -ItemType Directory -Path $heartbeatRoot -Force | Out-Null
        $epoch = ([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds
        $heartbeat = @{prompts_verified=$true;errors=@();updated_at=($epoch+1);pid=$PID;maintenance=$true;active=$false;ready=$true;pending_reasons=@()}
        [IO.File]::WriteAllText((Join-Path $heartbeatRoot 'broker-status.json'),($heartbeat | ConvertTo-Json))
        $script:taskFixtures[$brokerPlan.TaskName] = New-TaskFixture $brokerPlan 'Ready'
        $script:taskFixtures['Hermes_Gateway'] = [pscustomobject]@{TaskName='Hermes_Gateway';State='Running';Enabled=$true}
        $maintenanceTask = [pscustomobject]@{Plan=$brokerPlan;Task=$script:taskFixtures[$brokerPlan.TaskName]}
        $brokerCommand = '"'+$launcher+'" -I -S -B "'+(Join-Path $heartbeatRoot 'engine\research_team\broker.py')+'" serve --root "'+$heartbeatRoot+'"'
        $script:brokerSnapshotFixture = [pscustomobject]@{ProcessID=$PID;CreationTicks=123456789L;PhysicalPath=$processModule;CommandLine=$brokerCommand}
        Assert-Migration (Test-HermesResearchBrokerCommandLine -CommandLine $brokerCommand -Python $launcher -PhysicalPath $processModule -ResearchRoot $heartbeatRoot) 'Exact isolated broker command binds the selected launcher and research root'
        foreach ($badCommand in @(($brokerCommand+' --extra'),$brokerCommand.Replace(' serve ',' self-test '),$brokerCommand.Replace('-I -S -B','-i -S -B'),$brokerCommand.Replace($heartbeatRoot,($heartbeatRoot+'-foreign')))) {
            Assert-Migration (-not (Test-HermesResearchBrokerCommandLine -CommandLine $badCommand -Python $launcher -PhysicalPath $processModule -ResearchRoot $heartbeatRoot)) 'Extra arguments wrong command flags and foreign roots cannot authorize broker stop'
        }
        $maintenanceIdentity = Enter-HermesResearchMaintenance -ResearchRoot $heartbeatRoot -Tasks @($maintenanceTask) -BrokerPlan $brokerPlan -Python $launcher
        Assert-Migration ((Test-Path -LiteralPath (Join-Path $heartbeatRoot 'maintenance.json') -PathType Leaf) -and $maintenanceIdentity.ProcessID -eq $PID -and $maintenanceIdentity.CreationTicks -eq 123456789L) 'Ready task orphan receives maintenance acknowledgement and a precise process identity'
        Assert-Migration ($script:killedBrokerIDs.Count -eq 0) 'Maintenance acknowledgement does not terminate a process before backup and stop'
        Stop-HermesResearchMigrationTasks -Tasks @($maintenanceTask) -BrokerIdentity $maintenanceIdentity
        Assert-Migration ($script:killedBrokerIDs.Count -eq 1 -and $script:killedBrokerIDs[0] -eq $PID -and $script:stopped.Count -eq 0) 'Already Ready scheduler task still stops only its verified idle broker child'
        Assert-Migration ($script:taskFixtures['Hermes_Gateway'].Enabled -and $script:taskFixtures['Hermes_Gateway'].State -ceq 'Running') 'Orphan broker stop leaves the personal gateway untouched'
        $script:brokerSnapshotFixture.CreationTicks++
        Reject-Migration { Stop-HermesResearchMigrationTasks -Tasks @($maintenanceTask) -BrokerIdentity $maintenanceIdentity } 'PID reuse with a changed creation identity is never terminated'
        $script:brokerSnapshotFixture.CreationTicks--
        foreach ($field in @('active','maintenance')) {
            $heartbeat[$field] = -not $heartbeat[$field]
            [IO.File]::WriteAllText((Join-Path $heartbeatRoot 'broker-status.json'),($heartbeat | ConvertTo-Json))
            Reject-Migration { Stop-HermesResearchMigrationTasks -Tasks @($maintenanceTask) -BrokerIdentity $maintenanceIdentity } 'Active or non-maintenance broker is never terminated'
            $heartbeat[$field] = -not $heartbeat[$field]
        }
        [IO.File]::WriteAllText((Join-Path $heartbeatRoot 'broker-status.json'),($heartbeat | ConvertTo-Json))
        $script:brokerSnapshotFixture.CommandLine += ' --foreign'
        Reject-Migration { Stop-HermesResearchMigrationTasks -Tasks @($maintenanceTask) -BrokerIdentity $maintenanceIdentity } 'Changed command line is never terminated after maintenance'
        Reject-Migration { Enter-HermesResearchMaintenance -ResearchRoot $heartbeatRoot -Tasks @($maintenanceTask) -BrokerPlan $brokerPlan -Python $launcher } 'Unrelated process cannot be adopted through a stale PID or shared interpreter'
        $script:brokerSnapshotFixture.CommandLine = $brokerCommand
        $script:taskFixtures[$brokerPlan.TaskName].Description = 'foreign'
        Reject-Migration { Stop-HermesResearchMigrationTasks -Tasks @($maintenanceTask) -BrokerIdentity $maintenanceIdentity } 'Changed scheduler ownership prevents orphan termination'
        $script:taskFixtures[$brokerPlan.TaskName] = New-TaskFixture $brokerPlan 'Ready'
        Assert-Migration ($script:killedBrokerIDs.Count -eq 1) 'All identity and idle rejection cases leave process termination count unchanged'
        Exit-HermesResearchMaintenance -ResearchRoot $heartbeatRoot
        Assert-Migration (-not (Test-Path -LiteralPath (Join-Path $heartbeatRoot 'maintenance.json'))) 'Fixture maintenance marker is removed after the handshake'
        $heartbeat.updated_at = $epoch - 120
        [IO.File]::WriteAllText((Join-Path $heartbeatRoot 'broker-status.json'),($heartbeat | ConvertTo-Json))
        Reject-Migration { Enter-HermesResearchMaintenance -ResearchRoot $heartbeatRoot -Tasks @($maintenanceTask) -BrokerPlan $brokerPlan -Python $launcher } 'A still-live broker with stale heartbeat fails closed without forced termination'
        $script:brokerSnapshotFixture = $null
        $deadIdentity = Enter-HermesResearchMaintenance -ResearchRoot $heartbeatRoot -Tasks @($maintenanceTask) -BrokerPlan $brokerPlan -Python $launcher
        Assert-Migration ($null -eq $deadIdentity -and -not (Test-Path -LiteralPath (Join-Path $heartbeatRoot 'maintenance.json'))) 'Ready task with dead old PID and stale heartbeat permits a safe retry without termination'
        $script:taskFixtures.Clear(); $script:disabled.Clear(); $script:stopped.Clear()
        $script:processResult.StdOut = '{}'

        $aclRoot = Join-Path $script:fixtureRoot 'private-acl'
        New-Item -ItemType Directory -Path $aclRoot | Out-Null
        $currentSID = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $ownerBefore = (Get-Acl -LiteralPath $aclRoot).Owner
        Protect-HermesResearchPrivateDirectory -LiteralPath $aclRoot -OwnerSID $currentSID
        $firstAcl = Get-Acl -LiteralPath $aclRoot
        $rules = @($firstAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
        Assert-Migration ($firstAcl.Owner -ceq $ownerBefore -and $firstAcl.AreAccessRulesProtected -and $rules.Count -eq 2) 'Fresh private-folder ACL protects access without changing the existing owner'
        Assert-Migration (@($rules | Where-Object { $_.IdentityReference.Value -cnotin @($currentSID,'S-1-5-18') -or $_.FileSystemRights -ne 'FullControl' -or $_.AccessControlType -ne 'Allow' }).Count -eq 0) 'Private-folder DACL grants only current user and SYSTEM full control'
        $accessSection = [Security.AccessControl.AccessControlSections]::Access
        $firstDacl = $firstAcl.GetSecurityDescriptorSddlForm($accessSection)
        Protect-HermesResearchPrivateDirectory -LiteralPath $aclRoot -OwnerSID $currentSID
        $secondAcl = Get-Acl -LiteralPath $aclRoot
        Assert-Migration ($secondAcl.Owner -ceq $ownerBefore -and $secondAcl.GetSecurityDescriptorSddlForm($accessSection) -ceq $firstDacl) 'Repeated private-folder protection is a DACL-only no-op and preserves owner'

        $empty = @(Get-HermesResearchMigrationTasks -Prior $prior -Paths $paths -BrokerPlan $brokerPlan)
        Assert-Migration ($empty.Count -eq 0) 'Owned existing native profiles with null GatewayTask need no invented personal task ownership'
        $plans = @($brokerPlan)
        foreach ($profile in $prior.Profiles) {
            $plans += Get-HermesResearchTaskPlan -ProfileName $profile.ProfileName -HermesHome $paths.HermesHome -RuntimeRoot $paths.RuntimeRoot -OwnerSID $owner -TeamID $prior.TeamID -PowerShellPath $powershell -Manager $script:ResearchLegacyManager
        }
        foreach ($plan in $plans) { $script:taskFixtures[$plan.TaskName] = New-TaskFixture $plan }
        $script:taskFixtures['Hermes_Gateway'] = [pscustomobject]@{TaskName='Hermes_Gateway';State='Running';Enabled=$true}
        $owned = @(Get-HermesResearchMigrationTasks -Prior $prior -Paths $paths -BrokerPlan $brokerPlan)
        Assert-Migration ($owned.Count -eq 5 -and @($owned | Where-Object { $_.Plan.TaskName -ceq 'Hermes_Gateway' }).Count -eq 0) 'Only exact owned research tasks are selected while personal Gateway is excluded'
        $script:taskFixtures[$plans[2].TaskName].Description = 'foreign task'
        Reject-Migration { Get-HermesResearchMigrationTasks -Prior $prior -Paths $paths -BrokerPlan $brokerPlan } 'Foreign task metadata aborts discovery before any disable or stop'
        Assert-Migration ($script:disabled.Count -eq 0 -and $script:stopped.Count -eq 0) 'Discovery rejection has no task side effects'
        $script:taskFixtures[$plans[2].TaskName] = New-TaskFixture $plans[2]
        $prior.Profiles[0].GatewayTask = 'Hermes_Gateway'
        Reject-Migration { Get-HermesResearchMigrationTasks -Prior $prior -Paths $paths -BrokerPlan $brokerPlan } 'Recorded personal or arbitrary task names cannot be adopted'
        $prior.Profiles[0].GatewayTask = $null
        $owned = @(Get-HermesResearchMigrationTasks -Prior $prior -Paths $paths -BrokerPlan $brokerPlan)
        Stop-HermesResearchMigrationTasks -Tasks $owned
        Assert-Migration ($script:disabled.Count -eq 5 -and $script:stopped.Count -eq 5) 'All owned running research tasks are disabled then stopped'
        Assert-Migration ($script:taskFixtures['Hermes_Gateway'].Enabled -and $script:taskFixtures['Hermes_Gateway'].State -ceq 'Running') 'Personal Gateway lifecycle remains running and enabled'
        Assert-Migration (@($owned | Where-Object { $script:taskFixtures[$_.Plan.TaskName].Enabled }).Count -eq 0) 'Disabled former research tasks cannot restart after reboot'
        $disabledBefore = $script:disabled.Count
        $script:taskFixtures[$plans[0].TaskName].Actions[0].Arguments += ' foreign'
        Reject-Migration { Stop-HermesResearchMigrationTasks -Tasks $owned } 'Changed task action is rejected again immediately before disabling'
        Assert-Migration ($script:disabled.Count -eq $disabledBefore) 'Task action race does not disable the changed task'
        $script:taskFixtures[$plans[0].TaskName] = New-TaskFixture $plans[0] 'Ready'

        $history = @{}
        foreach ($profile in $prior.Profiles) {
            $dir = Join-Path $paths.HermesHome ('profiles\'+$profile.ProfileName)
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            foreach ($name in @('.env','config.yaml','SOUL.md','gateway.parked','sessions.db','memory.md')) {
                $path = Join-Path $dir $name
                [IO.File]::WriteAllText($path,('fixture '+$profile.ProfileName+' '+$name),(New-Object Text.UTF8Encoding($false)))
                $history[$path] = ConvertTo-HermesSha256 -LiteralPath $path
            }
        }
        foreach ($name in @('team.json','policy.json','private.json','live-test.json','broker.sqlite','policy.sqlite')) {
            $path = Join-Path $paths.RuntimeRoot ('research\'+$name)
            [IO.File]::WriteAllText($path,('fixture '+$name),(New-Object Text.UTF8Encoding($false)))
            $history[$path] = ConvertTo-HermesSha256 -LiteralPath $path
        }
        $backup = Backup-HermesResearchMigration -Paths $paths -Prior $prior -Tasks $owned
        $record = [IO.File]::ReadAllText((Join-Path $backup 'migration.json')) | ConvertFrom-Json
        Assert-Migration ($record.HistoryPreservedInPlace -and $record.TeamID -ceq $prior.TeamID -and $record.Files.Count -eq 20) 'Backup records exact team and all targeted profile and runtime config files'
        Assert-Migration ($script:exports.Count -eq 5) 'Every selected task is exported for recovery before replacement'
        Assert-Migration (@($history.Keys | Where-Object { (ConvertTo-HermesSha256 -LiteralPath $_) -cne $history[$_] }).Count -eq 0) 'Backup preserves all configuration session memory and database bytes in place'
        foreach ($file in $record.Files) { Assert-Migration ((ConvertTo-HermesSha256 -LiteralPath (Join-Path $backup $file.Relative)) -ceq $file.Sha256) ('Recovery copy retains exact hash '+$file.Relative) }

        $testRoot = Join-Path $script:fixtureRoot 'live-fixture'
        New-Item -ItemType Directory -Path $testRoot | Out-Null
        $selfTest = { Invoke-HermesResearchSelfTest -ResearchRoot $testRoot -Python 'fixture.exe' -Environment @{} -WorkspacePath $testRoot -ChannelID ('c'*26) -CommandPath 'hermes.exe' -Mention '@fixture' }
        $valid = [ordered]@{passed=$true;live=$true;audit_passed=$true;scenarios=@{S1=@{ready_for_delivery=$true;delivered=$true};S2=@{ready_for_delivery=$true;delivered=$true};S3=@{ready_for_delivery=$true;delivered=$true}};folder='C:\ws\_selftest-20261016';ledger_intact=$true;delivered=$true;lead='done';error=$null
            roles=[ordered]@{'research-scout'='done';'research-reviewer'='done';'research-worker'='done'}}
        $script:processResult.StdOut = $valid | ConvertTo-Json -Compress -Depth 4
        $result = & $selfTest
        Assert-Migration ($result.Passed -and $result.Live -and $result.AuditPassed -and @($result.Roles).Count -eq 4 -and $result.RequestID -ceq '_selftest-20261016') 'Live test passes only with four roles and S1-S2-S3 evidence, delivery and an intact ledger'
        Assert-Migration ((Test-Path -LiteralPath (Join-Path $testRoot 'live-test.json')) -and ([IO.File]::ReadAllText((Join-Path $testRoot 'live-test.json')) | ConvertFrom-Json).passed -eq $true) 'Live test evidence is kept with the team record'
        foreach ($case in @(
            @{ Name = 'a simulated (not live) run'; Change = { $valid.live = $false } },
            @{ Name = 'a blocked reviewer'; Change = { $valid.roles.'research-reviewer' = 'blocked'; $valid.passed = $false } },
            @{ Name = 'a lead that did not answer'; Change = { $valid.lead = 'failed (exit 1)' } },
            @{ Name = 'an unverified delivery'; Change = { $valid.delivered = $false } },
            @{ Name = 'a broken ledger chain'; Change = { $valid.ledger_intact = $false } }
        )) {
            $saved = $valid | ConvertTo-Json -Depth 4
            & $case.Change
            $script:processResult.StdOut = $valid | ConvertTo-Json -Compress -Depth 4
            $result = & $selfTest
            Assert-Migration (-not $result.Passed) ('Not ready after ' + $case.Name)
            $valid = $saved | ConvertFrom-Json
        }
        $script:processResult.StdOut = $valid | ConvertTo-Json -Compress -Depth 4
        $script:processResult.TimedOut = $true
        $result = & $selfTest
        Assert-Migration (-not $result.Passed -and $result.ErrorCode -ceq 'LiveTestTimeout') 'Live test timeout is reported explicitly without ready status'
        $script:processResult.TimedOut = $false; $script:processResult.ExitCode = 1
        $result = & $selfTest
        Assert-Migration (-not $result.Passed -and $result.ErrorCode -ceq 'LiveTestPending') 'A failing test process cannot mark the installation ready, whatever it prints'
        $script:processResult.ExitCode = 0; $script:processResult.StdOut = 'not-json'
        $result = & $selfTest
        Assert-Migration (-not $result.Passed -and $result.ErrorCode -ceq 'LiveTestEvidenceRejected') 'Malformed evidence is held rather than assumed successful'
        Write-Host ('Research migration tests passed: '+$script:passed)
    } finally {
        $resolved = [IO.Path]::GetFullPath($script:fixtureRoot)
        $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\hermes-migration-tests-'
        if ($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}
