[CmdletBinding()]
param([switch]$SmokeTest,[string]$PreviewPath,[ValidateSet('Server','Hermes','Team')][string]$PreviewStep = 'Team')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Start-HermesResearchSetup.cmd로 실행하세요.' }
Import-Module (Join-Path $PSScriptRoot 'src\HermesEasySetup.Loader.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$reader = New-Object Xml.XmlNodeReader ([xml][IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ui\ResearchWindow.xaml')))
try { $window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
$ui = @{}
foreach ($name in @(
    'WizardTabs','ServerTab','HermesTab','TeamTab','DockerCheckButton','DockerOpenButton','DockerStatus',
    'DockerPrerequisites','DockerAlternatives','DockerInstallConsent','DockerInstallButton','DockerGuideButton',
    'ServerRestoreButton','ServerId','ServerPort','AdminUsername','AdminEmail','AdminPassword','PasswordConfirm',
    'ServerResumeCheck','ServerConsent','ServerCreateButton','ServerOpenButton','ServerNextButton','ServerStatus',
    'HermesPlanButton','HermesStatusButton','HermesPlanText','HermesConsent','HermesInstallButton',
    'UseExistingHermesCheck','ExistingHermesHome','ExistingHermesInstallDir','ExistingHermesStatus',
    'AuthButton','AuthOpenButton','AuthStatus','AuthCode','ModelCombo','HermesNextButton',
    'TeamServerURL','HomeChannelID','TeamAdminPassword','AgentRows','TeamQuickActions','TeamAdvancedSettings','QuickSetupSummary',
    'ModelModeGateway','ModelModeCodex','GatewayPanel','AnthropicKey','OpenAIKey','LocalBaseURL','LocalModel','GatewayPort',
    'WorkspacePath','WorkspaceBrowseButton','HumanUsername','TaskTimeoutMinutes','ReviewerSlots','SelectedModelSummary','ModelEgressConsent','PublicWebConsent','MigrationConsent',
    'TeamResumeCheck','TeamConsent','TeamApplyButton','TeamOpenButton','TeamBoardButton','TeamPluginsButton','TeamResult','Progress','Log','CloseButton'
)) {
    $ui[$name] = $window.FindName($name)
    if ($null -eq $ui[$name]) { throw "필수 연구실 컨트롤이 없습니다: $name" }
}
$script:paths = Get-HermesDefaultPaths
$script:defaultPaths = $script:paths
$script:useExistingHermes = $false
$ui.ExistingHermesHome.Text = $script:paths.HermesHome
$ui.ExistingHermesInstallDir.Text = $script:paths.InstallDir
$script:teamDefinition = @(Get-HermesResearchTeamDefinition)
foreach ($slots in 1..3) { [void]$ui.ReviewerSlots.Items.Add([string]$slots) }
$script:teamInputsEdited = $false
$script:restoringTeam = $false
$script:lastLoadedTeamKey = $null
$script:agents = @()
$script:busy = $false
$script:dockerReady = $false
$script:dockerCanInstall = $false
$script:dockerCanOpen = $false
$script:dockerRebootRequired = $false
$script:initialDockerCheck = $false
$script:serverReady = $false
$script:serverIdentity = $null
$script:serverURL = $null
$script:channelURL = $null
$script:hermesReady = $false
$script:authenticated = $false
$script:plan = $null
$script:authURL = $null
$script:worker = $null
$script:workerAction = ''
$script:workerResult = $null
$script:workerFailed = $false
$script:workerEOF = $false
$script:pendingLine = $null
$script:stderr = $null
$script:inputPath = $null
$script:botIndex = -1
$script:autoSetup = $false
$script:autoReady = $false
$script:preferredModel = $null

function Add-ResearchLog {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    $ui.Log.AppendText((Protect-HermesLogText $Message) + [Environment]::NewLine)
    if ($ui.Log.Text.Length -gt 24000) { $ui.Log.Text = $ui.Log.Text.Substring($ui.Log.Text.Length - 18000) }
    $ui.Log.ScrollToEnd()
}

function Refresh-ResearchButtons {
    $idle = -not $script:busy
    $ui.CloseButton.IsEnabled = $idle
    $ui.TeamPluginsButton.IsEnabled = $idle -and (Test-Path -LiteralPath (Join-Path $script:paths.RuntimeRoot 'research\team.json') -PathType Leaf)
    foreach ($name in @('DockerCheckButton','DockerGuideButton','ServerRestoreButton','ServerId','ServerPort',
        'AdminUsername','AdminEmail','AdminPassword','PasswordConfirm','ServerResumeCheck','ServerConsent',
        'HermesConsent','UseExistingHermesCheck','TeamAdminPassword','TeamResumeCheck','TeamConsent',
        'ModelModeGateway','ModelModeCodex','WorkspacePath','WorkspaceBrowseButton','HumanUsername','TaskTimeoutMinutes','ReviewerSlots',
        'ModelEgressConsent','PublicWebConsent','MigrationConsent')) {
        $ui[$name].IsEnabled = $idle
    }
    $gatewayMode = ($ui.ModelModeGateway.IsChecked -eq $true)
    foreach ($name in @('AnthropicKey','OpenAIKey','LocalBaseURL','LocalModel','GatewayPort')) { $ui[$name].IsEnabled = $idle -and $gatewayMode }
    $ui.DockerOpenButton.IsEnabled = $idle -and $script:dockerCanOpen
    $ui.DockerInstallConsent.IsEnabled = $idle -and $script:dockerCanInstall
    $ui.DockerInstallButton.IsEnabled = $idle -and $script:dockerCanInstall -and $ui.DockerInstallConsent.IsChecked -eq $true
    $ui.ServerCreateButton.IsEnabled = $idle -and $script:dockerReady -and $ui.ServerConsent.IsChecked -eq $true
    $ui.ServerOpenButton.IsEnabled = $idle -and $script:serverReady
    $ui.ServerNextButton.IsEnabled = $ui.ServerOpenButton.IsEnabled
    $ui.HermesTab.IsEnabled = $script:serverReady
    $ui.ExistingHermesHome.IsEnabled = $idle -and $script:useExistingHermes
    $ui.ExistingHermesInstallDir.IsEnabled = $idle -and $script:useExistingHermes
    $ui.HermesPlanButton.IsEnabled = $idle -and $script:serverReady -and -not $script:useExistingHermes
    $ui.HermesStatusButton.IsEnabled = $idle -and $script:serverReady
    $ui.HermesConsent.IsEnabled = $idle -and -not $script:useExistingHermes
    $ui.HermesInstallButton.IsEnabled = $idle -and -not $script:useExistingHermes -and $null -ne $script:plan -and $ui.HermesConsent.IsChecked -eq $true
    $ui.AuthButton.IsEnabled = $idle -and $script:hermesReady -and -not $script:useExistingHermes
    foreach ($name in @('HermesPlanText','HermesConsent','HermesInstallButton','AuthButton','AuthOpenButton','AuthCode')) {
        $ui[$name].Visibility = $(if ($script:useExistingHermes) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible })
    }
    $ui.AuthOpenButton.IsEnabled = $null -ne $script:authURL
    $ui.ModelCombo.IsEnabled = $idle -and $script:authenticated
    $ui.HermesNextButton.IsEnabled = $idle -and $script:hermesReady
    $ui.TeamTab.IsEnabled = $script:serverReady -and $script:hermesReady
    $modelReady = $gatewayMode -or ($script:authenticated -and $null -ne $ui.ModelCombo.SelectedItem)
    $ui.TeamApplyButton.IsEnabled = $idle -and $ui.TeamTab.IsEnabled -and $modelReady -and $ui.TeamConsent.IsChecked -eq $true -and $ui.ModelEgressConsent.IsChecked -eq $true -and $ui.PublicWebConsent.IsChecked -eq $true
    $ui.SelectedModelSummary.Text = $(if ($null -ne $ui.ModelCombo.SelectedItem -and $script:authenticated) { 'Codex 모델: ' + [string]$ui.ModelCombo.SelectedItem + ' (네 역할 공통)' } else { 'Codex 모델: 2단계에서 로그인하면 선택할 수 있습니다.' })
    $quickModel = $(if ($gatewayMode) { '선택한 모델 라우터' } else { $ui.SelectedModelSummary.Text })
    $ui.QuickSetupSummary.Text = ('총괄·조사·분석/집필·감사 3+1 | {0}{1}작업 폴더: {2}{1}시간 한도 {3}분/작업 · 작업 시도 50 · 모델 오류 재시도 100 · 심사자 {4}명' -f $quickModel,[Environment]::NewLine,$ui.WorkspacePath.Text,$ui.TaskTimeoutMinutes.Text,[string]$ui.ReviewerSlots.SelectedItem)
    $ui.TeamOpenButton.IsEnabled = $idle -and $script:serverReady
    foreach ($agent in $script:agents) {
        $agent.Name.IsEnabled = $idle
        $agent.Token.IsEnabled = $idle
        $agent.Issue.IsEnabled = $idle -and $script:serverReady -and $script:dockerReady
    }
}

function Set-ResearchWizardOptions {
    param($Options)
    $ui.WorkspacePath.Text = [string]$Options.WorkspacePath
    $ui.HumanUsername.Text = [string]$Options.HumanUsername
    $ui.TaskTimeoutMinutes.Text = [string]$Options.TaskTimeoutMinutes
    $ui.ReviewerSlots.SelectedItem = [string]$Options.ReviewerSlots
    $ui.GatewayPort.Text = [string]$Options.GatewayPort
    # Saved installation consent is not consent for a new installation/test.
    $ui.ModelEgressConsent.IsChecked = $false; $ui.PublicWebConsent.IsChecked = $false; $ui.MigrationConsent.IsChecked = $false
}

