param([Parameter(Mandatory=$true)][string]$RegistrySubKey,[Parameter(Mandatory=$true)][string]$HermesHome,[Parameter(Mandatory=$true)][string]$InstallDir)
$ErrorActionPreference='Stop'
if ($RegistrySubKey -cnotmatch '^Software\\NST\.InstallRecovery\.Tests\\[0-9a-f]{32}$') { throw 'Fixture key escaped its private test root' }
Add-Type -TypeDefinition @'
using System;
using Microsoft.Win32;
namespace NST { public static class RecoveryFixtureEnvironment {
 public static string Key;
 static void Check(string name,string scope) {
  if(scope!="User" || (name!="Path" && name!="HERMES_HOME" && name!="HERMES_GIT_BASH_PATH")) throw new InvalidOperationException("Fixture API boundary");
  if(Key==null || !Key.StartsWith("Software\\NST.InstallRecovery.Tests\\",StringComparison.Ordinal)) throw new InvalidOperationException("Fixture key boundary");
 }
 public static string GetEnvironmentVariable(string name,string scope) {
  Check(name,scope); using(var key=Registry.CurrentUser.OpenSubKey(Key)) { return key.GetValue(name) as string; }
 }
 public static void SetEnvironmentVariable(string name,string value,string scope) {
  Check(name,scope); using(var key=Registry.CurrentUser.OpenSubKey(Key,true)) { if(value==null)key.DeleteValue(name,false); else key.SetValue(name,value,RegistryValueKind.String); }
 }
}}
'@
[NST.RecoveryFixtureEnvironment]::Key=$RegistrySubKey
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'upstream-path-stage.ps1'),[ref]$tokens,[ref]$errors)
$function=@($ast.FindAll({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq 'Set-PathVariable'},$true))
if ($errors.Count -ne 0 -or $function.Count -ne 1) { throw 'Invalid upstream fixture' }
# Test-only API redirection. Production executes the unchanged full installer.
. ([scriptblock]::Create($function[0].Extent.Text.Replace('[Environment]','[NST.RecoveryFixtureEnvironment]')))
function Write-Info {param($Message)}
function Write-Success {param($Message)}
$NoVenv=$false
Set-PathVariable
[pscustomobject]@{stage='path';ok=$true;skipped=$false;reason=$null;duration_ms=0}|ConvertTo-Json -Compress
exit 0
