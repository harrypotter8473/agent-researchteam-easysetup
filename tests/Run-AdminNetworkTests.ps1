[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\HermesEasySetup.Loader.psm1') -Force
& (Get-Module HermesEasySetup.Admin) {
    $script:passed = 0
    function Assert { param($Ok,$Name) if (-not $Ok) { throw $Name }; $script:passed++; Write-Host "PASS $Name" }
    function Reject { param([scriptblock]$Block,$Name) $failed = $false; try { & $Block | Out-Null } catch { $failed = $true }; Assert $failed $Name }
    foreach ($address in @('0.0.0.0','127.0.0.1','192.168.0.1','8.8.8.8','100.128.0.1','100.64.1.01','100.64.1.2:80','http://100.64.1.2','::1')) { Reject { Assert-HermesAdminNetworkAddress $address } 'Reject noncanonical/non-NetBird shared address' }
    Assert-HermesAdminNetworkAddress '100.69.1.2'
    Assert-HermesAdminNetworkAddress ''
    Assert $true 'Canonical CGNAT and private-only scope accepted'
    function script:Get-HermesAdminNetBirdAddress { return '100.69.1.2' }
    $root = Join-Path ([IO.Path]::GetTempPath()) ('hermes-network-unit-' + [Guid]::NewGuid().ToString('N'))
    $data = [pscustomobject]@{ ServerId = 'network-unit'; SiteName = 'Unit'; TeamName = 'lab'; TeamDisplayName = 'Lab'; ChannelName = 'agent'; Port = 18065; AdminUsername = 'labadmin'; AdminEmail = 'admin@example.invalid'; AdminPassword = 'Unit-Fixture-9274'; NetworkMode = 'Share'; NetworkAddress = '100.69.1.2' }
    Assert-HermesAdminNetworkInput $data
    $data.NetworkAddress = '100.69.1.3'
    Reject { Assert-HermesAdminNetworkInput $data } 'An address belonging to another PC is rejected'
    $data.NetworkAddress = '100.69.1.2'
    try {
        $state = New-HermesAdminState $data $root
        $state.AdminUserId = 'a'*26
        Set-HermesAdminComposeFiles $state
        $path = Join-Path $state.Directory 'compose.json'
        $oldText = [IO.File]::ReadAllText($path)
        Assert ((Get-HermesAdminServerURL $state) -ceq 'http://127.0.0.1:18065') 'Legacy deployment remains loopback only'
        $state | Add-Member NetworkAddress '100.69.1.2'
        $state | Add-Member NetworkTransition ([pscustomobject]@{ Previous = ''; Requested = '100.69.1.2' })
        Set-HermesAdminComposeFiles $state
        $compose = New-HermesAdminCompose $state
        Assert (@($compose.services.mattermost.ports).Count -eq 2 -and $compose.services.mattermost.ports[1] -ceq '100.69.1.2:18065:8065') 'Only explicit NetBird IP added; no wildcard publishing'
        Assert ($compose.services.mattermost.environment.MM_SERVICESETTINGS_SITEURL -ceq 'http://100.69.1.2:18065') 'Canonical SiteURL follows shared address'
        Assert (Test-HermesAdminNetworkTransition $state) 'Journal persists until runtime verification'
        $localPorts = @([pscustomobject]@{ HostIp = '127.0.0.1'; HostPort = '18065' })
        $sharedPorts = $localPorts + @([pscustomobject]@{ HostIp = '100.69.1.2'; HostPort = '18065' })
        Assert-HermesAdminPublishedPorts $state $sharedPorts
        Assert-HermesAdminPublishedPorts $state $localPorts -AllowTransition
        Assert $true 'Exact target or known prior scope allowed during recovery'
        Reject { Assert-HermesAdminPublishedPorts $state $localPorts } 'Final verification rejects stale prior scope'
        Reject { Assert-HermesAdminPublishedPorts $state @([pscustomobject]@{HostIp='0.0.0.0';HostPort='18065'}) -AllowTransition } 'Recovery never accepts wildcard port'
        $newText = [IO.File]::ReadAllText($path)
        [IO.File]::WriteAllText($path,'foreign file')
        Reject { Set-HermesAdminComposeFiles $state } 'External compose edit is never overwritten'
        [IO.File]::WriteAllText($path,$newText)
        $state.NetworkAddress = ''
        Set-HermesAdminComposeFiles $state
        Assert ([IO.File]::ReadAllText($path) -ceq $oldText) 'Interrupted transition can restore byte-exact old compose'
        $state.NetworkTransition = $null
        $script:failEndpoint = $false; $script:notAdmin = $false; $script:ups = 0
        function script:Invoke-HermesAdminAPI {
            param($BaseURL,$Path,$Method='GET',$Body=$null,$Token)
            if ($Path -eq '/api/v4/users/login') { return @{ Token = 'fixture-session' } }
            if ($Path -eq '/api/v4/users/me') { return @{ Data = @{ id = $(if ($script:notAdmin) { 'other' } else { $state.AdminUserId }); delete_at = 0; is_bot = $false; roles = 'system_admin' } } }
            if ($Path -eq '/api/v4/config') { return @{ Data = @{ ServiceSettings = @{ SiteURL = Get-HermesAdminServerURL $state } } } }
            if ($Path -eq '/api/v4/users/logout') { return @{} }
            throw 'Unexpected request'
        }
        function script:Invoke-HermesAdminCompose { param($State,$Arguments) $script:ups++; return @{} }
        function script:Wait-HermesAdminServer { param($BaseURL) }
        function script:Assert-HermesAdminPort { param($State,[switch]$Exact) }
        function script:Test-HermesAdminSharedEndpoint { param($State) if ($script:failEndpoint) { throw 'Fixture endpoint unavailable' } }
        $script:notAdmin = $true
        Reject { Set-HermesAdminNetwork $state $data 'http://127.0.0.1:18065' } 'Other administrator identity cannot change this deployment'
        Assert ([IO.File]::ReadAllText($path) -ceq $oldText) 'Rejected identity makes no compose changes'
        $script:notAdmin = $false; $script:failEndpoint = $true
        Reject { Set-HermesAdminNetwork $state $data 'http://127.0.0.1:18065' } 'Failed shared health check reported'
        Assert ((Get-HermesAdminNetworkAddress $state) -ceq '' -and -not (Test-HermesAdminNetworkTransition $state)) 'Failed exposure rolls back scope and journal'
        Assert ([IO.File]::ReadAllText($path) -ceq $oldText -and $script:ups -eq 2) 'Rollback recreates old service without changing data volumes'
        $script:failEndpoint = $false
        Set-HermesAdminNetwork $state $data 'http://127.0.0.1:18065'
        Assert ((Get-HermesAdminNetworkAddress $state) -ceq $data.NetworkAddress -and -not (Test-HermesAdminNetworkTransition $state)) 'Successful share seals journal'
        $before = $script:ups
        Set-HermesAdminNetwork $state $data 'http://127.0.0.1:18065'
        Assert ($script:ups -eq $before) 'Same shared scope is idempotent'
        $data.NetworkMode = 'Local'
        Set-HermesAdminNetwork $state $data 'http://127.0.0.1:18065'
        Assert ([IO.File]::ReadAllText($path) -ceq $oldText) 'Explicit unshare preserves original compose and volume names'
        Write-Host ('Admin network tests passed: ' + $script:passed)
    } finally {
        $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\hermes-network-unit-'
        $resolved = [IO.Path]::GetFullPath($root)
        if (-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup' }
        if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}
