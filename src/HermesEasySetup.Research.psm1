Set-StrictMode -Version 2.0

# Four complete personas; lead coordinates independent scout, worker and reviewer runners.
$script:ResearchTeamSchemaVersion = 2
$script:ResearchTeamRoles = @(
    [pscustomobject][ordered]@{ ProfileName = 'research-lead'; DisplayName = '총괄'; Runner = $false; Blind = $false
        Summary = '사용자와 대화하고 범위를 정하며 작업 보드에 일을 배정하고 단계별 확인 지점을 지킵니다. 원고를 쓰거나 심사하지 않습니다.' }
    [pscustomobject][ordered]@{ ProfileName = 'research-scout'; DisplayName = '조사'; Runner = $true; Blind = $false
        Summary = '선행 연구·문헌 조사와 보고서 초안을 실제로 읽은 출처로 작성하고, 원고의 인용을 검증합니다.' }
    [pscustomobject][ordered]@{ ProfileName = 'research-worker'; DisplayName = '분석·실험'; Runner = $true; Blind = $false
        Summary = '자료 분석·실험·집필·수정을 담당하며 수치와 산출물을 근거 파일에 연결합니다.' }
    [pscustomobject][ordered]@{ ProfileName = 'research-reviewer'; DisplayName = '감사·심사'; Runner = $true; Blind = $true
        Summary = '요구 충족·출처·방법·수치·일관성을 독립 블라인드 감사합니다. 원본 수정 없이 검증 기록만 작성합니다.' }
)
$script:ResearchTeamProfiles = @($script:ResearchTeamRoles | ForEach-Object { $_.ProfileName })
$script:ResearchModelModes = @('Gateway', 'Codex')

function Assert-HermesResearchFields {
    param($Value, [string[]]$Required, [string[]]$Optional = @(), [string]$Label)
    if ($Value -is [System.Collections.IDictionary]) { $names = @($Value.Keys) }
    elseif ($Value -is [System.Management.Automation.PSCustomObject]) { $names = @($Value.PSObject.Properties.Name) }
    else { throw "$Label 형식이 올바르지 않습니다." }
    foreach ($name in $names) {
        if ($name -isnot [string] -or ($Required + $Optional) -cnotcontains $name) { throw "$Label 허용 필드 외 값은 저장하거나 처리할 수 없습니다." }
    }
    foreach ($name in $Required) { if ($names -cnotcontains $name) { throw "$Label 필수 필드가 없습니다." } }
}

function Assert-HermesResearchText {
    param($Value, [int]$MaximumLength, [string]$Label)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt $MaximumLength) {
        throw "$Label 문자열이 비어 있거나 허용 길이를 벗어났습니다."
    }
    if ($Value -match '[\x00-\x1F\x7F]') { throw "$Label 허용되지 않은 제어 문자가 있습니다." }
}

function Get-HermesResearchTeamDefinition {
    [CmdletBinding()]
    param()
    return @($script:ResearchTeamRoles | ForEach-Object { [pscustomobject][ordered]@{
        ProfileName = $_.ProfileName; DisplayName = $_.DisplayName; Summary = $_.Summary; Runner = $_.Runner; Blind = $_.Blind } })
}

function New-HermesResearchDefaultAgents {
    [CmdletBinding()]
    param()
    foreach ($role in $script:ResearchTeamRoles) {
        [pscustomobject][ordered]@{ ProfileName = $role.ProfileName; DisplayName = $role.DisplayName; BotToken = '' }
    }
}

function Get-HermesResearchTeamSourceRoot {
    return [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $PSScriptRoot) 'team'))
}

