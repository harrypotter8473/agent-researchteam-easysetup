Set-StrictMode -Version 2.0

# Keep the original DPAPI entropy and helper names so existing encrypted
# server/bot credentials and wizard transport remain readable after upgrade.
$script:LabInputEntropy = [System.Text.Encoding]::UTF8.GetBytes('HermesEasySetup.LabInput.v1')

function Protect-HermesLabInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$LiteralPath
    )
    Add-Type -AssemblyName System.Security
    $json = $Value | ConvertTo-Json -Depth 12 -Compress
    $plain = [System.Text.Encoding]::UTF8.GetBytes($json)
    try {
        $encrypted = [System.Security.Cryptography.ProtectedData]::Protect($plain, $script:LabInputEntropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $parent = Split-Path -Parent $LiteralPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($LiteralPath, $encrypted)
    } finally {
        [Array]::Clear($plain, 0, $plain.Length)
    }
    return [System.IO.Path]::GetFullPath($LiteralPath)
}

function Unprotect-HermesLabInput {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    Add-Type -AssemblyName System.Security
    $encrypted = [System.IO.File]::ReadAllBytes($LiteralPath)
    $plain = $null
    try {
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($encrypted, $script:LabInputEntropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return ([System.Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json)
    } finally {
        if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
    }
}

Export-ModuleMember -Function @('Protect-HermesLabInput','Unprotect-HermesLabInput')
