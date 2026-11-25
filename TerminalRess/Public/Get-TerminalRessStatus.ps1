function Get-TerminalRessStatus {
    <#
    .SYNOPSIS
        Shows the guardian state, the tracked tabs and the saved (last) generation.
    #>
    [CmdletBinding()]
    param()
    $tabs = foreach ($f in Get-TRTabFiles $script:TR_Live) {
        $t = Read-TRJson $f.FullName
        if (-not $t) { continue }
        $run = Read-TRJson (Get-TRRunPath $f.FullName)
        [pscustomobject]@{
            ShellPid = $t.shellPid; Alive = (Test-TRShellAlive $t); Cwd = $t.cwd
            Running  = if ($run) { $run.name } else { $null }
            Resume   = if ($run -and $run.resume) { $run.resume.sessionId } else { $null }
            Pending  = $t.pendingCommand; LastCommand = $t.lastCommand; Updated = $t.updatedAt
        }
    }
    $last = foreach ($x in Get-TRLastTabs) { [pscustomobject]@{ ShellPid = $x.Tab.shellPid; Cwd = $x.Tab.cwd; Pending = $x.Tab.pendingCommand; LastCommand = $x.Tab.lastCommand } }
    $pidFile = Join-Path $script:TR_State 'guardian.pid'
    [pscustomobject]@{
        State            = $script:TR_State
        GuardianRunning  = Test-TRGuardianRunning
        GuardianPid      = if (Test-Path -LiteralPath $pidFile) { [int](Get-Content -LiteralPath $pidFile -Raw) } else { $null }
        ModuleVersion    = Get-TRModuleVersion $script:TR_ModuleRoot
        RuntimeVersion   = if ([IO.Directory]::Exists($script:TR_InstalledRuntime)) { Get-TRRuntimeVersion } else { $null }
        WindowsTerminal  = Get-TRWtPath
        TrackedTabs      = @($tabs)
        LastGeneration   = @($last)
        ProfileInstalled = Test-TRProfileInstalled $PROFILE.CurrentUserCurrentHost
        Config           = Get-TRConfig -Fresh
    }
}
