Set-StrictMode -Version 2.0

function Assert-HermesAdminBotInput {
    param($InputData)
    Assert-HermesAdminInput $InputData
    foreach ($key in @('BotUsername','BotDisplayName','BotDescription')) {
        if (-not $InputData.PSObject.Properties[$key]) { throw "봇 입력이 없습니다: $key" }
    }
    if ([string]$InputData.BotUsername -cnotmatch '^[a-z][a-z0-9._-]{2,21}$') { throw '봇 사용자 이름은 영문 소문자로 시작하는 3~22자여야 합니다.' }
    if ([string]::IsNullOrWhiteSpace($InputData.BotDisplayName) -or $InputData.BotDisplayName.Length -gt 64 -or $InputData.BotDisplayName -match '[\x00-\x1f]') { throw '봇 표시 이름은 줄바꿈 없이 1~64자로 입력하세요.' }
    if ($InputData.BotDescription.Length -gt 800 -or $InputData.BotDescription -match '[\x00-\x1f]') { throw '봇 설명은 줄바꿈 없이 800자 이하로 입력하세요.' }
    if ($InputData.BotUsername -ceq $InputData.AdminUsername) { throw '관리자와 봇은 다른 사용자 이름을 사용하세요.' }
}

function Restore-HermesAdminBotCreation {
    param($State,[string]$BaseURL,[string]$Token)
    if ($State.PSObject.Properties['BotCreationPending'] -and $State.BotCreationPending) {
        $null = Invoke-HermesAdminAPI -BaseURL $BaseURL -Path '/api/v4/config/patch' -Method PUT -Token $Token -Body @{ ServiceSettings = @{ EnableBotAccountCreation = $false } }
        $config = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path '/api/v4/config' -Token $Token).Data
        if ($config.ServiceSettings.EnableBotAccountCreation) { throw '봇 생성 기능을 다시 잠그지 못했습니다. 관리자 설정을 확인하고 재시도하세요.' }
        $State.BotCreationPending = $false
        Write-HermesAdminJSON (Join-Path $State.Directory 'deployment.json') $State
    }
}

function Enable-HermesAdminBotCreation {
    param($State,[string]$BaseURL,[string]$Token)
    # A fresh fixture has create_bot only on system_admin. Refuse unexpectedly broadened defaults.
    foreach ($roleName in @('system_user','system_guest','team_user','team_admin','channel_user','channel_admin')) {
        $role = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path ('/api/v4/roles/name/' + $roleName) -Token $Token).Data
        if (@($role.permissions) -contains 'create_bot') { throw '일반 역할에 봇 생성 권한이 있습니다. 관리 콘솔에서 권한을 확인하세요.' }
    }
    $config = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path '/api/v4/config' -Token $Token).Data
    if ($config.ServiceSettings.EnableBotAccountCreation) { throw '서버의 봇 생성 기능이 이미 열려 있습니다. 관리 콘솔에서 끈 뒤 재시도하세요. 기존 설정은 임의로 덮어쓰지 않습니다.' }
    $State | Add-Member -NotePropertyName BotCreationPending -NotePropertyValue $true -Force
    Write-HermesAdminJSON (Join-Path $State.Directory 'deployment.json') $State
    $null = Invoke-HermesAdminAPI -BaseURL $BaseURL -Path '/api/v4/config/patch' -Method PUT -Token $Token -Body @{ ServiceSettings = @{ EnableBotAccountCreation = $true } }
}

