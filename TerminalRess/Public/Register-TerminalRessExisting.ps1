function Register-TerminalRessExisting {
    <#
    .SYNOPSIS
        Starts tracking PowerShell tabs that were already open before TerminalRess was installed.
    .DESCRIPTION
        For every live PowerShell shell under a Windows Terminal in THIS Windows session that has no tab file yet,
        writes a seeded one: shellPid/shellStart/shellExe/session, the owning WT, and the cwd when it is known
        (the cwd of a running Claude Code session; otherwise null, so the tab restores in the default directory).
        pendingCommand is a placeholder, so a Claude Code child is resumed through the handler; other programs are
        not re-run (nothing typed is known). No environment is stored for seeded tabs.
        Tabs that already have a tab file are left alone.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Initialize-TRDirs
    $sid = Get-TRSessionId
    $snap = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath, CreationDate, SessionId)
    $byParent = @{}
    foreach ($p in $snap) { if (-not $byParent.ContainsKey([int]$p.ParentProcessId)) { $byParent[[int]$p.ParentProcessId] = @() }; $byParent[[int]$p.ParentProcessId] += $p }
    $seeded = @()
    foreach ($wt in @($snap | Where-Object { $_.Name -ieq 'WindowsTerminal.exe' -and $_.SessionId -eq $sid })) {
        try { $wtStart = [Diagnostics.Process]::GetProcessById([int]$wt.ProcessId).StartTime.Ticks } catch { continue }
        $hosts = @($wt) + @($byParent[[int]$wt.ProcessId] | Where-Object { $_.Name -ieq "OpenConsole.exe" })   # shells hang off WT directly or via OpenConsole
        foreach ($oc in $hosts) {
            foreach ($sh in @($byParent[[int]$oc.ProcessId] | Where-Object { $_.Name -in 'powershell.exe', 'pwsh.exe' })) {
                $file = Join-Path $script:TR_Live "$($sh.ProcessId).json"
                if (Test-Path -LiteralPath $file) { continue }
                $cwd = $null
                $claude = @($byParent[[int]$sh.ProcessId] | Where-Object { $_.Name -ieq 'claude.exe' } | Select-Object -First 1)[0]
                if ($claude) {
                    $sf = Join-Path (Get-TRClaudeSessionsDir) "$($claude.ProcessId).json"
                    if (Test-Path -LiteralPath $sf) { $s = Read-TRJson $sf; if ($s) { $cwd = $s.cwd } }
                }
                $o = [ordered]@{
                    shellPid = [int]$sh.ProcessId; shellStart = $sh.CreationDate.Ticks; shellExe = $sh.ExecutablePath; session = $sid; wtSession = $null
                    wtPid = [int]$wt.ProcessId; wtStart = $wtStart; exiting = $false; seeded = $true
                    cwd = $cwd; envDiff = $null; lastCommand = $null; pendingCommand = '(seeded by Register-TerminalRessExisting)'
                    updatedAt = [DateTime]::UtcNow.ToString('o')
                }
                if ($PSCmdlet.ShouldProcess("shell $($sh.ProcessId)", 'Seed tab file')) {
                    Write-TRJson $file $o
                    $seeded += [pscustomobject]@{ ShellPid = [int]$sh.ProcessId; Cwd = $cwd; ClaudeChild = [bool]$claude }
                }
            }
        }
    }
    $seeded
}
