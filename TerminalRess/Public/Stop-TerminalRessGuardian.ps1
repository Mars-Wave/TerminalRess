function Stop-TerminalRessGuardian {
    <#
    .SYNOPSIS
        Stops the guardian (only the process recorded in guardian.pid, and only if it really is a guardian).
    #>
    [CmdletBinding()]
    param()
    $pidFile = Join-Path $script:TR_State 'guardian.pid'
    if (-not (Test-Path -LiteralPath $pidFile)) { return $false }
    $gpid = [int](Get-Content -LiteralPath $pidFile -Raw)
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$gpid" -ErrorAction SilentlyContinue
    if ($p -and $p.CommandLine -like '*guardian.ps1*') {
        Stop-Process -Id $gpid -Force
        Wait-Process -Id $gpid -Timeout 5 -ErrorAction SilentlyContinue   # its mutex lives until it is gone
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    $false
}
