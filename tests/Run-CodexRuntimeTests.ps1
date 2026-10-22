[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'src\HermesEasySetup.Loader.psm1') -Force

# The verifier and process boundary are mocked in module scope. No installed
# Hermes, credentials, network, or provider command is read or executed.
& (Get-Module HermesEasySetup.Codex) {
    $script:passed = 0
    function Assert-CodexRuntime {
        param([bool]$Condition, [string]$Name)
        if (-not $Condition) { throw $Name }
        $script:passed++
        Write-Host "PASS $Name"
    }
    $script:paths = Get-HermesDefaultPaths -HermesHome (Join-Path ([IO.Path]::GetTempPath()) ('hermes-codex-errors-' + [guid]::NewGuid().ToString('N')))
    $script:verification = [pscustomobject]@{
        StaticProvenanceValid = $false
        CheckoutPresent = $true
        VenvPythonPresent = $true
        ExpectedCommit = 'fcbd1076a93841fa88855acce810e342a5b78101'
        MarkerPinnedCommit = '77a799e2f9c70d07ab909fd29133f2dd38ef94f6'
        RepositoryMetadataSafe = $false
        FailedChecks = @('CheckoutHeadMatches', 'RepositoryMetadataSafe', 'MarkerMatches')
    }
    $script:verifiedStatically = $false
    $script:processCalls = 0
    function script:Test-HermesInstallation {
        param($HermesHome, $InstallDir, $RuntimeRoot, [switch]$StaticOnly, $LogPath)
        $script:verifiedStatically = [bool]$StaticOnly
        return $script:verification
    }
    function script:Invoke-HermesProcess {
        $script:processCalls++
        throw 'No runtime command is allowed in this regression suite.'
    }
    function Read-FailureMessage {
        $message = $null
        try {
            Get-HermesCodexRuntime -HermesHome $script:paths.HermesHome -InstallDir $script:paths.InstallDir -RuntimeRoot $script:paths.RuntimeRoot | Out-Null
        } catch { $message = $_.Exception.Message }
        if ([string]::IsNullOrWhiteSpace($message)) { throw 'Unverified runtime must fail closed.' }
        return $message
    }

    $message = Read-FailureMessage
    Assert-CodexRuntime ($message.Contains('설치 폴더는 발견') -and $message.Contains('미설치라는 뜻은 아닙니다')) 'Existing installation is not reported as absent'
    Assert-CodexRuntime ($message.Contains($script:paths.InstallDir)) 'Verification failure identifies the checked install path'
    Assert-CodexRuntime ($message.Contains($script:verification.ExpectedCommit) -and $message.Contains($script:verification.MarkerPinnedCommit)) 'Required and recorded commit are distinguished'
    Assert-CodexRuntime ($message.Contains('일부 검사를 진행하지 못했습니다') -and $message.Contains('모두가 각각 손상되었다는 뜻은 아닙니다')) 'Cascading skipped checks are not presented as independent damage'
    Assert-CodexRuntime ($message.Contains('기존 Hermes 설치는 변경하지 않았습니다')) 'Existing-install preservation is explained'
    Assert-CodexRuntime ($message.Contains('RepositoryMetadataSafe') -and $message.Contains('MarkerMatches')) 'Raw failed check names remain available for diagnosis'
    Assert-CodexRuntime ($script:verifiedStatically -and $script:processCalls -eq 0) 'Unverified runtime never executes Hermes or auth commands'

    $script:verification.CheckoutPresent = $false
    $script:verification.VenvPythonPresent = $false
    $script:verification.MarkerPinnedCommit = $null
    $message = Read-FailureMessage
    Assert-CodexRuntime ($message.Contains('현재 확인 경로') -and $message.Contains('다른 위치')) 'Missing target does not imply Hermes is absent everywhere'
    Assert-CodexRuntime (-not $message.Contains('설치 기록 commit:') -and -not $message.Contains('일부 검사를 진행하지 못했습니다')) 'Missing target does not invent recorded version or metadata diagnosis'

    $script:verification.CheckoutPresent = $true
    $script:verification.RepositoryMetadataSafe = $true
    $message = Read-FailureMessage
    Assert-CodexRuntime (-not $message.Contains('일부 검사를 진행하지 못했습니다')) 'Metadata-safe failures do not claim metadata prevented checks'
    Assert-CodexRuntime ($script:processCalls -eq 0 -and -not (Test-Path -LiteralPath $script:paths.HermesHome)) 'All rejected cases leave fixture paths absent and execute no command'

    $script:existingCalls = 0
    $script:probeArguments = @()
    $script:probeEnvironment = $null
    $script:probeOutput = '{"LoggedIn":true,"Models":["existing-model","other-model"],"PreferredModel":"existing-model"}'
    function script:Get-HermesExistingRuntime {
        param($HermesHome, $InstallDir, $RuntimeRoot)
        $script:existingCalls++
        return [pscustomobject]@{ Paths = $script:paths; Command = 'C:\fixture\hermes.exe'; Python = 'C:\fixture\python.exe'; Version = 'Hermes existing-test'; RuntimeKind = 'Existing'; Environment = @{ HERMES_HOME = $script:paths.HermesHome } }
    }
    function script:Invoke-HermesProcess {
        param($FilePath, $ArgumentList, $WorkingDirectory, $Environment, $TimeoutSeconds)
        if ($FilePath -cne 'C:\fixture\python.exe') { throw 'Existing status must not invoke login or the CLI.' }
        $script:probeArguments = @($ArgumentList); $script:probeEnvironment = $Environment
        return [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = 0; StdOut = $script:probeOutput; StdErr = '' }
    }
    $result = Get-HermesCodexStatus -UseExistingHermes -HermesHome $script:paths.HermesHome
    Assert-CodexRuntime ($result.LoggedIn -and $result.ReadOnly -and $result.RuntimeKind -ceq 'Existing' -and $script:existingCalls -eq 1) 'Explicit existing mode uses the separate compatibility runtime'
    Assert-CodexRuntime ($result.PreferredModel -ceq 'existing-model' -and $result.Models[0] -ceq 'existing-model') 'Existing model preference is preserved without substituting a hardcoded model'
    Assert-CodexRuntime ($script:probeArguments[0] -ceq '-I' -and $script:probeArguments[1] -ceq '-S' -and $script:probeArguments[2] -ceq '-B' -and $script:probeEnvironment.PYTHONDONTWRITEBYTECODE -ceq '1' -and $script:probeEnvironment.HERMES_HOME -ceq $script:paths.HermesHome) 'Read-only status uses the original home and disables site startup and bytecode writes'
    $probe = [string]$script:probeArguments[-1]
    Assert-CodexRuntime ($probe.Contains('sys.addaudithook') -and $probe.Contains('socket.connect') -and $probe.Contains('os.rename') -and $probe.Contains('subprocess.')) 'Existing-auth probe blocks writes, sockets, and child commands'
    Assert-CodexRuntime ($probe.Contains('winreg.') -and $probe.Contains('os.spawn') -and $probe.Contains('os.startfile') -and $probe.Contains('socket.__new__')) 'Existing-auth probe also blocks registry mutation and alternate spawn or socket entry points'
    Assert-CodexRuntime ($probe.Contains('get_codex_model_ids()') -and -not $probe.Contains('access_token=') -and -not $probe.Contains('auth add')) 'Offline model discovery never receives tokens or forces login'
    Assert-CodexRuntime ($probe.Contains('resolve_codex_runtime_credentials(read_only=True)') -and -not $probe.Contains('get_codex_auth_status')) 'Existing auth bypasses credential pool heal and automatic status writes'
    Assert-CodexRuntime ($probe.Contains('except AuthError as exc:') -and $probe.Contains('codex_auth_missing') -and -not $probe.Contains('except Exception:' + "`n" + '        credentials = {}')) 'Only genuine missing credentials are treated as absent, not compatibility errors'
    $script:probeOutput = '{"LoggedIn":false,"Models":["existing-model"],"PreferredModel":"existing-model"}'
    $result = Get-HermesCodexStatus -UseExistingHermes
    Assert-CodexRuntime (-not $result.LoggedIn -and $result.Summary.Contains('새 로그인은 실행하지 않았습니다')) 'Unavailable existing credentials are reported without starting login'
    $script:probeOutput = '{"LoggedIn":true,"Models":["bad model token"],"PreferredModel":""}'
    $rejected = $false
    try { $null = Get-HermesCodexStatus -UseExistingHermes } catch { $rejected = -not $_.Exception.Message.Contains('bad model token') }
    Assert-CodexRuntime $rejected 'Malformed model responses fail without reflecting raw output'
    $script:probeOutput = '{"LoggedIn":"true","Models":["existing-model"],"PreferredModel":"existing-model"}'
    $rejected = $false
    try { $null = Get-HermesCodexStatus -UseExistingHermes } catch { $rejected = $true }
    Assert-CodexRuntime $rejected 'Existing auth readiness requires a Boolean status'
    Write-Host ('Codex runtime error tests passed: ' + $script:passed)
}
