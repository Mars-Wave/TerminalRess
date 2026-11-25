# TerminalRess guardian: single hidden instance per state dir. It records each tab's foreground child
# (live\<pid>.run.json) and owning Windows Terminal (live\<pid>.owner.json) and, when a tab shell dies, decides
# whether the user closed the tab or Windows Terminal ended. It loops every $IntervalSec while anything changes and
# every $IdleIntervalSec once nothing has for a few loops; a tab file change or a tab shell exit wakes it at once.
param([int]$IntervalSec = 3, [int]$IdleIntervalSec = 10, [switch]$Once)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
Initialize-TRDirs

$created = $false
$mutex = New-Object Threading.Mutex($false, (Get-TRMutexName 'Guardian'), [ref]$created)
if (-not $created -or (Test-TRLegacyGuardian)) { exit 0 }
[IO.File]::WriteAllText((Join-Path $TR_State 'guardian.pid'), [string]$PID, $TR_Utf8)

$selfVer = Get-TRRuntimeVersion $PSScriptRoot
$nextSync = [DateTime]::MinValue
$restart = $false
$waiter = $null
Write-TRLog "guardian started pid=$PID session=$(Get-TRSessionId) state=$TR_State version=$selfVer"

# Picks up Update-Module: copies the newest installed module's Runtime\ over an older runtime copy, and reports whether
# this guardian runs from that copy with older code (then it must restart to run the new one).
function Sync-Runtime {
    $null = Update-TRRuntime (Find-TRNewestModule)
    if ($PSScriptRoot.TrimEnd('\') -ne $TR_InstalledRuntime.TrimEnd('\')) { return $false }
    $v = Get-TRRuntimeVersion
    [bool]($v -and (-not $selfVer -or $v -gt $selfVer))
}

try {
    $G = New-TRGuardianState
    if (-not $Once) { try { $waiter = New-Object TRNative.Waiter $TR_Live } catch { Write-TRLog "no change notifications: $($_.Exception.Message)" } }
    do {
        if ([DateTime]::UtcNow -ge $nextSync) {
            $nextSync = [DateTime]::UtcNow.AddMinutes(5)
            try { $restart = Sync-Runtime } catch { Write-TRLog "runtime sync error: $($_.Exception.Message)" }
            if ($restart) { break }
        }
        try { $null = Invoke-TRGuardianTick $G } catch { Write-TRLog "tick error: $($_.Exception.Message)" }
        if ($Once) { break }
        $ms = 1000 * $(if ($G.Idle -ge $G.IdleAfter -and -not $G.Claude) { $IdleIntervalSec } else { $IntervalSec })
        if (-not $waiter) { Start-Sleep -Milliseconds $ms }
        elseif ($waiter.Wait($ms, $G.Alive.ToArray()) -ne 0) {
            $G.Idle = 0
            Start-Sleep -Milliseconds 500     # let the hook finish its write and a just-typed command start its process
            $waiter.Reset()
        }
    } while ($true)
} catch { Write-TRLog "guardian failed: $($_.Exception.Message)"; throw
} finally {
    if ($waiter) { $waiter.Dispose() }
    $mutex.Dispose()     # the named mutex must be gone before the replacement starts, or it would exit at once
    Remove-Item -LiteralPath (Join-Path $TR_State 'guardian.pid') -Force -ErrorAction SilentlyContinue
}
if ($restart) {
    Write-TRLog "guardian restarting on runtime $(Get-TRRuntimeVersion)"
    $null = Start-TRGuardianProcess
}
