function Restore-TerminalRess {
    <#
    .SYNOPSIS
        Restores the last generation of tabs now, as ONE new Windows Terminal window.
    .DESCRIPTION
        Normally not needed: opening any terminal restores automatically. Use this to force it.
        With -DryRun the wt.exe command line is returned and nothing is moved or launched.
    #>
    [CmdletBinding()]
    param([switch]$DryRun)
    Invoke-TRSweep
    $r = Invoke-TRRestoreAll -DryRun:$DryRun
    if ($null -eq $r) { Write-Verbose 'Nothing to restore.'; return }
    $r
}