function Get-HermesResearchTeamPayload {
    <# Every file of team/ checked against team/manifest.json before anything is installed. #>
    [CmdletBinding()]
    param([string]$SourceRoot = (Get-HermesResearchTeamSourceRoot))
    $root = [IO.Path]::GetFullPath($SourceRoot)
    $manifestPath = Join-Path $root 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw '연구팀 구성 파일 목록(team/manifest.json)이 없습니다. 배포 ZIP 전체를 다시 압축 해제하세요.' }
    try { $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { throw '연구팀 구성 파일 목록을 읽을 수 없습니다.' }
    if ($manifest.schema -ne 1 -or $null -eq $manifest.files) { throw '연구팀 구성 파일 목록 형식이 올바르지 않습니다.' }
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($manifest.files.PSObject.Properties)) {
        $relative = [string]$entry.Name
        if ($relative -cnotmatch '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' -or $relative -match '(^|/)\.\.(/|$)') { throw 'ResearchPayloadPathRejected' }
        $path = [IO.Path]::GetFullPath((Join-Path $root ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)))
        if (-not (Test-HermesPathContains -ParentPath $root -ChildPath $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "연구팀 구성 파일이 없습니다: $relative — 배포 ZIP 전체를 다시 압축 해제하세요."
        }
        if ((ConvertTo-HermesSha256 -LiteralPath $path).ToLowerInvariant() -cne ([string]$entry.Value).ToLowerInvariant()) {
            throw "연구팀 구성 파일이 배포본과 다릅니다: $relative"
        }
        $files.Add([pscustomobject]@{ Relative = $relative; Path = $path; Sha256 = ([string]$entry.Value).ToLowerInvariant() })
    }
    foreach ($required in @('shared/research_board.py', 'shared/team_service.py', 'shared/merge_config.py', 'shared/report_docx.py',
        'shared/team.hermes.md', 'shared/team_selftest.py', 'gateway/research_gateway_policy.py', 'gateway/research_gateway_litellm.py',
        'gateway/routing.yaml', 'gateway/hermes.overlay.yaml', 'template/CLAUDE.md', 'reports-template/CLAUDE.md')) {
        if (@($files | Where-Object { $_.Relative -ceq $required }).Count -ne 1) { throw "연구팀 구성에 필수 파일이 없습니다: $required" }
    }
    foreach ($profile in $script:ResearchTeamProfiles) {
        foreach ($required in @("$profile/SOUL.md", "$profile/config.overlay.yaml")) {
            if (@($files | Where-Object { $_.Relative -ceq $required }).Count -ne 1) { throw "연구팀 구성에 필수 파일이 없습니다: $required" }
        }
    }
    return [pscustomobject]@{ Root = $root; Files = $files.ToArray(); ManifestSha256 = (ConvertTo-HermesSha256 -LiteralPath $manifestPath).ToLowerInvariant() }
}

function ConvertTo-HermesResearchServerURL {
    param($Value)
    Assert-HermesResearchText $Value 2048 '서버 주소'
    $uri = $null
    if ($Value -match '\s' -or -not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        @('http', 'https') -cnotcontains $uri.Scheme -or [string]::IsNullOrWhiteSpace($uri.Host) -or
        $uri.Port -lt 1 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne '/') {
        throw '서버 주소에는 인증정보·쿼리·fragment·하위 경로가 없는 HTTP(S) 기본 주소를 입력하세요.'
    }
    $ip = $null
    $loopback = ($uri.DnsSafeHost -ieq 'localhost')
    if ([Net.IPAddress]::TryParse($uri.DnsSafeHost.Trim('[', ']'), [ref]$ip)) { $loopback = [Net.IPAddress]::IsLoopback($ip) }
    if ($uri.Scheme -ceq 'http' -and -not $loopback) { throw 'HTTP는 loopback 주소에서만 허용합니다. 원격 서버에는 HTTPS를 사용하세요.' }
    return $uri.GetLeftPart([UriPartial]::Authority)
}

function ConvertTo-HermesResearchModelURL {
    <# An OpenAI-compatible base URL for a local model server (vLLM, Ollama, LM Studio). #>
    param($Value)
    Assert-HermesResearchText $Value 2048 '로컬 모델 주소'
    $uri = $null
    if ($Value -match '\s' -or -not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        @('http', 'https') -cnotcontains $uri.Scheme -or [string]::IsNullOrWhiteSpace($uri.Host) -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw '로컬 모델 주소는 인증정보·쿼리가 없는 http(s)://호스트:포트/v1 형식이어야 합니다.'
    }
    return $Value.TrimEnd('/')
}

function Assert-HermesResearchSecret {
    param($Value, [string]$Label)
    if ($Value -isnot [string] -or $Value.Length -lt 20 -or $Value.Length -gt 400 -or $Value -match '[\s\x00-\x1F\x7F"''`$]') {
        throw "$Label 형식이 올바르지 않습니다. 공백 없이 복사한 키 전체를 입력하세요."
    }
}

