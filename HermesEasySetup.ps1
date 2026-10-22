[CmdletBinding()]
param(
    [ValidateSet('Diagnose', 'Plan', 'Install', 'Verify', 'Setup', 'CodexStatus', 'CodexAuth', 'DockerStatus', 'DockerInstall', 'AdminPreflight', 'AdminSetup', 'AdminBotSetup', 'ResearchTeamSetup', 'ResearchPluginsSetup', 'Bundle')]
    [string]$Action = 'Diagnose',
    [string]$HermesHome,
    [string]$InstallDir,
    [string]$RuntimeRoot,
    [switch]$IncludeDesktop,
    [switch]$SkipComputerUse,
    [ValidateSet('Later', 'Portal', 'Full')][string]$SetupMode = 'Portal',
    [switch]$Apply,
    [switch]$Resume,
    [switch]$UseExistingHermes,
    [switch]$ForceDownload,
    [switch]$LaunchSetup,
    [switch]$WaitForSetup,
    [switch]$Json,
    [switch]$JsonEvents,
    [string]$ExpectedPlanFingerprint,
    [string]$DestinationPath,
    [string]$SourceConfigPath,
    [string]$AdminInputPath,
    [string]$ResearchInputPath,
    [string]$AdminRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($Json -or $JsonEvents) { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false }
Import-Module (Join-Path $PSScriptRoot 'src\HermesEasySetup.Loader.psm1') -Force
$exitCodes = Get-HermesEasySetupExitCodes

function Write-ResultObject {
    param($Value)
    if ($Json -or $JsonEvents) {
        [Console]::Out.WriteLine(($Value | ConvertTo-Json -Depth 16 -Compress))
        [Console]::Out.Flush()
    } else {
        $Value | Format-List | Out-Host
    }
}

function Write-SetupEvent {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('starting', 'closed')][string]$State,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][AllowNull()]$Data
    )

    if (-not $JsonEvents) { return }
    $event = [ordered]@{
        type = 'setup'
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        state = $State
        message = $Message
        data = $Data
    }
    Write-ResultObject ([pscustomobject]$event)
}

$eventCallback = {
    param($Event)
    if ($JsonEvents) {
        [Console]::Out.WriteLine(($Event | ConvertTo-Json -Depth 16 -Compress))
        [Console]::Out.Flush()
        return
    }
    if ($Event.type -eq 'log') {
        Write-Host ("  {0}" -f $Event.message) -ForegroundColor DarkGray
    } elseif ($Event.type -eq 'stage') {
        $color = switch ($Event.state) { 'failed' { 'Red' } 'running' { 'Cyan' } 'skipped' { 'Yellow' } default { 'Green' } }
        Write-Host ("[{0,3}%] {1}" -f $Event.percent, $Event.message) -ForegroundColor $color
    } else {
        Write-Host ("[{0,3}%] {1}" -f $Event.percent, $Event.message) -ForegroundColor Cyan
    }
}.GetNewClosure()

