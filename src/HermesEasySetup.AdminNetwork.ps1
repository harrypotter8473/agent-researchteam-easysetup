Set-StrictMode -Version 2.0

# Retained for validating owned server states and safe scope rollback.
function Test-HermesNetBirdIPv4 {
    [CmdletBinding()]
    param([AllowNull()][string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$ip)) { return $false }
    $bytes = $ip.GetAddressBytes()
    return ($bytes.Count -eq 4 -and $bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127)
}

function Assert-HermesAdminNetworkAddress {
    param([AllowEmptyString()][string]$Address)
    if ($Address -and (-not (Test-HermesNetBirdIPv4 $Address) -or ([Net.IPAddress]::Parse($Address)).ToString() -cne $Address)) { throw '공유 주소는 표준 형식의 NetBird IPv4(100.64.0.0/10)만 허용합니다.' }
}

function Get-HermesAdminNetworkAddress {
    param($State)
    $address = $(if ($State.PSObject.Properties['NetworkAddress']) { [string]$State.NetworkAddress } else { '' })
    Assert-HermesAdminNetworkAddress $address
    return $address
}

function Get-HermesAdminServerURL {
    param($State)
    $address = Get-HermesAdminNetworkAddress $State
    if (-not $address) { $address = '127.0.0.1' }
    return "http://${address}:$($State.Identity.Port)"
}

function Get-HermesAdminNetBirdAddress {
    $exe = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'NetBird\netbird.exe'
    Assert-HermesAdminPath $exe
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'NetBird Windows 클라이언트를 설치하고 연결하세요.' }
    $result = Invoke-HermesProcess -FilePath $exe -ArgumentList @('status','--json') -TimeoutSeconds 10
    if ($result.ExitCode -ne 0 -or $result.TimedOut) { throw 'NetBird 상태를 확인하지 못했습니다.' }
    try { $status = $result.StdOut | ConvertFrom-Json; $address = ([string]$status.netbirdIp -split '/')[0] } catch { throw 'NetBird IPv4 상태 응답이 올바르지 않습니다.' }
    Assert-HermesAdminNetworkAddress $address
    if (-not $address) { throw 'NetBird에 연결된 IPv4가 없습니다.' }
    $local = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -ceq $address -and $_.AddressState -eq 'Preferred' })
    if ($local.Count -ne 1) { throw 'NetBird 주소가 이 PC의 활성 인터페이스에 할당되어 있지 않습니다.' }
    return $address
}

function Assert-HermesAdminNetworkInput {
    param($InputData)
    if (-not $InputData.PSObject.Properties['NetworkMode']) { return }
    if ($InputData.NetworkMode -cnotin @('Keep','Share','Local')) { throw '서버 공유 모드가 올바르지 않습니다.' }
    if ($InputData.NetworkMode -ceq 'Share') {
        if (-not $InputData.PSObject.Properties['NetworkAddress'] -or -not $InputData.NetworkAddress) { throw '공유할 NetBird IPv4를 입력하세요.' }
        Assert-HermesAdminNetworkAddress $InputData.NetworkAddress
        if ((Get-HermesAdminNetBirdAddress) -cne $InputData.NetworkAddress) { throw '선택한 공유 주소가 현재 이 PC의 NetBird 주소와 다릅니다.' }
    }
}

function Test-HermesAdminNetworkTransition {
    param($State)
    if (-not $State.PSObject.Properties['NetworkTransition'] -or $null -eq $State.NetworkTransition) { return $false }
    $transition = $State.NetworkTransition
    Assert-HermesAdminNetworkAddress ([string]$transition.Previous)
    Assert-HermesAdminNetworkAddress ([string]$transition.Requested)
    if ($transition.Previous -ceq $transition.Requested -or (Get-HermesAdminNetworkAddress $State) -cnotin @([string]$transition.Previous,[string]$transition.Requested)) { throw '공유 전환 기록이 올바르지 않습니다.' }
    return $true
}

function Set-HermesAdminNetworkCompose {
    param($State,[string]$Path)
    if (-not (Test-HermesAdminNetworkTransition $State)) { return }
    if ($State.PSObject.Properties['PluginTransition'] -and $null -ne $State.PluginTransition) { throw '동시에 여러 compose 설정 전환을 복구하지 않습니다.' }
    if (-not (Test-Path -LiteralPath $Path)) { throw '공유 전환 중 compose 파일이 사라졌습니다.' }
    $actual = [IO.File]::ReadAllText($Path)
    $permitted = @()
    foreach ($address in @([string]$State.NetworkTransition.Previous,[string]$State.NetworkTransition.Requested)) {
        $candidate = $State | ConvertTo-Json -Depth 32 | ConvertFrom-Json
        $candidate.NetworkAddress = $address
        $permitted += (New-HermesAdminCompose $candidate | ConvertTo-Json -Depth 32)
    }
    if ($actual -cnotin $permitted) { throw '공유 전환 기록과 다른 compose 파일입니다. 덮어쓰지 않습니다.' }
    Write-HermesAdminJSON $Path (New-HermesAdminCompose $State)
    # Keep the journal until the container and effective SiteURL have been verified.
}

