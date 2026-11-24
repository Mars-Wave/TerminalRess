function Uninstall-TerminalRess {
    <#
    .SYNOPSIS
        Removes the profile hooks, the Startup shortcut, the runtime copy and stops the guardian.
    .PARAMETER Purge
        Also delete the state folder (live/last/archive, config.json, log).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('CurrentHost', 'AllHosts')][string]$ProfileScope = 'CurrentHost',
        [string]$ProfilePath,
        [string]$StartupFolder,
        [switch]$Purge
    )
    if (-not $ProfilePath) { $ProfilePath = if ($ProfileScope -eq 'AllHosts') { $PROFILE.CurrentUserAllHosts } else { $PROFILE.CurrentUserCurrentHost } }
    $res = [ordered]@{ ProfileChanged = $false; ProfileBackup = $null; ShortcutRemoved = $false; RuntimeRemoved = $false; Purged = $false }

    if ($PSCmdlet.ShouldProcess($ProfilePath, 'Remove TerminalRess hooks from profile')) {
        $p = Set-TRProfileBlocks -Path $ProfilePath -Remove
        $res.ProfileChanged = $p.Changed; $res.ProfileBackup = $p.Backup
    }
    $lnk = Get-TRStartupShortcutPath $StartupFolder
    if ((Test-Path -LiteralPath $lnk) -and $PSCmdlet.ShouldProcess($lnk, 'Remove shortcut')) { [IO.File]::Delete($lnk); $res.ShortcutRemoved = $true }
    if ($PSCmdlet.ShouldProcess('guardian', 'Stop')) { $null = Stop-TerminalRessGuardian }
    if ((Test-Path -LiteralPath $script:TR_InstalledRuntime) -and $PSCmdlet.ShouldProcess($script:TR_InstalledRuntime, 'Remove runtime')) {
        [IO.Directory]::Delete($script:TR_InstalledRuntime, $true); $res.RuntimeRemoved = $true
    }
    if ($Purge -and (Test-Path -LiteralPath $script:TR_State) -and $PSCmdlet.ShouldProcess($script:TR_State, 'Delete state')) {
        [IO.Directory]::Delete($script:TR_State, $true); $res.Purged = $true
    }
    [pscustomobject]$res
}
