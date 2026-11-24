function Start-TerminalRessGuardian {
    <#
    .SYNOPSIS
        Starts the hidden guardian process (no-op if it is already running). Returns $true if it was started.
    #>
    [CmdletBinding()]
    param()
    $started = Start-TRGuardianProcess
    if (-not $started) { Write-Verbose 'Guardian already running.' }
    $started
}