function Get-ResearchWizardOptions {
    $options = New-HermesResearchWizardOptions -WorkspacePath $ui.WorkspacePath.Text.Trim() -HumanUsername $ui.HumanUsername.Text.Trim()
    $options.AllowModelEgress = $ui.ModelEgressConsent.IsChecked -eq $true
    $options.AllowPublicWeb = $ui.PublicWebConsent.IsChecked -eq $true
    $options.MigrationConsent = $ui.MigrationConsent.IsChecked -eq $true
    foreach ($pair in @(@('TaskTimeoutMinutes', $ui.TaskTimeoutMinutes.Text), @('ReviewerSlots', [string]$ui.ReviewerSlots.SelectedItem), @('GatewayPort', $ui.GatewayPort.Text))) {
        $amount = 0
        if (-not [int]::TryParse(([string]$pair[1]).Trim(), [ref]$amount)) { throw ($pair[0] + ': 정수를 입력하세요.') }
        $options.($pair[0]) = $amount
    }
    return (Assert-HermesResearchWizardOptions -Options $options -RuntimeRoot $script:paths.RuntimeRoot)
}

function Get-ResearchModelInput {
    if ($ui.ModelModeCodex.IsChecked -eq $true) {
        if ($null -eq $ui.ModelCombo.SelectedItem) { throw 'Codex 직접 연결에는 2단계의 로그인과 모델 선택이 필요합니다.' }
        return [pscustomobject]@{ Mode = 'Codex'; CodexModel = [string]$ui.ModelCombo.SelectedItem }
    }
    $model = [ordered]@{ Mode = 'Gateway' }
    if ($ui.AnthropicKey.Password) { $model.AnthropicKey = $ui.AnthropicKey.Password.Trim() }
    if ($ui.OpenAIKey.Password) { $model.OpenAIKey = $ui.OpenAIKey.Password.Trim() }
    if ($ui.LocalBaseURL.Text.Trim()) { $model.LocalBaseURL = $ui.LocalBaseURL.Text.Trim(); $model.LocalModel = $ui.LocalModel.Text.Trim() }
    $value = [pscustomobject]$model
    $null = Assert-HermesResearchModelInput $value
    return $value
}

function Test-ResearchWorkflowEvidence {
    param($Result)
    if ($null -eq $Result -or -not $Result.PSObject.Properties['ExecutionReady'] -or $Result.ExecutionReady -ne $true -or -not $Result.PSObject.Properties['WorkflowTest']) { return $false }
    $test = $Result.WorkflowTest
    if ($null -eq $test) { return $false }
    foreach ($key in @('Passed','Live','AuditPassed','Scenarios','RequestID','Roles','EvidencePath')) { if (-not $test.PSObject.Properties[$key]) { return $false } }
    if ((@($test.Scenarios | Sort-Object -Unique) -join ',') -cne 'S1,S2,S3') { return $false }
    if ($test.Passed -ne $true -or $test.Live -ne $true -or $test.AuditPassed -ne $true -or [string]::IsNullOrWhiteSpace([string]$test.RequestID) -or [string]::IsNullOrWhiteSpace([string]$test.EvidencePath)) { return $false }
    $roles = @($test.Roles | Sort-Object -Unique)
    return ($roles.Count -eq 4 -and ($roles -join ',') -ceq 'research-lead,research-reviewer,research-scout,research-worker')
}

function Add-ResearchAgentRows {
    $columns = @(170,150,0,0,105)
    foreach ($width in $columns) {
        $column = New-Object Windows.Controls.ColumnDefinition
        $column.Width = $(if ($width -eq 0) { New-Object Windows.GridLength(1,[Windows.GridUnitType]::Star) } else { New-Object Windows.GridLength($width) })
        [void]$ui.AgentRows.ColumnDefinitions.Add($column)
    }
    $header = New-Object Windows.Controls.RowDefinition
    $header.Height = [Windows.GridLength]::Auto
    [void]$ui.AgentRows.RowDefinitions.Add($header)
    $headers = @('프로필 (봇 사용자 이름)','표시 이름','봇 토큰','하는 일','토큰 발급')
    for ($columnIndex = 0; $columnIndex -lt $headers.Count; $columnIndex++) {
        $label = New-Object Windows.Controls.TextBlock
        $label.Text = $headers[$columnIndex]; $label.FontWeight = 'SemiBold'; $label.Margin = '0,0,8,8'
        [Windows.Controls.Grid]::SetColumn($label,$columnIndex)
        [void]$ui.AgentRows.Children.Add($label)
    }
    $defaults = @(New-HermesResearchDefaultAgents)
    for ($i = 0; $i -lt $defaults.Count; $i++) {
        $definition = @($script:teamDefinition | Where-Object { $_.ProfileName -ceq $defaults[$i].ProfileName })[0]
        $row = New-Object Windows.Controls.RowDefinition; $row.Height = [Windows.GridLength]::Auto
        [void]$ui.AgentRows.RowDefinitions.Add($row)
        $profile = New-Object Windows.Controls.TextBlock
        $profile.Text = [string]$defaults[$i].ProfileName; $profile.FontSize = 12; $profile.VerticalAlignment = 'Center'
        $name = New-Object Windows.Controls.TextBox; $name.Text = [string]$defaults[$i].DisplayName
        $token = New-Object Windows.Controls.PasswordBox
        $summary = New-Object Windows.Controls.TextBlock
        $summary.Text = [string]$definition.Summary; $summary.TextWrapping = 'Wrap'; $summary.FontSize = 12; $summary.Foreground = '#56657D'
        $issue = New-Object Windows.Controls.Button; $issue.Content = '봇 발급'; $issue.Tag = $i; $issue.VerticalAlignment = 'Top'
        $issue.Add_Click({ param($sender,$args) Start-ResearchBotIssuance -Index ([int]$sender.Tag) })
        [Windows.Automation.AutomationProperties]::SetName($name,('{0} 표시 이름' -f $defaults[$i].ProfileName))
        [Windows.Automation.AutomationProperties]::SetName($token,('{0} 봇 토큰' -f $defaults[$i].ProfileName))
        $controls = @($profile,$name,$token,$summary,$issue)
        for ($columnIndex = 0; $columnIndex -lt $controls.Count; $columnIndex++) {
            $control = $controls[$columnIndex]; $control.Margin = '0,0,8,10'
            [Windows.Controls.Grid]::SetRow($control,($i + 1)); [Windows.Controls.Grid]::SetColumn($control,$columnIndex)
            [void]$ui.AgentRows.Children.Add($control)
        }
        $script:agents += [pscustomobject]@{ ProfileName = [string]$defaults[$i].ProfileName; Name = $name; Token = $token; Issue = $issue }
    }
}

function Get-ResearchSavedTeam {
    param($State)
    $ownerSID = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($State.SchemaVersion -ne 2 -or $State.Manager -cne 'HermesEasySetup.ResearchTeam.v2' -or
        $State.OwnerSID -cne $ownerSID -or $State.TeamID -cnotmatch '^[a-f0-9]{32}$' -or
        $State.ServerURL -cne $script:serverURL -or $State.HomeChannelID -cne $ui.HomeChannelID.Text) { throw '저장된 연구팀 소유 정보가 현재 연구실과 일치하지 않습니다.' }
    foreach ($key in @('HermesHome','InstallDir','RuntimeRoot')) {
        if ([IO.Path]::GetFullPath([string]$State.$key) -ine [IO.Path]::GetFullPath([string]$script:paths.$key)) { throw '저장된 연구팀 경로가 현재 설정과 일치하지 않습니다.' }
    }
    $profiles = @($State.Profiles)
    $expected = @($script:teamDefinition | ForEach-Object { $_.ProfileName })
    if ($profiles.Count -ne $expected.Count -or @($profiles | Where-Object { $expected -cnotcontains $_.ProfileName }).Count -ne 0) { throw '저장된 연구팀의 프로필 구성이 다릅니다.' }
    # Saved consent is not consent for a new install: validate the rest with consent set, then clear it on the form.
    $saved = ($State.WizardOptions | ConvertTo-Json -Depth 6) | ConvertFrom-Json
    $saved.AllowModelEgress = $true; $saved.AllowPublicWeb = $true
    $options = Assert-HermesResearchWizardOptions -Options $saved -RuntimeRoot $script:paths.RuntimeRoot
    return [pscustomobject]@{ Profiles = $profiles; Options = $options; Model = $State.Model }
}

