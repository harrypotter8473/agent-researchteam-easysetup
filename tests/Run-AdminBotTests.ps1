[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\HermesEasySetup.Loader.psm1') -Force
& (Get-Module HermesEasySetup.Admin) {
    $script:passed = 0
    function Assert { param($Ok,$Name) if (-not $Ok) { throw $Name }; $script:passed++; Write-Host "PASS $Name" }
    function Reject { param([scriptblock]$Block,$Name) $failed = $false; try { & $Block | Out-Null } catch { $failed = $true }; Assert $failed $Name }
    function Missing { $e = New-Object Exception 'Fixture not found'; $e.Data['HttpStatus'] = 404; throw $e }
    $root = Join-Path ([IO.Path]::GetTempPath()) ('hermes-admin-bot-unit-' + [Guid]::NewGuid().ToString('N'))
    $data = [pscustomobject]@{ ServerId = 'unit-bots'; SiteName = 'Unit'; TeamName = 'lab'; TeamDisplayName = 'Lab'; ChannelName = 'agent'; Port = 18065; AdminUsername = 'labadmin'; AdminEmail = 'admin@example.invalid'; AdminPassword = 'Unit-Fixture-9274'; BotUsername = 'unit_bot'; BotDisplayName = 'Unit Bot'; BotDescription = 'Research assistant' }
    Assert-HermesAdminBotInput $data
    Assert $true 'Valid bot input'
    foreach ($case in @(@('BotUsername','../escape'),@('BotUsername','Aaa'),@('BotUsername','labadmin'),@('BotUsername','a'),@('BotUsername',('b'*23)),@('BotDisplayName',''),@('BotDisplayName',('x'*65)),@('BotDisplayName',"bad`nname"),@('BotDescription',('x'*801)),@('BotDescription',"bad`nrole"))) {
        $copy = $data | ConvertTo-Json | ConvertFrom-Json; $copy.($case[0]) = $case[1]
        Reject { Assert-HermesAdminBotInput $copy } ('Reject invalid ' + $case[0])
    }
    try {
        Reject { Invoke-HermesAdminBotSetup $data $root } 'Bot operation never creates a missing server'
        Assert (-not (Test-Path -LiteralPath $root)) 'Missing deployment leaves no directory'
        $state = New-HermesAdminState $data $root
        $state.AdminUserId = 'a'*26; $state.TeamId = 't'*26; $state.ChannelId = 'c'*26
        $record = New-HermesAdminBotRecord $state $data
        $again = New-HermesAdminBotRecord $state $data
        Assert ($record.OperationId -ceq $again.OperationId) 'Retry preserves bot operation ID'
        # A Prepared Korean record must be safely reusable before any API call or issuance.
        $unicodeData = $data | ConvertTo-Json | ConvertFrom-Json
        $unicodeData.BotUsername = 'unicode_bot'; $unicodeData.BotDisplayName = '총괄 에이전트'; $unicodeData.BotDescription = '한글 역할 메타데이터'
        $unicodeRecord = New-HermesAdminBotRecord $state $unicodeData
        $unicodePath = Join-Path $state.Directory 'bots\unicode_bot.json'
        [IO.File]::WriteAllText($unicodePath,($unicodeRecord | ConvertTo-Json -Depth 32),(New-Object Text.UTF8Encoding $false))
        $unicodeBytes = [IO.File]::ReadAllBytes($unicodePath)
        Assert (-not ($unicodeBytes[0] -eq 239 -and $unicodeBytes[1] -eq 187 -and $unicodeBytes[2] -eq 191)) 'Korean bot fixture is explicitly UTF-8 without BOM'
        $unicodeAgain = New-HermesAdminBotRecord $state $unicodeData
        Assert ($unicodeAgain.OperationId -ceq $unicodeRecord.OperationId) 'Korean Prepared bot retry preserves operation ID'
        Assert ($unicodeAgain.DisplayName -ceq $unicodeData.BotDisplayName -and $unicodeAgain.Description -ceq $unicodeData.BotDescription) 'Korean bot display name and description survive product metadata reader'
        Assert ($unicodeAgain.Status -ceq 'Prepared' -and -not $unicodeAgain.CreateAttempted -and -not $unicodeAgain.BotId -and -not $unicodeAgain.TokenId) 'Korean record retry does not issue or adopt a bot or token'
        $unicodeChanged = $unicodeData | ConvertTo-Json | ConvertFrom-Json; $unicodeChanged.BotDisplayName = '다른 이름'
        Reject { New-HermesAdminBotRecord $state $unicodeChanged } 'Korean bot display name remains immutable on retry'
        $copy = $data | ConvertTo-Json | ConvertFrom-Json; $copy.BotDisplayName = 'Changed'
        Reject { New-HermesAdminBotRecord $state $copy } 'Existing bot input is immutable'
        $bot = [pscustomobject]@{ user_id = 'b'*26; username = $data.BotUsername; owner_id = $state.AdminUserId; description = ($record.Description + ' ' + (Get-HermesAdminBotMarker $record)); display_name = $data.BotDisplayName; delete_at = 0 }
        $user = [pscustomobject]@{ id = $bot.user_id; username = $bot.username; is_bot = $true; delete_at = 0; roles = 'system_user' }
        Assert-HermesAdminBotIdentity $state $record $bot $user
        Assert $true 'Owned marker and general bot identity accepted'
        foreach ($case in @(@('owner_id',('z'*26)),@('description','Foreign bot'),@('delete_at',1),@('display_name','Foreign'),@('username','other_bot'))) {
            $copy = $bot | ConvertTo-Json | ConvertFrom-Json; $copy.($case[0]) = $case[1]
            Reject { Assert-HermesAdminBotIdentity $state $record $copy $user } ('Reject mismatched bot ' + $case[0])
        }
        foreach ($case in @(@('roles','system_user system_admin'),@('roles','custom_role'),@('roles',''),@('is_bot',$false),@('delete_at',1))) {
            $copy = $user | ConvertTo-Json | ConvertFrom-Json; $copy.($case[0]) = $case[1]
            Reject { Assert-HermesAdminBotIdentity $state $record $bot $copy } ('Reject unsafe bot user ' + $case[0])
        }
        $secretValue = [pscustomobject]@{ Token = [Guid]::NewGuid().ToString('N').Substring(0,26) }
        $vaultPath = Join-Path $state.Directory 'unit-secret.bin'
        Save-HermesAdminBotCredential $vaultPath $secretValue
        Assert ((Unprotect-HermesLabInput $vaultPath).Token -ceq $secretValue.Token) 'Bot secret DPAPI round-trip'
        Assert (-not [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($vaultPath)).Contains($secretValue.Token)) 'Encrypted token is not plaintext'
        Reject { Save-HermesAdminBotCredential $vaultPath $secretValue } 'Token vault never overwrites existing file'

        $script:remoteUser = $null; $script:remoteBot = $null; $script:tokenList = @(); $script:members = @{}
        $script:createdBots = 0; $script:createdTokens = 0; $script:creationEnabled = $false
        $script:loseBotResponse = $false; $script:loseTokenResponse = $false; $script:broadenRole = $false
        $script:issuedToken = [Guid]::NewGuid().ToString('N').Substring(0,26)
        function script:Invoke-HermesAdminAPI {
            param([string]$BaseURL,[string]$Path,[string]$Method='GET',$Body=$null,[string]$Token)
            $response = $null
            if ($Path -like '/api/v4/roles/name/*') { $response = @{ permissions = @($(if ($script:broadenRole) { 'create_bot' } else { 'read_bots' })) } }
            elseif ($Path -eq '/api/v4/config') { $response = @{ ServiceSettings = @{ EnableBotAccountCreation = $script:creationEnabled } } }
            elseif ($Path -eq '/api/v4/config/patch') { $script:creationEnabled = $Body.ServiceSettings.EnableBotAccountCreation }
            elseif ($Path -like '/api/v4/users/username/*') { if (-not $script:remoteUser) { Missing }; $response = $script:remoteUser }
            elseif ($Path -eq '/api/v4/bots' -and $Method -eq 'POST') {
                if (-not $script:creationEnabled) { throw 'Feature not enabled' }
                $script:createdBots++
                $script:remoteBot = [pscustomobject]@{ user_id = 'b'*26; username = $Body.username; owner_id = $state.AdminUserId; description = $Body.description; display_name = $Body.display_name; delete_at = 0 }
                $script:remoteUser = [pscustomobject]@{ id = 'b'*26; username = $Body.username; is_bot = $true; delete_at = 0; roles = 'system_user' }
                if ($script:loseBotResponse) { $script:loseBotResponse = $false; throw 'Lost bot response' }
                $response = $script:remoteBot
            }
            elseif ($Path -like '/api/v4/bots/*') { $response = $script:remoteBot }
            elseif ($Path -match '^/api/v4/(teams|channels)/[^/]+/members') {
                if ($Method -eq 'POST') {
                    $member = [pscustomobject]@{ user_id = $Body.user_id; roles = $(if ($Path -like '*teams*') { 'team_user' } else { 'channel_user' }); scheme_admin = $false; delete_at = 0 }
                    $script:members[$Path + '/' + $Body.user_id] = $member
                    $response = $member
                } else { if (-not $script:members.ContainsKey($Path)) { Missing }; $response = $script:members[$Path] }
            }
            elseif ($Path -like '/api/v4/users/*/tokens*') {
                if ($Method -eq 'POST') {
                    $script:createdTokens++
                    $issued = [pscustomobject]@{ id = 'k'*26; user_id = 'b'*26; token = $script:issuedToken; description = $Body.description; is_active = $true }
                    $script:tokenList = @($issued)
                    if ($script:loseTokenResponse) { $script:loseTokenResponse = $false; throw 'Lost token response' }
                    $response = $issued
                } else { $response = $script:tokenList }
            }
            elseif ($Path -eq '/api/v4/users/me') { if ($Token -cne $script:issuedToken) { throw 'Wrong bot bearer' }; $response = $script:remoteUser }
            else { throw ('Unexpected fixture request: ' + $Method + ' ' + $Path) }
            return [pscustomobject]@{ Data = $response; Token = '' }
        }
        $script:loseBotResponse = $true
        Reject { Initialize-HermesAdminBot $state $data 'http://127.0.0.1:18065' 'fixture-admin' } 'Simulate lost create response'
        Assert (-not $script:creationEnabled -and -not $state.BotCreationPending) 'Failure restores closed creation flag and journal'
        $first = Initialize-HermesAdminBot $state $data 'http://127.0.0.1:18065' 'fixture-admin'
        $again = Initialize-HermesAdminBot $state $data 'http://127.0.0.1:18065' 'fixture-admin'
        Assert ($script:createdBots -eq 1 -and $script:createdTokens -eq 1) 'Lost bot response and repeated operation do not create duplicates'
        Assert ($first.BotId -ceq $again.BotId -and $first.TokenId -ceq $again.TokenId) 'Same bot and token IDs returned on retry'
        $secret = Read-HermesAdminBotCredential $first
        Assert ($secret.Token -ceq $script:issuedToken) 'GUI credential handoff validates operation and IDs'
        Assert (-not ($first | ConvertTo-Json).Contains($secret.Token)) 'Public result has no token secret'
        Assert (-not [IO.File]::ReadAllText((Join-Path $state.Directory 'bots\unit_bot.json')).Contains($secret.Token)) 'Bot metadata has no token secret'
        $mismatch = $first | ConvertTo-Json | ConvertFrom-Json; $mismatch.OperationId = '0'*32
        Reject { Read-HermesAdminBotCredential $mismatch } 'GUI refuses mismatched credential identity'
        $script:tokenList[0].is_active = $false
        Reject { Initialize-HermesAdminBot $state $data 'http://127.0.0.1:18065' 'fixture-admin' } 'Disabled token is not silently replaced'
        Assert ($script:createdTokens -eq 1) 'Disabled token rejection does not issue token'
        $script:tokenList[0].is_active = $true
        $script:remoteBot.owner_id = 'z'*26
        Reject { Initialize-HermesAdminBot $state $data 'http://127.0.0.1:18065' 'fixture-admin' } 'Reassigned bot cannot be adopted'
        $script:remoteBot.owner_id = $state.AdminUserId
        $data.BotUsername = 'second_bot'
        Reject { Initialize-HermesAdminBot $state $data 'http://127.0.0.1:18065' 'fixture-admin' } 'Previously existing account is never adopted'
        $script:remoteUser = $null; $script:remoteBot = $null; $script:tokenList = @(); $script:members = @{}
        $script:loseTokenResponse = $true
        Reject { Initialize-HermesAdminBot $state $data 'http://127.0.0.1:18065' 'fixture-admin' } 'Simulate lost token response'
        $before = $script:createdTokens
        Reject { Initialize-HermesAdminBot $state $data 'http://127.0.0.1:18065' 'fixture-admin' } 'Lost token secret blocks unsafe retry'
        Assert ($script:createdTokens -eq $before) 'Uncertain issuance never duplicates token'
        $script:broadenRole = $true
        Reject { Enable-HermesAdminBotCreation $state 'http://127.0.0.1:18065' 'fixture-admin' } 'Broad create_bot role prevents opening feature'
        Assert (-not $script:creationEnabled) 'Unsafe permission check leaves creation disabled'
        $script:broadenRole = $false; $script:creationEnabled = $true
        Reject { Enable-HermesAdminBotCreation $state 'http://127.0.0.1:18065' 'fixture-admin' } 'Unowned existing feature setting is preserved'
        $state.BotCreationPending = $true
        Restore-HermesAdminBotCreation $state 'http://127.0.0.1:18065' 'fixture-admin'
        Assert (-not $script:creationEnabled -and -not $state.BotCreationPending) 'Interrupted owned creation journal is sealed on recovery'
        Write-Host ('Admin bot tests passed: ' + $script:passed)
    } finally {
        $expectedPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\hermes-admin-bot-unit-'
        $resolved = [IO.Path]::GetFullPath($root)
        if (-not $resolved.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup' }
        if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}
