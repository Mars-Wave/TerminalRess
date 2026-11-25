# Run at logon by the Startup shortcut (through startup.vbs, hidden): start the guardian and, if a previous
# generation is waiting in last\, launch Windows Terminal. Its first tab restores everything (see pre-adopt.ps1).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Initialize-TRDirs
$cfg = Get-TRConfig
$null = Start-TRGuardianProcess
Invoke-TRSweep
if (-not $cfg.restoreOnLogon) { return }
if ((Get-TRTabFiles $TR_Last).Count -eq 0) { return }
if (@(Get-TRWtProcesses (Get-TRSessionId)).Count -gt 0) { return }
$wt = Get-TRWtPath
if ($wt) { Start-TRProcess $wt '' }