function New-HermesAdminBotRecord {
    param($State,$InputData)
    $directory = Join-Path $State.Directory 'bots'
    Assert-HermesAdminPath $directory
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory | Out-Null }
    $path = Join-Path $directory ($InputData.BotUsername + '.json')
    $secretPath = Join-Path $directory ($InputData.BotUsername + '.bin')
    Assert-HermesAdminPath $path; Assert-HermesAdminPath $secretPath
    if (Test-Path -LiteralPath $path) {
        $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($record.Schema -ne 1 -or $record.DeploymentId -cne $State.DeploymentId -or $record.OperationId -cnotmatch '^[a-f0-9]{32}$' -or
            $record.Username -cne $InputData.BotUsername -or $record.DisplayName -cne $InputData.BotDisplayName -or $record.Description -cne $InputData.BotDescription -or
            $record.AdminUserId -cne $State.AdminUserId -or $record.TeamId -cne $State.TeamId -or $record.ChannelId -cne $State.ChannelId) { throw '기존 봇 발급 기록과 입력이 다릅니다. 같은 입력으로 재시도하세요. 기존 봇은 변경하지 않습니다.' }
        foreach ($key in @('BotId','TokenId')) { if ($record.$key -and $record.$key -cnotmatch '^[a-z0-9]{26}$') { throw '봇 발급 기록의 ID가 올바르지 않습니다.' } }
        return $record
    }
    if (Test-Path -LiteralPath $secretPath) { throw '기록이 없는 봇 인증 파일이 있습니다. 덮어쓰지 않습니다.' }
    $record = [pscustomobject][ordered]@{ Schema = 1; DeploymentId = $State.DeploymentId; OperationId = [Guid]::NewGuid().ToString('N'); Username = $InputData.BotUsername; DisplayName = $InputData.BotDisplayName; Description = $InputData.BotDescription; AdminUserId = $State.AdminUserId; TeamId = $State.TeamId; ChannelId = $State.ChannelId; BotId = ''; TokenId = ''; CreateAttempted = $false; Status = 'Prepared' }
    Write-HermesAdminJSON $path $record
    return $record
}

