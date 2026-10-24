# Private InstallEngine helpers. Never stop or modify a server/profile.
Set-StrictMode -Version 2.0

function Get-HermesUserEnvironmentRecord {
    param([Parameter(Mandatory=$true)][ValidateSet('Path','HERMES_HOME','HERMES_GIT_BASH_PATH')][string]$Name)
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try {
        if ($null -eq $key -or @($key.GetValueNames()) -notcontains $Name) { return [pscustomobject]@{Exists=$false;Kind=$null;Value=$null} }
        $kind=[string]$key.GetValueKind($Name)
        if (@('String','ExpandString') -notcontains $kind) { throw ("User $Name 레지스트리 형식이 문자열이 아닙니다: $kind") }
        return [pscustomobject]@{Exists=$true;Kind=$kind;Value=[string]$key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
    } finally { if ($null -ne $key) { $key.Dispose() } }
}

function Get-HermesMachinePathRecord {
    $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment')
    try {
        if ($null -eq $key -or @($key.GetValueNames()) -notcontains 'Path') { return [pscustomobject]@{Exists=$false;Kind=$null;Value=$null} }
        $kind=[string]$key.GetValueKind('Path')
        if (@('String','ExpandString') -notcontains $kind) { throw ('Machine PATH 형식을 확인할 수 없습니다: '+$kind) }
        return [pscustomobject]@{Exists=$true;Kind=$kind;Value=[string]$key.GetValue('Path',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
    } finally { if ($null -ne $key) { $key.Dispose() } }
}

function Set-HermesUserEnvironmentRecord {
    param([Parameter(Mandatory=$true)][ValidateSet('Path','HERMES_HOME','HERMES_GIT_BASH_PATH')][string]$Name,[Parameter(Mandatory=$true)]$Record)
    $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        if (-not [bool]$Record.Exists) { $key.DeleteValue($Name,$false) }
        else {
            if (@('String','ExpandString') -notcontains [string]$Record.Kind -or $Record.Value -isnot [string]) { throw '환경변수 복구 기록 형식이 올바르지 않습니다.' }
            $key.SetValue($Name,[string]$Record.Value,[Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$Record.Kind,$false))
        }
    } finally { $key.Dispose() }
    Send-HermesEnvironmentChangeNotification
}

function Send-HermesEnvironmentChangeNotification {
    if (-not ('NST.InstallEnvironmentNotification' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace NST { public static class InstallEnvironmentNotification {
 [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint message, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
}}
'@
    }
    $result=[IntPtr]::Zero
    [void][NST.InstallEnvironmentNotification]::SendMessageTimeout([IntPtr]0xffff,0x1a,[IntPtr]::Zero,'Environment',2,1000,[ref]$result)
}

function Get-HermesUserEnvironmentValue {
    param([Parameter(Mandatory=$true)][string]$Name)
    return [Environment]::GetEnvironmentVariable($Name,[EnvironmentVariableTarget]::User)
}

function Test-HermesEnvironmentRecordExact {
    param([AllowNull()]$Left,[AllowNull()]$Right)
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    return ([bool]$Left.Exists -eq [bool]$Right.Exists -and (Test-HermesEnvironmentValueExact $Left.Kind $Right.Kind) -and (Test-HermesEnvironmentValueExact $Left.Value $Right.Value))
}

function Get-HermesPersistentEnvironmentRecords {
    return [pscustomobject]@{UserPath=(Get-HermesUserEnvironmentRecord Path);UserHome=(Get-HermesUserEnvironmentRecord HERMES_HOME);UserGitBash=(Get-HermesUserEnvironmentRecord HERMES_GIT_BASH_PATH);MachinePath=(Get-HermesMachinePathRecord)}
}

function Add-HermesPathMaterializationPreparation {
    param([Parameter(Mandatory=$true)]$Preparation,[Parameter(Mandatory=$true)]$Snapshot)
    if ($Snapshot.PSObject.Properties.Name -notcontains 'OriginalEnvironmentRecords') { return $Preparation }
    $r=$Snapshot.OriginalEnvironmentRecords
    $redirected='USERPROFILE|HOME|HOMEDRIVE|HOMEPATH|LOCALAPPDATA|APPDATA|TEMP|TMP|XDG_CONFIG_HOME|XDG_DATA_HOME|XDG_CACHE_HOME|NPM_CONFIG_USERCONFIG|NPM_CONFIG_GLOBALCONFIG|NPM_CONFIG_CACHE|COREPACK_HOME|UV_CACHE_DIR|UV_TOOL_DIR|UV_TOOL_BIN_DIR|UV_PYTHON_INSTALL_DIR'
    if ($r.MachinePath.Kind -ceq 'ExpandString' -and [string]$r.MachinePath.Value -match ('(?i)%('+$redirected+')%')) { throw 'Machine PATH가 임시 프로필에서 달라지는 사용자 변수에 의존합니다. 시스템 PATH는 자동 변경하지 않습니다. 해당 변수 참조를 확인하세요.' }
    # Preserve the real user's expansion before child USERPROFILE isolation.
    # Raw registry value/type are retained for conditional rollback.
    $normalize=($r.UserPath.Exists -and $r.UserPath.Kind -ceq 'ExpandString' -and [string]$r.UserPath.Value -match '%[^%]+%' -and -not (Test-HermesEnvironmentValueExact $r.UserPath.Value $Snapshot.UserPath))
    if (-not $normalize) { return $Preparation }
    if (-not $Preparation.Changed) {
        $Preparation | Add-Member -NotePropertyName OriginalPathValues -NotePropertyValue @($Preparation.PathValues[0],$Preparation.PathValues[1]) -Force
        $Preparation.Changed=$true
    }
    $Preparation | Add-Member -NotePropertyName MaterializesUserPath -NotePropertyValue $true -Force
    return $Preparation
}

function Restore-HermesOriginalEnvironmentRecord {
    param([Parameter(Mandatory=$true)]$Snapshot,[Parameter(Mandatory=$true)][string]$Name,[Parameter(Mandatory=$true)][string]$RecordProperty,[AllowNull()]$ExpectedValue)
    $before=$Snapshot.OriginalEnvironmentRecords.$RecordProperty
    $actual=Get-HermesUserEnvironmentRecord -Name $Name
    if (Test-HermesEnvironmentRecordExact $actual $before) { return $true }
    $exists=-not [string]::IsNullOrEmpty([string]$ExpectedValue)
    $expected=[pscustomobject]@{Exists=$exists;Kind=$(if($exists){'String'}else{$null});Value=$(if($exists){[string]$ExpectedValue}else{$null})}
    if (-not (Test-HermesEnvironmentRecordExact $actual $expected)) { return $false }
    Set-HermesUserEnvironmentRecord -Name $Name -Record $before
    return (Test-HermesEnvironmentRecordExact (Get-HermesUserEnvironmentRecord -Name $Name) $before)
}

function Assert-HermesStagePathExpansionContext {
    param([Parameter(Mandatory=$true)][hashtable]$Environment)
    foreach($item in @(@('User PATH',(Get-HermesUserEnvironmentRecord Path)),@('Machine PATH',(Get-HermesMachinePathRecord)))) {
        $record=$item[1]
        if ($record.Kind -cne 'ExpandString') { continue }
        foreach($match in [regex]::Matches([string]$record.Value,'%([^%]+)%')) {
            $name=$match.Groups[1].Value
            $parent=[Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process)
            $child=$(if($Environment.ContainsKey($name)){$Environment[$name]}else{$null})
            $sameContext=$(if($null -eq $parent -or $null -eq $child){$null -eq $parent -and $null -eq $child}else{[string]::Equals([string]$parent,[string]$child,[StringComparison]::OrdinalIgnoreCase)})
            if (-not $sameContext) {
                throw ("$($item[0])의 %$name% 확장이 실제 사용자와 격리 설치 프로세스에서 다릅니다. 해당 PATH를 실행하지 않았습니다. 원본 형식·변수 참조를 확인하세요.")
            }
        }
    }
}

function Format-HermesPersistentEnvironmentDifference {
    param([Parameter(Mandatory=$true)]$Snapshot,[Parameter(Mandatory=$true)]$Result)
    $parts=New-Object 'System.Collections.Generic.List[string]'
    foreach ($field in @(@('PathValid','User PATH','ExpectedPath','ActualPath'),@('HermesHomeValid','User HERMES_HOME','ExpectedHermesHome','ActualHermesHome'),@('GitBashPathValid','User HERMES_GIT_BASH_PATH','ExpectedGitBashPath','ActualGitBashPath'))) {
        if ($Result.PSObject.Properties.Name -notcontains $field[0] -or [bool]$Result.($field[0])) { continue }
        $expected=[string]$Snapshot.($field[2]); $actual=$(if($Result.PSObject.Properties.Name -contains $field[3]){[string]$Result.($field[3])}else{'(자료 없음)'})
        if ($field[0] -ceq 'PathValid') {
            $e=@($expected -split ';');$a=@($actual -split ';');$different=0
            for ($i=0;$i -lt [Math]::Max($e.Count,$a.Count) -and $different -lt 4;$i++) {
                $ev=$(if($i -lt $e.Count){$e[$i]}else{'(없음)'});$av=$(if($i -lt $a.Count){$a[$i]}else{'(없음)'})
                if ($ev -cne $av) { $parts.Add(('User PATH 항목 {0}: 예상=[{1}] / 실제=[{2}]' -f ($i+1),$ev,$av));$different++ }
            }
            if ($different -eq 0) { $parts.Add('User PATH의 필수 Hermes 실행 폴더 또는 경로 형식이 일치하지 않습니다.') }
        } else { $parts.Add(('{0}: 예상=[{1}] / 실제=[{2}]' -f $field[1],$expected,$actual)) }
    }
    if ($parts.Count -eq 0) { $parts.Add('User 환경변수 불일치 (항목별 자료 없음)') }
    $text=Protect-HermesLogText ($parts -join '; ')
    if ($text.Length -gt 8192) { $text=$text.Substring(0,8192)+' [표시 길이 제한; 로컬 복구 기록 확인]' }
    return $text
}

function Save-HermesInstallEnvironmentCheckpoint {
    param([Parameter(Mandatory=$true)]$State,[Parameter(Mandatory=$true)]$Plan,[Parameter(Mandatory=$true)]$Snapshot,[Parameter(Mandatory=$true)][string]$InstallerSha256)
    if ($Snapshot.PSObject.Properties.Name -notcontains 'OriginalEnvironmentRecords') { return }
    $record=[pscustomobject]@{schema_version=1;plan_fingerprint=[string]$Plan.Fingerprint;source_commit=[string]$Plan.SourceCommit;installer_sha256=$InstallerSha256;original=$Snapshot.OriginalEnvironmentRecords;expected=[pscustomobject]@{UserPath=$Snapshot.ExpectedPath;UserHome=$Snapshot.ExpectedHermesHome;UserGitBash=$Snapshot.ExpectedGitBashPath};updated_at=[DateTime]::UtcNow.ToString('o')}
    $State | Add-Member -NotePropertyName environment_checkpoint -NotePropertyValue $record -Force
}

function Get-HermesInstallRecoveryProcesses {
    return @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Select-Object ProcessId,ExecutablePath,CommandLine)
}

function Assert-HermesFailedInstallNotInUse {
    param([Parameter(Mandatory=$true)]$Plan)
    $root=[IO.Path]::GetFullPath([string]$Plan.InstallDir).TrimEnd('\','/')
    foreach ($process in @(Get-HermesInstallRecoveryProcesses)) {
        if ([int]$process.ProcessId -eq $PID) { continue }
        if (([string]$process.ExecutablePath).StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or ([string]$process.CommandLine) -match ('(?i)'+[regex]::Escape($root)+'(?:[\\/"\s]|$)')) { throw ("실패 설치 경로를 사용하는 프로세스(PID $($process.ProcessId))가 있어 복구를 중단했습니다. 기존 서버·프로필을 강제 종료하지 않았습니다.") }
    }
}

function Get-HermesFailedLauncherPathRecovery {
    param([Parameter(Mandatory=$true)]$Plan,[Parameter(Mandatory=$true)]$State,[AllowNull()]$Verification,[Parameter(Mandatory=$true)][string]$InstallerSha256,[Parameter(Mandatory=$true)][AllowNull()][object[]]$PathValues)
    $launcher=[IO.Path]::GetFullPath((Join-Path ([string]$Plan.InstallDir) 'bin'))
    if (-not (Test-HermesPathContainsDirectory -PathValues $PathValues -Directory $launcher)) { return [pscustomobject]@{Changed=$false} }
    if (-not (Test-HermesStateMatchesResumeEnvelope -State $State -Plan $Plan)) { throw '기존 Hermes PATH의 실패 설치 소유권을 확인하지 못했습니다. 경로는 변경하지 않습니다.' }
    foreach ($name in @('repository','dependencies','path')) {
        $records=@($State.stages | Where-Object name -CEQ $name)
        if ($records.Count -ne 1 -or [string]$records[0].installer_sha256 -ine $InstallerSha256 -or ($name -ne 'path' -and [string]$records[0].status -cne 'Succeeded') -or ($name -eq 'path' -and @('Running','Failed','Succeeded') -cnotcontains [string]$records[0].status)) { throw ('기존 Hermes PATH를 자동 정리할 설치 단계 증명이 없습니다: '+$name) }
    }
    foreach ($name in @('CheckoutHeadMatches','CheckoutClean','OriginOfficial','CheckoutLayoutValid','IndexMatchesExpectedTree','IndexFlagsClean','LocalGitConfigSafe','RepositoryMetadataSafe','NoGitLinks','GitExcludesIsolated','LocalExcludeOverrideAbsent')) {
        if ($null -eq $Verification -or $Verification.PSObject.Properties.Name -notcontains $name -or -not [bool]$Verification.$name) { throw ('실패 설치의 출처·checkout 검증 미통과: '+$name+'. PATH는 보존합니다.') }
    }
    if ([bool]$Verification.MarkerMatches -or [bool]$Verification.LauncherAttestationValid) { throw '완료된 설치의 marker/attestation이 있어 실패 흔적으로 자동 인수하지 않습니다.' }
    if (Test-HermesPathContainsDirectory -PathValues @($PathValues[1]) -Directory $launcher) { throw ('Machine PATH에 Hermes 실행 폴더가 있습니다. 시스템 PATH는 자동 삭제하지 않습니다: '+$launcher) }
    $parts=New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in @(([string]$PathValues[0]).Split([char]';'))) {
        $path=ConvertTo-HermesComparablePathEntry -PathEntry $entry
        if (-not [string]::Equals($path,$launcher,[StringComparison]::OrdinalIgnoreCase)) { $parts.Add($entry) }
    }
    $after=$parts -join ';'
    return [pscustomobject]@{Changed=$true;Before=$PathValues[0];After=$(if($after.Length -eq 0){$null}else{$after});Machine=$PathValues[1];Launcher=$launcher}
}

function Invoke-HermesFailedLauncherPathRecovery {
    param([Parameter(Mandatory=$true)]$Preparation,[Parameter(Mandatory=$true)]$Plan,[Parameter(Mandatory=$true)]$State)
    if (-not $Preparation.Changed) { return $null }
    Assert-HermesFailedInstallNotInUse -Plan $Plan
    $current=Get-HermesRegistryPathValues
    if (-not (Test-HermesEnvironmentValueExact $current[0] $Preparation.Before) -or -not (Test-HermesEnvironmentValueExact $current[1] $Preparation.Machine)) { throw '실패 PATH 검사 후 다른 프로그램이 PATH를 변경했습니다. 덮어쓰지 않습니다.' }
    $record=Get-HermesUserEnvironmentRecord Path
    if (-not (Test-HermesOrdinaryDirectoryPathUnderRoot -LiteralPath ([string]$Plan.RuntimeRoot) -RootPath ([IO.Path]::GetPathRoot([string]$Plan.RuntimeRoot)))) { throw '실패 설치 복구 기록의 경로가 안전한 일반 로컬 폴더가 아닙니다.' }
    $journal=Join-Path ([string]$Plan.RuntimeRoot) ('failed-path-recovery-'+[guid]::NewGuid().ToString('N')+'.json')
    $data=[ordered]@{schema_version=1;plan_fingerprint=$Plan.Fingerprint;source_commit=$Plan.SourceCommit;before=$record;expected_user_path=$Preparation.After;removed_launcher=$Preparation.Launcher;checkpoint=$State;created_at=[DateTime]::UtcNow.ToString('o')}
    Write-HermesExclusiveFile -LiteralPath $journal -Bytes (New-Object Text.UTF8Encoding($false)).GetBytes(($data|ConvertTo-Json -Depth 18))
    if (-not (Test-HermesEnvironmentRecordExact $record (Get-HermesUserEnvironmentRecord Path))) { throw '실패 PATH 복구 직전 레지스트리 원본이 변경되었습니다.' }
    Set-HermesUserPathValue -Value $Preparation.After
    $after=Get-HermesRegistryPathValues
    if (-not (Test-HermesEnvironmentValueExact $after[0] $Preparation.After) -or -not (Test-HermesEnvironmentValueExact $after[1] $Preparation.Machine)) { throw '실패 PATH 복구 후 값이 예상과 다릅니다. 복구 기록을 보존했고 추가 변경은 중단합니다.' }
    return $journal
}
