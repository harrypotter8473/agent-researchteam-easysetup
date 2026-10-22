[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$errors = New-Object System.Collections.Generic.List[object]
$scripts = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' })

foreach ($scriptFile in $scripts) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    foreach ($parseError in @($parseErrors)) {
        $errors.Add([pscustomobject]@{
            File = $scriptFile.FullName
            Line = $parseError.Extent.StartLineNumber
            Message = $parseError.Message
        })
    }
}

$bomFiles = @($scripts) + @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'ui') -Filter '*.xaml' -File)
foreach ($file in $bomFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        $errors.Add([pscustomobject]@{
            File = $file.FullName
            Line = 1
            Message = 'Windows PowerShell 5.1용 UTF-8 BOM이 없습니다.'
        })
    }
}

if ($errors.Count -gt 0) {
    $errors.ToArray() | Format-Table -AutoSize
    exit 1
}

Write-Host "PASS PowerShell syntax and UTF-8 BOM ($($scripts.Count) scripts)" -ForegroundColor Green
exit 0