function Read-ResearchSavedTeam {
    param([switch]$OnlyIfUnedited)
    if ($OnlyIfUnedited -and $script:teamInputsEdited) { return }
    $path = Join-Path $script:paths.RuntimeRoot 'research\team.json'
    & (Get-Module HermesEasySetup.Admin) { param($value) Assert-HermesAdminPath $value } $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    if ((Get-Item -LiteralPath $path).Length -gt 262144) { throw '저장된 연구팀 기록의 크기가 올바르지 않습니다.' }
    $savedState = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($savedState.Manager -ceq 'HermesEasySetup.Research.v1') {
        Add-ResearchLog '이전 4역할 연구팀(분배 서비스)이 설치되어 있습니다. 새 네 역할 팀으로 바꾸려면 아래 「기존 연구팀 전환」에 동의하고 설치하세요. 기록은 보존됩니다.'
        return
    }
    $saved = Get-ResearchSavedTeam $savedState
    $key = $path + '|' + $script:paths.HermesHome + '|' + $script:paths.InstallDir + '|' + $savedState.TeamID
    if ($OnlyIfUnedited -and $script:lastLoadedTeamKey -ceq $key) { return }
    $tokens = @{}
    $botsPath = Join-Path $script:paths.RuntimeRoot 'research\private\bots.json'
    & (Get-Module HermesEasySetup.Admin) { param($value) Assert-HermesAdminPath $value } $botsPath
    if ((Test-Path -LiteralPath $botsPath -PathType Leaf) -and (Get-Item -LiteralPath $botsPath).Length -le 65536) {
        $bots = [IO.File]::ReadAllText($botsPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($profile in @($saved.Profiles)) {
            if ($bots.PSObject.Properties[[string]$profile.ProfileName]) {
                $token = [string]$bots.([string]$profile.ProfileName)
                if ($token -cmatch '^[a-z0-9]{26}$') { $tokens[[string]$profile.ProfileName] = $token }
            }
        }
    }
    $gatewayState = Get-HermesResearchGatewayState -RuntimeRoot $script:paths.RuntimeRoot
    # Commit to the form only after every saved value validates.
    $script:restoringTeam = $true
    try {
        Set-ResearchWizardOptions -Options $saved.Options
        foreach ($agent in $script:agents) {
            $profile = @($saved.Profiles | Where-Object ProfileName -CEQ $agent.ProfileName)[0]
            $agent.Name.Text = [string]$profile.DisplayName
            if ($tokens.ContainsKey([string]$agent.ProfileName)) { $agent.Token.Password = $tokens[[string]$agent.ProfileName] }
        }
        if ([string]$saved.Model.Mode -ceq 'Codex') {
            $ui.ModelModeCodex.IsChecked = $true
            $script:preferredModel = [string]$saved.Model.CodexModel
            if ($ui.ModelCombo.Items.Contains($script:preferredModel)) { $ui.ModelCombo.SelectedItem = $script:preferredModel }
        } else {
            $ui.ModelModeGateway.IsChecked = $true
            $ui.AnthropicKey.Password = [string]$gatewayState.AnthropicKey; $ui.OpenAIKey.Password = [string]$gatewayState.OpenAIKey
            $ui.LocalBaseURL.Text = [string]$saved.Model.LocalBaseURL; $ui.LocalModel.Text = [string]$saved.Model.LocalModel
        }
        $ui.TeamResumeCheck.IsChecked = $true; $script:lastLoadedTeamKey = $key
    } finally { $tokens.Clear(); $script:restoringTeam = $false }
    Add-ResearchLog '저장된 네 봇 연결·이름·모델·작업 설정을 불러왔습니다. 토큰과 키는 가려진 입력란에만 넣었으며 설치 시 다시 검증합니다.'
}

function Get-ResearchServerInput {
    param([AllowNull()][string]$AdminSecret)
    $identity = $script:serverIdentity
    $sameIdentity = ($null -ne $identity -and [string]$identity.ServerId -ceq $ui.ServerId.Text.Trim())
    $data = [pscustomobject]@{
        ServerId = $ui.ServerId.Text.Trim(); Port = $ui.ServerPort.Text.Trim()
        SiteName = $(if ($sameIdentity) { [string]$identity.SiteName } else { '1인 연구실' })
        TeamName = $(if ($sameIdentity) { [string]$identity.TeamName } else { 'research' })
        TeamDisplayName = $(if ($sameIdentity) { [string]$identity.TeamDisplayName } else { '개인 연구실' })
        ChannelName = $(if ($sameIdentity) { [string]$identity.ChannelName } else { 'agents' })
        AdminUsername = $ui.AdminUsername.Text.Trim(); AdminEmail = $ui.AdminEmail.Text.Trim()
        AdminPassword = $(if ($PSBoundParameters.ContainsKey('AdminSecret')) { $AdminSecret } else { $ui.AdminPassword.Password }); NetworkMode = 'Local'; NetworkAddress = ''
    }
    Assert-HermesAdminInput $data
    return $data
}

function Read-ResearchServerRecord {
    $serverId = $ui.ServerId.Text.Trim()
    if ($serverId -cnotmatch '^[a-z][a-z0-9-]{1,30}[a-z0-9]$') { throw '서버 ID를 확인하세요.' }
    $path = Join-Path (Get-HermesAdminRoot) ($serverId + '\deployment.json')
    & (Get-Module HermesEasySetup.Admin) { param($value) Assert-HermesAdminPath $value } $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw '저장된 연구 서버가 없습니다. 먼저 로컬 서버를 설치하세요.' }
    $state = [IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string]$state.Status -cne 'Ready' -or [string]$state.Identity.ServerId -cne $serverId -or
        [string]$state.ChannelId -cnotmatch '^[a-z0-9]{26}$' -or [string]$state.TeamId -cnotmatch '^[a-z0-9]{26}$') { throw '서버 완료 기록을 확인하지 못했습니다. 같은 서버를 이어서 설치하세요.' }
    if ($state.PSObject.Properties['NetworkAddress'] -and -not [string]::IsNullOrWhiteSpace([string]$state.NetworkAddress)) { throw '이 초기 연구실 마법사는 로컬 전용 서버를 사용합니다. 공유된 서버의 공개 범위와 소유 기록을 먼저 확인하세요. 이 화면에서 임의로 전환하지 않습니다.' }
    $port = 0
    if (-not [int]::TryParse([string]$state.Identity.Port,[ref]$port) -or $port -lt 1024 -or $port -gt 65535) { throw '저장된 서버 포트가 올바르지 않습니다.' }
    foreach ($key in @('TeamName','ChannelName')) { if ([string]$state.Identity.$key -cnotmatch '^[a-z][a-z0-9-]{1,30}[a-z0-9]$') { throw '저장된 팀·채널 주소가 올바르지 않습니다.' } }
    $ui.ServerPort.Text = [string]$port; $ui.AdminUsername.Text = [string]$state.Identity.AdminUsername; $ui.AdminEmail.Text = [string]$state.Identity.AdminEmail
    $script:serverIdentity = $state.Identity
    $script:serverURL = "http://127.0.0.1:$port"
    $script:channelURL = "$($script:serverURL)/$($state.Identity.TeamName)/channels/$($state.Identity.ChannelName)"
    $ui.TeamServerURL.Text = $script:serverURL; $ui.HomeChannelID.Text = [string]$state.ChannelId
    $wasRestoring = $script:restoringTeam
    $script:restoringTeam = $true
    try { $ui.HumanUsername.Text = [string]$state.Identity.AdminUsername } finally { $script:restoringTeam = $wasRestoring }
    $script:serverReady = $true; $ui.ServerResumeCheck.IsChecked = $true
    $ui.ServerStatus.Text = "연구실 주소: $($script:serverURL)`n팀·채널 준비 기록을 불러왔습니다. 연구팀 연결 시 각 봇과 채널 접근을 다시 확인합니다."
    try { Read-ResearchSavedTeam -OnlyIfUnedited } catch { Add-ResearchLog '기존 연구팀 배정을 불러오지 못했습니다. 같은 연구실·Windows 사용자·설치 경로인지 확인하세요. 기존 기록은 변경하지 않았습니다.' }
}

function Save-ResearchEncryptedInput {
    param($Value)
    $path = Join-Path $script:paths.RuntimeRoot ('ui-transport\research-' + [guid]::NewGuid().ToString('N') + '.bin')
    & (Get-Module HermesEasySetup.Admin) { param($value) Assert-HermesAdminPath $value } $path
    $script:inputPath = Protect-HermesLabInput -Value $Value -LiteralPath $path
    return $script:inputPath
}

function Start-ResearchWorker {
    param([string]$Action,[string[]]$ExtraArguments = @())
    if ($script:busy) { return }
    if ($script:useExistingHermes -and $Action -cin @('Plan','Install','CodexAuth')) { throw '기존 Hermes 사용 모드에서는 설치·업데이트·새 로그인을 실행하지 않습니다.' }
    if ($script:useExistingHermes -and $Action -cin @('CodexStatus','ResearchTeamSetup')) {
        if ([string]::IsNullOrWhiteSpace($ui.ExistingHermesHome.Text) -or [string]::IsNullOrWhiteSpace($ui.ExistingHermesInstallDir.Text)) { throw '기존 Hermes 데이터 폴더와 코드 폴더를 모두 확인하세요.' }
        $script:paths = Get-HermesDefaultPaths -HermesHome $ui.ExistingHermesHome.Text.Trim() -InstallDir $ui.ExistingHermesInstallDir.Text.Trim() -RuntimeRoot $script:defaultPaths.RuntimeRoot
        $ExtraArguments = @($ExtraArguments) + @('-UseExistingHermes')
    }
    $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'HermesEasySetup.ps1'),
        '-Action',$Action,'-JsonEvents','-HermesHome',$script:paths.HermesHome,'-InstallDir',$script:paths.InstallDir,'-RuntimeRoot',$script:paths.RuntimeRoot) + $ExtraArguments
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Get-HermesPowerShellExecutable
    $start.Arguments = (($arguments | ForEach-Object { ConvertTo-WindowsProcessArgument ([string]$_) }) -join ' ')
    $start.WorkingDirectory = $PSScriptRoot; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding $false
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding $false
    $process = New-Object Diagnostics.Process; $process.StartInfo = $start
    try { if (-not $process.Start()) { throw '작업 프로세스를 시작하지 못했습니다.' } } catch { $process.Dispose(); throw }
    $script:worker = $process; $script:workerAction = $Action; $script:workerResult = $null
    $script:workerFailed = $false; $script:workerEOF = $false; $script:busy = $true
    $script:stderr = $process.StandardError.ReadToEndAsync()
    $script:pendingLine = $process.StandardOutput.ReadLineAsync()
    $ui.Progress.Value = 0; Refresh-ResearchButtons; $timer.Start()
}

function Read-ResearchWorkerLine {
    param([string]$Line)
    if (-not $Line) { return }
    try { $event = $Line | ConvertFrom-Json } catch { return }
    if ($event.PSObject.Properties['type']) {
        if ([string]$event.type -ceq 'oauth') {
            if ([string]$event.data.URL -ceq 'https://auth.openai.com/codex/device' -and [string]$event.data.UserCode -cmatch '^[A-Z0-9][A-Z0-9-]{3,63}$') {
                $script:authURL = [string]$event.data.URL; $ui.AuthCode.Text = [string]$event.data.UserCode
                $ui.AuthStatus.Text = '인증 페이지를 열어 로그인하고 이 일회용 코드를 입력하세요.'; Refresh-ResearchButtons
            }
        } else {
            if ($event.PSObject.Properties['message']) { Add-ResearchLog ([string]$event.message) }
        }
        if ($event.PSObject.Properties['percent']) { $ui.Progress.Value = [math]::Min(100,[math]::Max(0,[double]$event.percent)) }
        if ([string]$event.type -ceq 'error') { $script:workerFailed = $true }
        if ([string]$event.type -ceq 'complete' -and $event.PSObject.Properties['data']) { $script:workerResult = $event.data }
    } elseif (@('AdminPreflight','DockerStatus','Plan','CodexStatus') -contains $script:workerAction) { $script:workerResult = $event }
}

