Set-StrictMode -Version 2.0

function New-HermesCodexEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$HermesHome,
        [Parameter(Mandatory = $true)][string]$InstallDir
    )
    $environment = Get-HermesCuratedProcessEnvironment
    $environment['HERMES_HOME'] = $HermesHome
    $environment['VIRTUAL_ENV'] = Join-Path $InstallDir 'venv'
    $environment['PYTHONHOME'] = $null
    $environment['PYTHONPATH'] = $null
    $environment['PYTHONUSERBASE'] = $null
    $environment['PYTHONSTARTUP'] = $null
    $environment['PYTHONINSPECT'] = $null
    $environment['PYTHONNOUSERSITE'] = '1'
    $environment['PYTHONSAFEPATH'] = '1'
    return $environment
}

function Get-HermesCodexRuntime {
    [CmdletBinding()]
    param([string]$HermesHome, [string]$InstallDir, [string]$RuntimeRoot, [switch]$UseExistingHermes)
    if ($UseExistingHermes) {
        # An explicit trust choice, not a fallback or a forged pinned attestation.
        $existingPaths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
        return (Get-HermesExistingRuntime -HermesHome $existingPaths.HermesHome -InstallDir $existingPaths.InstallDir -RuntimeRoot $existingPaths.RuntimeRoot)
    }
    $paths = Get-HermesDefaultPaths -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    $verificationLog = Join-Path ([System.IO.Path]::GetTempPath()) ('hermes-easy-setup-codex-verify-' + [guid]::NewGuid().ToString('N') + '.log')
    try {
        # OAuth status refresh runs repeatedly inside the GUI. A full installation
        # verification also launches `hermes doctor`, which can take several
        # minutes and makes a completed device login look frozen. Static
        # provenance already verifies the pinned checkout, launchers, marker,
        # exclusions, and launcher attestation; the auth command itself is the
        # bounded runtime check for this flow.
        $verification = Test-HermesInstallation -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir -RuntimeRoot $paths.RuntimeRoot -StaticOnly -LogPath $verificationLog
    } finally {
        if (Test-Path -LiteralPath $verificationLog -PathType Leaf) { Remove-Item -LiteralPath $verificationLog -Force -ErrorAction SilentlyContinue }
    }
    if (-not $verification.StaticProvenanceValid) {
        $installationFound = ([bool]$verification.CheckoutPresent -or [bool]$verification.VenvPythonPresent)
        $detail = New-Object System.Collections.Generic.List[string]
        if ($installationFound) {
            $detail.Add('검증된 Hermes 설치가 필요합니다. Hermes 설치 폴더는 발견했지만, 이 마법사가 요구하는 고정 버전·설치 검증 기록과 일치하지 않습니다. Hermes가 미설치라는 뜻은 아닙니다.')
        } else {
            $detail.Add('검증된 Hermes 설치가 필요합니다. 현재 확인 경로에서 검증할 설치를 찾지 못했습니다. 다른 위치에 설치된 Hermes까지 없다는 뜻은 아닙니다.')
        }
        $detail.Add("확인 경로: $($paths.InstallDir)")
        if ([string]$verification.ExpectedCommit -cmatch '^[0-9a-fA-F]{40}$') {
            $detail.Add("마법사 요구 commit: $($verification.ExpectedCommit)")
        }
        if ([string]$verification.MarkerPinnedCommit -cmatch '^[0-9a-fA-F]{40}$') {
            $detail.Add("설치 기록 commit: $($verification.MarkerPinnedCommit)")
        }
        if ($installationFound -and -not [bool]$verification.RepositoryMetadataSafe) {
            $detail.Add('Git 구조·설정이 이 마법사의 허용 조건과 달라 일부 검사를 진행하지 못했습니다. 아래 항목 모두가 각각 손상되었다는 뜻은 아닙니다.')
        }
        $detail.Add('기존 설치가 있으면 삭제하거나 재설치를 강행하지 말고 경로·버전·검증 기록을 먼저 확인하세요. 기존 Hermes 설치는 변경하지 않았습니다.')
        $detail.Add("통과하지 못했거나 확인하지 못한 검사: $(@($verification.FailedChecks) -join ', ')")
        throw ($detail -join [Environment]::NewLine)
    }
    $command = Join-Path $paths.InstallDir 'bin\hermes.exe'
    if (-not (Test-Path -LiteralPath $command -PathType Leaf)) { throw 'Hermes 실행 파일을 찾지 못했습니다.' }
    $python = Join-Path $paths.InstallDir 'venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Hermes Python 실행 파일을 찾지 못했습니다.' }
    return [pscustomobject]@{
        Paths = $paths
        Command = $command
        Python = $python
        Environment = New-HermesCodexEnvironment -HermesHome $paths.HermesHome -InstallDir $paths.InstallDir
    }
}

