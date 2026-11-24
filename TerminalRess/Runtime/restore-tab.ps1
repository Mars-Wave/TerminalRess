# Runs inside a restored tab. The shell is started with -NoProfile and this file is DOT-SOURCED at the prompt level
# (powershell -NoProfile -NoExit -Command ". restore-tab.ps1 <tabfile>"), so everything defined here and by the
# profiles lands in the global scope, exactly as in a normal shell.
param([Parameter(Mandatory)][string]$TabFile)

. (Join-Path $PSScriptRoot 'Common.ps1')
$rtTab = Read-TRJson $TabFile
if (-not $rtTab) { Write-Host "TerminalRess: cannot read $TabFile" -ForegroundColor Red; return }
$rtRun = Read-TRJson (Get-TRRunPath $TabFile)
$rtCfg = Get-TRConfig

# 1. pristine baseline (so the hook's diff covers everything restored + profile effects), 2. saved environment
$global:TerminalRessBaseline = [Environment]::GetEnvironmentVariables('Process')
Set-TREnvDiff $rtTab.envDiff

# 3. profiles see the restored env and can skip interactive setup: TERMINALRESS_RESTORING=1 (always) plus the explicit
#    config.profileEnv variables; those are removed again after the profile unless the saved tab has the variable itself
$env:TERMINALRESS_RESTORING = '1'
$rtPe = @{}
if ($rtCfg.profileEnv) {
    $rtEntries = if ($rtCfg.profileEnv -is [System.Collections.IDictionary]) { $rtCfg.profileEnv.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = $_.Key; Value = $_.Value } } } else { $rtCfg.profileEnv.PSObject.Properties }
    foreach ($rtE in $rtEntries) {
        $rtPe[[string]$rtE.Name] = $true
        if ($null -eq $rtTab.envDiff -or -not $rtTab.envDiff.PSObject.Properties[[string]$rtE.Name]) { [Environment]::SetEnvironmentVariable([string]$rtE.Name, [string]$rtE.Value, 'Process') }
    }
}
$rtProfiles = if ($env:TERMINALRESS_PROFILES) { @($env:TERMINALRESS_PROFILES -split ';') } else { @($PROFILE.AllUsersAllHosts, $PROFILE.AllUsersCurrentHost, $PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) }
foreach ($rtP in $rtProfiles) {
    if ($rtP -and (Test-Path -LiteralPath $rtP)) {
        try { . $rtP } catch { Write-Host "TerminalRess: profile error in $rtP : $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}
Remove-Item Env:\TERMINALRESS_RESTORING -ErrorAction SilentlyContinue
foreach ($rtN in $rtPe.Keys) {
    if ($null -eq $rtTab.envDiff -or -not $rtTab.envDiff.PSObject.Properties[$rtN]) { [Environment]::SetEnvironmentVariable($rtN, $null, 'Process') }
}

# 4. working directory, 5. command
if ($rtTab.cwd -and (Test-Path -LiteralPath $rtTab.cwd -PathType Container)) { Set-Location -LiteralPath $rtTab.cwd }
if ($rtTab.lastCommand -and $global:__TR) { $global:__TR.LastCommand = [string]$rtTab.lastCommand }
$rtAct = Get-TRTabAction $rtTab $rtRun $rtCfg
if ($rtAct) { . $global:TRRunAction $rtAct }
else { if (Get-Command TR_MarkRunning -ErrorAction SilentlyContinue) { try { TR_Snapshot; TR_WriteState } catch { } } }
Remove-Variable rtTab, rtRun, rtCfg, rtProfiles, rtP, rtAct, rtPe, rtEntries, rtE, rtN, TabFile -ErrorAction SilentlyContinue