function Set-ResearchDockerStatus {
    param($Status)
    if ($null -eq $Status -or $Status.Ready -isnot [bool] -or $Status.CanInstall -isnot [bool] -or $Status.CanOpen -isnot [bool]) { throw 'Docker 상태 응답을 확인하지 못했습니다.' }
    $rebootRequired = ($Status.PSObject.Properties['RebootRequired'] -and $Status.RebootRequired -eq $true)
    if ($rebootRequired) { $script:dockerRebootRequired = $true }
    $script:dockerReady = [bool]$Status.Ready -and -not $script:dockerRebootRequired
    $script:dockerCanInstall = [bool]$Status.CanInstall -and -not [bool]$Status.Installed
    $script:dockerCanOpen = [bool]$Status.CanOpen
    $ui.DockerStatus.Text = [string]$Status.Summary
    if ($script:dockerRebootRequired) { $ui.DockerStatus.Text += [Environment]::NewLine + '이번 설치에서 재부팅 필요를 확인했습니다. 직접 Windows를 재부팅한 뒤 마법사를 다시 실행하세요.' }
    $ui.DockerPrerequisites.Text = (@($Status.Prerequisites | ForEach-Object {
        $label = $(switch ([string]$_.State) { 'Pass' { '충족' } 'Fail' { '미충족' } default { '확인 필요' } })
        '[{0}] {1}: {2}' -f $label,$_.Name,$_.Message
    }) -join [Environment]::NewLine)
    if ($Status.PSObject.Properties['Alternatives'] -and $Status.Alternatives) { $ui.DockerAlternatives.Text = @($Status.Alternatives) -join [Environment]::NewLine }
    $ui.DockerInstallConsent.IsChecked = $false
    Refresh-ResearchButtons
}

function Set-ResearchAuthStatus {
    param($Status)
    $script:hermesReady = $true
    $script:authenticated = [bool]$Status.LoggedIn
    $ui.AuthStatus.Text = [string]$Status.Summary
    $previous = $(if ($script:preferredModel) { $script:preferredModel } else { [string]$ui.ModelCombo.SelectedItem })
    if (-not $previous -and $Status.PSObject.Properties['PreferredModel']) { $previous = [string]$Status.PreferredModel }
    if ($Status.PSObject.Properties['RuntimeKind'] -and $Status.RuntimeKind -ceq 'Existing') {
        $ui.ExistingHermesStatus.Text = "기존 설치 사용: $($Status.Version)`n코드: $($script:paths.InstallDir)`n데이터·인증·기존 프로필 유지 / 재설치 없음"
    }
    $ui.ModelCombo.Items.Clear()
    foreach ($model in @($Status.Models)) { [void]$ui.ModelCombo.Items.Add([string]$model) }
    if ($previous -and @($Status.Models) -contains $previous) { $ui.ModelCombo.SelectedItem = $previous }
    elseif ($ui.ModelCombo.Items.Count -gt 0) { $ui.ModelCombo.SelectedIndex = 0 }
}

function Complete-ResearchWorker {
    $timer.Stop()
    $process = $script:worker; $process.WaitForExit()
    $action = $script:workerAction; $result = $script:workerResult
    $success = ($process.ExitCode -eq 0 -and -not $script:workerFailed -and $null -ne $result)
    $process.Dispose(); $script:worker = $null; $script:pendingLine = $null; $script:stderr = $null
    $script:busy = $false
    if ($script:inputPath -and (Test-Path -LiteralPath $script:inputPath -PathType Leaf)) { Remove-Item -LiteralPath $script:inputPath -Force -ErrorAction SilentlyContinue }
    $script:inputPath = $null
    switch ($action) {
        { $_ -in @('DockerStatus','DockerInstall') } {
            if ($null -ne $result) {
                Set-ResearchDockerStatus $result
                if (-not $success) { $script:dockerReady = $false }
                if ($action -ceq 'DockerInstall') {
                    if ($result.RebootRequired) { Add-ResearchLog 'Docker 설치 후 Windows 재부팅이 필요합니다. 저장한 뒤 직접 재부팅하고 마법사를 다시 열어 준비 상태를 확인하세요.' }
                    elseif (-not $result.Ready -and $result.Installed) { Add-ResearchLog 'Docker 설치와 서버 준비는 별개입니다. Docker Desktop을 열어 약관·설정을 확인한 뒤 준비 상태를 다시 검사하세요.' }
                }
            } else {
                $script:dockerReady = $false; $script:dockerCanInstall = $false; $script:dockerCanOpen = $false
                $ui.DockerStatus.Text = 'Docker 확인·설치를 완료하지 못했습니다. 아래 안내를 확인하고 준비 상태를 다시 검사하세요.'
                $ui.DockerInstallConsent.IsChecked = $false
            }
        }
        'AdminPreflight' {
            $script:dockerReady = $success -and [bool]$result.Ready
            $ui.DockerStatus.Text = $(if ($script:dockerReady) { 'Docker Desktop / Linux 엔진 준비 완료' } else { 'Docker Desktop을 실행한 뒤 다시 확인하세요.' })
        }
        'AdminSetup' {
            if ($success -and [bool]$result.Ready) { Read-ResearchServerRecord; Add-ResearchLog '로컬 연구 서버가 준비되었습니다. 다음 단계에서 Hermes를 구성하세요.' }
            else { $script:serverReady = $false; $ui.ServerStatus.Text = '서버 설치를 완료하지 못했습니다. 오류 확인 후 같은 입력으로 이어서 설치하세요.'; $ui.ServerResumeCheck.IsChecked = $true }
        }
        'AdminBotSetup' {
            if ($success -and $script:botIndex -ge 0 -and $script:botIndex -lt $script:agents.Count) {
                $secret = Read-HermesAdminBotCredential $result
                try { $script:agents[$script:botIndex].Token.Password = [string]$secret.Token } finally { $secret = $null }
                Add-ResearchLog ('봇 토큰을 해당 행에 채웠습니다: ' + $script:agents[$script:botIndex].ProfileName)
            }
            if ($script:autoSetup) {
                if (-not $success -or $script:agents[$script:botIndex].Token.Password -cnotmatch '^[a-z0-9]{26}$') {
                    $script:autoSetup = $false; Add-ResearchLog '봇 자동 구성에서 멈췄습니다. 발급된 토큰은 보존했습니다. 같은 버튼으로 재시도하세요.'
                } elseif ($script:botIndex + 1 -lt $script:agents.Count) {
                    Start-ResearchBotIssuance ($script:botIndex + 1)
                } else {
                    $script:autoSetup = $false; $script:autoReady = $true
                    $ui.TeamApplyButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
                }
            }
        }
        'Plan' {
            $script:plan = $(if ($success) { $result } else { $null })
            if ($success) {
                $ui.HermesPlanText.Text = "릴리스: $($result.SourceTag)`ncommit: $($result.SourceCommit)`n코드: $($result.InstallDir)`n데이터: $($result.HermesHome)`n계획 지문: $($result.Fingerprint)`n기본 CLI 설치 · Computer Use/Desktop 자동 설치 건너뜀"
            }
        }
        'Install' {
            if ($success -and [bool]$result.Verified -and [bool]$result.Installed -and @($result.FailedChecks).Count -eq 0) {
                $script:hermesReady = $true
                Add-ResearchLog 'Hermes 설치 검증 완료. 모델 인증 상태를 확인합니다.'
                Start-ResearchWorker 'CodexStatus'
            }
        }
        { $_ -in @('CodexStatus','CodexAuth') } {
            if ($success) {
                Set-ResearchAuthStatus $result
                try { Read-ResearchSavedTeam -OnlyIfUnedited } catch { Add-ResearchLog '선택한 Hermes에서 기존 연구팀 연결을 복원하지 못했습니다. 입력 중인 값은 유지했습니다. 같은 연구실·설치 경로인지 확인하세요.' }
            }
            else { $script:authenticated = $false; $ui.AuthStatus.Text = 'Hermes 설치 또는 모델 인증 상태를 확인하지 못했습니다. 진행 안내를 확인하세요.' }
            $ui.AuthCode.Clear(); $script:authURL = $null
        }
        'ResearchPluginsSetup' {
            if ($success -and $null -ne $result -and $result.Ready) {
                Add-ResearchLog 'Mattermost 내부 작업보드·NST 브랜딩 적용 완료. 연구팀·검증 기록은 보존했습니다.'
                $ui.TeamResult.Text = 'Mattermost 왼쪽의 연구 작업보드를 여세요. 기존 창은 새로 고침하세요.' + [Environment]::NewLine + [string]$result.BoardURL
            }
        }
        'ResearchTeamSetup' {
            if ($null -ne $result) {
                $lines = @($result.Profiles | ForEach-Object { '{0} ({1}, 봇 @{2}): {3}' -f $_.DisplayName,$_.ProfileName,$_.BotUsername,$_.Status })
                if ($result.PSObject.Properties['WorkspacePath']) { $lines += ('작업 폴더: ' + [string]$result.WorkspacePath) }
                if ($result.PSObject.Properties['LocationsPath']) { $lines += ('저장 위치 안내: ' + [string]$result.LocationsPath) }
                if ($result.PSObject.Properties['Notes']) { foreach ($note in @($result.Notes)) { if ($note) { Add-ResearchLog ([string]$note) } } }
                $ui.TeamResult.Text = $lines -join [Environment]::NewLine
                $ui.TeamResumeCheck.IsChecked = $true
            }
            if ($success -and [bool]$result.Succeeded) {
                if (Test-ResearchWorkflowEvidence $result) {
                    $ui.TeamResult.Text = "사용 준비 완료 — 네 역할의 실제 작업·결과 전달·기록 확인`n" + $ui.TeamResult.Text + "`n검증 기록: " + [string]$result.WorkflowTest.EvidencePath
                    Add-ResearchLog ('설치 테스트를 통과했습니다. 연구 채널에서 @' + [string]$result.LeadUsername + ' 을(를) 멘션해 보고서나 논문 작업을 요청하세요. 테스트 폴더: ' + [string]$result.WorkflowTest.RequestID)
                } else {
                    $reason = $(if ($result.PSObject.Properties['PendingSettings']) { @($result.PendingSettings) -join ', ' } else { '네 역할의 실제 작업 증거가 확인되지 않음' })
                    if ($result.PSObject.Properties['WorkflowTest'] -and $null -ne $result.WorkflowTest -and $result.WorkflowTest.PSObject.Properties['ErrorCode']) { $reason += ' ' + [string]$result.WorkflowTest.ErrorCode }
                    $ui.TeamResult.Text = "사용 준비 미완료 — 연결·설정만으로 완료 처리하지 않습니다.`n" + $ui.TeamResult.Text
                    Add-ResearchLog ('실제 분업 테스트를 완료하지 못했습니다. 확인 후 같은 연구팀으로 다시 시도하세요. ' + $reason)
                }
            }
            else {
                $reason = ''
                if ($null -ne $result -and $result.PSObject.Properties['PendingSettings']) { $reason = @($result.PendingSettings) -join ', ' }
                if ($null -ne $result -and $result.PSObject.Properties['WorkflowTest'] -and $null -ne $result.WorkflowTest -and $result.WorkflowTest.PSObject.Properties['ErrorCode']) { $reason += ' ' + [string]$result.WorkflowTest.ErrorCode }
                $ui.TeamResult.Text = "사용 준비 미완료 — 실제 분업 검증을 통과하지 못했습니다.`n" + $ui.TeamResult.Text + "`n" + $reason.Trim()
                Add-ResearchLog ('연구팀의 연결·설정 또는 실제 분업 테스트를 완료하지 못했습니다. 같은 연구팀으로 다시 시도하세요. ' + $reason.Trim())
            }
        }
    }
    if (-not $success -and -not $script:workerFailed) { Add-ResearchLog '작업의 완료 결과를 확인하지 못했습니다. 일부 설정이 적용됐을 수 있으므로 상태를 다시 확인한 뒤 재시도하세요.' }
    Refresh-ResearchButtons
}

