# Test-only verbatim upstream helper from NousResearch/hermes-agent
# fcbd1076a93841fa88855acce810e342a5b78101, scripts/install.ps1 (MIT).
# Canonical function SHA256: 397bbaee6c434d6527eeb11125ab2b19ed89c89ae5890475d72d71fab110997e
function Set-PathVariable {
    Write-Info "Setting up hermes command..."
    
    if ($NoVenv) {
        $hermesBin = "$InstallDir"
    } else {
        # Expose ONLY the hermes launchers on PATH -- never the whole
        # venv\Scripts directory. venv\Scripts contains python.exe /
        # pythonw.exe / pip.exe, and putting it on the user PATH silently
        # hijacks the `python` command in every terminal on the machine
        # (#83797): unrelated projects start resolving python to Hermes'
        # runtime interpreter. A dedicated bin dir with copies of the
        # launcher exes keeps `hermes` globally available without
        # shadowing anything. (Launcher exes embed the venv interpreter
        # path, so they work from any location and survive updates.)
        $hermesBin = "$InstallDir\bin"
        New-Item -ItemType Directory -Force -Path $hermesBin | Out-Null
        foreach ($launcher in @("hermes.exe", "hermes-acp.exe")) {
            $src = "$InstallDir\venv\Scripts\$launcher"
            if (Test-Path $src) {
                Copy-Item -Force $src "$hermesBin\$launcher"
            }
        }
    }
    
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")

    # Migrate installs that got venv\Scripts onto PATH from earlier
    # installer versions -- remove it so the python shadowing stops.
    $legacyBin = "$InstallDir\venv\Scripts"
    if ((-not $NoVenv) -and $currentPath -like "*$legacyBin*") {
        $cleaned = ($currentPath -split ';' | Where-Object { $_ -and $_ -ne $legacyBin }) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $cleaned, "User")
        $currentPath = $cleaned
        Write-Info "Removed legacy venv\Scripts from user PATH (kept hermes via $hermesBin)"
    }
    
    if ($currentPath -notlike "*$hermesBin*") {
        [Environment]::SetEnvironmentVariable(
            "Path",
            "$hermesBin;$currentPath",
            "User"
        )
        Write-Success "Added to user PATH: $hermesBin"
    } else {
        Write-Info "PATH already configured"
    }
    
    # Set HERMES_HOME so the Python code finds config/data in the right place.
    # Only needed on Windows where we install to %LOCALAPPDATA%\hermes instead
    # of the Unix default ~/.hermes
    $currentHermesHome = [Environment]::GetEnvironmentVariable("HERMES_HOME", "User")
    if (-not $currentHermesHome -or $currentHermesHome -ne $HermesHome) {
        [Environment]::SetEnvironmentVariable("HERMES_HOME", $HermesHome, "User")
        Write-Success "Set HERMES_HOME=$HermesHome"
    }
    $env:HERMES_HOME = $HermesHome
    
    # Update current session
    $env:Path = "$hermesBin;$env:Path"
    
    Write-Success "hermes command ready"
}

