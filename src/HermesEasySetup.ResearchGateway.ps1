Set-StrictMode -Version 2.0

# The research team's model router (team/gateway): LiteLLM on 127.0.0.1, routing every agent by
# role and by each paper's sensitivity. Provider keys live only in <research>\gateway\env, in a
# folder readable by the current user and SYSTEM; agents get per-task keys from their runner.
$script:ResearchGatewayPackages = @('litellm[proxy]==1.105.1', 'pyyaml==6.0.3')
$script:ResearchGatewayLitellmVersion = '1.105.1'

function New-HermesResearchRandomHex {
    param([int]$Bytes = 24)
    $buffer = New-Object byte[] $Bytes
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    return (($buffer | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Read-HermesResearchEnvValues {
    param([string]$LiteralPath)
    $values = [ordered]@{}
    if (Test-Path -LiteralPath $LiteralPath -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($LiteralPath, [Text.Encoding]::UTF8)) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') { $values[$Matches[1]] = $Matches[2].Trim() }
        }
    }
    return $values
}

function Write-HermesResearchEnvValues {
    param([string]$LiteralPath, $Values, [string]$Header)
    $lines = @("# $Header")
    foreach ($key in @($Values.Keys)) {
        $value = [string]$Values[$key]
        if ($value -match '[\r\n]') { throw 'ResearchEnvValueRejected' }
        if ($value) { $lines += ('{0}={1}' -f $key, $value) }
    }
    Write-HermesResearchAtomicText -LiteralPath $LiteralPath -Text (($lines -join "`n") + "`n")
}

function Get-HermesResearchGatewayState {
    <# Existing provider keys, for the wizard to restore into its password boxes. #>
    param([string]$RuntimeRoot)
    $envPath = Join-Path $RuntimeRoot 'research\gateway\env'
    $values = Read-HermesResearchEnvValues -LiteralPath $envPath
    return [pscustomobject]@{
        Installed = (Test-Path -LiteralPath (Join-Path $RuntimeRoot 'research\gateway\venv\Scripts\litellm.exe') -PathType Leaf)
        AnthropicKey = $(if ($values.Contains('ANTHROPIC_API_KEY')) { [string]$values['ANTHROPIC_API_KEY'] } else { '' })
        OpenAIKey = $(if ($values.Contains('OPENAI_API_KEY')) { [string]$values['OPENAI_API_KEY'] } else { '' })
    }
}

function Install-HermesResearchModelGateway {
    param(
        [Parameter(Mandatory = $true)]$Paths, [Parameter(Mandatory = $true)][string]$Python,
        [Parameter(Mandatory = $true)][string]$TeamRoot, [Parameter(Mandatory = $true)]$Model,
        [Parameter(Mandatory = $true)]$ModelSummary, [int]$Port, [string]$OwnerSID, [hashtable]$Environment,
        [AllowNull()][scriptblock]$ProgressCallback
    )
    $dir = Join-Path $Paths.RuntimeRoot 'research\gateway'
    Protect-HermesResearchPrivateDirectory -LiteralPath $dir -OwnerSID $OwnerSID
    $venvPython = Join-Path $dir 'venv\Scripts\python.exe'
    $litellm = Join-Path $dir 'venv\Scripts\litellm.exe'
    $versionProbe = 'import importlib.metadata as m; print(m.version("litellm"))'
    $installed = $false
    if ((Test-Path -LiteralPath $venvPython -PathType Leaf) -and (Test-Path -LiteralPath $litellm -PathType Leaf)) {
        $probe = Invoke-HermesProcess -FilePath $venvPython -ArgumentList @('-c', $versionProbe) -Environment $Environment -TimeoutSeconds 60
        $installed = ($probe.Started -and -not $probe.TimedOut -and $probe.ExitCode -eq 0 -and $probe.StdOut.Trim() -ceq $script:ResearchGatewayLitellmVersion)
    }
    if (-not $installed) {
        Publish-HermesResearchStage $ProgressCallback 'research-gateway' ('모델 라우터(LiteLLM {0})를 전용 Python 환경에 설치합니다. 몇 분 걸릴 수 있습니다.' -f $script:ResearchGatewayLitellmVersion) 30
        if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
            $venv = Invoke-HermesProcess -FilePath $Python -ArgumentList @('-m', 'venv', (Join-Path $dir 'venv')) -Environment $Environment -TimeoutSeconds 300
            if (-not $venv.Started -or $venv.TimedOut -or $venv.ExitCode -ne 0) { throw '모델 라우터용 Python 환경을 만들지 못했습니다.' }
        }
        $pip = Invoke-HermesProcess -FilePath $venvPython -ArgumentList (@('-m', 'pip', 'install', '--disable-pip-version-check', '--no-input', '--quiet') + $script:ResearchGatewayPackages) -Environment $Environment -TimeoutSeconds 1800
        if (-not $pip.Started -or $pip.TimedOut -or $pip.ExitCode -ne 0) { throw '모델 라우터(LiteLLM) 설치에 실패했습니다. 인터넷 연결을 확인하고 다시 실행하세요.' }
        $probe = Invoke-HermesProcess -FilePath $venvPython -ArgumentList @('-c', $versionProbe) -Environment $Environment -TimeoutSeconds 60
        if (-not $probe.Started -or $probe.ExitCode -ne 0 -or $probe.StdOut.Trim() -cne $script:ResearchGatewayLitellmVersion -or -not (Test-Path -LiteralPath $litellm -PathType Leaf)) { throw 'ResearchGatewayVersionMismatch' }
    }
    foreach ($name in @('research_gateway_policy.py', 'research_gateway_litellm.py', 'render_config.py')) {
        Copy-Item -LiteralPath (Join-Path $TeamRoot ('gateway\' + $name)) -Destination (Join-Path $dir $name) -Force -ErrorAction Stop
    }
    # routing.yaml is the user's to tune after the first install; the model list follows the wizard.
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'routing.yaml') -PathType Leaf)) {
        Copy-Item -LiteralPath (Join-Path $TeamRoot 'gateway\routing.yaml') -Destination (Join-Path $dir 'routing.yaml') -ErrorAction Stop
    }
    $spec = [ordered]@{ cloud = @($ModelSummary.Cloud); local = $null }
    if ($ModelSummary.LocalBaseURL) { $spec.local = [ordered]@{ base_url = $ModelSummary.LocalBaseURL; model = $ModelSummary.LocalModel; fast_model = $ModelSummary.LocalFastModel } }
    $specPath = Join-Path $dir 'models.json'
    Write-HermesResearchAtomicText -LiteralPath $specPath -Text ($spec | ConvertTo-Json -Depth 5)
    $render = Invoke-HermesProcess -FilePath $venvPython -ArgumentList @((Join-Path $dir 'render_config.py'), (Join-Path $TeamRoot 'gateway\litellm.config.yaml'), (Join-Path $dir 'litellm.config.yaml'), $specPath) -Environment $Environment -TimeoutSeconds 60
    if (-not $render.Started -or $render.TimedOut -or $render.ExitCode -ne 0) { throw 'ResearchGatewayConfigRenderFailed' }

    $envPath = Join-Path $dir 'env'
    $previous = Read-HermesResearchEnvValues -LiteralPath $envPath
    $secret = $(if ($previous.Contains('RESEARCH_GATEWAY_SECRET') -and [string]$previous['RESEARCH_GATEWAY_SECRET'] -cmatch '^[a-f0-9]{48}$') { [string]$previous['RESEARCH_GATEWAY_SECRET'] } else { New-HermesResearchRandomHex 24 })
    $master = $(if ($previous.Contains('LITELLM_MASTER_KEY') -and [string]$previous['LITELLM_MASTER_KEY'] -cmatch '^sk-[a-f0-9]{48}$') { [string]$previous['LITELLM_MASTER_KEY'] } else { 'sk-' + (New-HermesResearchRandomHex 24) })
    $get = { param($name) if ($Model -is [Collections.IDictionary]) { $Model[$name] } elseif ($Model.PSObject.Properties[$name]) { $Model.$name } else { $null } }
    $values = [ordered]@{
        RESEARCH_GATEWAY_SECRET = $secret; LITELLM_MASTER_KEY = $master
        ANTHROPIC_API_KEY = [string](& $get 'AnthropicKey'); OPENAI_API_KEY = [string](& $get 'OpenAIKey')
        PYTHONUTF8 = '1'
    }
    Write-HermesResearchEnvValues -LiteralPath $envPath -Values $values -Header 'Research team model router — provider keys. Managed by Hermes Easy Setup; re-run the wizard to change.'
    return [pscustomobject]@{ Dir = $dir; Port = $Port; Url = "http://127.0.0.1:$Port/v1"; Secret = $secret; Litellm = $litellm }
}