function Assert-HermesAdminPublishedPorts {
    param($State,$Ports,[switch]$AllowTransition)
    $addresses = @((Get-HermesAdminNetworkAddress $State))
    if ($AllowTransition -and (Test-HermesAdminNetworkTransition $State)) { $addresses += @([string]$State.NetworkTransition.Previous,[string]$State.NetworkTransition.Requested) }
    $actual = @($Ports | ForEach-Object { [string]$_.HostIp + ':' + [string]$_.HostPort } | Sort-Object)
    foreach ($address in $addresses) {
        $expected = @("127.0.0.1:$($State.Identity.Port)")
        if ($address) { $expected += "${address}:$($State.Identity.Port)" }
        if (($actual -join ',') -ceq (@($expected | Sort-Object) -join ',')) { return }
    }
    throw '기존 컨테이너의 포트 공개 범위가 기록과 다릅니다. 변경하지 않습니다.'
}

function Test-HermesAdminSharedEndpoint {
    param($State)
    $url = Get-HermesAdminServerURL $State
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri ($url + '/api/v4/system/ping') -MaximumRedirection 0 -TimeoutSec 10
        if (($response.Content | ConvertFrom-Json).status -cne 'OK') { throw 'Not ready' }
    } catch { throw '이 PC에서 공유 주소 응답을 확인하지 못했습니다. NetBird 연결과 Docker 포트·방화벽 상태를 확인하세요.' }
}

function Set-HermesAdminNetwork {
    param($State,$InputData,[string]$BaseURL)
    $mode = $(if ($InputData.PSObject.Properties['NetworkMode']) { [string]$InputData.NetworkMode } else { 'Keep' })
    if ($mode -ceq 'Keep') { return }
    Assert-HermesAdminNetworkInput $InputData
    $previous = Get-HermesAdminNetworkAddress $State
    $requested = $(if ($mode -ceq 'Share') { [string]$InputData.NetworkAddress } else { '' })
    $token = $null
    $changed = $false
    try {
        $token = (Invoke-HermesAdminAPI $BaseURL '/api/v4/users/login' 'POST' @{ login_id = $InputData.AdminUsername; password = $InputData.AdminPassword }).Token
        $me = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path '/api/v4/users/me' -Token $token).Data
        if ($me.id -cne $State.AdminUserId -or $me.delete_at -ne 0 -or ($me.PSObject.Properties['is_bot'] -and $me.is_bot) -or @($me.roles -split ' ') -notcontains 'system_admin') { throw '서버 공유 변경에는 이 배포의 사람 시스템 관리자 인증이 필요합니다.' }
        if ($previous -cne $requested) {
            Set-HermesAdminComposeFiles $State
            if (Test-HermesAdminNetworkTransition $State) { throw '이전 서버 공유 전환 복구를 먼저 완료하세요.' }
            $State | Add-Member NetworkAddress $requested -Force
            $State | Add-Member NetworkTransition ([pscustomobject]@{ Previous = $previous; Requested = $requested }) -Force
            Write-HermesAdminJSON (Join-Path $State.Directory 'deployment.json') $State
            $changed = $true
            Set-HermesAdminComposeFiles $State
            $null = Invoke-HermesAdminCompose $State @('up','-d','mattermost')
            Wait-HermesAdminServer $BaseURL
        }
        Test-HermesAdminSharedEndpoint $State
        $config = (Invoke-HermesAdminAPI -BaseURL $BaseURL -Path '/api/v4/config' -Token $token).Data
        if ($config.ServiceSettings.SiteURL -cne (Get-HermesAdminServerURL $State)) { throw '실제 SiteURL이 요청한 공유 주소와 다릅니다.' }
        Assert-HermesAdminPort $State -Exact
        if ($changed) { $State.NetworkTransition = $null; Write-HermesAdminJSON (Join-Path $State.Directory 'deployment.json') $State }
    } catch {
        if ($changed) {
            try {
                $State.NetworkAddress = $previous
                Write-HermesAdminJSON (Join-Path $State.Directory 'deployment.json') $State
                Set-HermesAdminComposeFiles $State
                $null = Invoke-HermesAdminCompose $State @('up','-d','mattermost')
                Wait-HermesAdminServer $BaseURL
                Assert-HermesAdminPort $State -Exact
                $State.NetworkTransition = $null
                Write-HermesAdminJSON (Join-Path $State.Directory 'deployment.json') $State
            } catch { throw '공유 설정과 이전 설정 복구를 완료하지 못했습니다. 데이터는 보존됩니다. NetBird·Docker를 복구하고 같은 서버를 이어서 설정하세요.' }
            throw '공유 주소 전환 검증에 실패하여 이전 공개 범위로 되돌렸습니다. NetBird·Docker·방화벽을 확인하고 재시도하세요.'
        }
        throw
    } finally { if ($token) { try { $null = Invoke-HermesAdminAPI -BaseURL $BaseURL -Path '/api/v4/users/logout' -Method POST -Token $token } catch { } } }
}