function Get-HermesExistingCodexStatus {
    [CmdletBinding()]
    param([string]$HermesHome, [string]$InstallDir, [string]$RuntimeRoot)
    $runtime = Get-HermesCodexRuntime -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot -UseExistingHermes
    $runtime.Environment['PYTHONDONTWRITEBYTECODE'] = '1'
    # Do not run `auth add`, copy auth.json, refresh credentials, or pass a token
    # to model discovery. The probe only emits booleans and model identifiers.
    # Python's audit hook also blocks attempted writes, subprocesses and sockets
    # in older Hermes implementations whose status helper is not read-only.
    $program = @'
import sys, os, json, re, io, contextlib
sys.dont_write_bytecode = True
def readonly_audit(event, args):
    if event == "open":
        mode = args[1] if len(args) > 1 else None
        flags = args[2] if len(args) > 2 else 0
        if (isinstance(mode, str) and any(c in mode for c in "wax+")) or (isinstance(flags, int) and flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND)):
            raise PermissionError("HermesExistingReadOnlyProbe:" + event)
    if event == "os.mkdir" and args and os.path.isdir(args[0]):
        return
    if event.startswith(("winreg.", "os.spawn", "os.exec", "os.startfile", "subprocess.")) or event in ("os.mkdir", "os.remove", "os.rename", "os.rmdir", "os.link", "os.symlink", "os.truncate", "os.chmod", "os.utime", "os.chown", "os.system", "socket.__new__", "socket.connect", "socket.bind", "socket.getaddrinfo"):
        raise PermissionError("HermesExistingReadOnlyProbe:" + event)
sys.addaudithook(readonly_audit)
# -I -S prevents .pth/sitecustomize from running before the audit hook.
# Add only the checked source install and its venv packages, never site.main().
sys.path.insert(0, os.path.join(os.getcwd(), "venv", "Lib", "site-packages"))
sys.path.insert(0, os.getcwd())
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    from hermes_cli.auth import resolve_codex_runtime_credentials, AuthError
    from hermes_cli.codex_models import get_codex_model_ids
    try:
        credentials = resolve_codex_runtime_credentials(read_only=True)
    except AuthError as exc:
        if getattr(exc, "code", None) != "codex_auth_missing":
            raise
        credentials = {}
    found = bool(credentials.get("api_key"))
    models = get_codex_model_ids()
    preferred = ""
    try:
        from hermes_cli.config import read_raw_config
        model = read_raw_config().get("model", {})
        if isinstance(model, dict) and model.get("provider") == "openai-codex":
            preferred = model.get("default", "")
    except PermissionError:
        raise
    except Exception:
        pass
