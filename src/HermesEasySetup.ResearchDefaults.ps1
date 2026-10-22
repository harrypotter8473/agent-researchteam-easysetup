Set-StrictMode -Version 2.0

# Visible, editable installation proposals for the research team — no hidden grants.
$script:ResearchOptionRanges = @{
    ReviewerSlots = @(1, 3); TaskTimeoutMinutes = @(30, 720); GatewayPort = @(1024, 65535)
}

function New-HermesResearchWizardOptions {
    param([string]$WorkspacePath, [string]$HumanUsername = 'researcher')
    if ([string]::IsNullOrWhiteSpace($WorkspacePath)) {
        $WorkspacePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Hermes Research Workspace'
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 2; WorkspacePath = $WorkspacePath; HumanUsername = $HumanUsername
        ReviewerSlots = 1; TaskTimeoutMinutes = 180; GatewayPort = 18400
        AllowModelEgress = $false; AllowPublicWeb = $false; MigrationConsent = $false
    }
}

function Assert-HermesResearchWizardOptions {
    param([Parameter(Mandatory = $true)]$Options, [Parameter(Mandatory = $true)][string]$RuntimeRoot)
    # Normalize dictionaries and PSCustomObject consistently for PS 5.1 callers.
    $value = ($Options | ConvertTo-Json -Depth 6) | ConvertFrom-Json
    Assert-HermesResearchFields $value @('SchemaVersion','WorkspacePath','HumanUsername','ReviewerSlots','TaskTimeoutMinutes','GatewayPort','AllowModelEgress','AllowPublicWeb','MigrationConsent') @() '설치 선택'
    if ($value.SchemaVersion -ne 2) { throw 'ResearchWizardOptionsSchemaRejected' }
    if ($value.HumanUsername -isnot [string] -or $value.HumanUsername -cnotmatch '^[a-z0-9][a-z0-9._-]{1,63}$') { throw '연구를 요청할 실제 Mattermost 사용자 이름을 입력하세요. 표시 이름이나 봇 이름은 사용할 수 없습니다.' }
    if ($value.WorkspacePath -isnot [string] -or $value.WorkspacePath -cnotmatch '^[A-Za-z]:[\\/]' -or $value.WorkspacePath -match '[\x00-\x1f]') { throw '작업 폴더는 이 PC의 절대 경로로 선택하세요.' }
    $workspace = [IO.Path]::GetFullPath($value.WorkspacePath).TrimEnd('\','/')
    $runtime = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\','/')
    if ($workspace.Length -le 3 -or $workspace -ieq $runtime -or $workspace.StartsWith($runtime + '\',[StringComparison]::OrdinalIgnoreCase) -or $runtime.StartsWith($workspace + '\',[StringComparison]::OrdinalIgnoreCase)) { throw '작업 폴더는 드라이브 전체나 Hermes 설치·운영 폴더가 아닌 별도 연구 폴더로 선택하세요.' }
    if (-not (Test-HermesSafeTargetPath -LiteralPath $workspace).Safe) { throw 'ResearchWorkspacePathRejected' }
    if ((Test-Path -LiteralPath $workspace) -and -not (Test-Path -LiteralPath $workspace -PathType Container)) { throw '작업 폴더는 폴더여야 합니다.' }
    $value.WorkspacePath = $workspace
    foreach ($key in $script:ResearchOptionRanges.Keys) {
        $amount = $value.$key; $range = $script:ResearchOptionRanges[$key]
        if (($amount -isnot [int] -and $amount -isnot [long]) -or $amount -lt $range[0] -or $amount -gt $range[1]) {
            throw ('{0}: {1}~{2} 사이의 정수로 입력하세요.' -f @{ ReviewerSlots = '동시 심사 수'; TaskTimeoutMinutes = '작업 시간 한도(분)'; GatewayPort = '모델 라우터 포트' }[$key], $range[0], $range[1])
        }
    }
    foreach ($flag in @('AllowModelEgress','AllowPublicWeb','MigrationConsent')) {
        if ($value.$flag -isnot [bool]) { throw 'ResearchWizardConsentTypeRejected' }
    }
    if (-not $value.AllowModelEgress) { throw '선택한 모델 제공자(또는 로컬 모델)에 작업·논문 내용을 보내는 선택을 확인하세요.' }
    if (-not $value.AllowPublicWeb) { throw '문헌 조사에 필요한 공개 웹 검색·원문 읽기 선택을 확인하세요.' }
    return $value
}