function Save-HermesAdminBotRecord {
    param($State,$Record)
    Write-HermesAdminJSON (Join-Path $State.Directory ('bots\' + $Record.Username + '.json')) $Record
}

function Get-HermesAdminBotMarker {
    param($Record)
    return "[Hermes Easy Setup:$($Record.DeploymentId):$($Record.OperationId)]"
}

function Assert-HermesAdminBotIdentity {
    param($State,$Record,$Bot,$User)
    $description = ($Record.Description + ' ' + (Get-HermesAdminBotMarker $Record)).Trim()
    if ($Bot.user_id -cnotmatch '^[a-z0-9]{26}$' -or $User.id -cne $Bot.user_id -or -not $User.is_bot -or $User.delete_at -ne 0 -or $Bot.delete_at -ne 0 -or
        $User.username -cne $Record.Username -or $Bot.username -cne $Record.Username -or $Bot.owner_id -cne $State.AdminUserId -or
        $Bot.description -cne $description -or $Bot.display_name -cne $Record.DisplayName -or
        ($Record.BotId -and $Record.BotId -cne $Bot.user_id) -or $User.roles -cne 'system_user') {
        throw '봇 소유자·이름·발급 기록·일반 사용자 권한 확인에 실패했습니다. 다른 계정은 변경하지 않습니다.'
    }
}

function Get-HermesAdminBotTokens {
    param([string]$BaseURL,[string]$Token,[string]$BotId)
    for ($page = 0; $page -lt 100; $page++) {
        $items = @((Invoke-HermesAdminAPI -BaseURL $BaseURL -Path "/api/v4/users/$BotId/tokens?page=$page&per_page=100" -Token $Token).Data | Where-Object { $null -ne $_ })
        foreach ($item in $items) { Write-Output $item }
        if ($items.Count -lt 100) { return }
    }
    throw '토큰 목록이 너무 많아 안전하게 확인하지 못했습니다. 새 토큰을 발급하지 않습니다.'
}

function Save-HermesAdminBotCredential {
    param([string]$Path,$Value)
    Assert-HermesAdminPath $Path
    if (Test-Path -LiteralPath $Path) { throw '기존 봇 인증 파일을 덮어쓰지 않습니다.' }
    $temp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $null = Protect-HermesLabInput -Value $Value -LiteralPath $temp
        [IO.File]::Move($temp,$Path)
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Read-HermesAdminBotCredential {
    # GUI-only secret handoff. Callers must never serialize this return value to logs/events.
    param($Result)
    if ($Result.BotUsername -cnotmatch '^[a-z][a-z0-9._-]{2,21}$') { throw '봇 이름이 올바르지 않습니다.' }
    $path = Join-Path $Result.Directory ('bots\' + $Result.BotUsername + '.bin')
    Assert-HermesAdminPath $path
    $secret = Unprotect-HermesLabInput -LiteralPath $path
    if ($secret.DeploymentId -cne $Result.DeploymentId -or $secret.OperationId -cne $Result.OperationId -or $secret.BotId -cne $Result.BotId -or $secret.TokenId -cne $Result.TokenId -or $secret.Token -cnotmatch '^[a-z0-9]{26}$') { throw '저장된 봇 인증과 완료 기록이 다릅니다.' }
    return $secret
}

function Initialize-HermesAdminBot {
    param($State,$InputData,[string]$BaseURL,[string]$Token)
    $record = New-HermesAdminBotRecord $State $InputData
    $user = $null
    try { $user = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path ('/api/v4/users/username/' + $record.Username) -Token $Token).Data }
    catch { if ($_.Exception.Data['HttpStatus'] -ne 404) { throw } }
    if ($user -and -not $record.CreateAttempted) { throw '같은 사용자 이름의 계정이 이미 있습니다. 새 봇 이름을 선택하세요. 기존 계정은 재사용하지 않습니다.' }
    if (-not $user) {
        if ($record.BotId) { throw '기록에 있는 봇이 서버에서 사라졌습니다. 자동 재생성하지 않습니다.' }
        $record.CreateAttempted = $true
        Save-HermesAdminBotRecord $State $record
        try {
            Enable-HermesAdminBotCreation $State $BaseURL $Token
            $null = Invoke-HermesAdminAPI -BaseURL $BaseURL -Path '/api/v4/bots' -Method POST -Token $Token -Body @{ username = $record.Username; display_name = $record.DisplayName; description = ($record.Description + ' ' + (Get-HermesAdminBotMarker $record)).Trim() }
        } finally { Restore-HermesAdminBotCreation $State $BaseURL $Token }
        $user = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path ('/api/v4/users/username/' + $record.Username) -Token $Token).Data
    }
    if (-not $user.is_bot) { throw '같은 이름의 일반 사용자입니다. 봇으로 변환하지 않습니다.' }
    $bot = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path ('/api/v4/bots/' + $user.id) -Token $Token).Data
    Assert-HermesAdminBotIdentity $State $record $bot $user
    $record.BotId = $bot.user_id
    Save-HermesAdminBotRecord $State $record
    foreach ($kind in @('teams','channels')) {
        $targetId = $(if ($kind -eq 'teams') { $State.TeamId } else { $State.ChannelId })
        $memberPath = "/api/v4/$kind/$targetId/members/$($record.BotId)"
        try { $member = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path $memberPath -Token $Token).Data }
        catch {
            if ($_.Exception.Data['HttpStatus'] -ne 404) { throw }
            $body = @{ user_id = $record.BotId }
            if ($kind -eq 'teams') { $body.team_id = $targetId }
            $null = Invoke-HermesAdminAPI -BaseURL $BaseURL -Path "/api/v4/$kind/$targetId/members" -Method POST -Token $Token -Body $body
            $member = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path $memberPath -Token $Token).Data
        }
        $allowedRole = $(if ($kind -eq 'teams') { 'team_user' } else { 'channel_user' })
        if ($member.user_id -cne $record.BotId -or $member.roles -cne $allowedRole -or
            ($member.PSObject.Properties['delete_at'] -and $member.delete_at -ne 0) -or ($member.PSObject.Properties['scheme_admin'] -and $member.scheme_admin)) { throw '봇의 일반 팀·채널 멤버 권한을 확인하지 못했습니다.' }
    }
    $description = 'HermesEasySetup/' + $record.OperationId
    $tokens = @(Get-HermesAdminBotTokens $BaseURL $Token $record.BotId)
    $matching = @($tokens | Where-Object { $_.description -ceq $description })
    $secretPath = Join-Path $State.Directory ('bots\' + $record.Username + '.bin')
    Assert-HermesAdminPath $secretPath
    if (Test-Path -LiteralPath $secretPath) {
        $secret = Unprotect-HermesLabInput -LiteralPath $secretPath
        if ($secret.DeploymentId -cne $State.DeploymentId -or $secret.OperationId -cne $record.OperationId -or $secret.BotId -cne $record.BotId -or
            $matching.Count -ne 1 -or $matching[0].id -cne $secret.TokenId -or -not $matching[0].is_active -or
            ($record.TokenId -and $record.TokenId -cne $secret.TokenId) -or $secret.Token -cnotmatch '^[a-z0-9]{26}$') { throw '저장된 토큰이 서버 기록과 다르거나 비활성 상태입니다. 새 토큰을 자동 발급하지 않습니다.' }
    } else {
        if ($matching.Count -gt 0 -or $record.TokenId) { throw '토큰은 이미 발급되었지만 이 PC의 암호화된 인증 파일이 없습니다. 중복 발급하지 않습니다. 관리 콘솔에서 해당 토큰을 확인하세요.' }
        $issued = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path "/api/v4/users/$($record.BotId)/tokens" -Method POST -Token $Token -Body @{ description = $description }).Data
        if ($issued.user_id -cne $record.BotId -or $issued.id -cnotmatch '^[a-z0-9]{26}$' -or $issued.token -cnotmatch '^[a-z0-9]{26}$') { throw '발급된 토큰 응답을 검증하지 못했습니다. 같은 입력으로 재시도하여 서버 기록을 확인하세요.' }
        $secret = [pscustomobject]@{ DeploymentId = $State.DeploymentId; OperationId = $record.OperationId; BotId = $record.BotId; TokenId = $issued.id; Token = $issued.token }
        Save-HermesAdminBotCredential $secretPath $secret
        $issued = $null
    }
    $me = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path '/api/v4/users/me' -Token $secret.Token).Data
    if ($me.id -cne $record.BotId -or -not $me.is_bot -or $me.delete_at -ne 0 -or $me.roles -cne 'system_user') { throw '발급된 토큰이 일반 봇 계정으로 인증되지 않습니다.' }
    $null = Invoke-HermesAdminAPI -BaseURL $BaseURL -Path "/api/v4/channels/$($State.ChannelId)/members/$($record.BotId)" -Token $secret.Token
    $record.TokenId = $secret.TokenId; $record.Status = 'Ready'
    Save-HermesAdminBotRecord $State $record
    $secret = $null
    return [pscustomobject]@{ Kind = 'Bot'; Ready = $true; Directory = $State.Directory; DeploymentId = $State.DeploymentId; OperationId = $record.OperationId; ServerURL = (Get-HermesAdminServerURL $State); BotUsername = $record.Username; BotDisplayName = $record.DisplayName; BotId = $record.BotId; TokenId = $record.TokenId; TeamId = $State.TeamId; HomeChannelId = $State.ChannelId; Role = 'system_user'; SecretStorage = 'DPAPI CurrentUser (GUI copy only)' }
}