function Assert-HermesResearchModelInput {
    <# -> the model choice without secrets (for state files and logs). #>
    param([Parameter(Mandatory = $true)]$Model)
    Assert-HermesResearchFields $Model @('Mode') @('CodexModel', 'AnthropicKey', 'OpenAIKey', 'LocalBaseURL', 'LocalModel', 'LocalFastModel') '모델 선택'
    if ($Model.Mode -isnot [string] -or $script:ResearchModelModes -cnotcontains $Model.Mode) { throw '모델 연결 방식을 선택하세요.' }
    $get = { param($name) if ($Model -is [Collections.IDictionary]) { $Model[$name] } elseif ($Model.PSObject.Properties[$name]) { $Model.$name } else { $null } }
    $summary = [ordered]@{ Mode = [string]$Model.Mode; CodexModel = $null; Cloud = @(); LocalBaseURL = $null; LocalModel = $null; LocalFastModel = $null }
    if ($Model.Mode -ceq 'Codex') {
        $name = & $get 'CodexModel'
        Assert-HermesResearchText $name 128 'Codex 모델 이름'
        if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$') { throw 'Codex 모델 이름 형식이 올바르지 않습니다.' }
        foreach ($key in @('AnthropicKey', 'OpenAIKey', 'LocalBaseURL')) { if (& $get $key) { throw 'Codex 직접 연결에서는 API 키·로컬 모델을 입력하지 않습니다. 라우터 연결을 선택하세요.' } }
        $summary.CodexModel = $name
        return [pscustomobject]$summary
    }
    $anthropic = & $get 'AnthropicKey'; $openai = & $get 'OpenAIKey'; $local = & $get 'LocalBaseURL'
    if ($anthropic) { Assert-HermesResearchSecret $anthropic 'Anthropic API 키'; $summary.Cloud += 'anthropic' }
    if ($openai) { Assert-HermesResearchSecret $openai 'OpenAI API 키'; $summary.Cloud += 'openai' }
    if ($local) {
        $summary.LocalBaseURL = ConvertTo-HermesResearchModelURL $local
        foreach ($key in @('LocalModel', 'LocalFastModel')) {
            $value = & $get $key
            if ($key -ceq 'LocalFastModel' -and -not $value) { $value = & $get 'LocalModel' }
            Assert-HermesResearchText $value 200 '로컬 모델 이름'
            if ($value -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$') { throw '로컬 모델 이름 형식이 올바르지 않습니다.' }
            $summary[$key] = $value
        }
    } elseif ((& $get 'LocalModel') -or (& $get 'LocalFastModel')) { throw '로컬 모델 이름을 쓰려면 로컬 모델 주소도 입력하세요.' }
    if ($summary.Cloud.Count -eq 0 -and -not $summary.LocalBaseURL) { throw '라우터에는 Anthropic·OpenAI API 키 중 하나 이상 또는 로컬 모델이 필요합니다.' }
    return [pscustomobject]$summary
}

function Assert-HermesResearchTeamInput {
    <# -> the validated input without secrets. Tokens and keys stay in the caller's object. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$InputObject)
    Assert-HermesResearchFields $InputObject @('SchemaVersion', 'ServerURL', 'HomeChannelID', 'Agents', 'Model') @('WizardOptions') '연구 팀 입력'
    if (($InputObject.SchemaVersion -isnot [int] -and $InputObject.SchemaVersion -isnot [long]) -or $InputObject.SchemaVersion -ne $script:ResearchTeamSchemaVersion) {
        throw '연구 팀 입력 형식 버전이 이 마법사와 다릅니다.'
    }
    $server = ConvertTo-HermesResearchServerURL $InputObject.ServerURL
    if ($InputObject.HomeChannelID -isnot [string] -or $InputObject.HomeChannelID -cnotmatch '^[a-z0-9]{26}$') { throw 'Home Channel ID는 소문자·숫자 26자리여야 합니다.' }
    $model = Assert-HermesResearchModelInput $InputObject.Model
    $agentList = @($InputObject.Agents)
    if ($agentList.Count -ne $script:ResearchTeamProfiles.Count) { throw '연구 팀은 정확히 네 에이전트여야 합니다.' }
    $seenProfiles = @(); $seenNames = @(); $seenTokens = @()
    $agents = New-Object System.Collections.Generic.List[object]
    foreach ($agent in $agentList) {
        Assert-HermesResearchFields $agent @('ProfileName', 'DisplayName', 'BotToken') -Label '에이전트'
        if ($agent.ProfileName -isnot [string] -or $script:ResearchTeamProfiles -cnotcontains $agent.ProfileName -or $seenProfiles -ccontains $agent.ProfileName) {
            throw '네 연구 프로필을 중복 없이 사용하세요.'
        }
        Assert-HermesResearchText $agent.DisplayName 200 '에이전트 표시명'
        $name = $agent.DisplayName.Trim()
        if ($seenNames -contains $name) { throw '에이전트 표시명은 서로 달라야 합니다.' }
        if ($agent.BotToken -isnot [string] -or $agent.BotToken -cnotmatch '^[a-z0-9]{26}$' -or $seenTokens -ccontains $agent.BotToken) {
            throw '에이전트마다 서로 다른 소문자·숫자 26자리 봇 토큰이 필요합니다.'
        }
        $seenProfiles += $agent.ProfileName; $seenNames += $name; $seenTokens += $agent.BotToken
        $agents.Add([pscustomobject][ordered]@{ ProfileName = $agent.ProfileName; DisplayName = $name })
    }
    $ordered = @(foreach ($profile in $script:ResearchTeamProfiles) { $agents | Where-Object { $_.ProfileName -ceq $profile } })
    return [pscustomobject][ordered]@{
        SchemaVersion = $script:ResearchTeamSchemaVersion; ServerURL = $server; HomeChannelID = $InputObject.HomeChannelID
        Model = $model; Agents = $ordered
    }
}

Export-ModuleMember -Function @(
    'Get-HermesResearchTeamDefinition', 'New-HermesResearchDefaultAgents', 'Get-HermesResearchTeamSourceRoot',
    'Get-HermesResearchTeamPayload', 'Assert-HermesResearchModelInput', 'Assert-HermesResearchTeamInput',
    'Assert-HermesResearchFields', 'Assert-HermesResearchText'
)