safe = lambda s: isinstance(s, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{1,127}", s) is not None
models = list(dict.fromkeys(m for m in models if safe(m)))
preferred = preferred if safe(preferred) else ""
if preferred and preferred not in models:
    models.insert(0, preferred)
print(json.dumps({"LoggedIn": found, "Models": models, "PreferredModel": preferred}))
'@
    $result = Invoke-HermesProcess -FilePath $runtime.Python -ArgumentList @('-I', '-S', '-B', '-c', $program) -WorkingDirectory $runtime.Paths.InstallDir -Environment $runtime.Environment -TimeoutSeconds 45
    if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) {
        throw '기존 Hermes의 읽기 전용 인증·모델 확인을 완료하지 못했습니다. 인증은 수정하지 않았습니다. 이 설치의 상태 조회 API 호환성을 확인하세요.'
    }
    try {
        $status = $result.StdOut.Trim() | ConvertFrom-Json
        if ($status.LoggedIn -isnot [bool]) { throw 'InvalidStatus' }
        $models = @($status.Models | Where-Object { $_ -is [string] -and $_ -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$' } | Select-Object -Unique)
        if ($models.Count -eq 0 -or $models.Count -ne @($status.Models).Count) { throw 'InvalidModels' }
        $preferred = [string]$status.PreferredModel
        if ($preferred -and $models -cnotcontains $preferred) { throw 'InvalidPreferredModel' }
    } catch { throw '기존 Hermes의 상태 응답을 확인하지 못했습니다. 기존 인증·설정은 변경하지 않았습니다.' }
    return [pscustomobject][ordered]@{
        LoggedIn = [bool]$status.LoggedIn; Provider = 'openai-codex'; Models = $models; PreferredModel = $preferred
        RuntimeKind = 'Existing'; Version = [string]$runtime.Version; ReadOnly = $true
        Summary = $(if ($status.LoggedIn) { '기존 Hermes와 저장된 Codex 인증을 발견했습니다. 외부 로그인 유효성 검사는 하지 않았으며 인증·기존 설정은 변경하지 않았습니다.' } else { '기존 Hermes는 인식했습니다. 저장된 Codex 인증을 찾지 못했습니다. 기존 Hermes에서 계정 상태를 확인하세요. 새 로그인은 실행하지 않았습니다.' })
    }
}

function Get-HermesCodexModels {
    [CmdletBinding()]
    param([string]$HermesHome, [string]$InstallDir, [string]$RuntimeRoot)
    $runtime = Get-HermesCodexRuntime -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    $program = 'import json; from hermes_cli.auth import get_codex_auth_status; from hermes_cli.codex_models import get_codex_model_ids; s=get_codex_auth_status(); print(json.dumps(get_codex_model_ids(access_token=s.get("api_key") if s.get("logged_in") else None)))'
    $result = Invoke-HermesProcess -FilePath $runtime.Python -ArgumentList @('-c', $program) -WorkingDirectory $runtime.Paths.InstallDir -Environment $runtime.Environment -TimeoutSeconds 45
    if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) { throw 'Hermes Codex 모델 목록을 읽지 못했습니다.' }
    try { $models = @($result.StdOut.Trim() | ConvertFrom-Json) } catch { throw 'Hermes Codex 모델 목록 형식이 올바르지 않습니다.' }
    $safeModels = @($models | ForEach-Object { [string]$_ } | Where-Object { $_ -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{1,127}$' } | Select-Object -Unique)
    if ($safeModels.Count -eq 0) { throw '선택 가능한 OpenAI Codex 모델이 없습니다.' }
    return $safeModels
}

function Get-HermesCodexStatus {
    [CmdletBinding()]
    param([string]$HermesHome, [string]$InstallDir, [string]$RuntimeRoot, [switch]$UseExistingHermes)
    if ($UseExistingHermes) {
        return (Get-HermesExistingCodexStatus -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot)
    }
    $runtime = Get-HermesCodexRuntime -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    $result = Invoke-HermesProcess -FilePath $runtime.Command -ArgumentList @('auth', 'status', 'openai-codex') -WorkingDirectory $runtime.Paths.InstallDir -Environment $runtime.Environment -TimeoutSeconds 45
    $text = (($result.StdOut + [Environment]::NewLine + $result.StdErr).Trim())
    $loggedIn = ($result.Started -and -not $result.TimedOut -and $result.ExitCode -eq 0 -and $text -match '(?i)logged in|authenticated|credentials:\s*[✓✔]')
    $models = @()
    try { $models = @(Get-HermesCodexModels -HermesHome $runtime.Paths.HermesHome -InstallDir $runtime.Paths.InstallDir -RuntimeRoot $runtime.Paths.RuntimeRoot) } catch { $models = @('gpt-5.6-terra') }
    return [pscustomobject][ordered]@{
        LoggedIn = $loggedIn
        Provider = 'openai-codex'
        Models = $models
        Summary = $(if ($loggedIn) { 'OpenAI Codex 인증됨' } else { 'OpenAI Codex 로그인이 필요함' })
    }
}

function Invoke-HermesCodexAuthentication {
    [CmdletBinding()]
    param(
        [string]$HermesHome,
        [string]$InstallDir,
        [string]$RuntimeRoot,
        [AllowNull()][scriptblock]$ProgressCallback
    )
    $runtime = Get-HermesCodexRuntime -HermesHome $HermesHome -InstallDir $InstallDir -RuntimeRoot $RuntimeRoot
    [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'stage' -Stage 'codex-auth' -State 'running' -Message 'OpenAI Codex 일회용 인증 코드를 요청하고 있습니다.' -Percent 20)
    $runtime.Environment['PYTHONUNBUFFERED'] = '1'
    $oauthState = @{
        URL = 'https://auth.openai.com/codex/device'
        ExpectCode = $false
        UserCode = $null
        Published = $false
    }
    $lineCallback = {
        param([string]$StreamName, [AllowNull()][string]$Line)
        if ($StreamName -cne 'StdOut' -or [string]::IsNullOrWhiteSpace($Line) -or [bool]$oauthState.Published) { return }
        $clean = [regex]::Replace($Line, '\x1B\[[0-?]*[ -/]*[@-~]', '').Trim()
        if ($clean -match '(?i)^2\.\s+Enter this code:') {
            $oauthState.ExpectCode = $true
            return
        }
        if ([bool]$oauthState.ExpectCode -and $clean -cmatch '^[A-Z0-9][A-Z0-9-]{3,63}$') {
            $oauthState.UserCode = $clean
            $oauthState.Published = $true
            $data = [pscustomobject][ordered]@{ URL = [string]$oauthState.URL; UserCode = [string]$oauthState.UserCode }
            [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'oauth' -Stage 'codex-auth' -State 'awaiting-user' -Message '브라우저에서 로그인한 뒤 아래 일회용 코드를 입력하세요.' -Percent 45 -Data $data)
        }
    }.GetNewClosure()
    $result = Invoke-HermesProcess -FilePath $runtime.Command -ArgumentList @('auth', 'add', 'openai-codex', '--type', 'oauth', '--label', 'Hermes Easy Setup') -WorkingDirectory $runtime.Paths.InstallDir -Environment $runtime.Environment -TimeoutSeconds 900 -OutputLineCallback $lineCallback
    if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0) {
        $detail = Protect-HermesLogText ([string]$result.StdErr).Trim()
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = '로그인이 취소되었거나 제한 시간을 초과했습니다.' }
        throw "OpenAI Codex 인증을 완료하지 못했습니다: $detail"
    }
    $status = Get-HermesCodexStatus -HermesHome $runtime.Paths.HermesHome -InstallDir $runtime.Paths.InstallDir -RuntimeRoot $runtime.Paths.RuntimeRoot
    if (-not $status.LoggedIn) { throw 'OAuth 절차가 끝났지만 Hermes에서 OpenAI Codex 인증을 확인하지 못했습니다.' }
    [void](Publish-HermesEvent -Callback $ProgressCallback -Type 'complete' -Stage 'codex-auth' -State 'succeeded' -Message 'OpenAI Codex 인증을 확인했습니다.' -Percent 100 -Data $status)
    return $status
}

Export-ModuleMember -Function @(
    'Get-HermesCodexModels',
    'Get-HermesCodexStatus',
    'Invoke-HermesCodexAuthentication'
)