function Invoke-HermesAdminBotSetup {
    [CmdletBinding()]
    param($InputData,[string]$DeploymentRoot = (Get-HermesAdminRoot),[scriptblock]$ProgressCallback)
    Assert-HermesAdminBotInput $InputData
    $owned = $false; $token = $null; $state = $null
    $mutex = New-Object Threading.Mutex($false,('Local\HermesAdminSetup-' + $InputData.ServerId))
    try {
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw '같은 서버의 설치 또는 봇 발급이 진행 중입니다.' }
        $path = Join-Path $DeploymentRoot ($InputData.ServerId + '\deployment.json')
        Assert-HermesAdminPath $path
        if (-not (Test-Path -LiteralPath $path)) { throw '먼저 이 마법사에서 서버·관리자 생성을 완료하세요.' }
        $state = New-HermesAdminState $InputData $DeploymentRoot -Resume
        if (Test-HermesAdminNetworkTransition $state) { throw '서버 공유 전환이 중단되었습니다. 먼저 같은 서버를 이어서 설정하세요.' }
        if ($state.Status -cne 'Ready' -or $state.AdminUserId -cnotmatch '^[a-z0-9]{26}$' -or $state.TeamId -cnotmatch '^[a-z0-9]{26}$' -or $state.ChannelId -cnotmatch '^[a-z0-9]{26}$') { throw '서버 설정을 먼저 완료한 뒤 봇을 추가하세요.' }
        $null = Get-HermesAdminPreflight
        Assert-HermesAdminResources $state; Assert-HermesAdminPort $state; Set-HermesAdminComposeFiles $state
        $running = Invoke-HermesAdminCompose $state @('ps','--status','running','-q','mattermost')
        if (-not $running.StdOut.Trim()) { throw '해당 서버가 꺼져 있습니다. 서버 설정을 이어서 실행하세요.' }
        $baseURL = "http://127.0.0.1:$($state.Identity.Port)"
        if ($ProgressCallback) { & $ProgressCallback ([pscustomobject]@{ type = 'stage'; percent = 15; message = '기존 테스트 서버와 실제 시스템 관리자 권한을 확인합니다.' }) }
        $token = (Invoke-HermesAdminAPI $baseURL '/api/v4/users/login' 'POST' @{ login_id = $InputData.AdminUsername; password = $InputData.AdminPassword }).Token
        if (-not $token) { throw '관리자 로그인 세션이 없습니다.' }
        $me = (Invoke-HermesAdminAPI -BaseURL $baseURL -Path '/api/v4/users/me' -Token $token).Data
        if ($me.id -cne $state.AdminUserId -or $me.username -cne $state.Identity.AdminUsername -or $me.email -cne $state.Identity.AdminEmail -or ($me.PSObject.Properties['is_bot'] -and $me.is_bot) -or $me.delete_at -ne 0 -or @($me.roles -split ' ') -notcontains 'system_admin') { throw '이 서버의 활성 인간 시스템 관리자만 봇과 토큰을 만들 수 있습니다.' }
        Restore-HermesAdminBotCreation $state $baseURL $token
        $team = (Invoke-HermesAdminAPI -BaseURL $baseURL -Path "/api/v4/teams/$($state.TeamId)" -Token $token).Data
        $channel = (Invoke-HermesAdminAPI -BaseURL $baseURL -Path "/api/v4/channels/$($state.ChannelId)" -Token $token).Data
        if ($team.name -cne $state.Identity.TeamName -or $team.delete_at -ne 0 -or $channel.team_id -cne $state.TeamId -or $channel.name -cne $state.Identity.ChannelName -or $channel.delete_at -ne 0) { throw '지정한 팀·채널이 설치 기록과 다르거나 삭제되었습니다.' }
        if ($ProgressCallback) { & $ProgressCallback ([pscustomobject]@{ type = 'stage'; percent = 45; message = '봇 계정·팀·채널 멤버십과 토큰 발급 기록을 확인합니다. 토큰은 로그에 출력하지 않습니다.' }) }
        $result = Initialize-HermesAdminBot $state $InputData $baseURL $token
        if ($ProgressCallback) { & $ProgressCallback ([pscustomobject]@{ type = 'complete'; percent = 100; message = '봇과 토큰이 준비되었습니다. 마법사의 토큰 복사 버튼을 사용하세요.'; data = $result }) }
        return $result
    } finally {
        if ($token) { try { $null = Invoke-HermesAdminAPI -BaseURL $baseURL -Path '/api/v4/users/logout' -Method POST -Token $token } catch { } }
        if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose()
    }
}
