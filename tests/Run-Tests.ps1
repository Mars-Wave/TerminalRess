# Plain-assertion test runner (Pester 5 is not assumed to be installed).  Usage:  powershell -File tests\Run-Tests.ps1
# Non-destructive: uses a throw-away state dir (TERMINALRESS_STATE), never touches real tabs, never launches wt.exe
# (TERMINALRESS_DRYRUN=1 makes every process launch a log line instead), never starts real claude sessions.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$modDir = Join-Path $root 'TerminalRess'
foreach ($n in 'CLAUDECODE', 'WT_SESSION', 'TERMINALRESS_TAB') { [Environment]::SetEnvironmentVariable($n, $null, 'Process') }

$work = Join-Path $env:LOCALAPPDATA ('Temp\TerminalRessTests\' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$state = Join-Path $work 'state'
$env:TERMINALRESS_STATE = $state
$env:TERMINALRESS_DRYRUN = '1'
$env:TERMINALRESS_RUNTIME = Join-Path $work 'runtime'      # never the real installed runtime (module import syncs it)
$env:CLAUDE_CONFIG_DIR = Join-Path $work 'claude'
New-Item -ItemType Directory -Force -Path (Join-Path $env:CLAUDE_CONFIG_DIR 'sessions') | Out-Null

$script:pass = 0; $script:fail = 0
function Assert([bool]$Cond, [string]$Msg) { if ($Cond) { $script:pass++; Write-Host "  ok   $Msg" -ForegroundColor DarkGreen } else { $script:fail++; Write-Host "  FAIL $Msg" -ForegroundColor Red } }
function Section([string]$n) { Write-Host "`n== $n" -ForegroundColor Cyan }
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Invoke-ChildShell([string]$Code) {
    $f = Join-Path $work ([guid]::NewGuid().ToString('N') + '.ps1')
    [IO.File]::WriteAllText($f, $Code, (New-Object Text.UTF8Encoding $true))
    (& $psExe -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | Out-String)
}
function Reset-State { if (Test-Path $state) { [IO.Directory]::Delete($state, $true) } }
function New-FakeTab($Pid_, $Start, $Cwd, $Pending, $Last, $Env, [string]$Dir, $Run) {
    $o = [ordered]@{ shellPid = $Pid_; shellStart = $Start; shellExe = $psExe; session = (Get-Process -Id $PID).SessionId; wtSession = 'x'; cwd = $Cwd; envDiff = $Env; lastCommand = $Last; pendingCommand = $Pending; updatedAt = 'now' }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    [IO.File]::WriteAllText((Join-Path $Dir "$Pid_.json"), ($o | ConvertTo-Json -Depth 5 -Compress), (New-Object Text.UTF8Encoding $false))
    if ($Run) { [IO.File]::WriteAllText((Join-Path $Dir "$Pid_.run.json"), ($Run | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding $false)) }
}

try {
    Section 'manifest + import'
    $m = Test-ModuleManifest (Join-Path $modDir 'TerminalRess.psd1')
    $mv = $m.Version.ToString()
    Assert ($m.Version -ge [version]'1.0.0') 'manifest valid'
    Import-Module (Join-Path $modDir 'TerminalRess.psd1') -Force
    $exported = (Get-Command -Module TerminalRess).Name | Sort-Object
    Assert ($exported.Count -eq 7) "7 public commands: $($exported -join ', ')"
    $mod = Get-Module TerminalRess

    Section 'claude argv rewriter'
    $r1 = & $mod { $a = ConvertTo-TRClaudeResumeArgs (Get-TRArgv '"C:\Users\x\.local\bin\claude.exe" --dangerously-skip-permissions --resume') 'aaaaaaaa-0000-0000-0000-000000000001'; $a -join ' ' }
    Assert ($r1 -eq '--dangerously-skip-permissions --resume aaaaaaaa-0000-0000-0000-000000000001') "bare --resume picker: $r1"
    $r2 = & $mod { $a = ConvertTo-TRClaudeResumeArgs (Get-TRArgv '"C:\Users\x\.local\bin\claude.exe" --dangerously-skip-permissions --resume 12345678-90ab-cdef-1234-567890abcdef --fork-session') 'bbbbbbbb-0000-0000-0000-000000000002'; $a -join ' ' }
    Assert ($r2 -eq '--dangerously-skip-permissions --resume bbbbbbbb-0000-0000-0000-000000000002') "resume <id> --fork-session: $r2"
    $r3 = & $mod { $a = ConvertTo-TRClaudeResumeArgs (Get-TRArgv 'claude.exe -c --model opus --add-dir a b --session-id z -p "hola mundo" --verbose "do it"') 'sid'; $a -join ' ' }
    Assert ($r3 -eq '--model opus --add-dir a b --verbose --resume sid') "continue/session-id/print/prompt dropped: $r3"

    Section 'wt argument quoting'
    $q = & $mod { (ConvertTo-TRWtArg 'C:\a b\c;d\') + '|' + (ConvertTo-TRWtArg 'Z:\o e\') + '|' + (ConvertTo-TRWtArg 'plain') }
    Assert ($q -eq '"C:\a b\c\;d\\"|"Z:\o e\\"|plain') "quoting: $q"

    Section 'mutex names: FIPS-safe hash + legacy guardian'
    $hs = & $mod { (Get-TRHash 'abc') + '|' + (Get-TRHash 'ABC') + '|' + (Get-TRHash 'abc' -Md5) }
    Assert ($hs -eq 'ba7816bf|ba7816bf|90015098') "SHA256 prefix, case-insensitive, legacy MD5 kept for the old name: $hs"
    $names = & $mod { @((Get-TRMutexName 'Guardian'), (Get-TRMutexName 'Guardian' -Legacy)) }
    Assert ($names[0] -match '^Local\\TerminalRess-Guardian-[0-9a-f]{8}$' -and $names[0] -ne $names[1]) "guardian mutex name: $($names[0])"
    Assert (-not (& $mod { Test-TRGuardianRunning })) 'no guardian running for the test state dir'
    $legacy = New-Object Threading.Mutex($false, $names[1])
    try {
        Assert (& $mod { Test-TRGuardianRunning }) 'a pre-upgrade guardian (MD5-named mutex) counts as running'
        & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $modDir 'Runtime\guardian.ps1') -Once | Out-Null
        $glog = Join-Path $state 'guardian.log'
        Assert (-not ((Test-Path $glog) -and ((Get-Content $glog -Raw) -match 'guardian started'))) 'a new guardian does not start beside a pre-upgrade one'
    } finally { $legacy.Dispose() }
    Assert (-not (& $mod { Test-TRGuardianRunning })) 'legacy mutex released'
    & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $modDir 'Runtime\guardian.ps1') -Once | Out-Null
    Assert ((Test-Path $glog) -and ((Get-Content $glog -Raw) -match 'guardian started')) 'control: guardian starts once the legacy mutex is gone'

    Section 'claude resume handler (fake sessions dir)'
    $sdir = Join-Path $env:CLAUDE_CONFIG_DIR 'sessions'
    '{"pid":4242,"sessionId":"11111111-1111-1111-1111-111111111111","cwd":"C:\\Work\\p\u00e1gina","kind":"interactive"}' | Set-Content (Join-Path $sdir '4242.json') -Encoding UTF8
    $child = [pscustomobject]@{ ProcessId = 4242; Name = 'claude.exe'; ExecutablePath = 'C:\x\claude.exe'; CommandLine = '"C:\x\claude.exe" --dangerously-skip-permissions --resume' }
    $res = & $mod { param($c) Get-TRResumeCommand $c (Get-TRArgv $c.CommandLine) } $child
    Assert ($res.sessionId -eq '11111111-1111-1111-1111-111111111111') 'sessionId from sessions file'
    Assert ($res.cwd -eq "C:\Work\p$([char]0xe1)gina") 'cwd from sessions file (accent)'
    Assert (($res.args -join ' ') -eq '--dangerously-skip-permissions --resume 11111111-1111-1111-1111-111111111111') "args: $($res.args -join ' ')"
    '{"pid":4242,"sessionId":"22222222-2222-2222-2222-222222222222","cwd":"C:\\Work"}' | Set-Content (Join-Path $sdir '4242.json') -Encoding UTF8
    $res = & $mod { param($c) Get-TRResumeCommand $c (Get-TRArgv $c.CommandLine) } $child
    Assert ($res.sessionId -eq '22222222-2222-2222-2222-222222222222') 'follows /resume or /clear (new sessionId)'
    $child2 = [pscustomobject]@{ ProcessId = 9999; Name = 'claude.exe'; ExecutablePath = 'C:\x\claude.exe'; CommandLine = '"C:\x\claude.exe" --resume 33333333-3333-3333-3333-333333333333 --fork-session' }
    $res = & $mod { param($c) Get-TRResumeCommand $c (Get-TRArgv $c.CommandLine) } $child2
    Assert ($res.sessionId -eq '33333333-3333-3333-3333-333333333333') 'fallback to command line when sessions file is missing'
    # generic handler from config
    New-Item -ItemType Directory -Force -Path $state | Out-Null
    '{"resumeHandlers":[{"exe":"codex.exe","command":["{exe}","resume","--last"]}]}' | Set-Content (Join-Path $state 'config.json') -Encoding UTF8
    $res = & $mod { Get-TRConfig -Fresh | Out-Null; Get-TRResumeCommand ([pscustomobject]@{ ProcessId = 1; Name = 'codex.exe'; ExecutablePath = 'C:\c\codex.exe' }) @('C:\c\codex.exe') }
    Assert ($res -and $res.exe -eq 'C:\c\codex.exe' -and ($res.args -join ' ') -eq 'resume --last') 'config-defined resume handler'
    Assert ($null -eq (& $mod { Get-TRResumeCommand ([pscustomobject]@{ ProcessId = 1; Name = 'ping.exe'; ExecutablePath = 'x' }) @('x') })) 'no handler for other programs'
    Remove-Item (Join-Path $state 'config.json'); & $mod { $script:TR_ConfigCache = $null }

    Section 'claude background sessions (continued-in chain, attach vs resume)'
    $proj = Join-Path $work 'claude\projects\G--x'
    New-Item -ItemType Directory -Force -Path $proj | Out-Null
    $sA = 'aaaaaaaa-0000-0000-0000-00000000000a'; $sB = 'bbbbbbbb-0000-0000-0000-00000000000b'; $sC = 'cccccccc-0000-0000-0000-00000000000c'
    $u8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText((Join-Path $proj "$sA.jsonl"), ('{"type":"user","message":{}}' + "`n" + '{"type":"cost-state"}' + "`n" + "{`"type`":`"continued-in`",`"sessionId`":`"$sA`",`"continuedInSessionId`":`"$sB`"}" + "`n"), $u8)
    [IO.File]::WriteAllText((Join-Path $proj "$sB.jsonl"), '{"type":"assistant","message":{}}' + "`n", $u8)
    Assert ((& $mod { param($s) Get-TRClaudeContinuation $s } $sA) -eq $sB) 'continued-in record followed to the background session'
    Assert ((& $mod { param($s) Get-TRClaudeContinuation $s } $sB) -eq $sB) 'session without continuation stays'
    [IO.File]::WriteAllText((Join-Path $proj "$sC.jsonl"), ("{`"type`":`"continued-in`",`"continuedInSessionId`":`"$sB`"}" + "`n" + '{"type":"user","message":{}}' + "`n"), $u8)
    Assert ((& $mod { param($s) Get-TRClaudeContinuation $s } $sC) -eq $sC) 'continued-in followed by more messages (session used again) is ignored'
    $runA = [pscustomobject]@{ argv = @('C:\x\claude.exe', '--dangerously-skip-permissions', '--resume', $sA); resume = [pscustomobject]@{ handler = 'claude'; sessionId = $sA } }
    $actA = @{ Kind = 'Resume'; Exe = 'C:\x\claude.exe'; Args = [string[]]@('--dangerously-skip-permissions', '--resume', $sA); Cwd = 'C:\w' }
    $bgLive = { param($all) @([pscustomobject]@{ id = 'bbbbbbbb'; sessionId = 'bbbbbbbb-0000-0000-0000-00000000000b'; kind = 'background'; name = 'IA' }) }
    $bgNone = { param($all) @() }
    $r = & $mod { param($a, $r, $f) Resolve-TRClaudeAction $a $r -AgentsFn $f } $actA $runA $bgLive
    Assert (($r.Args -join ' ') -eq 'attach bbbbbbbb' -and $r.Cwd -eq 'C:\w') "handed-off session still running in the daemon: attach ($($r.Args -join ' '))"
    $r = & $mod { param($a, $r, $f) Resolve-TRClaudeAction $a $r -AgentsFn $f } $actA $runA $bgNone
    Assert (($r.Args -join ' ') -eq "--dangerously-skip-permissions --resume $sB") "daemon gone: resume the continued session with the original flags ($($r.Args -join ' '))"
    $runB = [pscustomobject]@{ argv = @('C:\x\claude.exe', '--resume', $sB); resume = [pscustomobject]@{ handler = 'claude'; sessionId = $sB } }
    $actB = @{ Kind = 'Resume'; Exe = 'C:\x\claude.exe'; Args = [string[]]@('--resume', $sB); Cwd = $null }
    $called = $false
    $r = & $mod { param($a, $r, $f) Resolve-TRClaudeAction $a $r -AgentsFn $f } $actB $runB { param($all) $script:called = $true; @() }
    Assert ((($r.Args -join ' ') -eq "--resume $sB") -and -not $called) 'ordinary foreground session: unchanged, claude not asked'
    $runT = [pscustomobject]@{ argv = @('C:\x\claude.exe', 'attach', 'bbbbbbbb'); resume = [pscustomobject]@{ handler = 'claude'; sessionId = $null } }
    $actT = @{ Kind = 'Resume'; Exe = 'C:\x\claude.exe'; Args = [string[]]@('attach', 'bbbbbbbb'); Cwd = $null }
    $r = & $mod { param($a, $r, $f) Resolve-TRClaudeAction $a $r -AgentsFn $f } $actT $runT $bgLive
    Assert (($r.Args -join ' ') -eq 'attach bbbbbbbb') 'tab running `claude attach`: attaches again while the session runs'
    $bgDone = { param($all) if ($all) { @([pscustomobject]@{ id = 'bbbbbbbb'; sessionId = 'bbbbbbbb-0000-0000-0000-00000000000b'; kind = 'background' }) } else { @() } }
    $r = & $mod { param($a, $r, $f) Resolve-TRClaudeAction $a $r -AgentsFn $f } $actT $runT $bgDone
    Assert (($r.Args -join ' ') -eq "--resume $sB") "attached session finished: resumed by its full id ($($r.Args -join ' '))"
    $r = & $mod { param($a, $r, $f) Resolve-TRClaudeAction $a $r -AgentsFn $f } @{ Kind = 'Pretype'; Text = 'x' } $runA $bgLive
    Assert ($r.Kind -eq 'Pretype') 'non-resume actions pass through'

    Section 'tab action selection (replay allowlist)'
    $act = & $mod {
        $cfg = Get-TRConfig
        $claude = [pscustomobject]@{ name = 'claude.exe'; resume = [pscustomobject]@{ exe = 'C:\x\claude.exe'; args = @('--resume', 'abc'); cwd = 'C:\w' } }
        $k = { param($tab, $run) $a = Get-TRTabAction ([pscustomobject]$tab) $run $cfg; if ($a) { $a.Kind } else { '-' } }
        @((& $k @{ pendingCommand = 'claude --resume'; lastCommand = 'x' } $claude),
          (& $k @{ pendingCommand = 'nvim foo'; lastCommand = 'x' } ([pscustomobject]@{ name = 'nvim.exe' })),
          (& $k @{ pendingCommand = 'ssh host'; lastCommand = 'x' } ([pscustomobject]@{ name = 'ssh.exe' })),
          (& $k @{ pendingCommand = 'ping -t 1.1.1.1'; lastCommand = 'x' } ([pscustomobject]@{ name = 'PING.EXE' })),
          (& $k @{ pendingCommand = 'git push'; lastCommand = 'x' } ([pscustomobject]@{ name = 'git.exe' })),
          (& $k @{ pendingCommand = 'Start-Sleep 99'; lastCommand = 'x' } $null),
          (& $k @{ pendingCommand = $null; lastCommand = 'echo hi' } $claude),
          (& $k @{ pendingCommand = 'seed'; seeded = $true; lastCommand = $null } $claude),
          (& $k @{ pendingCommand = 'seed'; seeded = $true; lastCommand = $null } ([pscustomobject]@{ name = 'nvim.exe' })),
          (& $k @{ pendingCommand = $null; lastCommand = $null } $null)) -join ','
    }
    Assert ($act -eq 'Resume,Replay,Replay,Pretype,Pretype,Pretype,Pretype,Resume,-,-') "claude=Resume, allowlisted nvim/ssh=Replay, ping/git push/no child=Pretype, idle=Pretype, seeded: claude only: $act"
    $pt = & $mod { (Get-TRTabAction ([pscustomobject]@{ pendingCommand = 'git push'; lastCommand = 'x' }) ([pscustomobject]@{ name = 'git.exe' }) (Get-TRConfig)).Text }
    Assert ($pt -eq 'git push') 'a non-allowlisted running command is pre-typed in its typed form'
    Section 'profile blocks (idempotent, BOM + CRLF + accents preserved, clean uninstall)'
    $prof = Join-Path $work 'profile.ps1'
    $orig = "# perfil $([char]0xbf)qu$([char]0xe9)?`r`nSet-Location C:\`r`nfunction prompt { 'x> ' }`r`n"
    [IO.File]::WriteAllText($prof, $orig, (New-Object Text.UTF8Encoding $true))
    $a = & $mod { param($p) Set-TRProfileBlocks -Path $p } $prof
    $t1 = [IO.File]::ReadAllText($prof)
    Assert ($a.Changed -and $a.Backup -and (Test-Path $a.Backup)) 'install changes the profile and writes a backup'
    Assert ($t1.StartsWith('# >>> TerminalRess (pre) >>>')) 'pre-hook is at the TOP'
    Assert ($t1.TrimEnd().EndsWith('# <<< TerminalRess <<<')) 'main hook is at the END'
    Assert ($t1.Contains("qu$([char]0xe9)?") -and $t1.Contains("`r`n")) 'accents and CRLF preserved'
    Assert ([IO.File]::ReadAllBytes($prof)[0] -eq 0xEF) 'BOM preserved'
    $b = & $mod { param($p) Set-TRProfileBlocks -Path $p } $prof
    Assert (-not $b.Changed -and ([IO.File]::ReadAllText($prof) -ceq $t1)) 'second install is a no-op (idempotent)'
    $c = & $mod { param($p) Set-TRProfileBlocks -Path $p -Remove } $prof
    Assert ($c.Changed -and ([IO.File]::ReadAllText($prof).TrimEnd() -ceq $orig.TrimEnd())) 'uninstall restores the original content'
    $old = "# >>> TerminalRess (pre) >>>`r`nif (`$env:WT_SESSION) { `$global:X = 1 }`r`n# <<< TerminalRess (pre) <<<`r`n`r`n" + $orig
    [IO.File]::WriteAllText($prof, $old, (New-Object Text.UTF8Encoding $true))
    $u = & $mod { param($p) Set-TRProfileBlocks -Path $p } $prof
    $tu = [IO.File]::ReadAllText($prof)
    Assert ($u.Changed -and $tu.Contains('pre-adopt.ps1') -and -not $tu.Contains('$global:X = 1') -and ([regex]::Matches($tu, '>>> TerminalRess \(pre\)')).Count -eq 1) 'an old pre-hook block is upgraded in place (no duplicate)'
    & $mod { param($p) Set-TRProfileBlocks -Path $p -Remove | Out-Null } $prof
    $wi = Uninstall-TerminalRess -ProfilePath $prof -StartupFolder (Join-Path $work 'startup') -WhatIf
    Assert (-not $wi.ProfileChanged -and -not $wi.RuntimeRemoved) 'Uninstall -WhatIf changes nothing'

    Section 'dead tab verdict + sweep'
    Reset-State; & $mod { Initialize-TRDirs }
    $wt = @([Diagnostics.Process]::GetProcessesByName('WindowsTerminal') | Where-Object { $_.SessionId -eq (Get-Process -Id $PID).SessionId })
    $live = Join-Path $state 'live'
    $before = (@($wt | ForEach-Object { $_.StartTime }) + (Get-Date) | Sort-Object | Select-Object -First 1).AddHours(-2).Ticks   # older than any running WT
    New-FakeTab 99991 $before 'C:\' $null 'old' $null $live
    & $mod { Invoke-TRSweep }
    Assert ((Test-Path (Join-Path $state 'last\99991.json')) -and -not (Test-Path (Join-Path $live '99991.json'))) 'dead tab from before the current WT started is moved to last (previous generation)'
    if ($wt.Count -gt 0) {
        $after = [datetime]::Now.Ticks
        New-FakeTab 99992 $after 'C:\' $null 'new' $null $live
        $tab = Get-Content (Join-Path $live '99992.json') -Raw | ConvertFrom-Json
        $v = & $mod { param($t) Get-TRDeadTabVerdict $t } $tab
        Assert ($v -eq 'closed') "dead tab that started while WT is alive = user closed it (verdict $v)"
        & $mod { Invoke-TRSweep }
        Assert (Test-Path (Join-Path $live '99992.json')) 'sweep never deletes (guardian owns that decision)'
        Remove-Item (Join-Path $live '99992.json')
    } else { Write-Host '  skip (no WindowsTerminal running): closed-tab verdict' -ForegroundColor Yellow }

    Section 'restore -DryRun (exact wt command)'
    Reset-State; & $mod { Initialize-TRDirs }
    $last = Join-Path $state 'last'
    $acc = Join-Path $work "dir $([char]0xf1);x"; New-Item -ItemType Directory -Force -Path $acc | Out-Null
    New-FakeTab 2002 ([datetime]'2026-01-01T10:00:02').Ticks $acc 'ping -t 127.0.0.1' 'x' $null $last
    New-FakeTab 2001 ([datetime]'2026-01-01T10:00:01').Ticks $acc $null 'echo hi' $null $last
    $dry = Restore-TerminalRess -DryRun
    Write-Host "  $dry" -ForegroundColor DarkGray
    Assert ($dry -match ' -w new new-tab ') 'one new window'
    Assert (([regex]::Matches($dry, ' ; new-tab ')).Count -eq 1 -and ([regex]::Matches($dry, 'new-tab')).Count -eq 2) 'one new-tab per saved tab, chained with " ; "'
    Assert ($dry.IndexOf('2001.json') -lt $dry.IndexOf('2002.json')) 'ordered by shell start time'
    Assert ($dry.Contains('\;x')) 'semicolon in a directory name is escaped'
    Assert ($dry.Contains('-NoProfile -NoExit -Command')) 'restored shells start with -NoProfile and dot-source restore-tab'
    Assert ((Get-ChildItem $last -Filter *.json).Count -eq 2) '-DryRun does not move anything'

    Section 'hook: registration, pre-baseline env diff, $?, pending command'
    Reset-State
    $hook = Join-Path $modDir 'Runtime\tab-hook.ps1'
    $env:TERMINALRESS_FORCE = '1'
    $out = Invoke-ChildShell @"
`$env:WT_SESSION = 'test-session'; `$env:NO_COLOR = '1'
`$global:TerminalRessBaseline = [Environment]::GetEnvironmentVariables('Process')   # pre-hook
`$env:VSCMD_TEST = 'from-profile'; `$env:PATH += ';C:\added'                          # what a profile does
function prompt { `$global:seen = "ok=`$? lec=`$global:LASTEXITCODE"; 'ORIG> ' }
. '$hook'
Set-Location '$acc'
`$env:MY_VAR = 'hola $([char]0xf1)'
`$env:MY_ESC = 'q"b\c' + [char]9 + 'd'
Get-Item C:\definitely-missing -ErrorAction SilentlyContinue
`$r = prompt
"PROMPT=[`$r] SEEN=[`$global:seen]"
`$h = (Get-PSReadLineOption).AddToHistoryHandler
"HANDLER=" + `$h.Invoke('ping -t 127.0.0.1')
`$null = `$h.Invoke('exit')
"FILE=" + (Join-Path '$state' "live\`$PID.json")
"@
    Write-Host ($out.TrimEnd() -split "`n" | ForEach-Object { "  | $_" } | Out-String).TrimEnd() -ForegroundColor DarkGray
    $file = ($out -split "`r?`n" | Where-Object { $_ -like 'FILE=*' } | Select-Object -First 1) -replace '^FILE=', ''
    Assert ($out -match 'PROMPT=\[ORIG> \]') 'original prompt output preserved'
    Assert ($out -match 'SEEN=\[ok=False') 'original prompt saw $? = False'
    Assert ($out -match 'HANDLER=MemoryAndFile') 'history handler chained, return value kept'
    $tab = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert ($tab.cwd -eq $acc) 'state file: cwd (accented path)'
    Assert ($tab.envDiff.VSCMD_TEST -eq 'from-profile') 'env diff includes vars set by the PROFILE (baseline is pre-profile)'
    Assert ($tab.envDiff.MY_VAR -eq "hola $([char]0xf1)") 'env diff includes a var set later (accent intact)'
    Assert ($tab.envDiff.MY_ESC -ceq ('q"b\c' + [char]9 + 'd')) 'quotes, backslashes and control characters survive the JSON round trip'
    Assert ($tab.envDiff.Path -like '*;C:\added') 'env diff includes PATH change'
    Assert (-not $tab.envDiff.PSObject.Properties['NO_COLOR'] -and -not $tab.envDiff.PSObject.Properties['WT_SESSION']) 'denylisted vars (NO_COLOR, WT_*) excluded'
    Assert ($tab.pendingCommand -eq 'ping -t 127.0.0.1') 'pendingCommand recorded at accept time'
    Assert ($tab.exiting -eq $true) 'typed exit marks the tab file exiting=true'
    Assert ($tab.shellExe -like '*powershell.exe' -and $tab.shellStart -gt 0) 'shell exe + start time recorded'
    Assert ((Get-Content (Join-Path $state 'dryrun.log') -Raw) -match 'guardian\.ps1') 'hook ensures the guardian is started'
    Assert (-not (Get-ChildItem (Join-Path $state 'live') -Filter *.tmp)) 'atomic write leaves no tmp files'
    Assert (-not $tab.PSObject.Properties['wtPid']) 'the hook leaves the owning WT to the guardian'
    $out = Invoke-ChildShell "`$env:WT_SESSION = 'light'; . '$hook'; 'LOADED=' + [bool]`$global:__TR + ' COMMON=' + [bool](Get-Command Get-TROwnerWt -ErrorAction SilentlyContinue) + ' CIM=' + [bool](Get-Module CimCmdlets) + ' UTILITY=' + [bool](Get-Module Microsoft.PowerShell.Utility)"
    Assert ($out -match 'LOADED=True COMMON=False CIM=False UTILITY=False') "hook loads only Base.ps1: no CIM, no Utility module (JSON cmdlets, New-Object): $($out.Trim())"

    Section 'hook: not active in tool shells'
    Reset-State
    $out = Invoke-ChildShell "`$env:WT_SESSION='x'; `$env:CLAUDECODE='1'; . '$hook'; 'LOADED=' + [bool]`$global:__TR"
    Assert ($out -match 'LOADED=False') 'CLAUDECODE set -> inactive'
    $env:TERMINALRESS_FORCE = $null
    $nested = Join-Path $work 'nested.ps1'
    [IO.File]::WriteAllText($nested, "param(`$S) if (`$S) { `$env:WT_SESSION = `$S }; . '$hook'; 'NESTED=' + [bool]`$global:__TR", (New-Object Text.UTF8Encoding $true))
    $out = Invoke-ChildShell @"
`$env:WT_SESSION = 'outer'
. '$hook'
'OUTER=' + [bool]`$global:__TR + ' MARK=' + `$env:TERMINALRESS_TAB
& '$psExe' -NoProfile -ExecutionPolicy Bypass -File '$nested'
& '$psExe' -NoProfile -ExecutionPolicy Bypass -File '$nested' 'new-tab-session'
"@
    Assert ($out -match 'OUTER=True MARK=outer') 'a tracked shell marks its environment with its WT_SESSION'
    Assert (([regex]::Matches($out, 'NESTED=False')).Count -eq 1) 'a shell started inside a tracked tab (same WT_SESSION) -> inactive'
    Assert (([regex]::Matches($out, 'NESTED=True')).Count -eq 1) 'a new tab opened from a tracked shell (own WT_SESSION, inherited marker) -> tracked'
    Assert ('TERMINALRESS_TAB' -match (& $mod { $TR_ScrubRegex })) 'the marker is scrubbed from every process TerminalRess launches (restored tabs, guardian)'
    $out = Invoke-ChildShell ". '$hook'; 'LOADED=' + [bool]`$global:__TR"
    Assert ($out -match 'LOADED=False') 'no WT_SESSION -> inactive'
    $env:TERMINALRESS_FORCE = '1'

    Section 'guardian: capture (ping, fake claude with fake sessions dir) and tab-closed decision'
    Reset-State; & $mod { Initialize-TRDirs }
    Copy-Item (Join-Path $env:SystemRoot 'System32\cmd.exe') (Join-Path $work 'claude.exe') -Force   # stand-in process named claude.exe
    $shellCode = @"
param(`$Mode)
`$env:WT_SESSION = "test-`$Mode"
. '$hook'
`$null = prompt
if (`$Mode -eq 'ping') { `$global:__TR.Pending = 'ping -t 127.0.0.1'; TR_WriteState; ping -t 127.0.0.1 | Out-Null }
elseif (`$Mode -eq 'claude') {
    `$global:__TR.Pending = 'claude --dangerously-skip-permissions --resume'; TR_WriteState
    `$p = Start-Process '$work\claude.exe' -ArgumentList '/c ping -n 600 127.0.0.1 >nul & rem --dangerously-skip-permissions --resume' -NoNewWindow -PassThru
    '{"pid":' + `$p.Id + ',"sessionId":"44444444-4444-4444-4444-444444444444","cwd":"C:\\Work"}' | Set-Content ('$($env:CLAUDE_CONFIG_DIR)\sessions\' + `$p.Id + '.json') -Encoding UTF8
    Start-Sleep 600
} else { Start-Sleep 600 }
"@
    $shellFile = Join-Path $work 'testshell.ps1'
    [IO.File]::WriteAllText($shellFile, $shellCode, (New-Object Text.UTF8Encoding $true))
    $mine = @()
    foreach ($mode in 'idle', 'ping', 'claude') {
        $p = Start-Process $psExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$shellFile`" $mode" -WindowStyle Hidden -PassThru
        $mine += $p.Id; Start-Sleep -Milliseconds 800
    }
    Start-Sleep 6
    & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $modDir 'Runtime\guardian.ps1') -Once | Out-Null
    $runs = @{}
    foreach ($id in $mine) { $rp = Join-Path $state "live\$id.run.json"; if (Test-Path $rp) { $runs[$id] = [IO.File]::ReadAllText($rp, [Text.Encoding]::UTF8) | ConvertFrom-Json } }
    Assert ($runs[$mine[1]].name -eq 'PING.EXE' -and $runs[$mine[1]].commandLine -like '*-t 127.0.0.1') 'ping child captured with its command line'
    Assert (-not $runs.ContainsKey($mine[0])) 'idle tab has no run file'
    $cr = $runs[$mine[2]]
    if (-not ($cr -and $cr.resume.sessionId)) { Write-Host ("  DEBUG run=" + ($cr | ConvertTo-Json -Depth 5 -Compress) + " sess=" + ((Get-ChildItem (Join-Path $env:CLAUDE_CONFIG_DIR "sessions") | ForEach-Object { $_.Name + "=" + (Get-Content $_.FullName -Raw) }) -join "~") + " cfg=" + $env:CLAUDE_CONFIG_DIR) -ForegroundColor Yellow }
    Assert ($cr -and $cr.name -eq 'claude.exe' -and $cr.resume.sessionId -eq '44444444-4444-4444-4444-444444444444') 'claude child captured with current sessionId from the sessions file'
    Assert ($cr -and ($cr.resume.args -join ' ') -like '*--dangerously-skip-permissions --resume 44444444-4444-4444-4444-444444444444') 'claude resume args rebuilt'
    # kill ONLY what this test created
    $allP = @(Get-CimInstance Win32_Process); $kids = @(); $front = @($mine)
    while ($front.Count) { $next = @($allP | Where-Object { $front -contains $_.ParentProcessId -and $_.Name -ne 'conhost.exe' } | ForEach-Object ProcessId); $kids += $next; $front = $next }   # descendants of MY test shells only
    Stop-Process -Id ($kids + $mine) -Force -ErrorAction SilentlyContinue
    Start-Sleep 1
    '{"graceSeconds":0}' | Set-Content (Join-Path $state 'config.json') -Encoding UTF8
    & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $modDir 'Runtime\guardian.ps1') -Once | Out-Null
    $lastN = (& $mod { param($d) Get-TRTabFiles $d } (Join-Path $state "last")).Count
    if ($wt.Count -gt 0) { Assert ($lastN -eq 0 -and -not (Get-ChildItem (Join-Path $state 'live') -Filter *.json)) 'WT alive + tabs died = user closed them: files deleted, nothing in last' }
    else { Assert ($lastN -eq 3) 'WT gone + tabs died = generation ended: 3 tabs moved to last' }
    Remove-Item (Join-Path $state 'config.json') -ErrorAction SilentlyContinue

    Section 'launcher: pre-adopt spawns ALL saved tabs into this window, then exits the launcher shell'
    Reset-State; & $mod { Initialize-TRDirs; $script:TR_ConfigCache = $null }
    '{"profileArgs":["--skip-vcvars"]}' | Set-Content (Join-Path $state 'config.json') -Encoding UTF8
    $last = Join-Path $state 'last'
    $preAdopt = Join-Path $modDir 'Runtime\pre-adopt.ps1'
    New-FakeTab 3002 ([datetime]'2026-01-01T10:00:02').Ticks $work $null 'echo hi' $null $last
    New-FakeTab 3001 ([datetime]'2026-01-01T10:00:01').Ticks $acc 'Write-Output X' 'x' ([pscustomobject]@{ RESTORE_VAR = 'restored-value' }) $last
    New-FakeTab 3003 ([datetime]'2026-01-01T10:00:03').Ticks $work $null 'dir' $null $last
    $out = Invoke-ChildShell @"
`$env:WT_SESSION = 'adopt-test'
. '$preAdopt'
"LAUNCHER_CONTINUED"
"@
    Write-Host ($out.TrimEnd() -split "`n" | ForEach-Object { "  | $_" } | Out-String).TrimEnd() -ForegroundColor DarkGray
    $dl = Get-Content (Join-Path $state 'dryrun.log') -Raw
    Assert (-not ($out -match 'LAUNCHER_CONTINUED')) 'launcher shell exits right after spawning (nothing after pre-adopt runs)'
    Assert (([regex]::Matches($dl, 'wt\.exe -w 0 new-tab')).Count -eq 1 -and ([regex]::Matches($dl, 'new-tab')).Count -eq 3) 'ALL 3 tabs opened with one "wt -w 0 new-tab ... ; new-tab ..." call'
    Assert ($dl.IndexOf('3001.json') -lt $dl.IndexOf('3002.json') -and $dl.IndexOf('3002.json') -lt $dl.IndexOf('3003.json')) 'original order'
    Assert (([regex]::Matches($dl, '# --skip-vcvars')).Count -eq 3) 'every restored tab carries the configured profileArgs'
    Assert ((Get-ChildItem $last -File -ErrorAction SilentlyContinue).Count -eq 0 -and (Get-ChildItem (Join-Path $state 'archive') -Recurse -Filter 3001.json)) 'last\ moved to archive\ before spawning'
    $out2 = Invoke-ChildShell "`$env:WT_SESSION = 'adopt-test2'; . '$preAdopt'; 'LAUNCHER_CONTINUED'"
    Assert ($out2 -match 'LAUNCHER_CONTINUED') 'a second terminal finds nothing saved and continues as a normal shell'
    $out3 = Invoke-ChildShell "`$env:WT_SESSION = 'adopt-test3'; `$env:TERMINALRESS_RESTORING = '1'; . '$preAdopt'; 'LAUNCHER_CONTINUED'"
    Assert ($out3 -match 'LAUNCHER_CONTINUED') 'a restored tab (TERMINALRESS_RESTORING=1) never acts as a launcher'

    Section 'owner-based verdict, typed exit, seeding'
    Reset-State; & $mod { Initialize-TRDirs; $script:TR_ConfigCache = $null }
    $me = Get-Process -Id $PID
    $live = Join-Path $state 'live'
    New-FakeTab 5001 ([datetime]::Now.Ticks) 'C:\' $null 'x' $null $live
    $tab = [IO.File]::ReadAllText((Join-Path $live '5001.json')) | ConvertFrom-Json
    $tab | Add-Member wtPid $PID -Force; $tab | Add-Member wtStart $me.StartTime.Ticks -Force
    Assert ((& $mod { param($t) Get-TRDeadTabVerdict $t } $tab) -eq 'closed') 'owner WT alive -> closed'
    $tab.wtStart = $me.StartTime.Ticks - 600000000
    Assert ((& $mod { param($t) Get-TRDeadTabVerdict $t } $tab) -eq 'ended') 'owner pid reused / gone -> ended (even if another WT runs)'
    $tab.wtPid = 99999999
    Assert ((& $mod { param($t) Get-TRDeadTabVerdict $t } $tab) -eq 'ended') 'owner dead -> ended'
    $tab | Add-Member exiting $true -Force
    $tab | Add-Member wtPid $null -Force
    $r = & $mod { param($t) Resolve-TRDeadTab (Get-Item (Join-Path $script:TR_Live '5001.json')) $t } $tab
    Assert ($r -eq 'deleted' -and -not (Test-Path (Join-Path $state 'last\5001.json'))) 'typed exit -> tab deleted, not moved to last'
    New-FakeTab 5002 ([datetime]'2026-01-01').Ticks 'C:\' $null 'x' $null $live
    $x = [IO.File]::ReadAllText((Join-Path $live '5002.json')) | ConvertFrom-Json; $x | Add-Member exiting $true -Force
    [IO.File]::WriteAllText((Join-Path $live '5002.json'), ($x | ConvertTo-Json -Compress))
    & $mod { Invoke-TRSweep }
    Assert (-not (Test-Path (Join-Path $live '5002.json')) -and -not (Test-Path (Join-Path $state 'last\5002.json'))) 'sweep drops exiting tabs instead of keeping them'
    if ($wt.Count -gt 0) {
        $seeded = @(Register-TerminalRessExisting)
        Write-Host ("  seeded " + $seeded.Count + " existing tab(s): " + (($seeded | ForEach-Object { $_.ShellPid }) -join ',')) -ForegroundColor DarkGray
        $sf = Get-ChildItem $live -Filter *.json | Where-Object { $_.Name -notlike '*.run.json' }
        Assert ($seeded.Count -eq $sf.Count) 'one tab file per existing WT shell'
        if ($sf) {
            $s1 = [IO.File]::ReadAllText($sf[0].FullName) | ConvertFrom-Json
            Assert ($s1.seeded -and $s1.wtPid -and $s1.shellExe -and $null -eq $s1.envDiff) 'seeded file: owner + shell exe recorded, no envDiff'
            Assert (@(Register-TerminalRessExisting).Count -eq 0) 'seeding twice adds nothing'
        }
    } else { Write-Host '  skip (no WindowsTerminal running): seeding' -ForegroundColor Yellow }
    Section 'owner sidecar (guardian) + config fast path'
    Reset-State; & $mod { Initialize-TRDirs }
    $t0 = [datetime]'2026-01-01T10:00:00'
    $mkProc = { param($id, $ppid, $name, $sec) [pscustomobject]@{ ProcessId = [uint32]$id; ParentProcessId = [uint32]$ppid; Name = $name; CreationDate = $t0.AddSeconds($sec) } }
    $byId = @{}
    foreach ($p in @((& $mkProc 10 1 'WindowsTerminal.exe' 0), (& $mkProc 11 10 'OpenConsole.exe' 5), (& $mkProc 12 11 'powershell.exe' 6), (& $mkProc 13 10 'pwsh.exe' 7),
                     (& $mkProc 14 12 'powershell.exe' 8), (& $mkProc 20 1 'WindowsTerminal.exe' 50), (& $mkProc 21 20 'OpenConsole.exe' 51), (& $mkProc 15 21 'pwsh.exe' 9))) { $byId[$p.ProcessId] = $p }
    $own = & $mod { param($m) @(12, 13, 14, 15 | ForEach-Object { $w = Find-TROwnerInSnapshot $_ $m; if ($w) { $w.ProcessId } else { '-' } }) -join ',' } $byId
    Assert ($own -eq '10,10,-,-') "owner walk: via OpenConsole, direct, nested shell = none, reused parent PIDs = none: $own"
    $live = Join-Path $state 'live'
    New-FakeTab 12 $t0.AddSeconds(6).Ticks 'C:\' $null 'x' $null $live
    New-FakeTab 14 $t0.AddSeconds(8).Ticks 'C:\' $null 'x' $null $live
    & $mod { param($m) foreach ($n in 12, 14) { $f = Join-Path $script:TR_Live "$n.json"; Set-TRTabOwner $f (Read-TRTab $f) $m } } $byId
    Assert ((Test-Path (Join-Path $live '12.owner.json')) -and -not (Test-Path (Join-Path $live '14.owner.json'))) 'guardian writes the owner sidecar only when it finds the WT'
    $rt12 = & $mod { Read-TRTab (Join-Path $script:TR_Live '12.json') }
    Assert ($rt12.wtPid -eq 10 -and $rt12.wtStart -eq $t0.Ticks -and $rt12.cwd -eq 'C:\') 'Read-TRTab merges the owner into the tab'
    Assert (@(& $mod { Get-TRTabFiles $script:TR_Live }).Count -eq 2) 'sidecars are not tab files'
    New-FakeTab 12 $t0.AddSeconds(99).Ticks 'C:\' $null 'x' $null $live
    Assert ($null -eq (& $mod { Read-TRTab (Join-Path $script:TR_Live '12.json') }).wtPid) 'a stale owner (PID reused by a newer shell) is ignored'
    & $mod { Move-TRTabFiles (Join-Path $script:TR_Live '12.json') $script:TR_Last; Remove-TRTabFiles (Join-Path $script:TR_Live '14.json') }
    Assert ((Test-Path (Join-Path $state 'last\12.owner.json')) -and @(Get-ChildItem $live).Count -eq 0) 'the owner sidecar moves and is deleted with its tab'
    $me = Get-Process -Id $PID
    $mkOwner = { param($n, $start, $wpid, $wstart) & $mod { param($n, $o) Write-TRJson (Join-Path $script:TR_Live "$n.owner.json") $o } $n ([ordered]@{ shellPid = $n; shellStart = $start; wtPid = $wpid; wtStart = $wstart }) }
    New-FakeTab 99971 $t0.Ticks 'C:\' $null 'x' $null $live; & $mkOwner 99971 $t0.Ticks 99999999 $t0.Ticks
    $now = [datetime]::Now.Ticks
    New-FakeTab 99972 $now 'C:\' $null 'x' $null $live; & $mkOwner 99972 $now $PID $me.StartTime.Ticks
    & $mod { Invoke-TRSweep }
    Assert ((Test-Path (Join-Path $state 'last\99971.json')) -and (Test-Path (Join-Path $state 'last\99971.owner.json'))) 'sweep: dead shell whose sidecar owner is gone -> moved to last with its sidecar'
    Assert ((Test-Path (Join-Path $live '99972.json')) -and -not (Test-Path (Join-Path $state 'last\99972.json'))) 'sweep: dead shell whose sidecar owner is alive -> left for the guardian'
    $r = & $mod { $f = Get-Item (Join-Path $script:TR_Live '99972.json'); Resolve-TRDeadTab $f (Read-TRTab $f.FullName) }
    Assert ($r -eq 'deleted' -and @(Get-ChildItem $live).Count -eq 0) 'dead shell whose sidecar owner is alive -> closed, tab and sidecar deleted'
    foreach ($n in '99973.owner.json', '99974.run.json', '99971.run.json') { [IO.File]::WriteAllText((Join-Path $live $n), '{}') }
    & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $modDir 'Runtime\guardian.ps1') -Once | Out-Null
    $left = @(Get-ChildItem $live -Name) -join ','
    Assert ($left -eq '99971.run.json') "guardian prunes orphan sidecars, keeps one whose tab is in last\ (mid-move): $left"
    Remove-Item (Join-Path $live '99971.run.json')
    $envOut = Join-Path $work 'scrub.txt'
    & $mod { param($o) $env:TERMINALRESS_TAB = 'scrub-test'; $env:TERMINALRESS_DRYRUN = $null
        try { Start-TRProcess (Join-Path $env:SystemRoot 'System32\cmd.exe') "/c set > `"$o`"" -Hidden } finally { $env:TERMINALRESS_TAB = $null; $env:TERMINALRESS_DRYRUN = '1' } } $envOut
    $deadline = (Get-Date).AddSeconds(10)
    while (-not ((Test-Path $envOut) -and (Get-Content $envOut -Raw) -match 'TERMINALRESS_STATE=') -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    $envTxt = Get-Content $envOut -Raw
    Assert ($envTxt -match '(?m)^TERMINALRESS_STATE=' -and $envTxt -notmatch '(?m)^TERMINALRESS_TAB=') 'Start-TRProcess removes TERMINALRESS_TAB from the child environment'
    $dl = & $mod { (Get-TREnvDenylist) -join '|' }
    Assert ($dl -eq ((& $mod { Get-TRDefaultConfig }).envDenylist -join '|')) 'denylist fast path: no config.json -> defaults'
    foreach ($c in @('{ "graceSeconds": 1, "envDenylist" : [ "A*", "B]" ,"c d" ] }', '{"envDenylist":[]}', '{"envDenylist":["x\\y","Q"]}', '{"envDenylist":null}', '{"graceSeconds":2}')) {
        [IO.File]::WriteAllText((Join-Path $state 'config.json'), $c)
        $fast = & $mod { $script:TR_ConfigCache = $null; (Get-TREnvDenylist) -join '|' }
        $full = & $mod { (Get-TRConfig -Fresh).envDenylist -join '|' }
        Assert ($fast -ceq $full) "denylist fast path = Get-TRConfig for $c -> [$fast]"
    }
    Remove-Item (Join-Path $state 'config.json'); & $mod { $script:TR_ConfigCache = $null }

    Section 'guardian loop: process snapshot, cached tab files, known child, idle back-off, wake-ups'
    Reset-State; & $mod { Initialize-TRDirs }
    $nat = & $mod {
        Initialize-TRNativeProcs
        $s = [TRNative.Procs]::Snapshot(); $me = [Diagnostics.Process]::GetCurrentProcess(); $p = $s.ById[[uint32]$PID]
        $par = [int](Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
        @(($p.ParentProcessId -eq $par), ($p.CreationDate -eq $me.StartTime), [TRNative.Procs]::IsAlive($PID, $me.StartTime.Ticks),
          (-not [TRNative.Procs]::IsAlive($PID, $me.StartTime.AddMinutes(-1).Ticks)), (-not [TRNative.Procs]::IsAlive(99999999, 0)),
          (@($s.Children($par) | Where-Object { $_.ProcessId -eq $PID }).Count -eq 1)) -join ','
    }
    Assert ($nat -eq 'True,True,True,True,True,True') "Toolhelp snapshot (parent, start time, children) and liveness with the PID-reuse guard: $nat"
    $live = Join-Path $state 'live'
    $enc = { param($c) '-NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($c)) }
    $sh = Start-Process $psExe -ArgumentList (& $enc "& '$work\claude.exe' /c ping -n 900 127.0.0.1 | Out-Null; Start-Sleep 900") -WindowStyle Hidden -PassThru
    $cl = $null; $deadline = (Get-Date).AddSeconds(15)
    while (-not $cl -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; $cl = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($sh.Id) AND Name='claude.exe'" }
    $sessFile = Join-Path $env:CLAUDE_CONFIG_DIR "sessions\$($cl.ProcessId).json"
    [IO.File]::WriteAllText($sessFile, '{"sessionId":"aaaaaaaa-0000-0000-0000-00000000000a","cwd":"C:\\"}')
    New-FakeTab $sh.Id $sh.StartTime.Ticks 'C:\' 'claude' $null $null $live
    $runFile = Join-Path $live "$($sh.Id).run.json"
    $G = & $mod { New-TRGuardianState }
    $tick = { & $mod { param($g) Invoke-TRGuardianTick $g } $G }
    $a1 = & $tick; $run = [IO.File]::ReadAllText($runFile) | ConvertFrom-Json
    Assert ($a1 -and $G.Claude -and $run.name -eq 'claude.exe' -and $run.resume.sessionId -eq 'aaaaaaaa-0000-0000-0000-00000000000a') 'first loop: tab read, claude child found, run file written'
    $quiet = @(1..5 | ForEach-Object { & $tick })
    Assert ($quiet -notcontains $true -and $G.Idle -ge $G.IdleAfter -and $G.Idle -eq 5) "nothing changed: $($G.Idle) quiet loops in a row switch the guardian to the idle interval"
    [IO.File]::WriteAllText($sessFile, '{"sessionId":"bbbbbbbb-0000-0000-0000-00000000000b","cwd":"C:\\"}')
    $a2 = & $tick; $run = [IO.File]::ReadAllText($runFile) | ConvertFrom-Json
    Assert ($a2 -and $G.Idle -eq 0 -and $run.resume.sessionId -eq 'bbbbbbbb-0000-0000-0000-00000000000b') '/resume or /clear (sessions file changed, same process) updates the run file on the next loop'
    $ping = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($cl.ProcessId)"
    Stop-Process -Id (@($ping.ProcessId) + $cl.ProcessId) -Force -ErrorAction SilentlyContinue; Wait-Process -Id $cl.ProcessId -Timeout 5 -ErrorAction SilentlyContinue
    $a3 = & $tick; $kept = Test-Path $runFile; $a4 = & $tick
    Assert ($a3 -and $kept -and $a4 -and -not (Test-Path $runFile) -and -not $G.Claude) 'an ended program is noticed by PID without any file change; its run file goes after two empty loops'
    Assert (-not $G.NextScan.ContainsKey($sh.Id) -and (& $tick)) 'shortly after a command was typed a tab without a child is looked at every loop (a slow program starts its child late)'
    $G.ReadAt[$sh.Id] = [DateTime]::UtcNow.AddSeconds(-$G.QuickScanSec); $null = & $tick
    Assert ($G.NextScan.ContainsKey($sh.Id) -and -not (& $tick)) 'a command running in-process (no child) is looked at again only every 30 s or when its tab changes'
    New-FakeTab $sh.Id $sh.StartTime.Ticks 'C:\' $null 'x' $null $live
    Assert ((& $tick) -and $G.Idle -eq 0 -and -not $G.NextScan.ContainsKey($sh.Id)) 'a changed tab file is read again and makes the loop active'
    $fb = & $mod {
        param($shPid) $g = New-TRGuardianState; $g.Native = $false
        $s = Get-TRProcSnapshot $g; $me = [Diagnostics.Process]::GetCurrentProcess(); $par = [int]$s.ById[[uint32]$PID].ParentProcessId
        @((Invoke-TRGuardianTick $g), $g.Alive.Contains($shPid), (Test-TRProcAlive $g $PID $me.StartTime.Ticks), (-not (Test-TRProcAlive $g $PID $me.StartTime.AddMinutes(-1).Ticks)),
          (-not (Test-TRProcAlive $g 99999999 0)), (@($s.Children($par) | Where-Object { $_.ProcessId -eq $PID }).Count -eq 1), (@($s.Children(99999999)).Count -eq 0)) -join ','
    } $sh.Id
    Assert ($fb -eq 'True,True,True,True,True,True,True') "without the compiled helpers the loop falls back to Get-Process and a CIM snapshot: $fb"
    $w = & $mod { param($d) New-Object TRNative.Waiter $d } $live
    try {
        $writeLater = { param($n) Start-Process $psExe -ArgumentList (& $enc "Start-Sleep -Milliseconds 400; [IO.File]::WriteAllText('$live\$n', '{}')") -WindowStyle Hidden }
        & $writeLater "$($sh.Id).run.json"; $r0 = $w.Wait(2500, [int[]]@())
        & $writeLater '77.json'; $sw = [Diagnostics.Stopwatch]::StartNew(); $r1 = $w.Wait(15000, [int[]]@()); $t1 = $sw.Elapsed.TotalSeconds
        $w.Reset()
        $q = Start-Process $psExe -ArgumentList '-NoProfile -Command Start-Sleep 1' -WindowStyle Hidden -PassThru
        $sw = [Diagnostics.Stopwatch]::StartNew(); $r2 = $w.Wait(15000, [int[]]@($sh.Id, $q.Id)); $t2 = $sw.Elapsed.TotalSeconds
        Assert ($r0 -eq 0 -and $r1 -eq 1 -and $t1 -lt 10 -and $r2 -eq 2 -and $t2 -lt 10) "wait: the guardian's own sidecar writes do not wake it, a tab file change and a shell exit do ($r0/$r1/$r2)"
    } finally { $w.Dispose() }
    Stop-Process -Id $sh.Id -Force -ErrorAction SilentlyContinue

    Section 'restore-tab: baseline -> env -> RESTORING profile -> cwd -> command'
    Reset-State; & $mod { Initialize-TRDirs }
    $fprof = Join-Path $work 'fakeprofile.ps1'
    "`"PROFILE_SAW var=`$env:RT_VAR restoring=`$env:TERMINALRESS_RESTORING`"; Set-Location C:\Windows" | Set-Content $fprof -Encoding UTF8
    New-FakeTab 4001 ([datetime]'2026-01-01T10:00:01').Ticks $acc 'Write-Output RAN-PENDING' 'x' ([pscustomobject]@{ RT_VAR = 'rv' }) (Join-Path $work 'rt') $null
    $tf = Join-Path $work 'rt\4001.json'
    $rtScript = Join-Path $modDir 'Runtime\restore-tab.ps1'
    $env:TERMINALRESS_PROFILES = $fprof
    $out = (& $psExe -NoProfile -ExecutionPolicy Bypass -Command ". '$rtScript' '$tf'; 'AFTER cwd=' + (Get-Location).Path + ' restoring=[' + `$env:TERMINALRESS_RESTORING + '] baseline_has_RT_VAR=' + `$global:TerminalRessBaseline.ContainsKey('RT_VAR')" 2>&1 | Out-String)
    $env:TERMINALRESS_PROFILES = $null
    Write-Host ($out.TrimEnd() -split "`n" | ForEach-Object { "  | $_" } | Out-String).TrimEnd() -ForegroundColor DarkGray
    Assert ($out -match 'PROFILE_SAW var=rv restoring=1') 'profile sees restored env and TERMINALRESS_RESTORING=1'
    Assert ($out -match [regex]::Escape("AFTER cwd=$acc") -and $out -match 'restoring=\[\]') 'cwd set AFTER the profile; RESTORING removed'
    Assert (-not ($out -match 'RAN-PENDING')) 'a non-allowlisted pending command is NOT executed in a restored tab (pre-typed instead)'
    Assert ($out -match 'baseline_has_RT_VAR=False') 'baseline is the pristine pre-restore env'
    Section 'profileArgs / profileEnv plumbing'
    Reset-State; & $mod { Initialize-TRDirs; $script:TR_ConfigCache = $null }
    '{"profileArgs":["--skip-vcvars","a;b"],"profileEnv":{"PV_X":"skip","PV_Y":"cfg"}}' | Set-Content (Join-Path $state 'config.json') -Encoding UTF8
    New-FakeTab 4101 ([datetime]'2026-01-01T10:00:01').Ticks $acc $null $null ([pscustomobject]@{ PV_Y = 'saved' }) (Join-Path $work 'rt3') $null
    $tf3 = Join-Path $work 'rt3\4101.json'
    $ta = & $mod { param($f) $t = Read-TRJson $f; New-TRTabArgs $t $f } $tf3
    Assert ($ta.Contains('# --skip-vcvars a\;b"')) "wt args carry the profileArgs as a trailing, escaped comment: $ta"
    "`"PROFILE_ARGS=`" + ([Environment]::GetCommandLineArgs() -join '|'); `"PROFILE_ENV x=`$env:PV_X y=`$env:PV_Y`"" | Set-Content $fprof -Encoding UTF8
    $env:TERMINALRESS_PROFILES = $fprof
    $out = (& $psExe -NoProfile -ExecutionPolicy Bypass -Command ". '$rtScript' '$tf3' # --skip-vcvars a;b; 'AFTER x=[' + `$env:PV_X + '] y=[' + `$env:PV_Y + ']'" 2>&1 | Out-String)
    $out4 = (& $psExe -NoProfile -ExecutionPolicy Bypass -Command ". '$rtScript' '$tf3'; 'AFTER x=[' + `$env:PV_X + '] y=[' + `$env:PV_Y + ']'" 2>&1 | Out-String)
    $env:TERMINALRESS_PROFILES = $null
    Write-Host ($out.TrimEnd() -split "`n" | ForEach-Object { "  | $_" } | Out-String).TrimEnd() -ForegroundColor DarkGray
    Assert ($out -match 'PROFILE_ARGS=.*--skip-vcvars') 'the profile sees the profileArgs in [Environment]::GetCommandLineArgs()'
    Assert ($out4 -match 'PROFILE_ENV x=skip y=saved') 'profileEnv is set before the profile; the saved value of a variable wins'
    Assert ($out4 -match 'AFTER x=\[\] y=\[saved\]') 'profileEnv removed after the profile unless the saved tab has the variable'
    Remove-Item (Join-Path $state 'config.json') -ErrorAction SilentlyContinue; & $mod { $script:TR_ConfigCache = $null }

    Section 'restore-tab with a profile that loads the hook (variable collisions) + replay allowlist'
    Reset-State; & $mod { Initialize-TRDirs; $script:TR_ConfigCache = $null }
    '{"replayAllowlist":["fakeprog"]}' | Set-Content (Join-Path $state 'config.json') -Encoding UTF8
    "if (`$env:WT_SESSION) { . '$hook' }" | Set-Content $fprof -Encoding UTF8
    New-FakeTab 4002 ([datetime]'2026-01-01T10:00:01').Ticks $acc 'Write-Output RAN-REPLAY' 'x' $null (Join-Path $work 'rt2') ([pscustomobject]@{ name = 'fakeprog.exe' })
    New-FakeTab 4003 ([datetime]'2026-01-01T10:00:02').Ticks $acc 'Write-Output SHOULD-NOT-RUN' 'x' $null (Join-Path $work 'rt2') ([pscustomobject]@{ name = 'git.exe' })
    $env:TERMINALRESS_PROFILES = $fprof; $env:WT_SESSION = 'rt-test'
    $o1 = (& $psExe -NoProfile -ExecutionPolicy Bypass -Command ". '$rtScript' '$(Join-Path $work 'rt2\4002.json')'; 'HOOK=' + [bool]`$global:__TR" 2>&1 | Out-String)
    $o2 = (& $psExe -NoProfile -ExecutionPolicy Bypass -Command ". '$rtScript' '$(Join-Path $work 'rt2\4003.json')'; 'HOOK=' + [bool]`$global:__TR" 2>&1 | Out-String)
    $env:TERMINALRESS_PROFILES = $null; $env:WT_SESSION = $null
    Assert ($o1 -match 'HOOK=True' -and $o1 -match 'RAN-REPLAY') 'allowlisted program is re-run even though the profile loaded the hook into the same scope'
    Assert ($o2 -match 'HOOK=True' -and -not ($o2 -match 'SHOULD-NOT-RUN')) 'non-allowlisted program is not executed'

    Section 'profile pre-hook gate: WT relaunched before the guardian swept the dead tabs'
    $gate = Join-Path $work 'gate'
    $gateState = Join-Path $gate 'state'; $gateApp = Join-Path $gate 'app'
    New-Item -ItemType Directory -Force -Path (Join-Path $gateState 'live'), (Join-Path $gateState 'last'), (Join-Path $gateApp 'TerminalRess\runtime') | Out-Null
    "'PRE-ADOPT-CALLED'" | Set-Content (Join-Path $gateApp 'TerminalRess\runtime\pre-adopt.ps1') -Encoding UTF8
    $preBlock = (& $mod { Get-TRPreBlock }) -join "`r`n"
    $gateScript = Join-Path $gate 'pre.ps1'
    [IO.File]::WriteAllText($gateScript, "`$env:LOCALAPPDATA = '$gateApp'; `$env:TERMINALRESS_STATE = '$gateState'; `$env:WT_SESSION = 'gate'`r`n$preBlock", (New-Object Text.UTF8Encoding $true))
    $g0 = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $gateScript 2>&1 | Out-String)
    '{}' | Set-Content (Join-Path $gateState "live\$PID.json") -Encoding UTF8
    $g1 = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $gateScript 2>&1 | Out-String)
    Remove-Item (Join-Path $gateState "live\$PID.json")
    '{}' | Set-Content (Join-Path $gateState 'live\999999.json') -Encoding UTF8
    $g2 = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $gateScript 2>&1 | Out-String)
    Assert (-not ($g0 -match 'PRE-ADOPT-CALLED')) 'nothing saved and nothing dead: pre-adopt is not loaded'
    Assert (-not ($g1 -match 'PRE-ADOPT-CALLED')) 'only live tabs: pre-adopt is not loaded'
    Assert ($g2 -match 'PRE-ADOPT-CALLED') 'a dead tab not yet swept into last\ still triggers pre-adopt'

    Section 'runtime auto-update'
    $rt = $env:TERMINALRESS_RUNTIME
    $srcHook = [IO.File]::ReadAllText((Join-Path $modDir 'Runtime\tab-hook.ps1'))
    Assert (-not (Test-Path $rt)) 'module import with TerminalRess not installed creates no runtime'
    Assert (-not (& $mod { Update-TRRuntime $TR_ModuleRoot }) -and -not (Test-Path $rt)) 'not installed: update is a no-op and creates nothing'
    $st = Get-TerminalRessStatus
    Assert ($st.ModuleVersion -eq [version]$mv -and $null -eq $st.RuntimeVersion) "status: module $($st.ModuleVersion), no runtime"
    New-Item -ItemType Directory -Force -Path $rt | Out-Null
    'old' | Set-Content (Join-Path $rt 'tab-hook.ps1')
    Assert (& $mod { Update-TRRuntime $TR_ModuleRoot }) 'unstamped (pre-version.txt) runtime is updated'
    '0.9.0' | Set-Content (Join-Path $rt 'version.txt'); 'old' | Set-Content (Join-Path $rt 'tab-hook.ps1')
    Assert (& $mod { Update-TRRuntime $TR_ModuleRoot }) 'older runtime: updated'
    Assert ([IO.File]::ReadAllText((Join-Path $rt 'tab-hook.ps1')) -ceq $srcHook -and (Test-Path (Join-Path $rt 'guardian.ps1')) -and (Test-Path (Join-Path $rt 'Base.ps1'))) 'runtime files replaced by the module copy (new files added)'
    Assert ((Get-Content (Join-Path $rt 'version.txt') -Raw).Trim() -eq $mv -and (Get-TerminalRessStatus).RuntimeVersion -eq [version]$mv) 'runtime stamped with the module version (status shows it)'
    Assert (@(Get-ChildItem $rt -Filter '*.tmp').Count -eq 0) 'no staging files left behind'
    foreach ($v in $mv, '9.0.0') {
        $v | Set-Content (Join-Path $rt 'version.txt'); 'local' | Set-Content (Join-Path $rt 'tab-hook.ps1')
        $u = & $mod { Update-TRRuntime $TR_ModuleRoot }
        Assert (-not $u -and (Get-Content (Join-Path $rt 'tab-hook.ps1') -Raw).Trim() -eq 'local' -and (Get-Content (Join-Path $rt 'version.txt') -Raw).Trim() -eq $v) "runtime $v vs module ${mv}: untouched"
    }

    $roots = Join-Path $work 'modroots'
    foreach ($x in @(@('a', 'TerminalRess\1.0.0', '1.0.0', $true), @('b', 'TerminalRess\1.2.0', '1.2.0', $true), @('a', 'TerminalRess\1.5.0', '1.5.0', $false), @('c', 'TerminalRess', '1.1.0', $true))) {
        $d = Join-Path $roots "$($x[0])\$($x[1])"
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        "@{ ModuleVersion = '$($x[2])' }" | Set-Content (Join-Path $d 'TerminalRess.psd1')
        New-Item -ItemType Directory -Force -Path (Join-Path $d 'Runtime') | Out-Null
        foreach ($f in @(if ($x[3]) { 'Base.ps1', 'Common.ps1', 'tab-hook.ps1', 'guardian.ps1' } else { 'Base.ps1', 'Common.ps1' })) { '' | Set-Content (Join-Path $d "Runtime\$f") }
    }
    $best = & $mod { param($r) Find-TRNewestModule $r } @((Join-Path $roots 'a'), (Join-Path $roots 'b'), (Join-Path $roots 'c'), (Join-Path $roots 'none'))
    Assert ($best -eq (Join-Path $roots 'b\TerminalRess\1.2.0')) "newest complete module across roots (versioned + flat layouts, half-copied one skipped): $best"
    $mr = & $mod { @(Get-TRModuleRoots) }
    Assert (@($mr | Where-Object { $_ -like '*\PowerShell\Modules' }).Count -ge 1 -and @($mr | Where-Object { $_ -like '*\WindowsPowerShell\Modules' }).Count -ge 1) 'module roots cover both editions'

    Reset-State
    '0.9.0' | Set-Content (Join-Path $rt 'version.txt'); 'old' | Set-Content (Join-Path $rt 'tab-hook.ps1')
    $o = Invoke-ChildShell "Import-Module '$(Join-Path $modDir 'TerminalRess.psd1')'; 'IMPORTED'"
    Assert ($o -match 'IMPORTED' -and (Get-Content (Join-Path $rt 'version.txt') -Raw).Trim() -eq $mv -and [IO.File]::ReadAllText((Join-Path $rt 'tab-hook.ps1')) -ceq $srcHook) 'module import upgrades an older installed runtime'

    # a guardian running from an older installed runtime finds the newer module, updates the runtime and restarts itself
    Reset-State
    Get-ChildItem $rt -File | Remove-Item
    Copy-Item (Join-Path $modDir 'Runtime\*') $rt
    '0.9.0' | Set-Content (Join-Path $rt 'version.txt'); 'old' | Set-Content (Join-Path $rt 'tab-hook.ps1')
    try { $env:TERMINALRESS_MODULEROOTS = $root; & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $rt 'guardian.ps1') -Once | Out-Null }
    finally { Remove-Item Env:\TERMINALRESS_MODULEROOTS }
    $glog = Get-Content (Join-Path $state 'guardian.log') -Raw
    $dry = Get-Content (Join-Path $state 'dryrun.log') -Raw -ErrorAction SilentlyContinue
    Assert ((Get-Content (Join-Path $rt 'version.txt') -Raw).Trim() -eq $mv -and [IO.File]::ReadAllText((Join-Path $rt 'tab-hook.ps1')) -ceq $srcHook) 'guardian updates an older installed runtime from the newest module'
    Assert ($glog -match "guardian restarting on runtime $([regex]::Escape($mv))" -and $dry -like "*$(Join-Path $rt 'guardian.ps1')*") 'guardian exits and relaunches itself on the new runtime'
    Assert (-not (Test-Path (Join-Path $state 'guardian.pid')) -and -not (& $mod { Test-TRGuardianRunning })) 'old guardian released its mutex and pid file'
}
finally {
    Remove-Item Env:\TERMINALRESS_FORCE, Env:\TERMINALRESS_MODULEROOTS, Env:\TERMINALRESS_DRYRUN, Env:\TERMINALRESS_STATE, Env:\TERMINALRESS_RUNTIME, Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
    try { [IO.Directory]::Delete($work, $true) } catch { Write-Host "  (could not delete $work)" -ForegroundColor Yellow }
}
Write-Host ("`n{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $script:fail