function Start-ResearchBotIssuance {
    param([int]$Index)
    if ($script:busy -or -not $script:serverReady -or $Index -lt 0 -or $Index -ge $script:agents.Count) { return }
    try {
        $data = Get-ResearchServerInput -AdminSecret $ui.TeamAdminPassword.Password
        $data | Add-Member BotUsername $script:agents[$Index].ProfileName
        $data | Add-Member BotDisplayName $script:agents[$Index].Name.Text.Trim()
        $data | Add-Member BotDescription 'Hermes local research agent'
        Assert-HermesAdminBotInput $data
        $script:botIndex = $Index
        $path = Save-ResearchEncryptedInput $data
        Start-ResearchWorker 'AdminBotSetup' @('-Apply','-AdminInputPath',$path)
        $data = $null
    } catch { $script:autoSetup = $false; $script:autoReady = $false; Add-ResearchLog $_.Exception.Message; Remove-ResearchUnusedInput; Refresh-ResearchButtons }
}

function Start-ResearchAutomaticSetup {
    if ($script:busy -or $script:autoSetup -or $ui.TeamConsent.IsChecked -ne $true) { return }
    $null = Get-ResearchModelInput
    $null = Get-ResearchWizardOptions
    if (-not $ui.TeamAdminPassword.Password) { throw '이 서버의 관리자 비밀번호를 입력하세요. 네 봇·토큰은 자동으로 발급·검증합니다.' }
    $script:autoSetup = $true
    $script:autoReady = $false
    Add-ResearchLog '기본설정 자동 구성: 네 봇·토큰 → 전체 페르소나 → 독립 실행기 → 실제 S1·S2·S3 검증'
    Start-ResearchBotIssuance 0
}

function Remove-ResearchUnusedInput {
    if (-not $script:busy -and $script:inputPath -and (Test-Path -LiteralPath $script:inputPath -PathType Leaf)) {
        Remove-Item -LiteralPath $script:inputPath -Force -ErrorAction SilentlyContinue; $script:inputPath = $null
    }
}

Add-ResearchAgentRows
Set-ResearchWizardOptions -Options (New-HermesResearchWizardOptions)
foreach ($agent in $script:agents) {
    $agent.Name.Add_TextChanged({ if (-not $script:restoringTeam -and -not $script:busy) { $script:teamInputsEdited = $true } })
    $agent.Token.Add_PasswordChanged({ if (-not $script:restoringTeam -and -not $script:busy) { $script:teamInputsEdited = $true } })
}
foreach ($control in @('WorkspacePath','HumanUsername','TaskTimeoutMinutes','LocalBaseURL','LocalModel','GatewayPort')) { $ui[$control].Add_TextChanged({ if (-not $script:restoringTeam -and -not $script:busy) { $script:teamInputsEdited = $true; Refresh-ResearchButtons } }) }
foreach ($control in @('AnthropicKey','OpenAIKey')) { $ui[$control].Add_PasswordChanged({ if (-not $script:restoringTeam -and -not $script:busy) { $script:teamInputsEdited = $true } }) }
foreach ($control in @('ModelModeGateway','ModelModeCodex')) { $ui[$control].Add_Checked({ Refresh-ResearchButtons }) }
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(300)
$workerTick = {
    try {
        while (-not $script:workerEOF -and $script:pendingLine.IsCompleted) {
            $line = $script:pendingLine.GetAwaiter().GetResult()
            if ($null -eq $line) { $script:workerEOF = $true; break }
            Read-ResearchWorkerLine $line
            $script:pendingLine = $script:worker.StandardOutput.ReadLineAsync()
        }
        if ($script:worker.HasExited -and $script:workerEOF) { Complete-ResearchWorker }
    } catch {
        $script:workerFailed = $true; Add-ResearchLog '작업 표시를 완료하지 못했습니다. 진행 결과를 확인하고 같은 입력으로 다시 시도하세요.'
        $script:workerEOF = $true; $script:pendingLine = $null
        if ($null -eq $script:worker) { $timer.Stop(); $script:busy = $false; Remove-ResearchUnusedInput; Refresh-ResearchButtons }
        elseif ($script:worker.HasExited) { Complete-ResearchWorker }
    }
}
$timer.Add_Tick($workerTick)

