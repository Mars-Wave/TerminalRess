# TerminalRess shared library: Base.ps1 plus everything the restore paths, the guardian and the module need.
# Dot-sourced by the module, by the guardian, by pre-adopt/restore-tab and by startup.ps1 (the tab hook loads only Base.ps1).
# Keep it dependency free and Windows PowerShell 5.1 compatible.
# ASCII only: PowerShell 5.1 reads BOM-less files as ANSI.

. (Join-Path $PSScriptRoot 'Base.ps1')

# ---------------------------------------------------------------- io
function Write-TRJson([string]$Path, $Obj) {
    $tmp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, ($Obj | ConvertTo-Json -Depth 6 -Compress), $script:TR_Utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Write-TRJsonPretty([string]$Path, $Obj) { [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 6), $script:TR_Utf8) }
function Write-TRLog([string]$Message) {
    try {
        $log = Join-Path $script:TR_State 'guardian.log'
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 200KB) { Move-Item -LiteralPath $log "$log.old" -Force }
        [IO.File]::AppendAllText($log, ("{0:s} {1}`r`n" -f (Get-Date), $Message), $script:TR_Utf8)
    } catch { }
}
function Get-TRSessionId { [Diagnostics.Process]::GetCurrentProcess().SessionId }

# ---------------------------------------------------------------- runtime updates
# Profiles dot-source the installed copy, never the module, so a new module version only takes effect once its
# Runtime\ is copied over. runtime\version.txt records the module version the copy came from.
function Get-TRModuleVersion([string]$ModuleDir) {
    $p = Join-Path $ModuleDir 'TerminalRess.psd1'
    if (-not [IO.File]::Exists($p)) { return $null }
    $m = [regex]::Match([IO.File]::ReadAllText($p), "ModuleVersion\s*=\s*'([0-9.]+)'")
    if ($m.Success) { [version]$m.Groups[1].Value } else { $null }
}
function Get-TRRuntimeVersion([string]$Dir = $script:TR_InstalledRuntime) {
    $p = Join-Path $Dir 'version.txt'
    $v = $null
    if ([IO.File]::Exists($p) -and [version]::TryParse([IO.File]::ReadAllText($p).Trim(), [ref]$v)) { $v } else { $null }
}
function Set-TRFileSwap([string]$Tmp, [string]$Path) {
    # A shell dot-sourcing $Path sees the old or the new file, never half of one; a reader holding it open only delays the swap.
    try {
        for ($i = 1; ; $i++) {
            try {
                if ([IO.File]::Exists($Path)) { [IO.File]::Replace($Tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($Tmp, $Path) }
                return
            } catch { if ($i -ge 10) { throw }; Start-Sleep -Milliseconds 200 }
        }
    } finally { if ([IO.File]::Exists($Tmp)) { [IO.File]::Delete($Tmp) } }
}
function Copy-TRRuntime([string]$Src, [string]$Dst, [version]$Version) {
    if (-not (Test-Path -LiteralPath $Dst)) { New-Item -ItemType Directory -Force -Path $Dst | Out-Null }
    # files new to $Dst first: an updated file may dot-source one the old runtime did not have
    foreach ($f in Get-ChildItem -LiteralPath $Src -File | Sort-Object { [IO.File]::Exists((Join-Path $Dst $_.Name)) }, Name) {
        if ($f.Name -eq 'version.txt') { continue }
        $to = Join-Path $Dst $f.Name
        [IO.File]::Copy($f.FullName, "$to.$PID.tmp", $true)
        Set-TRFileSwap "$to.$PID.tmp" $to
    }
    # stamped last: an interrupted copy stays older and is retried by the next sync
    $vf = Join-Path $Dst 'version.txt'
    [IO.File]::WriteAllText("$vf.$PID.tmp", [string]$Version, $script:TR_Utf8)
    Set-TRFileSwap "$vf.$PID.tmp" $vf
}
function Update-TRRuntime([string]$ModuleDir) {
    # Upgrade only, and only an installed runtime: never creates it, never downgrades.
    if (-not $ModuleDir -or -not [IO.Directory]::Exists($script:TR_InstalledRuntime)) { return $false }
    $v = Get-TRModuleVersion $ModuleDir
    $src = Join-Path $ModuleDir 'Runtime'
    if (-not $v -or -not [IO.Directory]::Exists($src)) { return $false }
    # check-and-copy under one lock: an older module (the other edition's folder) must not slip in after a newer one
    $created = $false
    $m = New-Object Threading.Mutex($false, (Get-TRMutexName 'Runtime'), [ref]$created)
    try { $null = $m.WaitOne(30000) } catch [Threading.AbandonedMutexException] { }
    try {
        $cur = Get-TRRuntimeVersion
        if ($cur -and $cur -ge $v) { return $false }
        Copy-TRRuntime $src $script:TR_InstalledRuntime $v
    } finally { try { $m.ReleaseMutex() } catch { }; $m.Dispose() }
    Write-TRLog "runtime updated $cur -> $v from $ModuleDir"
    $true
}
function Get-TRModuleRoots {
    if ($env:TERMINALRESS_MODULEROOTS) { return @($env:TERMINALRESS_MODULEROOTS -split ';' | Where-Object { $_ }) }
    # both editions: the guardian runs under 5.1, whose PSModulePath lacks the pwsh 7 folders
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $r = @($env:PSModulePath -split ';') + @((Join-Path $docs 'WindowsPowerShell\Modules'), (Join-Path $docs 'PowerShell\Modules'),
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'), (Join-Path $env:ProgramFiles 'PowerShell\Modules'))
    $seen = @{}
    foreach ($x in $r) { if ($x) { $k = $x.TrimEnd('\').ToLowerInvariant(); if (-not $seen[$k]) { $seen[$k] = 1; $x.TrimEnd('\') } } }
}
function Find-TRNewestModule([string[]]$Roots = @(Get-TRModuleRoots)) {
    $best = $null; $bestV = $null
    foreach ($r in $Roots) {
        $base = Join-Path $r 'TerminalRess'
        if (-not [IO.Directory]::Exists($base)) { continue }
        foreach ($d in @($base) + @([IO.Directory]::GetDirectories($base))) {
            $v = Get-TRModuleVersion $d
            if (-not $v -or ($bestV -and $v -le $bestV)) { continue }
            # a version Update-Module is still copying in must not be taken (and stamped) half-populated
            $rt = Join-Path $d 'Runtime'
            if (@('Base.ps1', 'Common.ps1', 'tab-hook.ps1', 'guardian.ps1' | Where-Object { -not [IO.File]::Exists((Join-Path $rt $_)) }).Count -eq 0) { $best = $d; $bestV = $v }
        }
    }
    $best
}

# ---------------------------------------------------------------- tab files
# <pid>.json is written by the tab's hook only; the guardian writes the sidecars <pid>.run.json (foreground child) and
# <pid>.owner.json (owning WT), so neither ever rewrites a file the other one owns.
function Get-TRTabFiles([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File | Where-Object { $_.Name -notlike '*.*.json' })
}
function Get-TRRunPath([string]$TabPath) { $TabPath -replace '\.json$', '.run.json' }
function Get-TROwnerPath([string]$TabPath) { $TabPath -replace '\.json$', '.owner.json' }
function Get-TRTabFileSet([string]$TabPath) { @($TabPath, (Get-TRRunPath $TabPath), (Get-TROwnerPath $TabPath)) }
function Remove-TRTabFiles([string]$TabPath) {
    foreach ($p in Get-TRTabFileSet $TabPath) { if (Test-Path -LiteralPath $p) { [IO.File]::Delete($p) } }
}
function Move-TRTabFiles([string]$TabPath, [string]$DestDir) {
    foreach ($p in Get-TRTabFileSet $TabPath) {
        if (Test-Path -LiteralPath $p) { Move-Item -LiteralPath $p -Destination $DestDir -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------- liveness
# .NET, no CIM (the guardian uses [TRNative.Procs]::IsAlive).
function Test-TRShellAlive($Tab) {
    try { $p = [Diagnostics.Process]::GetProcessById([int]$Tab.shellPid); return ([math]::Abs($p.StartTime.Ticks - [int64]$Tab.shellStart) -lt 30000000) } catch { return $false }
}
function Get-TRWtProcesses($SessionId) {
    @([Diagnostics.Process]::GetProcessesByName('WindowsTerminal') | Where-Object { $null -eq $SessionId -or $_.SessionId -eq $SessionId })
}
function Get-TRTabSession($Tab) { if ($null -ne $Tab.session) { [int]$Tab.session } else { Get-TRSessionId } }

# The tab file with the owning WT (wtPid + wtStart) merged in from the guardian's owner sidecar. Seeded tab files carry
# the owner themselves. The sidecar must match shellStart: a reused PID must not inherit a stale owner.
function Read-TRTab([string]$Path) {
    $t = Read-TRJson $Path
    if ($t -and -not $t.wtPid) {
        $o = Read-TRJson (Get-TROwnerPath $Path)
        if ($o -and [int64]$o.shellStart -eq [int64]$t.shellStart) {
            $t | Add-Member wtPid $o.wtPid -Force; $t | Add-Member wtStart $o.wtStart -Force
        }
    }
    $t
}
# shell -> OpenConsole -> WindowsTerminal in a process snapshot ($ById: ProcessId -> object with ParentProcessId, Name and
# CreationDate, as Win32_Process or TRNative.Proc). $null when not under a WT.
# A parent must be older than its child, or its PID was reused after the real parent ended.
function Find-TROwnerInSnapshot([int]$ShellPid, $ById) {
    $c = $ById[[uint32]$ShellPid]
    if (-not $c) { return $null }
    $p = $ById[[uint32]$c.ParentProcessId]
    if ($p -and $p.Name -ieq 'OpenConsole.exe' -and $p.CreationDate -le $c.CreationDate) { $c = $p; $p = $ById[[uint32]$c.ParentProcessId] }
    if ($p -and $p.Name -ieq 'WindowsTerminal.exe' -and $p.CreationDate -le $c.CreationDate) { return $p }
    $null
}
# Records the owning WT of a live tab that has none yet (the hook leaves that to the guardian, which has a process snapshot).
function Set-TRTabOwner([string]$TabPath, $Tab, $ById) {
    if ($Tab.wtPid) { return }
    $w = Find-TROwnerInSnapshot ([int]$Tab.shellPid) $ById
    if ($w) { Write-TRJson (Get-TROwnerPath $TabPath) ([ordered]@{ shellPid = [int]$Tab.shellPid; shellStart = [int64]$Tab.shellStart; wtPid = [int]$w.ProcessId; wtStart = $w.CreationDate.Ticks }) }
}
# $true/$false = owner alive/gone, $null = owner unknown.
function Test-TROwnerAlive($Tab) {
    if (-not $Tab.wtPid -or -not $Tab.wtStart) { return $null }
    try { $p = [Diagnostics.Process]::GetProcessById([int]$Tab.wtPid); return ([math]::Abs($p.StartTime.Ticks - [int64]$Tab.wtStart) -lt 30000000) } catch { return $false }
}
# A dead tab shell: owning WT still alive -> the user closed the tab ('closed'); owner gone -> 'ended' (previous generation).
# Owner unknown: any WT that was already running when the shell started counts as the owner.
function Get-TRDeadTabVerdict($Tab) {
    $o = Test-TROwnerAlive $Tab
    if ($o -eq $true) { return 'closed' }
    if ($o -eq $false) { return 'ended' }
    $started = [datetime]::new([int64]$Tab.shellStart)
    foreach ($w in (Get-TRWtProcesses (Get-TRTabSession $Tab))) {
        try { if ($w.StartTime -le $started.AddSeconds(1)) { return 'closed' } } catch { }
    }
    'ended'
}
function Resolve-TRDeadTab($TabFile, $Tab) {
    # a typed `exit` is a deliberate close, even when it ends the last tab and WT with it
    if ($Tab.exiting -or (Get-TRDeadTabVerdict $Tab) -eq 'closed') { Remove-TRTabFiles $TabFile.FullName; return 'deleted' }
    Move-TRTabFiles $TabFile.FullName $script:TR_Last; 'moved'
}
# Moves dead tabs of an ended generation into last\ (typed-exit tabs are dropped). Other deletions need the guardian grace period.
function Invoke-TRSweep {
    Initialize-TRDirs
    foreach ($f in Get-TRTabFiles $script:TR_Live) {
        $tab = Read-TRTab $f.FullName
        if (-not $tab -or (Test-TRShellAlive $tab)) { continue }
        if ($tab.exiting) { Remove-TRTabFiles $f.FullName; continue }
        if ((Get-TRDeadTabVerdict $tab) -eq 'ended') { Move-TRTabFiles $f.FullName $script:TR_Last }
    }
}
# shell -> OpenConsole -> WindowsTerminal. Returns @{ ParentName; Pid; Start; Path } (Pid/Start/Path null when not found).
function Get-TROwnerWt([int]$ShellPid = $PID) {
    $r = [ordered]@{ ParentName = $null; Pid = $null; Start = $null; Path = $null }
    try {
        $ppid = (Get-CimInstance Win32_Process -Filter "ProcessId=$ShellPid" -Property ParentProcessId -ErrorAction Stop).ParentProcessId
        $parent = [Diagnostics.Process]::GetProcessById([int]$ppid)
        $r.ParentName = $parent.ProcessName
        $wtp = $null
        if ($parent.ProcessName -eq 'WindowsTerminal') { $wtp = $parent }
        elseif ($parent.ProcessName -eq 'OpenConsole') {
            $gp = (Get-CimInstance Win32_Process -Filter "ProcessId=$ppid" -Property ParentProcessId -ErrorAction Stop).ParentProcessId
            $c = [Diagnostics.Process]::GetProcessById([int]$gp)
            if ($c.ProcessName -eq 'WindowsTerminal') { $wtp = $c }
        }
        if ($wtp) {
            $r.Pid = $wtp.Id; $r.Start = $wtp.StartTime.Ticks
            try { $r.Path = $wtp.MainModule.FileName } catch { }
        }
    } catch { }
    [pscustomobject]$r
}
function Get-TRLiveAliveTabs([int]$ExceptPid = 0) {
    foreach ($f in Get-TRTabFiles $script:TR_Live) {
        $t = Read-TRJson $f.FullName
        if ($t -and [int]$t.shellPid -ne $ExceptPid -and (Test-TRShellAlive $t)) { $t }
    }
}

# ---------------------------------------------------------------- processes
function Get-TRWtPath($Owner) {
    # the wt.exe that sits next to the WindowsTerminal.exe that owns the current tab comes first, so a second
    # install (portable copy, preview) restores into ITS OWN terminal
    if ($Owner -and $Owner.Path) {
        $own = Join-Path (Split-Path $Owner.Path) 'wt.exe'
        if (Test-Path -LiteralPath $own) { return $own }
    }
    $cfg = Get-TRConfig
    if ($cfg.wtPath -and (Test-Path -LiteralPath $cfg.wtPath)) { return [string]$cfg.wtPath }
    $c = Get-Command wt.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $cands = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\WindowsTerminal\wt.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Windows Terminal\wt.exe'),
        (Join-Path $env:ProgramFiles 'WindowsTerminal\wt.exe'),
        (Join-Path $HOME 'scoop\apps\windows-terminal\current\wt.exe'),
        (Join-Path $HOME 'scoop\apps\windows-terminal-preview\current\wt.exe'))
    foreach ($p in $cands) { if (Test-Path -LiteralPath $p) { return $p } }
    foreach ($w in (Get-TRWtProcesses (Get-TRSessionId))) {
        try { $p = Join-Path (Split-Path $w.MainModule.FileName) 'wt.exe'; if (Test-Path -LiteralPath $p) { return $p } } catch { }
    }
    $null
}
# ---------------------------------------------------------------- argv / resume handlers
function Get-TRArgv([string]$CommandLine) {
    if (-not ('TRNative.Args' -as [type])) {
        Add-Type -Namespace TRNative -Name Args -MemberDefinition @'
[DllImport("shell32.dll", SetLastError=true)] static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string cl, out int n);
[DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr h);
public static string[] Split(string cl) {
  int n; IntPtr p = CommandLineToArgvW(cl, out n);
  if (p == IntPtr.Zero) return new string[0];
  try { var r = new string[n]; for (int i = 0; i < n; i++) r[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(p, i * IntPtr.Size)); return r; }
  finally { LocalFree(p); }
}
'@
    }
    [string[]][TRNative.Args]::Split($CommandLine)
}

# ---------------------------------------------------------------- guardian loop
# The guardian runs for days, so its loop must cost next to nothing: processes are checked by PID, the process table is read
# with Toolhelp (a fifth of a full Win32_Process query, and no WmiPrvSE work) only when needed, and its wait wakes on a tab
# file change or a tab shell exit instead of polling fast.
function Initialize-TRNativeProcs {
    if ('TRNative.Procs' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
namespace TRNative {
public sealed class Proc {
    public uint ProcessId; public uint ParentProcessId; public string Name;
    bool queried; DateTime? created;
    // local time like Win32_Process.CreationDate and Process.StartTime; null when the process cannot be opened
    public DateTime? CreationDate { get { if (!queried) { queried = true; created = Procs.StartTime(ProcessId); } return created; } }
}
public sealed class ProcSnapshot {
    public Hashtable ById = new Hashtable();
    readonly Dictionary<uint, List<Proc>> byParent = new Dictionary<uint, List<Proc>>();
    internal void Add(Proc p) {
        ById[p.ProcessId] = p;
        List<Proc> l;
        if (!byParent.TryGetValue(p.ParentProcessId, out l)) { l = new List<Proc>(); byParent[p.ParentProcessId] = l; }
        l.Add(p);
    }
    public Proc[] Children(int pid) { List<Proc> l; return byParent.TryGetValue((uint)pid, out l) ? l.ToArray() : new Proc[0]; }
}
public static class Procs {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Entry {
        public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID; public uint th32ModuleID, cntThreads, th32ParentProcessID;
        public int pcPriClassBase; public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr h, ref Entry e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr h, ref Entry e);
    [DllImport("kernel32.dll")] internal static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] internal static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr h, out long created, out long exited, out long kernel, out long user);
    public static ProcSnapshot Snapshot() {
        IntPtr h = CreateToolhelp32Snapshot(2, 0);
        if (h == new IntPtr(-1)) throw new InvalidOperationException("CreateToolhelp32Snapshot failed: " + Marshal.GetLastWin32Error());
        try {
            var s = new ProcSnapshot();
            var e = new Entry(); e.dwSize = (uint)Marshal.SizeOf(typeof(Entry));
            for (bool ok = Process32FirstW(h, ref e); ok; ok = Process32NextW(h, ref e)) {
                if (e.th32ProcessID == 0) continue;
                var p = new Proc(); p.ProcessId = e.th32ProcessID; p.ParentProcessId = e.th32ParentProcessID; p.Name = e.szExeFile;
                s.Add(p);
            }
            return s;
        } finally { CloseHandle(h); }
    }
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    public static DateTime? StartTime(uint pid) {
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) return null;
        try { long c, x, k, u; return GetProcessTimes(h, out c, out x, out k, out u) ? DateTime.FromFileTime(c) : (DateTime?)null; }
        finally { CloseHandle(h); }
    }
    // running (an exited process stays openable while anyone holds a handle) and started within 3 s of startTicks: not a reused PID
    public static bool IsAlive(int pid, long startTicks) {
        IntPtr h = OpenProcess(0x1000, false, (uint)pid);
        if (h == IntPtr.Zero) return false;
        try {
            uint code; long c, x, k, u;
            if (!GetExitCodeProcess(h, out code) || code != 259 || !GetProcessTimes(h, out c, out x, out k, out u)) return false;
            return Math.Abs(DateTime.FromFileTime(c).Ticks - startTicks) < 30000000;
        } finally { CloseHandle(h); }
    }
}
public sealed class Waiter : IDisposable {
    [DllImport("kernel32.dll")] static extern uint WaitForMultipleObjects(uint n, IntPtr[] handles, bool all, uint ms);
    readonly AutoResetEvent changed = new AutoResetEvent(false);
    readonly FileSystemWatcher watcher;
    public Waiter(string dir) {
        watcher = new FileSystemWatcher(dir);
        watcher.NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite;
        watcher.Created += OnChange; watcher.Changed += OnChange; watcher.Deleted += OnChange; watcher.Renamed += OnChange;
        watcher.EnableRaisingEvents = true;
    }
    void OnChange(object sender, FileSystemEventArgs e) {
        // tab files (<pid>.json) only: the guardian's own sidecar writes must not wake it
        string n = e.Name;
        if (n != null && n.EndsWith(".json", StringComparison.OrdinalIgnoreCase) && n.IndexOf('.') == n.Length - 5) changed.Set();
    }
    // 0 = timed out, 1 = a tab file changed, 2 = one of the processes ended
    public int Wait(int ms, int[] pids) {
        var hs = new List<IntPtr>(); hs.Add(changed.SafeWaitHandle.DangerousGetHandle());
        try {
            foreach (int pid in pids) { if (hs.Count >= 64) break; IntPtr h = Procs.OpenProcess(0x00100000, false, (uint)pid); if (h != IntPtr.Zero) hs.Add(h); }
            uint r = WaitForMultipleObjects((uint)hs.Count, hs.ToArray(), false, (uint)ms);
            if (r == 0) return 1;
            if (r < (uint)hs.Count) return 2;
            if (r == 0xFFFFFFFF) Thread.Sleep(ms);
            return 0;
        } finally { for (int i = 1; i < hs.Count; i++) Procs.CloseHandle(hs[i]); }
    }
    // one write raises several notifications: drop the rest once the loop is about to look anyway
    public void Reset() { changed.Reset(); }
    public void Dispose() { watcher.Dispose(); changed.Dispose(); }
}
}
'@
}
function New-TRGuardianState {
    $native = $true
    try { Initialize-TRNativeProcs } catch {     # no C# compiler (AV, policy, Constrained Language): fall back to the slower path
        $native = $false; Write-TRLog "native process helpers unavailable, using Get-Process and CIM: $($_.Exception.Message)"
    }
    @{
        Native = $native
        Grace = [int](Get-TRConfig).graceSeconds; Session = Get-TRSessionId; SessionsDir = Get-TRClaudeSessionsDir
        IgnoreNames = @('conhost.exe', 'OpenConsole.exe')
        Tabs      = @{}    # tab path -> @{ Stamp; Tab }: a tab file is parsed again only when it or its owner sidecar changes
        Child     = @{}    # shellPid -> its foreground child (pid, start, name, exe, command line)
        NextScan  = @{}    # shellPid -> when to look for a child again in a tab that runs a command without one
        ReadAt    = @{}    # shellPid -> when its tab file last changed: a just-typed command may start its child late
        QuickScanSec = 15
        Claude    = $false # a claude.exe child is known: /resume and /clear are seen only on a loop, so no idle interval
        DeadSince = @{}    # shellPid -> first seen dead
        NoChild   = @{}    # shellPid -> consecutive loops without a foreground child
        RunKey    = @{}    # shellPid -> child pid|start|claude sessions file time the run file was built from
        RunSig    = @{}    # shellPid -> last written run file content
        Alive     = New-Object 'Collections.Generic.List[int]'   # live tab shells to wake on when they end
        Idle      = 0      # consecutive loops in which nothing changed
        IdleAfter = 5
    }
}
function Get-TRRunInfo($Child, [int]$ShellPid) {
    $argv = @()
    try { if ($Child.CommandLine) { $argv = Get-TRArgv $Child.CommandLine } } catch { }
    $info = [ordered]@{ shellPid = $ShellPid; childPid = [int]$Child.ProcessId; name = $Child.Name; exe = $Child.ExecutablePath; commandLine = $Child.CommandLine; argv = $argv }
    $resume = Get-TRResumeCommand $Child $argv
    if ($resume) { $info['resume'] = $resume }
    $info
}
function Test-TRProcAlive($G, [int]$Id, [long]$StartTicks) {
    if ($G.Native) { return [TRNative.Procs]::IsAlive($Id, $StartTicks) }
    try { $p = [Diagnostics.Process]::GetProcessById($Id); -not $p.HasExited -and [Math]::Abs($p.StartTime.Ticks - $StartTicks) -lt 30000000 } catch { $false }
}
# A process table with ById (uint32 pid -> process with ParentProcessId, Name, CreationDate) and Children(pid).
function Get-TRProcSnapshot($G) {
    if ($G.Native) { return [TRNative.Procs]::Snapshot() }
    $byId = @{}; $byParent = @{}
    foreach ($p in Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,Name,CreationDate) {
        $byId[[uint32]$p.ProcessId] = $p
        $l = $byParent[[uint32]$p.ParentProcessId]
        if (-not $l) { $l = New-Object 'Collections.Generic.List[object]'; $byParent[[uint32]$p.ParentProcessId] = $l }
        $l.Add($p)
    }
    $s = [pscustomobject]@{ ById = $byId; ByParent = $byParent }
    $s | Add-Member ScriptMethod Children { param($Id) $l = $this.ByParent[[uint32]$Id]; if ($l) { $l.ToArray() } }
    $s
}
# The foreground program of a live shell in a process snapshot: claude.exe first, else the newest child. $null when there is none.
function Get-TRForegroundChild($G, $Snap, [int]$ShellPid) {
    $start = $Snap.ById[[uint32]$ShellPid].CreationDate
    $kids = @(foreach ($k in $Snap.Children($ShellPid)) {
        # a child older than the shell belonged to an earlier owner of the PID; this guardian itself is spawned by the first tab
        if ($k.ProcessId -ne $PID -and $G.IgnoreNames -notcontains $k.Name -and $k.CreationDate -ge $start) { $k }
    })
    if ($kids.Count -gt 1) { $kids = @($kids | Sort-Object @{ e = { $_.Name -ine 'claude.exe' } }, @{ e = { $_.CreationDate }; Descending = $true }) }
    foreach ($k in $kids) {
        $c = Get-CimInstance Win32_Process -Filter "ProcessId=$($k.ProcessId)" -Property ProcessId,CommandLine,ExecutablePath -ErrorAction SilentlyContinue
        if (-not $c -or $c.CommandLine -like '*guardian.ps1*') { continue }   # gone, or another state dir's guardian
        return [pscustomobject]@{ ProcessId = [int]$k.ProcessId; Start = $k.CreationDate.Ticks; Name = $k.Name; ExecutablePath = $c.ExecutablePath; CommandLine = $c.CommandLine }
    }
    $null
}
# One guardian loop over live\: records foreground children and owners of live tabs, resolves dead ones after the grace
# period. Returns $true when anything changed or is still pending ($G.Idle counts the quiet loops in a row).
# The process snapshot is taken only when a tab changed or lost its foreground child: a running program is re-checked by PID.
function Invoke-TRGuardianTick($G) {
    $active = $false
    $G.Alive.Clear(); $G.Claude = $false
    $all = @{}
    if ([IO.Directory]::Exists($script:TR_Live)) { foreach ($fi in ([IO.DirectoryInfo]$script:TR_Live).GetFiles('*.json')) { $all[$fi.Name] = $fi } }
    # a sidecar written just as its tab was moved or deleted elsewhere would linger; a tab still in last\ is mid-move
    foreach ($n in @($all.Keys)) {
        $tabName = $n -replace '\..*$', '.json'
        if (-not $all.ContainsKey($tabName) -and -not [IO.File]::Exists((Join-Path $script:TR_Last $tabName))) {
            Remove-Item -LiteralPath $all[$n].FullName -Force -ErrorAction SilentlyContinue; $all.Remove($n)
        }
    }
    $snap = $null; $seen = @{}; $paths = @{}; $now = [DateTime]::UtcNow
    foreach ($f in @($all.Values)) {
        if ($f.Name -like '*.*.json') { continue }
        $paths[$f.FullName] = 1
        $o = $all[$f.BaseName + '.owner.json']
        $stamp = "$($f.LastWriteTimeUtc.Ticks)|$($f.Length)|$(if ($o) { $o.LastWriteTimeUtc.Ticks })"
        $c = $G.Tabs[$f.FullName]
        $changed = -not $c -or $c.Stamp -ne $stamp
        if ($changed) {
            $active = $true
            $c = @{ Stamp = $stamp; Tab = (Read-TRTab $f.FullName) }
            if ($c.Tab) { $G.Tabs[$f.FullName] = $c } else { $G.Tabs.Remove($f.FullName) }   # unreadable: retried next loop
        }
        $tab = $c.Tab
        if (-not $tab) { continue }
        $spid = [int]$tab.shellPid
        $seen[$spid] = 1
        if ($changed) { $G.ReadAt[$spid] = $now }
        if (Test-TRProcAlive $G $spid ([int64]$tab.shellStart)) {
            $G.DeadSince.Remove($spid)
            $G.Alive.Add($spid)
            if ((Get-TRTabSession $tab) -ne $G.Session) { continue }
            if ($changed -and -not $tab.wtPid) {
                if (-not $snap) { $snap = Get-TRProcSnapshot $G }
                try { Set-TRTabOwner $f.FullName $tab $snap.ById } catch { Write-TRLog "owner write $spid failed: $($_.Exception.Message)" }   # must not starve the rest of the loop
            }
            $runName = $f.BaseName + '.run.json'
            $runPath = $f.DirectoryName + '\' + $runName      # no Join-Path: this runs for every tab on every loop
            $child = $null
            if ($tab.pendingCommand) {     # at a prompt nothing runs in the foreground: the hook clears pendingCommand there
                $k = $G.Child[$spid]
                if (-not $changed -and $k -and (Test-TRProcAlive $G $k.ProcessId $k.Start)) { $child = $k }
                elseif (-not $changed -and $G.NextScan[$spid] -and $now -lt $G.NextScan[$spid]) { continue }
                else {
                    if (-not $snap) { $snap = Get-TRProcSnapshot $G }
                    $child = Get-TRForegroundChild $G $snap $spid
                }
            }
            $G.Child[$spid] = $child
            if (-not $child) {
                $G.NoChild[$spid] = 1 + [int]$G.NoChild[$spid]
                # two consecutive empty loops: avoids deleting the run file while a dying WT takes children first
                if ($G.NoChild[$spid] -lt 2) { $active = $true; continue }
                if ($all.ContainsKey($runName)) {
                    Remove-Item -LiteralPath $runPath -Force -ErrorAction SilentlyContinue
                    $G.RunSig.Remove($spid); $G.RunKey.Remove($spid); $active = $true
                }
                # a long in-process command (a script, Start-Sleep) has no child: look again every 30 s or when the tab changes,
                # but keep looking every loop for a while after the command was typed, as a slow program starts its child late
                if (-not $tab.pendingCommand) { $G.NextScan.Remove($spid) }
                elseif (($now - $G.ReadAt[$spid]).TotalSeconds -lt $G.QuickScanSec) { $G.NextScan.Remove($spid); $active = $true }
                else { $G.NextScan[$spid] = $now.AddSeconds(30) }
                continue
            }
            $G.NoChild[$spid] = 0; $G.NextScan.Remove($spid)
            # /resume and /clear switch claude's session without a new process: its sessions file changes then
            $sess = if ($child.Name -ieq 'claude.exe') { $G.Claude = $true; [IO.File]::GetLastWriteTimeUtc($G.SessionsDir + "\$($child.ProcessId).json").Ticks }
            $key = "$($child.ProcessId)|$($child.Start)|$sess"
            if ($G.RunKey[$spid] -ne $key -or -not $all.ContainsKey($runName)) {
                $info = Get-TRRunInfo $child $spid
                $sig = $info | ConvertTo-Json -Depth 6 -Compress
                if ($G.RunSig[$spid] -ne $sig -or -not $all.ContainsKey($runName)) {
                    $info['updatedAt'] = [DateTime]::UtcNow.ToString('o')
                    Write-TRJson $runPath $info
                    $G.RunSig[$spid] = $sig; $active = $true
                }
                $G.RunKey[$spid] = $key
            }
        } else {
            $active = $true
            if (-not $G.DeadSince.ContainsKey($spid)) { $G.DeadSince[$spid] = $now }
            if (($now - $G.DeadSince[$spid]).TotalSeconds -ge $G.Grace) {
                $r = Resolve-TRDeadTab $f $tab
                Write-TRLog "shell $spid dead -> $r"
                $G.Tabs.Remove($f.FullName); $seen.Remove($spid)
            }
        }
    }
    foreach ($k in @($G.Tabs.Keys)) { if (-not $paths.ContainsKey($k)) { $G.Tabs.Remove($k); $active = $true } }
    foreach ($m in $G.DeadSince, $G.NoChild, $G.RunKey, $G.RunSig, $G.Child, $G.NextScan, $G.ReadAt) { foreach ($k in @($m.Keys)) { if (-not $seen.ContainsKey($k)) { $m.Remove($k) } } }
    if ($active) { $G.Idle = 0 } else { $G.Idle++ }
    $active
}

# Claude Code: keep the original flags, drop session selection / print / prompt, append --resume <id>.
function ConvertTo-TRClaudeResumeArgs([string[]]$Argv, [string]$SessionId) {
    $valueFlags    = 'model', 'permission-mode', 'settings', 'append-system-prompt', 'system-prompt', 'agent', 'agents', 'fallback-model', 'max-turns', 'output-format', 'input-format', 'name', 'n', 'setting-sources', 'betas', 'effort', 'permission-prompt-tool', 'max-budget-usd', 'ide-port', 'teammate-mode', 'debug-file'
    $variadicFlags = 'add-dir', 'allowedTools', 'allowed-tools', 'disallowedTools', 'disallowed-tools', 'mcp-config', 'plugin-dir', 'tools'
    $dropBool      = 'continue', 'c', 'fork-session', 'print', 'p'
    $out = New-Object 'Collections.Generic.List[string]'
    $i = 1
    while ($i -lt $Argv.Count) {
        $a = $Argv[$i]
        if ($a -eq '--') { break }
        if ($a -match '^--?([^=]+)=') {
            if ($Matches[1] -in 'resume', 'r', 'session-id') { $i++; continue }
            $out.Add($a); $i++; continue
        }
        if ($a -match '^--?(.+)$') {
            $n = $Matches[1]
            if ($n -in 'resume', 'r') { $i++; if ($i -lt $Argv.Count -and $Argv[$i] -notlike '-*') { $i++ }; continue }
            if ($n -eq 'session-id')  { $i++; if ($i -lt $Argv.Count) { $i++ }; continue }
            if ($n -in $dropBool)     { $i++; continue }
            $out.Add($a); $i++
            if ($n -in $valueFlags -and $i -lt $Argv.Count) { $out.Add($Argv[$i]); $i++ }
            elseif ($n -in $variadicFlags) { while ($i -lt $Argv.Count -and $Argv[$i] -notlike '-*') { $out.Add($Argv[$i]); $i++ } }
            continue
        }
        $i++   # positional prompt: dropped
    }
    if ($SessionId) { $out.Add('--resume'); $out.Add($SessionId) }
    ,$out.ToArray()
}
function Get-TRClaudeSessionsDir {
    $base = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    Join-Path $base 'sessions'
}
function Get-TRClaudeResume($Child, [string[]]$Argv) {
    $sid = $null; $cwd = $null
    $sf = Join-Path (Get-TRClaudeSessionsDir) "$($Child.ProcessId).json"
    if (Test-Path -LiteralPath $sf) { $s = Read-TRJson $sf; if ($s) { $sid = $s.sessionId; $cwd = $s.cwd } }
    if (-not $sid -and $Argv) {          # fallback: the command line
        for ($i = 1; $i -lt $Argv.Count - 1; $i++) { if ($Argv[$i] -in '--resume', '-r', '--session-id') { $sid = $Argv[$i + 1]; break } }
        if ($sid -notmatch '^[0-9a-fA-F-]{36}$') { $sid = $null }
    }
    $rargs = if ($sid) { ConvertTo-TRClaudeResumeArgs $Argv $sid } elseif ($Argv.Count -gt 1) { [string[]]$Argv[1..($Argv.Count - 1)] } else { @() }
    [ordered]@{ handler = 'claude'; exe = $Child.ExecutablePath; args = @($rargs); cwd = $cwd; sessionId = $sid }
}
function Get-TRClaudeProjectsDir {
    $base = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    Join-Path $base 'projects'
}
# A session handed to Claude's background daemon goes on under a new id: its transcript ends with a continued-in record.
# Follows that chain; a record followed by more messages (the old session was used again) does not count.
function Get-TRClaudeContinuation([string]$SessionId, [string]$ProjectsDir = (Get-TRClaudeProjectsDir)) {
    if (-not [IO.Directory]::Exists($ProjectsDir)) { return $SessionId }
    $seen = @{}
    while ($SessionId -and -not $seen.ContainsKey($SessionId) -and $seen.Count -lt 8) {
        $seen[$SessionId] = 1
        $file = $null
        foreach ($d in [IO.Directory]::GetDirectories($ProjectsDir)) { $p = Join-Path $d "$SessionId.jsonl"; if ([IO.File]::Exists($p)) { $file = $p; break } }
        if (-not $file) { break }
        $next = $null
        try {
            $fs = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
            try {
                $fs.Seek([Math]::Max(0, $fs.Length - 65536), 'Begin') | Out-Null
                $lines = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() -split "`n"
            } finally { $fs.Dispose() }
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                $l = $lines[$i]
                if ($l -match '"type":"(user|assistant)"') { break }
                if ($l -match '"type":"continued-in"' -and $l -match '"continuedInSessionId":"([0-9a-fA-F-]{36})"') { $next = $Matches[1]; break }
            }
        } catch { }
        if (-not $next) { break }
        $SessionId = $next
    }
    $SessionId
}
# Live Claude sessions as reported by `claude agents --json` (documented; --all adds finished background ones). $null on failure.
function Get-TRClaudeAgents([string]$Exe, [switch]$All) {
    try {
        $a = @('agents', '--json'); if ($All) { $a += '--all' }
        $out = & $Exe @a 2>$null | Out-String
        if ($LASTEXITCODE -ne 0 -or -not $out.Trim()) { return $null }
        @($out | ConvertFrom-Json | ForEach-Object { $_ })
    } catch { $null }
}
# Restore-time fix-up of a claude Resume action for sessions living in the background daemon:
#   - the tab ran `claude --resume X` and X was later moved to the background (now Y): attach to Y if it is still running,
#     otherwise resume Y with the original flags;
#   - the tab ran `claude attach Y`: attach again if Y is still running, otherwise resume Y's session.
# $AgentsFn (tests) returns the agent list for a [bool] "all" argument.
function Resolve-TRClaudeAction($Act, $Run, [string]$ProjectsDir = (Get-TRClaudeProjectsDir), [scriptblock]$AgentsFn) {
    if (-not $Act -or $Act.Kind -ne 'Resume' -or -not $Run -or -not $Run.resume -or $Run.resume.handler -ne 'claude') { return $Act }
    if (-not $AgentsFn) { $exe = $Act.Exe; $AgentsFn = { param($all) Get-TRClaudeAgents $exe -All:$all }.GetNewClosure() }
    $argv = [string[]]@($Run.argv)
    $attach = if ($argv.Count -ge 3 -and $argv[1] -eq 'attach') { $argv[2] } else { $null }
    $sid = [string]$Run.resume.sessionId
    if (-not $attach) {
        if (-not $sid) { return $Act }
        $sid = Get-TRClaudeContinuation $sid $ProjectsDir
        if ($sid -eq $Run.resume.sessionId) { return $Act }   # an ordinary foreground session: nothing to ask claude
    }
    $match = { param($e) if ($attach) { $e.id -eq $attach -or $e.name -eq $attach -or ([string]$e.sessionId).StartsWith($attach) } else { $e.sessionId -eq $sid } }
    $live = @(& $AgentsFn $false | Where-Object { $_ -and $_.kind -eq 'background' -and (& $match $_) })
    if ($live.Count) {
        $target = if ($live[0].id) { [string]$live[0].id } else { [string]$live[0].sessionId }
        return @{ Kind = 'Resume'; Exe = $Act.Exe; Args = [string[]]@('attach', $target); Cwd = $Act.Cwd }
    }
    if ($attach) {
        $done = @(& $AgentsFn $true | Where-Object { $_ -and (& $match $_) })
        if (-not $done.Count -or -not $done[0].sessionId) { return $Act }   # unknown: let `claude attach` say so
        $sid = [string]$done[0].sessionId
    }
    @{ Kind = 'Resume'; Exe = $Act.Exe; Args = (ConvertTo-TRClaudeResumeArgs $argv $sid); Cwd = $Act.Cwd }
}
# Handler registry: built-in claude + config.resumeHandlers entries
#   { "exe": "codex.exe", "command": ["{exe}", "resume", "--last"] }   ({argv} expands to the original arguments)
function Get-TRResumeCommand($Child, [string[]]$Argv) {
    $name = [string]$Child.Name
    if ($name -ieq 'claude.exe') { return (Get-TRClaudeResume $Child $Argv) }
    foreach ($h in @((Get-TRConfig).resumeHandlers)) {
        if (-not $h -or -not $h.exe -or $name -ine [string]$h.exe) { continue }
        $parts = New-Object 'Collections.Generic.List[string]'
        foreach ($c in @($h.command)) {
            if ($c -eq '{exe}') { $parts.Add([string]$Child.ExecutablePath) }
            elseif ($c -eq '{argv}') { if ($Argv.Count -gt 1) { foreach ($a in $Argv[1..($Argv.Count - 1)]) { $parts.Add($a) } } }
            else { $parts.Add([string]$c) }
        }
        if ($parts.Count -eq 0) { continue }
        $rest = if ($parts.Count -gt 1) { [string[]]$parts.GetRange(1, $parts.Count - 1).ToArray() } else { @() }
        return [ordered]@{ handler = [string]$h.exe; exe = $parts[0]; args = @($rest); cwd = $null; sessionId = $null }
    }
    $null
}

# ---------------------------------------------------------------- wt command lines
function ConvertTo-TRWtArg([string]$s) {
    $s = $s.Replace(';', '\;')
    if ($s -ne '' -and $s -notmatch '[\s"]') { return $s }
    $s = [regex]::Replace($s, '(\\*)"', '$1$1\"')
    $s = [regex]::Replace($s, '(\\+)$', '$1$1')
    '"' + $s + '"'
}
function New-TRTabArgs($Tab, [string]$TabFile) {
    $restoreTab = Join-Path (Get-TRRuntimeDir) 'restore-tab.ps1'
    $q = { param($x) "'" + ([string]$x).Replace("'", "''") + "'" }
    $inner = ". " + (& $q $restoreTab) + " " + (& $q $TabFile)
    $pa = @((Get-TRConfig).profileArgs | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { ("$_" -replace '[\r\n]+', ' ') })
    if ($pa.Count -gt 0) { $inner += ' # ' + ($pa -join ' ') }      # trailing comment: harmless to PowerShell, visible in GetCommandLineArgs()
    $shell = 'powershell.exe'
    if ($Tab.shellExe -and (Test-Path -LiteralPath $Tab.shellExe)) { $shell = [string]$Tab.shellExe }
    $a = @('new-tab')
    if ($Tab.cwd -and (Test-Path -LiteralPath $Tab.cwd -PathType Container)) { $a += '-d'; $a += [string]$Tab.cwd }
    $a += $shell, '-NoProfile', '-NoExit', '-Command', $inner
    ($a | ForEach-Object { ConvertTo-TRWtArg $_ }) -join ' '
}

function Get-TRLastTabs {
    $tabs = @()
    foreach ($f in Get-TRTabFiles $script:TR_Last) {
        $t = Read-TRJson $f.FullName
        if ($t -and $t.shellStart) { $tabs += [pscustomobject]@{ File = $f; Tab = $t } }
    }
    @($tabs | Sort-Object { [int64]$_.Tab.shellStart })
}
# Moves last\ into archive\<Dir> (keeps the 5 newest generations).
function Move-TRLastToArchive([string]$Dir) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Get-ChildItem -LiteralPath $script:TR_Last -File -ErrorAction SilentlyContinue | Move-Item -Destination $Dir -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $script:TR_Archive -Directory | Sort-Object Name -Descending | Select-Object -Skip 5 | ForEach-Object { [IO.Directory]::Delete($_.FullName, $true) }
}
function Enter-TRRestoreLock {
    $created = $false
    $m = New-Object Threading.Mutex($false, (Get-TRMutexName 'Restore'), [ref]$created)
    if ($m.WaitOne(0)) { return $m }
    $m.Dispose(); $null
}

# Opens every tab of last\ (original order) in window $Window ('new' or '0'). last\ is archived BEFORE spawning, so
# restored tabs never re-trigger. Caller holds the restore lock. Returns the tab count (or, with -DryRun, the wt command line).
function Start-TRSavedTabs([string]$Wt, [string]$Window, [switch]$DryRun) {
    $tabs = Get-TRLastTabs
    if ($tabs.Count -eq 0) { return $null }
    $arch = Join-Path $script:TR_Archive (Get-Date -Format 'yyyyMMdd-HHmmssfff')
    $wtArgs = "-w $Window " + (@($tabs | ForEach-Object { New-TRTabArgs $_.Tab (Join-Path $arch $_.File.Name) }) -join ' ; ')
    if ($DryRun) { return "$Wt $wtArgs" }
    Move-TRLastToArchive $arch
    Start-TRProcess $Wt $wtArgs
    $tabs.Count
}

# Restore-TerminalRess: everything into ONE NEW window.
function Invoke-TRRestoreAll([switch]$DryRun) {
    Initialize-TRDirs
    $wt = Get-TRWtPath
    if (-not $wt) { throw 'Windows Terminal (wt.exe) was not found. Set "wtPath" in config.json.' }
    $lock = Enter-TRRestoreLock
    if (-not $lock) { return 'restore already running' }
    try {
        $r = Start-TRSavedTabs $wt 'new' -DryRun:$DryRun
        if ($null -eq $r -or $DryRun) { return $r }
        "restored $r tab(s)"
    } finally { try { $lock.ReleaseMutex() } catch { } }
}

# Called by pre-adopt.ps1 in a freshly started launcher shell: if a saved generation exists and nothing else is tracked, open
# ALL saved tabs in the launcher's window. Returns the number of tabs spawned, or 0 (the caller then continues as a normal shell).
function Invoke-TRSpawnAll($Owner) {
    if ((Get-TRTabFiles $script:TR_Last).Count -eq 0) { Invoke-TRSweep; if ((Get-TRTabFiles $script:TR_Last).Count -eq 0) { return 0 } }
    if (@(Get-TRLiveAliveTabs $PID).Count -gt 0) { return 0 }
    $wt = Get-TRWtPath $Owner
    if (-not $wt) { return 0 }
    $lock = Enter-TRRestoreLock
    if (-not $lock) { return 0 }
    try { [int](Start-TRSavedTabs $wt '0') } finally { try { $lock.ReleaseMutex() } catch { } }
}

# ---------------------------------------------------------------- applying a saved tab
function Set-TREnvDiff($Diff) {
    if (-not $Diff) { return }
    foreach ($p in $Diff.PSObject.Properties) {
        [Environment]::SetEnvironmentVariable($p.Name, $(if ($null -eq $p.Value) { $null } else { [string]$p.Value }), 'Process')
    }
}
function Test-TRReplayAllowed([string]$ExeName, $Cfg) {
    if (-not $ExeName) { return $false }
    $leaf = [IO.Path]::GetFileNameWithoutExtension($ExeName).ToLowerInvariant()
    foreach ($d in @($Cfg.replayAllowlist)) { if ($leaf -eq ([IO.Path]::GetFileNameWithoutExtension([string]$d)).ToLowerInvariant()) { return $true } }
    $false
}
# What should this tab do? Returns @{Kind=Resume|Replay|Pretype; ...} or $null.
#   Resume  - a resume handler matched the foreground program (claude, config handlers): always resumed
#   Replay  - the foreground program's exe is on config.replayAllowlist: the typed line is re-executed
#   Pretype - anything else that was running (builds, pushes, deploys, no child at all) and idle tabs: typed, NOT executed
function Get-TRTabAction($Tab, $Run, $Cfg) {
    $pending = [string]$Tab.pendingCommand
    if ($pending) {
        if ($Run -and $Run.resume -and $Run.resume.exe) {
            return @{ Kind = 'Resume'; Exe = [string]$Run.resume.exe; Args = [string[]]@($Run.resume.args); Cwd = $Run.resume.cwd }
        }
        if ($Tab.seeded) { return $null }          # seeded placeholder: nothing typed is known
        if ($Run -and (Test-TRReplayAllowed ([string]$Run.name) $Cfg)) { return @{ Kind = 'Replay'; Text = $pending } }
        return @{ Kind = 'Pretype'; Text = $pending }
    }
    if ($Tab.lastCommand) { return @{ Kind = 'Pretype'; Text = [string]$Tab.lastCommand } }
    $null
}
# Executed with dot-sourcing (". $global:TRRunAction $act") so Replay runs in the caller's (global) scope.
$global:TRRunAction = {
    param($Act)
    if (-not $Act) { return }
    if ($Act.Kind -eq 'Pretype') {
        # PowerShell raises OnIdle also between pipelines BEFORE the first prompt, where Insert() is lost (PSReadLine resets its
        # buffer when it starts reading). So the action only fires once a prompt has completed since registration and PSReadLine
        # has been waiting for a key for a moment; then it unregisters itself.
        # (The subscriber's -MessageData is NOT visible in $Event for engine events, hence the global.)
        $tr0 = $global:__TR
        $global:TRPretype = @{ Text = [string]$Act.Text; Log = $env:TERMINALRESS_TESTLOG; At = [DateTime]::UtcNow; Count0 = $(if ($tr0) { [int]$tr0.PromptCount } else { 0 }) }
        $null = Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action {
            $m = $global:TRPretype; $t = $global:__TR
            if (-not $m) { Unregister-Event -SubscriptionId $EventSubscriber.SubscriptionId -ErrorAction SilentlyContinue; return }
            if ($t) { if ([int]$t.PromptCount -le $m.Count0 -or ([DateTime]::UtcNow - $t.PromptAt).TotalMilliseconds -lt 400) { return } }
            elseif (([DateTime]::UtcNow - $m.At).TotalSeconds -lt 2) { return }
            $global:TRPretype = $null
            try {
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert([string]$m.Text)
                if ($m.Log) { [IO.File]::AppendAllText($m.Log, "PRETYPED pid=$PID text=$($m.Text)`r`n") }   # test-only log
            } catch { if ($m.Log) { try { [IO.File]::AppendAllText($m.Log, "PRETYPE-FAILED pid=$PID $($_.Exception.Message)`r`n") } catch { } } }
            Unregister-Event -SubscriptionId $EventSubscriber.SubscriptionId -ErrorAction SilentlyContinue
        }
        return
    }
    if ($Act.Kind -eq 'Resume') {
        if ($Act.Cwd -and (Test-Path -LiteralPath $Act.Cwd -PathType Container)) { Set-Location -LiteralPath $Act.Cwd }
        $trText = ($Act.Exe + ' ' + ($Act.Args -join ' '))
    } else { $trText = [string]$Act.Text }
    if (Get-Command TR_MarkRunning -ErrorAction SilentlyContinue) { TR_MarkRunning $trText }
    Write-Host "TerminalRess: $trText" -ForegroundColor DarkGray
    if ($Act.Kind -eq 'Resume') { & $Act.Exe @($Act.Args) } else { Invoke-Expression $Act.Text }
}
