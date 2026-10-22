[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Loader.psm1') -Force
& (Get-Module HermesEasySetup.Admin) {
    $script:checks=0
    function Assert($ok,$message){if(-not $ok){throw $message};$script:checks++;Write-Host ('PASS '+$message)}
    function Reject($action,$message){$failed=$false;try{& $action|Out-Null}catch{$failed=$true};Assert $failed $message}
    $script:fixture=Join-Path ([IO.Path]::GetTempPath()) ('plugins-offline-'+[guid]::NewGuid().ToString('N'))
    $script:admin=Join-Path $script:fixture 'admin'
    $script:runtime=Join-Path $script:fixture 'runtime'
    $script:private=Join-Path $script:runtime 'mattermost-plugins'
    $server=Join-Path $script:admin 'research-local';$workspace=Join-Path $script:fixture 'workspace'
    $null=New-Item -ItemType Directory -Path $server,(Join-Path $script:runtime 'research'),$workspace,$script:private,(Join-Path $script:fixture 'python') -Force
    $script:python=Join-Path $script:fixture 'python\python.exe';[IO.File]::WriteAllText($script:python,'not executable; process boundary mocked')
    $team=[pscustomobject]@{Manager='HermesEasySetup.ResearchTeam.v2';OwnerSID=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;RuntimeRoot=$script:runtime;TeamID=('e'*32);HomeChannelID=('c'*26);ServerURL='http://127.0.0.1:18065';WizardOptions=@{WorkspacePath=$workspace;HumanUsername='researcher'}}
    Write-HermesAdminJSON (Join-Path $script:runtime 'research\team.json') $team
    $serverState=[pscustomobject]@{Owner='HermesEasySetup.Admin';DeploymentId=('d'*32);Project=('hes-research-local-'+('d'*8));Directory=$server;Identity=@{Port=18065;ServerId='research-local';TeamName='research'};ChannelId=('c'*26);PluginMode='disabled'}
    Write-HermesAdminJSON (Join-Path $server 'deployment.json') $serverState
    [IO.File]::WriteAllText((Join-Path $server 'compose.json'),'fixture')
    $script:pin=Get-HermesResearchPluginPackages
    Assert (@($script:pin.packages).Count -eq 2) 'Two pinned plugin packages verified'
    $script:active=@();$script:inactive=@();$script:uploads=$false;$script:modeCalls=@();$script:commands=@();$script:known=@();$script:failUpload=$false;$script:signature='false';$script:configPatch=$null;$script:listOverride=$null;$script:running=$false
    function Get-HermesAdminRoot {return $script:admin}
    function Set-HermesAdminComposeFiles {param($State)}
    function Get-HermesResearchPluginContainer {param($State) return ('1'*64)}
    function Test-HermesResearchPluginReady {param($BaseURL,$Secret) return $true}
    function Invoke-RestMethod {
        param($Uri,$Headers,$TimeoutSec,$MaximumRedirection)
        if($Uri -cne 'http://127.0.0.1:56789/api/projects'){throw 'Unexpected fixture HTTP boundary'}
        return [pscustomobject]@{projects=@([pscustomobject]@{tasks=@([pscustomobject]@{status=$(if($script:running){'running'}else{'done'})})})}
    }
    function Wait-HermesAdminServer {param($BaseURL)}
    function Set-HermesAdminPluginMode {param($State,$Mode) $script:modeCalls+=$Mode;$script:uploads=($Mode -ceq 'upload')}
    function Invoke-HermesAdminCompose {param($State,$Arguments) if(($Arguments -join ' ') -cne 'up -d mattermost'){throw 'Unexpected Docker mutation'}}
    function Start-HermesResearchPluginBridge {
        param($Root,$Python,$Team,$Pin)
        $prior=$null;if($script:known.Count){$prior=[pscustomobject]@{Packages=$script:known}}
        $record=[pscustomobject]@{Packages=$script:known;Ready=$false;BoardURL=''}
        return [pscustomobject]@{Directory=$script:private;Config=@{port=56789;secret=('f'*64)};Record=$record;Prior=$prior}
    }
    function Invoke-HermesPluginDocker {
        param([string[]]$Arguments,[string]$InputJSON)
        $script:commands+=($Arguments -join ' ')
        $text=$Arguments -join ' '
        if($text -like '*config get PluginSettings.RequirePluginSignature'){return $script:signature}
        if($text -like '*config get PluginSettings.EnableUploads'){return ($script:uploads.ToString().ToLowerInvariant())}
        if($text -like '*user search researcher'){return (@{id=('u'*26);username='researcher';delete_at=0}|ConvertTo-Json)}
        if($text -like '*plugin list'){if($null -ne $script:listOverride){return $script:listOverride};return (@{active=$script:active;inactive=$script:inactive}|ConvertTo-Json -Depth 5)}
        if($text -like '*plugin disable *'){
            $disabled=$Arguments[-1]
            $script:inactive=@($script:inactive|Where-Object {$_.id -cne $disabled})+@($script:active|Where-Object {$_.id -ceq $disabled})
            $script:active=@($script:active|Where-Object {$_.id -cne $disabled})
            return
        }
        if($text -like '*config patch /dev/stdin'){$script:configPatch=$InputJSON|ConvertFrom-Json;return}
        if($text -like '*plugin add *'){
            if($script:failUpload){throw 'fixture upload failure'}
            Assert $script:uploads 'Upload is open only during package installation'
            $package=@($script:pin.packages|Where-Object {$text -like ('*'+$_.file+'*')})[0]
            $script:active=@($script:active|Where-Object {$_.id -cne $package.id})+@([pscustomobject]@{id=$package.id;version=$package.version})
            return
        }
        if($text -like '*--probe'){Assert ($InputJSON -match 'BridgeSecret') 'Probe receives secret only over stdin';return}
    }
    try{
        foreach($json in @('{"active":[],"inactive":[]}','[{"active":[],"inactive":[]}]','null','[]')){
            $script:listOverride=$json
            Assert (@(Get-HermesResearchPluginList 'fixture').Count -eq 0) ('Empty plugin response: '+$json)
        }
        $script:listOverride='[{"active":[{"id":"first","version":"1.0.0"}],"inactive":[{"id":"second","version":"2.0.0"}]}]'
        $parsed=@(Get-HermesResearchPluginList 'fixture')
        Assert ($parsed.Count -eq 2 -and $parsed[0].id -ceq 'first' -and $parsed[0].Enabled -and -not $parsed[1].Enabled) 'Actual array-wrapped mmctl response retains activation state'
        $script:listOverride='[{"unexpected":[]}]'
        Reject {Get-HermesResearchPluginList 'fixture'} 'Unknown list shape fails before plugin mutation'
        $script:listOverride=$null
        $script:active=@([pscustomobject]@{id='com.gist.wordmark';version='0.3.0'})
        Reject {Invoke-HermesResearchPluginsSetup -RuntimeRoot $script:runtime -Python $script:python} 'Explicit Apply required'
        $result=Invoke-HermesResearchPluginsSetup -RuntimeRoot $script:runtime -Python $script:python -Apply
        Assert ($result.Ready -and $result.UploadsLocked) 'Plugins ready only after installation, activation, probe and upload lock'
        Assert (($result.Plugins -join ',') -ceq 'com.hermes.research-board,com.nst.wordmark') 'Korean board and NST included'
        Assert (@($script:inactive|Where-Object id -CEQ 'com.gist.wordmark').Count -eq 1 -and @($script:commands|Where-Object {$_ -like '*plugin disable com.gist.wordmark'}).Count -eq 1) 'GIST is disabled, not deleted, when enabling NST'
        Assert ($result.BoardURL -ceq 'http://127.0.0.1:18065/research/com.hermes.research-board/board') 'Team-scoped Mattermost board URL'
        Assert (-not $result.ResearchChanged -and -not $result.ScenariosRerun) 'Existing agents and S1-S2-S3 are not rerun'
        Assert (($script:modeCalls -join ',') -ceq 'upload,enabled') 'Upload transition closes after installation'
        Assert (($script:commands -join ' ') -notmatch ('f'*64)) 'Bridge secret never appears in process command arguments'
        Assert ($script:configPatch.PluginSettings.Plugins.'com.hermes.research-board'.AllowedUserIDs -ceq ('u'*26)) 'Default board reader is the selected human'
        Assert (Test-Path -LiteralPath (Join-Path $workspace 'Mattermost Research Board.url')) 'Workspace shortcut uses Mattermost route'
        $script:known=@($script:pin.packages);$script:commands=@()
        $again=Invoke-HermesResearchPluginsSetup -RuntimeRoot $script:runtime -Python $script:python -Apply
        Assert ($again.Ready -and @($script:commands|Where-Object {$_ -like '*plugin add *'}).Count -eq 0) 'Same package reapply does not reinstall or rotate credentials'
        $script:active=@($script:active|ForEach-Object {if($_.id -ceq 'com.hermes.research-board'){[pscustomobject]@{id=$_.id;version='0.1.0'}}else{$_}})
        $script:known=@($script:pin.packages|ForEach-Object {if($_.id -ceq 'com.hermes.research-board'){[pscustomobject]@{id=$_.id;version='0.1.0';sha256=('a'*64)}}else{$_}})
        $script:commands=@()
        $upgrade=Invoke-HermesResearchPluginsSetup -RuntimeRoot $script:runtime -Python $script:python -Apply
        Assert ($upgrade.Ready -and @($script:commands|Where-Object {$_ -like '*plugin add *--force'}).Count -eq 1) 'Only an owned older plugin can upgrade to a pinned higher version'
        $script:known=@($script:pin.packages|ForEach-Object {if($_.id -ceq 'com.hermes.research-board'){[pscustomobject]@{id=$_.id;version=$_.version;sha256=('a'*64)}}else{$_}})
        Reject {Invoke-HermesResearchPluginsSetup -RuntimeRoot $script:runtime -Python $script:python -Apply} 'Same-version different digest is not silently overwritten'
        $script:known=@();$script:modeCalls=@()
        Reject {Invoke-HermesResearchPluginsSetup -RuntimeRoot $script:runtime -Python $script:python -Apply} 'Unowned existing plugin is not overwritten'
        Assert (-not $script:uploads -and $script:modeCalls[-1] -ceq 'enabled') 'Failure still closes uploads'
        $script:active=@();$script:failUpload=$true
        Reject {Invoke-HermesResearchPluginsSetup -RuntimeRoot $script:runtime -Python $script:python -Apply} 'Upload failure is not marked ready'
        Assert (-not $script:uploads) 'Upload failure leaves upload gate closed'
        $script:modeCalls=@();$script:running=$true
        Reject {Invoke-HermesResearchPluginsSetup -RuntimeRoot $script:runtime -Python $script:python -Apply} 'Active research blocks a Mattermost restart'
        Assert ($script:modeCalls.Count -eq 0) 'Busy refusal happens before changing upload or restarting server'
        $script:running=$false
        $script:modeCalls=@();$script:signature='true'
        Reject {Invoke-HermesResearchPluginsSetup -RuntimeRoot $script:runtime -Python $script:python -Apply} 'Signature-required server is not weakened'
        Assert ($script:modeCalls.Count -eq 0) 'Signature refusal happens before any server transition'
        Write-Host ($script:checks.ToString()+' plugin installer checks passed (all external boundaries mocked)')
    }finally{
        # This is a newly-created test fixture only, never a user's runtime.
        $full=[IO.Path]::GetFullPath($script:fixture)
        if([IO.Path]::GetDirectoryName($full) -ine [IO.Path]::GetTempPath().TrimEnd('\') -or [IO.Path]::GetFileName($full) -notlike 'plugins-offline-*'){throw 'Fixture cleanup path rejected'}
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