$ui.WorkspaceBrowseButton.Add_Click({
    try {
        if ($script:busy) { return }
        Add-Type -AssemblyName System.Windows.Forms
        $picker = New-Object Windows.Forms.FolderBrowserDialog
        try {
            $picker.Description = '연구용 작업 폴더를 선택하세요. 입력 자료는 하위 inputs 폴더에서 읽습니다.'
            $picker.SelectedPath = $ui.WorkspacePath.Text
            if ($picker.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $ui.WorkspacePath.Text = $picker.SelectedPath }
        } finally { $picker.Dispose() }
    } catch { Add-ResearchLog $_.Exception.Message }
})
foreach ($name in @('ServerConsent','HermesConsent','TeamConsent','DockerInstallConsent','ModelEgressConsent','PublicWebConsent')) {
    $ui[$name].Add_Checked({ Refresh-ResearchButtons }); $ui[$name].Add_Unchecked({ Refresh-ResearchButtons })
}
$ui.ModelCombo.Add_SelectionChanged({ Refresh-ResearchButtons })
$ui.ReviewerSlots.Add_SelectionChanged({ if (-not $script:restoringTeam -and -not $script:busy) { $script:teamInputsEdited=$true; Refresh-ResearchButtons } })
$ui.DockerCheckButton.Add_Click({ try { $script:dockerReady = $false; Start-ResearchWorker 'DockerStatus' } catch { Add-ResearchLog $_.Exception.Message; Refresh-ResearchButtons } })
$ui.DockerOpenButton.Add_Click({
    try {
        if ($script:busy -or -not $script:dockerCanOpen) { return }
        Open-HermesDockerDesktop | Out-Null
        $script:dockerReady = $false; Refresh-ResearchButtons
        Add-ResearchLog 'Docker Desktop의 약관과 초기 설정을 직접 확인하세요. Linux 엔진 실행 후 준비 상태를 다시 검사하세요.'
    } catch { Add-ResearchLog $_.Exception.Message }
})
$ui.DockerInstallButton.Add_Click({
    try {
        if ($script:busy -or -not $script:dockerCanInstall -or $ui.DockerInstallConsent.IsChecked -ne $true) { return }
        $script:dockerReady = $false; $ui.DockerInstallConsent.IsChecked = $false
        Add-ResearchLog '공식 Docker 설치 파일을 다운로드·검증합니다. 설치 창에서 요청하는 내용은 직접 확인하세요. 약관을 자동 동의하거나 PC를 재부팅하지 않습니다.'
        Start-ResearchWorker 'DockerInstall' @('-Apply')
    } catch { Add-ResearchLog $_.Exception.Message; Refresh-ResearchButtons }
})
$ui.DockerGuideButton.Add_Click({ if (-not $script:busy) { Start-Process 'https://docs.docker.com/desktop/setup/install/windows-install/' | Out-Null } })
$ui.ServerRestoreButton.Add_Click({ try { Read-ResearchServerRecord; Start-ResearchWorker 'DockerStatus' } catch { $script:serverReady = $false; Add-ResearchLog $_.Exception.Message; Refresh-ResearchButtons } })
$ui.ServerCreateButton.Add_Click({
    try {
        if ($script:busy -or $ui.ServerConsent.IsChecked -ne $true -or -not $script:dockerReady) { return }
        if ($ui.AdminPassword.Password -cne $ui.PasswordConfirm.Password) { throw '비밀번호 확인이 일치하지 않습니다.' }
        $path = Save-ResearchEncryptedInput (Get-ResearchServerInput)
        # Carry the password in this window only, before clearing step 1. Never log it.
        $ui.TeamAdminPassword.Password = $ui.AdminPassword.Password
        $extra = @('-Apply','-AdminInputPath',$path)
        if ($ui.ServerResumeCheck.IsChecked -eq $true) { $extra += '-Resume' }
        Start-ResearchWorker 'AdminSetup' $extra
        $ui.AdminPassword.Clear(); $ui.PasswordConfirm.Clear()
    } catch { Add-ResearchLog $_.Exception.Message; Remove-ResearchUnusedInput; Refresh-ResearchButtons }
})
foreach ($name in @('ServerId','ServerPort','AdminUsername','AdminEmail')) {
    $ui[$name].Add_TextChanged({ if (-not $script:busy) { $script:serverReady = $false; $script:serverIdentity = $null; Refresh-ResearchButtons } })
}
$ui.ServerOpenButton.Add_Click({ if ($script:serverReady) { Start-Process $script:serverURL | Out-Null } })
$ui.ServerNextButton.Add_Click({ if ($script:serverReady) { $ui.WizardTabs.SelectedIndex = 1 } })
function Reset-ResearchHermesSelection {
    $script:hermesReady = $false; $script:authenticated = $false; $script:plan = $null
    $script:preferredModel = $null
    $script:authURL = $null; $ui.AuthCode.Clear(); $ui.ModelCombo.Items.Clear()
    $ui.HermesConsent.IsChecked = $false; $ui.HermesPlanText.Clear()
    $ui.AuthStatus.Text = '선택한 경로에서 기존 Hermes·인증을 다시 확인하세요.'
    $ui.TeamConsent.IsChecked = $false
    Refresh-ResearchButtons
}
$ui.UseExistingHermesCheck.Add_Checked({ $script:useExistingHermes = $true; Reset-ResearchHermesSelection })
$ui.UseExistingHermesCheck.Add_Unchecked({ $script:useExistingHermes = $false; $script:paths = $script:defaultPaths; Reset-ResearchHermesSelection })
foreach ($name in @('ExistingHermesHome','ExistingHermesInstallDir')) {
    $ui[$name].Add_TextChanged({ if ($script:useExistingHermes -and -not $script:busy) { Reset-ResearchHermesSelection } })
}
$ui.HermesPlanButton.Add_Click({
    try { $script:plan = $null; $ui.HermesConsent.IsChecked = $false; Start-ResearchWorker 'Plan' @('-SkipComputerUse','-SetupMode','Later') }
    catch { Add-ResearchLog $_.Exception.Message }
})
$ui.HermesInstallButton.Add_Click({
    try {
        if ($script:busy -or $script:useExistingHermes -or $null -eq $script:plan -or $ui.HermesConsent.IsChecked -ne $true) { return }
        $extra = @('-Apply','-SkipComputerUse','-SetupMode','Later','-ExpectedPlanFingerprint',[string]$script:plan.Fingerprint)
        $prior = Read-HermesInstallState -LiteralPath $script:paths.StateFile
        if ($null -ne $prior -and @('Running','Failed') -contains [string]$prior.status -and [string]$prior.plan_fingerprint -ceq [string]$script:plan.Fingerprint) { $extra += '-Resume' }
        Start-ResearchWorker 'Install' $extra
    } catch { Add-ResearchLog $_.Exception.Message }
})
$ui.HermesStatusButton.Add_Click({ try { Start-ResearchWorker 'CodexStatus' } catch { Add-ResearchLog $_.Exception.Message } })
$ui.AuthButton.Add_Click({ try { $ui.AuthCode.Clear(); $script:authURL = $null; Start-ResearchWorker 'CodexAuth' @('-Apply') } catch { Add-ResearchLog $_.Exception.Message } })
$ui.AuthOpenButton.Add_Click({ if ($script:authURL -ceq 'https://auth.openai.com/codex/device') { Start-Process $script:authURL | Out-Null } })
$ui.HermesNextButton.Add_Click({ if ($script:hermesReady) { $ui.WizardTabs.SelectedIndex = 2 } })
$ui.TeamOpenButton.Add_Click({ if ($script:serverReady) { Start-Process $script:channelURL | Out-Null } })
$ui.TeamBoardButton.Add_Click({
    try {
        $pluginRecord = Join-Path $script:paths.RuntimeRoot 'mattermost-plugins\state.json'
        if (Test-Path -LiteralPath $pluginRecord -PathType Leaf) {
            $plugin = [IO.File]::ReadAllText($pluginRecord,[Text.Encoding]::UTF8)|ConvertFrom-Json
            if ($plugin.Ready -and [string]$plugin.BoardURL -cmatch '^http://127\.0\.0\.1:[0-9]{4,5}/[a-z0-9-]+/com\.hermes\.research-board/board$') {
                Start-Process ([string]$plugin.BoardURL) | Out-Null; return
            }
        }
        $recordPath = Join-Path $script:paths.RuntimeRoot 'research\dashboard.json'
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf) -or (Get-Item -LiteralPath $recordPath).Length -gt 4096) { throw '연구 웹 보드가 아직 시작되지 않았습니다. 기본설정 자동 구성을 먼저 진행하세요.' }
        $record = [IO.File]::ReadAllText($recordPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ([string]$record.url -cnotmatch '^http://127\.0\.0\.1:[1-9][0-9]{0,4}/$') { throw '연구 보드 주소를 확인할 수 없습니다.' }
        Start-Process ([string]$record.url) | Out-Null
    } catch { Add-ResearchLog $_.Exception.Message }
})
$ui.TeamPluginsButton.Add_Click({
    if (-not $script:busy) { Start-ResearchWorker 'ResearchPluginsSetup' @('-Apply') }
})
$ui.TeamApplyButton.Add_Click({
    try {
        if ($script:busy -or $ui.TeamConsent.IsChecked -ne $true -or -not $script:hermesReady -or -not $script:serverReady) { return }
        if (-not $script:autoReady) { Start-ResearchAutomaticSetup; return }
        $script:autoReady = $false
        $data = [pscustomobject]@{
            SchemaVersion = 2; ServerURL = $ui.TeamServerURL.Text; HomeChannelID = $ui.HomeChannelID.Text
            Model = (Get-ResearchModelInput); WizardOptions = (Get-ResearchWizardOptions)
            Agents = @($script:agents | ForEach-Object { [pscustomobject]@{ ProfileName = $_.ProfileName; DisplayName = $_.Name.Text.Trim(); BotToken = $_.Token.Password } })
        }
        $null = Assert-HermesResearchTeamInput -InputObject $data
        $path = Save-ResearchEncryptedInput $data
        $extra = @('-Apply','-ResearchInputPath',$path)
        if ($ui.TeamResumeCheck.IsChecked -eq $true) { $extra += '-Resume' }
        Start-ResearchWorker 'ResearchTeamSetup' $extra
        $data = $null
    } catch { Add-ResearchLog $_.Exception.Message; Remove-ResearchUnusedInput; Refresh-ResearchButtons }
})
$ui.CloseButton.Add_Click({ $window.Close() })
$window.Add_Closing({ param($sender,$eventArgs)
    if ($script:busy) { $eventArgs.Cancel = $true; Add-ResearchLog '설치·인증·연결 작업 완료 후 창을 닫으세요.' }
    else { foreach ($agent in $script:agents) { $agent.Token.Clear() }; $ui.AdminPassword.Clear(); $ui.PasswordConfirm.Clear(); $ui.TeamAdminPassword.Clear(); $ui.AnthropicKey.Clear(); $ui.OpenAIKey.Clear(); Remove-ResearchUnusedInput }
})
Refresh-ResearchButtons
$script:teamInputsEdited = $false
if ($SmokeTest) {
    if ($ui.TeamQuickActions.Parent.Children.IndexOf($ui.TeamQuickActions) -ne 0 -or $ui.TeamAdvancedSettings.IsExpanded -or
        -not $ui.TeamQuickActions.Child.Children[0].Children.Contains($ui.TeamApplyButton)) { throw '자동 구성 버튼이 3페이지 최상단에 없거나 세부 설정이 기본으로 펼쳐졌습니다.' }
    if ($script:agents.Count -ne 4 -or $ui.ServerCreateButton.IsEnabled -or $ui.HermesInstallButton.IsEnabled -or $ui.TeamApplyButton.IsEnabled) { throw '연구실 기본 동작이 안전하지 않습니다.' }
    if ($ui.HermesTab.IsEnabled -or $ui.TeamTab.IsEnabled -or $ui.ServerConsent.IsChecked -or $ui.TeamConsent.IsChecked) { throw '준비되지 않은 연구실 단계가 활성화됐습니다.' }
    if ([string]::IsNullOrWhiteSpace($ui.WorkspacePath.Text) -or [string]$ui.ReviewerSlots.SelectedItem -cne '1' -or $ui.TaskTimeoutMinutes.Text -cne '180' -or $ui.ModelModeCodex.IsChecked -ne $true) { throw '네 역할 연구팀의 기본 선택(작업 폴더·심사자 수·시간 한도·라우터)이 준비되지 않았습니다.' }
    if ($ui.ModelEgressConsent.IsChecked -or $ui.PublicWebConsent.IsChecked -or $ui.MigrationConsent.IsChecked) { throw '모델·웹·기존 연결 전환 동의가 미리 선택됐습니다.' }
    if (Test-ResearchWorkflowEvidence ([pscustomobject]@{ExecutionReady=$true})) { throw '연결 준비만으로 실제 분업 테스트가 통과됐습니다.' }
    $workflowFixture = [pscustomobject]@{ ExecutionReady = $true; WorkflowTest = [pscustomobject]@{Passed=$true;Live=$true;AuditPassed=$true;Scenarios=@('S1','S2','S3');RequestID='fixture-request';EvidencePath='fixture-evidence';Roles=@('research-lead','research-scout','research-worker','research-reviewer')} }
    if (-not (Test-ResearchWorkflowEvidence $workflowFixture)) { throw '네 역할의 실제 테스트 증거가 준비 상태로 연결되지 않습니다.' }
    $workflowFixture.WorkflowTest.Live = $false
    if (Test-ResearchWorkflowEvidence $workflowFixture) { throw '모의 테스트를 실제 분업 검증으로 표시했습니다.' }
    $workflowFixture.WorkflowTest.Live = $true; $workflowFixture.WorkflowTest.Roles = @('research-lead','research-scout','research-worker','research-worker')
    if (Test-ResearchWorkflowEvidence $workflowFixture) { throw '감사·심사 역할이 누락된 테스트를 완료로 표시했습니다.' }
    if (@($script:agents | Where-Object { $_.Token.Password }).Count -ne 0 -or $ui.AdminPassword.Password -or $ui.PasswordConfirm.Password -or $ui.AnthropicKey.Password -or $ui.OpenAIKey.Password) { throw '초기 입력에 비밀값이 있습니다.' }
    if ((@($script:agents | ForEach-Object { $_.ProfileName }) -join ',') -cne 'research-lead,research-scout,research-worker,research-reviewer') { throw '연구 프로필 네 개가 표시되지 않습니다.' }
    if ($ui.DockerInstallConsent.IsChecked -or $ui.DockerInstallButton.IsEnabled -or $ui.DockerOpenButton.IsEnabled) { throw '확인 전 Docker 설치·실행이 활성화됐습니다.' }
    $dockerFixture = [pscustomobject]@{
        Installed = $false; Ready = $false; CanInstall = $true; CanOpen = $false; RebootRequired = $false
        Summary = '미설치 테스트'; Prerequisites = @(); Alternatives = @('대안 안내 테스트')
    }
    $script:workerAction = 'DockerStatus'; $script:workerResult = $null
    Read-ResearchWorkerLine ($dockerFixture | ConvertTo-Json -Compress)
    if ($null -eq $script:workerResult -or $script:workerResult.Installed) { throw 'Docker 조회 JSON이 처리되지 않습니다.' }
    Set-ResearchDockerStatus $script:workerResult
    if ($ui.DockerInstallButton.IsEnabled -or -not $ui.DockerInstallConsent.IsEnabled) { throw 'Docker 설치 동의가 우회됐습니다.' }
    $ui.DockerInstallConsent.IsChecked = $true
    if (-not $ui.DockerInstallButton.IsEnabled) { throw '동의한 미설치 환경에서 Docker 설치가 활성화되지 않습니다.' }
    $script:busy = $true; Refresh-ResearchButtons
    if ($ui.DockerInstallButton.IsEnabled -or $ui.DockerInstallConsent.IsEnabled -or $ui.DockerCheckButton.IsEnabled) { throw 'Docker 작업 중 입력이 차단되지 않습니다.' }
    $script:busy = $false
    $dockerFixture.Installed = $true; $dockerFixture.CanInstall = $false; $dockerFixture.CanOpen = $true
    Set-ResearchDockerStatus $dockerFixture
    $ui.ServerConsent.IsChecked = $true
    if ($ui.ServerCreateButton.IsEnabled -or $ui.DockerInstallButton.IsEnabled) { throw 'Docker 설치만으로 서버 준비가 완료됐습니다.' }
    $dockerFixture.Ready = $true; $dockerFixture.RebootRequired = $true
    Set-ResearchDockerStatus $dockerFixture
    if ($ui.ServerCreateButton.IsEnabled) { throw '재부팅 필요 상태에서 서버 설치가 활성화됐습니다.' }
    $dockerFixture.RebootRequired = $false
    Set-ResearchDockerStatus $dockerFixture
    if ($ui.ServerCreateButton.IsEnabled) { throw '다시 확인이 이번 설치의 재부팅 요구를 지웠습니다.' }
    $script:dockerRebootRequired = $false # Simulate a fresh wizard session after reboot.
    $script:workerAction = 'DockerInstall'; $script:workerResult = $null
    Read-ResearchWorkerLine ([pscustomobject]@{ type = 'complete'; message = '설치 테스트'; data = $dockerFixture } | ConvertTo-Json -Compress -Depth 6)
    if ($null -eq $script:workerResult -or -not $script:workerResult.Installed) { throw 'Docker 설치 complete 이벤트가 처리되지 않습니다.' }
    Set-ResearchDockerStatus $script:workerResult
    if (-not $ui.ServerCreateButton.IsEnabled) { throw 'Docker Linux 엔진 준비 확인이 서버 단계로 연결되지 않습니다.' }
    $ui.ServerConsent.IsChecked = $false
    $script:dockerReady = $false; $script:dockerCanInstall = $false; $script:dockerCanOpen = $false
    $ui.DockerStatus.Text = '설치 위치·공식 서명·Linux 엔진과 PC 준비 상태를 확인합니다.'
    $ui.DockerAlternatives.Text = 'WSL2 Ubuntu 직접 설치 또는 별도 Linux·기존 Mattermost 서버 연결이 대안입니다. 이 초기 버전에서는 대안 안내만 제공합니다.'
    $script:serverURL = 'http://127.0.0.1:18065'; $ui.HomeChannelID.Text = 'c' * 26
    $resumeFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('hermes-gui-resume-' + [guid]::NewGuid().ToString('N'))
    $priorPaths = $script:paths
    $priorKey = $script:lastLoadedTeamKey
    $priorEdited = $script:teamInputsEdited
    $formBefore = @($script:agents | ForEach-Object { @{Name=$_.Name.Text;Token=$_.Token.Password} })
    try {
        $script:paths = [pscustomobject]@{ RuntimeRoot=(Join-Path $resumeFixtureRoot 'runtime');HermesHome=(Join-Path $resumeFixtureRoot 'home');InstallDir=(Join-Path $resumeFixtureRoot 'home\hermes-agent') }
        $options = New-HermesResearchWizardOptions -WorkspacePath 'C:\Research Fixture' -HumanUsername 'fixture-user'
        $options.ReviewerSlots = 2; $options.TaskTimeoutMinutes = 240
        $profiles = @(New-HermesResearchDefaultAgents | ForEach-Object { [pscustomobject]@{ ProfileName = $_.ProfileName; DisplayName = ('저장된 ' + $_.DisplayName); BotUserID = ('u' * 26); BotUsername = $_.ProfileName; OwnsProfile = $true; Status = 'Configured' } })
        $fixtureState = [pscustomobject]@{
            SchemaVersion = 2; Manager = 'HermesEasySetup.ResearchTeam.v2'; OwnerSID = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; TeamID = 'a' * 32
            ServerURL = $script:serverURL; HomeChannelID = $ui.HomeChannelID.Text; RuntimeRoot = $script:paths.RuntimeRoot; HermesHome = $script:paths.HermesHome; InstallDir = $script:paths.InstallDir
            Model = [pscustomobject]@{ Mode = 'Gateway'; Cloud = @('anthropic'); LocalBaseURL = 'http://127.0.0.1:8000/v1'; LocalModel = 'fixture-local' }; WizardOptions = $options; Profiles = $profiles
        }
        $researchRoot = Join-Path $script:paths.RuntimeRoot 'research'
        New-Item -ItemType Directory -Path (Join-Path $researchRoot 'private') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $researchRoot 'gateway') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $researchRoot 'team.json'),($fixtureState | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
        $bots = [ordered]@{}; $index = 0
        foreach ($profile in $profiles) { $index++; $bots[$profile.ProfileName] = ([string][char](96 + $index)) * 26 }
        [IO.File]::WriteAllText((Join-Path $researchRoot 'private\bots.json'),($bots | ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $researchRoot 'gateway\env'),("ANTHROPIC_API_KEY=sk-ant-fixture-key-0123456789`n"),(New-Object Text.UTF8Encoding($false)))
        $script:teamInputsEdited = $false; $script:lastLoadedTeamKey = $null
        Read-ResearchSavedTeam -OnlyIfUnedited
        if (@($script:agents | Where-Object { $_.Token.Password.Length -ne 26 }).Count -ne 0 -or $ui.Log.Text.Contains('a' * 26) -or $ui.Log.Text.Contains('sk-ant-fixture')) { throw '복원된 비공개 토큰·키가 비어 있거나 안내에 노출됐습니다.' }
        if ($script:agents[0].Name.Text -cne '저장된 총괄' -or [string]$ui.ReviewerSlots.SelectedItem -cne '2' -or $ui.TaskTimeoutMinutes.Text -cne '240' -or
            $ui.AnthropicKey.Password -cne 'sk-ant-fixture-key-0123456789' -or $ui.LocalModel.Text -cne 'fixture-local' -or $ui.ModelEgressConsent.IsChecked) { throw '저장된 네 역할 설정·모델이 복원되지 않았거나 동의가 미리 선택됐습니다.' }
        $script:agents[0].Name.Text = '사용자가 입력 중인 값'
        if (-not $script:teamInputsEdited) { throw '연구팀 입력 편집이 추적되지 않습니다.' }
        Read-ResearchSavedTeam -OnlyIfUnedited
        if ($script:agents[0].Name.Text -cne '사용자가 입력 중인 값') { throw '상태 새로고침이 입력 중인 이름을 덮어썼습니다.' }
        $fixtureState.OwnerSID = 'S-1-5-18'
        [IO.File]::WriteAllText((Join-Path $researchRoot 'team.json'),($fixtureState | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
        $rejected = $false; try { Read-ResearchSavedTeam } catch { $rejected = $true }
        if (-not $rejected) { throw '다른 사용자의 연구팀 기록을 불러왔습니다.' }
    } finally {
        $script:paths = $priorPaths; $script:lastLoadedTeamKey = $priorKey
        $script:restoringTeam = $true
        for ($index = 0; $index -lt $script:agents.Count; $index++) { $script:agents[$index].Name.Text=$formBefore[$index].Name; $script:agents[$index].Token.Password=$formBefore[$index].Token }
        $ui.AnthropicKey.Clear(); $ui.LocalBaseURL.Clear(); $ui.LocalModel.Clear(); Set-ResearchWizardOptions -Options (New-HermesResearchWizardOptions)
        $script:restoringTeam = $false; $script:teamInputsEdited = $priorEdited
        $resolvedFixture = [IO.Path]::GetFullPath($resumeFixtureRoot)
        $fixturePrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\hermes-gui-resume-'
        if ($resolvedFixture.StartsWith($fixturePrefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedFixture)) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
    }
    # Router mode needs no Codex login; Codex mode does.
    $script:serverReady = $true; $script:hermesReady = $true; $script:authenticated = $false
    Refresh-ResearchButtons
    if (-not $ui.TeamTab.IsEnabled -or $ui.TeamApplyButton.IsEnabled) { throw 'Hermes 설치 후 연구팀 단계가 열리지 않거나 동의 없이 설치가 활성화됐습니다.' }
    $ui.TeamConsent.IsChecked = $true; Refresh-ResearchButtons
    if ($ui.TeamApplyButton.IsEnabled) { throw '모델·웹 전송 선택 없이 연구팀 설치가 활성화됐습니다.' }
    $ui.ModelEgressConsent.IsChecked = $true; $ui.PublicWebConsent.IsChecked = $true; Refresh-ResearchButtons
    if (-not $ui.TeamApplyButton.IsEnabled) { throw '라우터 연결에서 설치 조건이 충족돼도 버튼이 활성화되지 않습니다.' }
    $rejected = $false; try { $null = Get-ResearchModelInput } catch { $rejected = $true }
    if (-not $rejected) { throw 'API 키·로컬 모델 없이 라우터 입력이 통과했습니다.' }
    $ui.ModelModeCodex.IsChecked = $true; Refresh-ResearchButtons
    if ($ui.TeamApplyButton.IsEnabled -or $ui.AnthropicKey.IsEnabled) { throw 'Codex 로그인 없이 Codex 직접 연결 설치가 활성화됐거나 라우터 입력이 열려 있습니다.' }
    $script:authenticated = $true; [void]$ui.ModelCombo.Items.Add('mock-model'); $ui.ModelCombo.SelectedIndex = 0; Refresh-ResearchButtons
    if (-not $ui.TeamApplyButton.IsEnabled -or (Get-ResearchModelInput).CodexModel -cne 'mock-model') { throw 'Codex 직접 연결 선택이 설치 입력으로 전달되지 않습니다.' }
    $ui.ModelModeGateway.IsChecked = $true
    $formOptions = Get-ResearchWizardOptions
    if ($formOptions.ReviewerSlots -ne 1 -or $formOptions.TaskTimeoutMinutes -ne 180 -or $formOptions.WorkspacePath -cne $ui.WorkspacePath.Text.TrimEnd('\','/')) { throw '화면 선택이 설치 입력으로 전달되지 않습니다.' }
    $script:busy = $true; Refresh-ResearchButtons
    if ($ui.TeamApplyButton.IsEnabled -or $ui.CloseButton.IsEnabled -or @($script:agents | Where-Object { $_.Token.IsEnabled }).Count -ne 0 -or $ui.AnthropicKey.IsEnabled) { throw '작업 중 입력과 닫기가 차단되지 않습니다.' }
    $script:busy = $false; Refresh-ResearchButtons
    $ui.UseExistingHermesCheck.IsChecked = $true
    if ($ui.TeamConsent.Content -isnot [Windows.Controls.TextBlock] -or -not $ui.TeamConsent.Content.Text.Contains('실제 모델')) { throw '기존 Hermes 선택이 실제 작업 테스트 동의 문구를 제거했습니다.' }
    $script:plan = [pscustomobject]@{ Fingerprint = 'fixture' }
    $ui.HermesConsent.IsChecked = $true
    Set-ResearchAuthStatus ([pscustomobject]@{ LoggedIn = $true; Models = @('original-model','other-model'); PreferredModel = 'original-model'; Summary = 'fixture existing credentials'; RuntimeKind = 'Existing'; Version = 'fixture version' })
    Refresh-ResearchButtons
    if ($ui.HermesPlanButton.IsEnabled -or $ui.HermesInstallButton.IsEnabled -or $ui.AuthButton.IsEnabled -or [string]$ui.ModelCombo.SelectedItem -cne 'original-model') { throw '기존 Hermes 모드가 재설치·새 로그인을 허용하거나 기존 모델 선택을 잃었습니다.' }
    $originalHomeText = $ui.ExistingHermesHome.Text
    $script:preferredModel = 'other-model'
    $ui.ExistingHermesHome.Text = $originalHomeText + '-changed'
    if ($script:authenticated -or $script:hermesReady -or $ui.HermesNextButton.IsEnabled -or $ui.TeamApplyButton.IsEnabled -or $null -ne $script:preferredModel) { throw '경로 변경이 이전 인증·모델 선택을 재사용했습니다.' }
    $ui.ExistingHermesHome.Text = $originalHomeText
    $ui.UseExistingHermesCheck.IsChecked = $false
    Refresh-ResearchButtons
    $script:worker = [pscustomobject]@{ HasExited = $true; ExitCode = 1 }
    $script:worker | Add-Member ScriptMethod WaitForExit { }
    $script:worker | Add-Member ScriptMethod Dispose { }
    $script:pendingLine = [pscustomobject]@{ IsCompleted = $true }
    $script:pendingLine | Add-Member ScriptMethod GetAwaiter { throw 'mock read failure' }
    $script:workerEOF = $false; $script:busy = $true; $script:workerAction = 'mock-fault'; $script:workerResult = $null
    & $workerTick
    if ($script:busy -or $null -ne $script:worker -or -not $ui.CloseButton.IsEnabled) { throw '작업 읽기 실패 후 종료 잠금이 풀리지 않습니다.' }
    # Exercise the real completion chain without a server, profile, credential file or model.
    $originalIssue = ${function:Start-ResearchBotIssuance}
    $originalSave = ${function:Save-ResearchEncryptedInput}
    $originalStart = ${function:Start-ResearchWorker}
    $originalCredential = ${function:Read-HermesAdminBotCredential}
    try {
        $script:issuedFixture = @(); $script:startedFixture = @(); $script:busy = $false
        function Start-ResearchBotIssuance { param([int]$Index) $script:botIndex = $Index; $script:issuedFixture += $Index }
        function Save-ResearchEncryptedInput { param($Value) return 'offline-fixture-only' }
        function Start-ResearchWorker { param($Action,$ExtraArguments) $script:startedFixture += $Action }
        function Read-HermesAdminBotCredential { param($Value) return [pscustomobject]@{ Token=(('a' * 25) + [string]$script:botIndex) } }
        $ui.ServerId.Text='research-fixture'; $ui.ServerPort.Text='18065'
        $ui.AdminUsername.Text='fixture-admin'; $ui.AdminEmail.Text='fixture@example.invalid'
        $script:dockerReady=$true; $ui.ServerConsent.IsChecked=$true
        $ui.AdminPassword.Password='Offline-Fixture-Pass-0172!'; $ui.PasswordConfirm.Password='Offline-Fixture-Pass-0172!'
        $ui.ServerCreateButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
        if ($ui.TeamAdminPassword.Password -cne 'Offline-Fixture-Pass-0172!' -or $ui.AdminPassword.Password -or $ui.PasswordConfirm.Password -or $ui.Log.Text.Contains('Offline-Fixture-Pass-0172!')) {
            throw '1단계 비밀번호가 3단계에 이어지지 않거나 로그에 노출됐습니다.'
        }
        $script:startedFixture=@(); $ui.ServerConsent.IsChecked=$false
        $ui.ModelModeCodex.IsChecked = $true
        Set-ResearchAuthStatus ([pscustomobject]@{LoggedIn=$true;Models=@('mock-model');PreferredModel='mock-model';Summary='fixture'})
        $ui.TeamConsent.IsChecked=$true; $ui.ModelEgressConsent.IsChecked=$true; $ui.PublicWebConsent.IsChecked=$true
        $ui.TeamAdminPassword.Password='offline-fixture-only'
        $ui.TeamServerURL.Text='http://127.0.0.1:18065'; $ui.HomeChannelID.Text=('c' * 26)
        $script:serverReady=$true; $script:hermesReady=$true; Refresh-ResearchButtons
        if (-not $ui.TeamApplyButton.IsEnabled) { throw '준비된 기본설정 버튼이 비활성 상태입니다.' }
        $ui.TeamApplyButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
        for ($fixtureIndex = 0; $fixtureIndex -lt 4; $fixtureIndex++) {
            if ($script:botIndex -ne $fixtureIndex) { throw 'Automatic bot issuance skipped a role' }
            $script:worker = [pscustomobject]@{ ExitCode=0 }
            $script:worker | Add-Member ScriptMethod WaitForExit {}
            $script:worker | Add-Member ScriptMethod Dispose {}
            $script:workerAction='AdminBotSetup'; $script:workerResult=[pscustomobject]@{Ready=$true}
            $script:workerFailed=$false; $script:inputPath=$null
            Complete-ResearchWorker
        }
        if (($script:issuedFixture -join ',') -cne '0,1,2,3' -or ($script:startedFixture -join ',') -cne 'ResearchTeamSetup') {
            throw 'One click did not chain four bot connections into exactly one team setup'
        }
        $script:issuedFixture=@(); $script:startedFixture=@(); $script:autoSetup=$true; $script:botIndex=1
        $script:worker=[pscustomobject]@{ExitCode=1}
        $script:worker | Add-Member ScriptMethod WaitForExit {}
        $script:worker | Add-Member ScriptMethod Dispose {}
        $script:workerAction='AdminBotSetup'; $script:workerResult=$null; $script:workerFailed=$true
        Complete-ResearchWorker
        if ($script:autoSetup -or $script:issuedFixture.Count -or $script:startedFixture.Count -or -not $script:agents[0].Token.Password) {
            throw 'Failed bot issuance continued or discarded existing tokens'
        }
    } finally {
        Set-Item Function:Start-ResearchBotIssuance $originalIssue
        Set-Item Function:Save-ResearchEncryptedInput $originalSave
        Set-Item Function:Start-ResearchWorker $originalStart
        if ($originalCredential) { Set-Item Function:Read-HermesAdminBotCredential $originalCredential }
        else { Remove-Item Function:Read-HermesAdminBotCredential -ErrorAction SilentlyContinue }
        foreach ($agent in $script:agents) { $agent.Token.Clear() }
        $ui.TeamAdminPassword.Clear(); $script:autoSetup=$false; $script:autoReady=$false
        $script:workerFailed=$false
    }
    $ui.Log.Clear()
    if ($PreviewPath) {
        if ($PreviewStep -ceq 'Hermes') {
            $ui.UseExistingHermesCheck.IsChecked = $true
            Set-ResearchAuthStatus ([pscustomobject]@{ LoggedIn = $true; Models = @('existing-model'); PreferredModel = 'existing-model'; Summary = '미리보기: 기존 Hermes와 저장된 인증 발견 — 기존 파일 변경 없음'; RuntimeKind = 'Existing'; Version = 'Hermes existing source (commit example)' })
            Refresh-ResearchButtons
        }
        $ui.WizardTabs.SelectedIndex = $(switch ($PreviewStep) { 'Server' { 0 } 'Hermes' { 1 } default { 2 } })
        $window.Show(); $window.UpdateLayout()
        $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($window)
        $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [IO.File]::Open([IO.Path]::GetFullPath($PreviewPath),[IO.FileMode]::CreateNew)
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
    }
    Write-Host 'PASS local research WPF: 3+1 team, router/Codex model choice, Docker/model/web consent, live S1-S2-S3 evidence gate, private token/key restore and edit preservation, failed-worker cleanup'
    $window.Close(); exit 0
}
$window.Add_ContentRendered({
    if (-not $script:busy -and -not $script:initialDockerCheck) {
        $script:initialDockerCheck = $true
        try { Start-ResearchWorker 'DockerStatus' } catch { Add-ResearchLog $_.Exception.Message }
    }
})
$window.ShowDialog() | Out-Null