try {
    $common = @{ HermesHome = $HermesHome; InstallDir = $InstallDir; RuntimeRoot = $RuntimeRoot }
    if ($UseExistingHermes -and $Action -cnotin @('CodexStatus', 'ResearchTeamSetup', 'ResearchPluginsSetup')) {
        throw '기존 Hermes 사용 모드에서는 인증 확인과 연구팀 연결만 허용합니다. 설치·업데이트·새 로그인은 실행하지 않습니다.'
    }
    switch ($Action) {
        'DockerStatus' {
            Write-ResultObject (Get-HermesDockerDesktopStatus)
        }
        'DockerInstall' {
            if (-not $Apply) { throw (New-Object System.InvalidOperationException 'Docker 다운로드·설치는 -Apply 승인이 필요합니다.') }
            $paths = Get-HermesDefaultPaths -RuntimeRoot $RuntimeRoot
            $result = Install-HermesDockerDesktop -RuntimeRoot $paths.RuntimeRoot -Apply -ProgressCallback $eventCallback
            $installFailed = @('InstallFailed','InstallNotDetected','InstallerStillRunning','Cancelled') -ccontains [string]$result.StatusCode
            if ($JsonEvents) {
                & $eventCallback ([pscustomobject]@{
                    type = 'complete'; state = $(if ($installFailed) { 'failed' } else { 'closed' }); percent = 100
                    message = [string]$result.Summary; data = $result
                })
            } else { Write-ResultObject $result }
            if ($installFailed) { exit $exitCodes.InstallStageFailed }
        }
        'Diagnose' {
            $result = Get-HermesPreflight @common -IncludeDesktop:$IncludeDesktop
            Write-ResultObject $result
            if (-not $result.Ready) { exit $exitCodes.PreflightFailed }
        }
        'Plan' {
            $arguments = @{
                HermesHome = $HermesHome; InstallDir = $InstallDir; RuntimeRoot = $RuntimeRoot
                IncludeDesktop = $IncludeDesktop; SkipComputerUse = $SkipComputerUse; SetupMode = $SetupMode
            }
            if (-not [string]::IsNullOrWhiteSpace($SourceConfigPath)) { $arguments.SourceConfigPath = $SourceConfigPath }
            Write-ResultObject (New-HermesInstallPlan @arguments)
        }
        'Install' {
            $planArguments = @{
                HermesHome = $HermesHome; InstallDir = $InstallDir; RuntimeRoot = $RuntimeRoot
                IncludeDesktop = $IncludeDesktop; SkipComputerUse = $SkipComputerUse; SetupMode = $SetupMode
            }
            if (-not [string]::IsNullOrWhiteSpace($SourceConfigPath)) { $planArguments.SourceConfigPath = $SourceConfigPath }
            if (-not $Apply) {
                Write-ResultObject (New-HermesInstallPlan @planArguments)
                throw (New-Object System.InvalidOperationException '설치 변경을 승인하려면 -Apply를 함께 지정하세요.')
            }
            $installArguments = @{
                HermesHome = $HermesHome; InstallDir = $InstallDir; RuntimeRoot = $RuntimeRoot
                IncludeDesktop = $IncludeDesktop; SkipComputerUse = $SkipComputerUse; SetupMode = $SetupMode
                Resume = $Resume; ForceDownload = $ForceDownload; ProgressCallback = $eventCallback
                ExpectedPlanFingerprint = $ExpectedPlanFingerprint
            }
            if (-not [string]::IsNullOrWhiteSpace($SourceConfigPath)) { $installArguments.SourceConfigPath = $SourceConfigPath }
            $result = Invoke-HermesInstall @installArguments
            if ($LaunchSetup -and $SetupMode -ne 'Later') {
                $result | Add-Member -NotePropertyName SetupLaunch -NotePropertyValue (Start-HermesOfficialSetup -HermesHome $result.Plan.HermesHome -InstallDir $result.Plan.InstallDir -RuntimeRoot $result.Plan.RuntimeRoot -Mode $SetupMode -Wait:$WaitForSetup)
            }
            if (-not $JsonEvents) { Write-ResultObject $result }
        }
        'Verify' {
            $result = Test-HermesInstallation @common -ProgressCallback $eventCallback
            Write-ResultObject $result
            if (-not $result.Verified) { exit $exitCodes.VerificationFailed }
        }
        'Setup' {
            Write-SetupEvent -State 'starting' -Message '현재 Hermes 설치를 검증하고 공식 설정 창을 여는 중입니다.' -Data $null
            $setupResult = Start-HermesOfficialSetup -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot -Mode $SetupMode -Wait:$WaitForSetup
            if ($JsonEvents) {
                if ($WaitForSetup) {
                    $setupEventData = [pscustomobject][ordered]@{
                        Started = [bool]$setupResult.Started
                        Exited = [bool]$setupResult.Exited
                        ExitCode = $setupResult.ExitCode
                        Mode = [string]$setupResult.Mode
                        ProcessId = $setupResult.ProcessId
                    }
                    Write-SetupEvent -State 'closed' -Message '공식 Hermes 설정 창이 닫혔습니다. 설정 완료 여부는 이 마법사에서 확인하지 않았습니다.' -Data $setupEventData
                }
            } else {
                Write-ResultObject $setupResult
            }
        }
        'CodexStatus' {
            Write-ResultObject (Get-HermesCodexStatus @common -UseExistingHermes:$UseExistingHermes)
        }
        'CodexAuth' {
            if (-not $Apply) { throw (New-Object System.InvalidOperationException 'OpenAI Codex 인증을 시작하려면 -Apply를 함께 지정하세요.') }
            $result = Invoke-HermesCodexAuthentication @common -ProgressCallback $eventCallback
            if (-not $JsonEvents) { Write-ResultObject $result }
        }
        'AdminPreflight' {
            Write-ResultObject (Get-HermesAdminPreflight)
        }
        { $_ -in @('AdminSetup','AdminBotSetup') } {
            if (-not $Apply) { throw (New-Object System.InvalidOperationException '새 로컬 테스트 서버를 만들려면 -Apply 승인이 필요합니다.') }
            if ([string]::IsNullOrWhiteSpace($AdminInputPath)) { throw '암호화된 관리자 입력 파일이 필요합니다.' }
            $paths = Get-HermesDefaultPaths -RuntimeRoot $RuntimeRoot
            $inputPath = [IO.Path]::GetFullPath($AdminInputPath)
            $transportRoot = [IO.Path]::GetFullPath((Join-Path $paths.RuntimeRoot 'ui-transport'))
            if (-not (Test-HermesPathContains -ParentPath $transportRoot -ChildPath $inputPath)) { throw '관리자 입력 파일은 마법사 transport 폴더 안에 있어야 합니다.' }
            try {
                $inputData = Unprotect-HermesLabInput -LiteralPath $inputPath
                $arguments = @{ InputData = $inputData; ProgressCallback = $eventCallback }
                if ($AdminRoot) { $arguments.DeploymentRoot = $AdminRoot }
                if ($Action -eq 'AdminBotSetup') { $result = Invoke-HermesAdminBotSetup @arguments }
                else { $result = Invoke-HermesAdminSetup @arguments -Resume:$Resume }
                if (-not $JsonEvents) { Write-ResultObject $result }
            } finally {
                $inputData = $null
                if (Test-Path -LiteralPath $inputPath -PathType Leaf) { Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue }
            }
        }
        'ResearchPluginsSetup' {
            $paths = Get-HermesDefaultPaths @common
            $result = Invoke-HermesResearchPluginsSetup -RuntimeRoot $paths.RuntimeRoot -Apply:$Apply -ProgressCallback $eventCallback
            if ($JsonEvents) {
                & $eventCallback ([pscustomobject]@{type='complete';state='succeeded';percent=100;message='Mattermost 작업보드·NST 연결 완료. 기존 연구팀과 검증 기록을 유지했습니다.';data=$result})
            } else { Write-ResultObject $result }
        }
        'ResearchTeamSetup' {
            if (-not $Apply) { throw (New-Object System.InvalidOperationException '연구팀 생성·변경은 -Apply 승인이 필요합니다.') }
            if ([string]::IsNullOrWhiteSpace($ResearchInputPath)) { throw '암호화된 연구팀 입력 파일이 필요합니다.' }
            $paths = Get-HermesDefaultPaths @common
            $inputPath = [IO.Path]::GetFullPath($ResearchInputPath)
            $transportRoot = [IO.Path]::GetFullPath((Join-Path $paths.RuntimeRoot 'ui-transport'))
            if (-not (Test-HermesPathContains -ParentPath $transportRoot -ChildPath $inputPath)) { throw '연구팀 입력 파일은 마법사 transport 폴더 안에 있어야 합니다.' }
            & (Get-Module HermesEasySetup.Admin) { param($path) Assert-HermesAdminPath $path } $inputPath
            try {
                $researchInput = Unprotect-HermesLabInput -LiteralPath $inputPath
                $result = Invoke-HermesResearchTeamSetup -InputObject $researchInput @common -ReuseExistingProfiles:$Resume -UseExistingHermes:$UseExistingHermes -ProgressCallback $eventCallback
                if ($JsonEvents) {
                    & $eventCallback ([pscustomobject]@{
                        type = 'complete'; state = $(if ($result.Succeeded) { 'succeeded' } else { 'failed' })
                        percent = 100; message = $(if ($result.Succeeded -and $result.ExecutionReady) { '네 역할의 실제 작업·결과 전달·기록 테스트를 통과했습니다. 사용 준비 완료.' } else { '사용 준비 전입니다. 미완료 설정 또는 실제 분업 테스트 결과를 확인하세요. 기존 기록은 보존했습니다.' })
                        data = $result
                    })
                } else { Write-ResultObject $result }
                if (-not $result.Succeeded) { exit $exitCodes.VerificationFailed }
            } finally {
                $researchInput = $null
                if (Test-Path -LiteralPath $inputPath -PathType Leaf) { Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue }
            }
        }
        'Bundle' {
            $arguments = @{ HermesHome = $HermesHome; InstallDir = $InstallDir; RuntimeRoot = $RuntimeRoot; DestinationPath = $DestinationPath }
            if (-not [string]::IsNullOrWhiteSpace($SourceConfigPath)) { $arguments.SourceConfigPath = $SourceConfigPath }
            Write-ResultObject (Export-HermesDiagnosticBundle @arguments)
        }
    }
    exit $exitCodes.Success
} catch {
    $code = $exitCodes.UnexpectedFailure
    if ($_.Exception -is [System.InvalidOperationException] -and $_.Exception.Message -like '*-Apply*') {
        $code = $exitCodes.InvalidArguments
    } elseif ($_.Exception.Data.Contains('ExitCode')) {
        $code = [int]$_.Exception.Data['ExitCode']
    }
    $errorResult = [pscustomobject]@{
        type = 'error'; timestamp = (Get-Date).ToUniversalTime().ToString('o')
        state = 'failed'; exit_code = $code; message = (Protect-HermesLogText $_.Exception.Message)
    }
    if ($Json -or $JsonEvents) {
        [Console]::Out.WriteLine(($errorResult | ConvertTo-Json -Compress)); [Console]::Out.Flush()
    } else {
        Write-Error $errorResult.message
    }
    exit $code
}
