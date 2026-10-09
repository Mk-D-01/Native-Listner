# Drake: tiny offline voice launcher.
#   "hey drake, start youtube"          -> one-shot
#   "hey drake" ... (beep) "open steam" -> two-step: wake, then command within $CommandWindow seconds
#   "hey drake quit"                    -> exit
# Apps are defined in apps.json (name -> URL, URI, or executable path).

param([switch]$Hidden)   # set by drake-hidden.vbs; makes "restart" relaunch without a window

$ErrorActionPreference = 'Stop'
$Threshold     = 0.70   # min recognizer confidence; raise if false triggers, lower if it ignores you
$CommandWindow = 6      # seconds to wait for a command after "hey drake"

$engine = $null
$LogFile = Join-Path $PSScriptRoot 'drake.log'
function Log-Error($msg) {
    Write-Host "[drake] ERROR: $msg"
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 200KB) { Remove-Item $LogFile }
        Add-Content $LogFile ("{0:s} {1}" -f (Get-Date), $msg)
    } catch {}
}
# A broken/missing JSON file disables that feature instead of killing Drake.
function Read-Json($file) {
    try { Get-Content (Join-Path $PSScriptRoot $file) -Raw | ConvertFrom-Json }
    catch { Log-Error "$file unreadable, ignoring it: $($_.Exception.Message)"; $null }
}

function Restart-Drake {
    Write-Host '[drake] restarting (reloads apps.json / windows.json)'
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Hidden) { $a += '-Hidden' }
    $style = if ($Hidden) { 'Hidden' } else { 'Normal' }
    if ($engine) { $engine.Dispose() }   # release the mic before the new instance grabs it
    Start-Process powershell -ArgumentList $a -WindowStyle $style
    exit
}

try {   # anything fatal below (e.g. no microphone) is logged, then Drake restarts itself after a pause

Add-Type -AssemblyName System.Speech
$apps = Read-Json 'apps.json'
if (-not $apps) { $apps = [pscustomobject]@{} }
$names = @($apps.PSObject.Properties.Name)
$engine  = New-Object System.Speech.Recognition.SpeechRecognitionEngine
$culture = $engine.RecognizerInfo.Culture
$engine.SetInputToDefaultAudioDevice()

function New-Gram($name, $parts) {
    $gb = New-Object System.Speech.Recognition.GrammarBuilder
    $gb.Culture = $culture
    foreach ($p in $parts) { $gb.Append($p) }
    $g = New-Object System.Speech.Recognition.Grammar($gb)
    $g.Name = $name
    $g
}
function Choice($items) {
    $c = New-Object System.Speech.Recognition.Choices
    $items | ForEach-Object { $c.Add([string]$_) }
    $c
}

$hd    = Choice 'hey drake', 'drake'   # wake word: the "hey" is optional
$verbs = Choice 'start', 'open', 'launch'
$appCh = Choice $names

$wake   = New-Gram 'wake'   @($hd)
$full   = New-Gram 'full'   @($hd, $verbs, $appCh)
$cmd    = New-Gram 'cmd'    @($verbs, $appCh)
$quit   = New-Gram 'quit'   @($hd, 'quit')
$idle   = @($wake, $full)     # active while waiting for "hey drake"
$listen = @($cmd)             # active only right after the wake word
foreach ($word in 'restart', 'suspend') {
    $idle   += New-Gram 'full' @($hd, $word)
    $listen += New-Gram 'cmd'  @($word)
}
$getup = New-Gram 'getup' @('drake get up')   # the only phrase heard while suspended

# Volume: "volume up/down" (+/-20), "set volume <0-100>" (spoken as words, e.g. "forty five")
$VolumeStep = 20
$small = 'zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen'.Split(' ')
$tens  = ($null, $null, 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety')
$numWords = [ordered]@{}   # spoken words -> number
0..19 | ForEach-Object { $numWords[$small[$_]] = $_ }
20..99 | ForEach-Object {
    $w = $tens[[int][math]::Floor($_ / 10)]
    if ($_ % 10) { $w += ' ' + $small[$_ % 10] }
    $numWords[$w] = $_
}
$numWords['one hundred'] = 100
$volWords = Choice 'volume up', 'volume down', 'turn volume up', 'turn volume down'
$numCh    = Choice @($numWords.Keys)
$idle   += New-Gram 'full' @($hd, $volWords)
$listen += New-Gram 'cmd'  @($volWords)
$idle   += New-Gram 'full' @($hd, 'set volume', $numCh)
$listen += New-Gram 'cmd'  @('set volume', $numCh)

# Window switching: "switch to <name>", targets defined in windows.json
$wins = [ordered]@{}
$winCfg = Read-Json 'windows.json'
if ($winCfg) { $winCfg.PSObject.Properties | ForEach-Object { $wins[$_.Name] = $_.Value } }
if ($wins.Count) {
    $swCh   = Choice @($wins.Keys)
    $idle   += New-Gram 'full'  @($hd, 'switch to', $swCh)
    $listen += New-Gram 'cmd'   @('switch to', $swCh)
    $idle   += New-Gram 'full'  @($hd, 'close', $swCh)
    $listen += New-Gram 'cmd'   @('close', $swCh)
}
# Songs: "play <title>" (title = cleaned file name) or "play music" (random). Folder set in config.json.
$songs = [ordered]@{}
$cfg = Read-Json 'config.json'
$songDir = if ($cfg) { $cfg.songs_folder } else { '' }
if ($songDir -and -not (Test-Path -LiteralPath $songDir -PathType Container)) {
    Log-Error "songs_folder not found: $songDir"
} elseif ($songDir) {
    $audio = '.mp3', '.wav', '.flac', '.m4a', '.wma', '.ogg', '.aac'
    Get-ChildItem -LiteralPath $songDir -Recurse -File |
        Where-Object { $audio -contains $_.Extension.ToLower() } |
        Select-Object -First 300 |      # keep the grammar small; huge vocabularies hurt accuracy
        ForEach-Object {
            $n = ($_.BaseName.ToLower() -replace '[^a-z0-9 ]', ' ' -replace '\s+', ' ').Trim()
            if ($n -and -not $songs.Contains($n)) { $songs[$n] = $_.FullName }
        }
}
if ($songs.Count) {
    $songCh = Choice (@($songs.Keys) + $(if (-not $songs.Contains('music')) { 'music' }))
    $idle   += New-Gram 'full' @($hd, 'play', $songCh)
    $listen += New-Gram 'cmd'  @('play', $songCh)
}
foreach ($g in $idle + $listen + $quit + $getup) { $engine.LoadGrammar($g) }
foreach ($g in $listen + $getup) { $g.Enabled = $false }

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class Win {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);

    // Visible titled window whose process name and/or title substring match.
    static bool Matches(IntPtr h, string proc, string title) {
        if (!IsWindowVisible(h)) return false;
        int len = GetWindowTextLength(h);
        if (len == 0) return false;
        var sb = new StringBuilder(len + 1);
        GetWindowText(h, sb, sb.Capacity);
        if (!string.IsNullOrEmpty(title) && sb.ToString().IndexOf(title, StringComparison.OrdinalIgnoreCase) < 0) return false;
        if (!string.IsNullOrEmpty(proc)) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            try { return string.Equals(Process.GetProcessById((int)pid).ProcessName, proc, StringComparison.OrdinalIgnoreCase); }
            catch { return false; }
        }
        return true;
    }

    // First match (topmost in z-order), or IntPtr.Zero.
    public static IntPtr Find(string proc, string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!Matches(h, proc, title)) return true;
            found = h;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    // Politely ask every matching window to close (WM_CLOSE); apps can still prompt to save. Returns count.
    public static int Close(string proc, string title) {
        int n = 0;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (Matches(h, proc, title)) { PostMessage(h, 0x10, IntPtr.Zero, IntPtr.Zero); n++; }
            return true;
        }, IntPtr.Zero);
        return n;
    }

    public static void Focus(IntPtr h) {
        if (IsIconic(h)) ShowWindow(h, 9);   // SW_RESTORE
        keybd_event(0x12, 0, 0, UIntPtr.Zero);  // tap Alt so Windows allows the focus change
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        SetForegroundWindow(h);
    }
}
'@

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
    int RegisterControlChangeNotify(IntPtr p);
    int UnregisterControlChangeNotify(IntPtr p);
    int GetChannelCount(out uint c);
    int SetMasterVolumeLevel(float l, ref Guid ctx);
    int SetMasterVolumeLevelScalar(float l, ref Guid ctx);
    int GetMasterVolumeLevel(out float l);
    int GetMasterVolumeLevelScalar(out float l);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
    int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(int flow, int mask, out IntPtr devs);
    int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev);
}
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }
public static class Vol {
    static IAudioEndpointVolume Ep() {
        var en = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        IMMDevice dev;
        Marshal.ThrowExceptionForHR(en.GetDefaultAudioEndpoint(0, 1, out dev));   // render, multimedia
        Guid iid = typeof(IAudioEndpointVolume).GUID;
        object o;
        Marshal.ThrowExceptionForHR(dev.Activate(ref iid, 23, IntPtr.Zero, out o));
        return (IAudioEndpointVolume)o;
    }
    public static int Get() { float v; Marshal.ThrowExceptionForHR(Ep().GetMasterVolumeLevelScalar(out v)); return (int)Math.Round(v * 100); }
    public static void Set(int pct) {
        pct = Math.Max(0, Math.Min(100, pct));
        Guid g = Guid.Empty;
        Marshal.ThrowExceptionForHR(Ep().SetMasterVolumeLevelScalar(pct / 100f, ref g));
    }
}
'@

function Set-Volume($pct) {
    [Vol]::Set([int]$pct)
    Write-Host "[drake] volume -> $([Vol]::Get())%"
}

function Switch-To($name) {
    $w = $wins[$name]
    $h = [Win]::Find($w.process, $w.title)
    if ($h -ne [IntPtr]::Zero) {
        Write-Host "[drake] switching to $name"
        [Win]::Focus($h)
    } elseif ($apps.PSObject.Properties[$name]) {
        Write-Host "[drake] no window for $name, launching"
        Launch $name
    } else {
        Write-Host "[drake] no open window matches '$name'"
    }
}

function Close-App($name) {
    $w = $wins[$name]
    $n = [Win]::Close($w.process, $w.title)
    Write-Host "[drake] close $name -> asked $n window(s) to close"
}

# Deaf to everything except "drake get up" (also disables "hey drake quit").
function Suspend-Drake {
    Write-Host '[drake] suspended. Say "drake get up" to resume'
    [console]::Beep(440, 200)
    foreach ($g in $idle + $listen + $quit) { $g.Enabled = $false }
    $getup.Enabled = $true
    while ($true) {
        $r = $engine.Recognize([TimeSpan]::FromHours(1))
        if ($r) { Write-Host ("[drake] (suspended) heard '{0}' ({1:N2})" -f $r.Text, $r.Confidence) }
        if ($r -and $r.Confidence -ge $Threshold) { break }
    }
    $getup.Enabled = $false
    foreach ($g in $idle) { $g.Enabled = $true }
    $quit.Enabled = $true
    [console]::Beep(880, 120); [console]::Beep(1100, 120)
    Write-Host '[drake] awake'
}

function Play-Song($name) {
    $path = if ($songs.Contains($name)) { $songs[$name] } else { @($songs.Values) | Get-Random }
    Write-Host "[drake] playing $path"
    Invoke-Item -LiteralPath $path   # opens in your default music player ([ ] in names is safe)
}

function Run-Command($text) {
    if ($text -match 'restart$') { Restart-Drake }
    elseif ($text -match 'volume up$')   { Set-Volume ([Vol]::Get() + $VolumeStep) }
    elseif ($text -match 'volume down$') { Set-Volume ([Vol]::Get() - $VolumeStep) }
    elseif ($text -match 'set volume (.+)$') { Set-Volume $numWords[$Matches[1]] }
    elseif ($text -match 'play (.+)$') { Play-Song $Matches[1] }
    elseif ($text -match 'suspend$') { Suspend-Drake }
    elseif ($text -match 'close (.+)$') { Close-App $Matches[1] }
    elseif ($text -match 'switch to (.+)$') { Switch-To $Matches[1] }
    else { Launch $text }
}

function Launch($text) {
    $app = $names | Where-Object { $text -match "\b$([regex]::Escape($_))$" } | Select-Object -First 1
    if ($app) {
        Write-Host "[drake] launching $app"
        $t = $apps.$app
        if (Test-Path -LiteralPath $t -PathType Leaf) {
            Start-Process -FilePath $t -WorkingDirectory (Split-Path $t -Parent)
        } else {
            Start-Process $t
        }
    }
}

Write-Host "[drake] listening. Apps: $($names -join ', ') | Songs: $($songs.Count)"
function Reset-Grammars {   # back to the normal "waiting for hey drake" state
    foreach ($g in $listen + $getup) { $g.Enabled = $false }
    foreach ($g in $idle + $quit)    { $g.Enabled = $true }
}

$fails = 0
while ($true) {
    try {
        $r = $engine.Recognize([TimeSpan]::FromHours(1))
        $fails = 0
        if ($r) { Write-Host ("[drake] heard '{0}' ({1:N2})" -f $r.Text, $r.Confidence) }
        if (-not $r -or $r.Confidence -lt $Threshold) { continue }
        switch ($r.Grammar.Name) {
            'quit' { Write-Host '[drake] bye'; return }
            'full' { Run-Command $r.Text }
            'wake' {
                [console]::Beep(880, 120)
                foreach ($g in $idle)   { $g.Enabled = $false }
                foreach ($g in $listen) { $g.Enabled = $true }
                $c = $engine.Recognize([TimeSpan]::FromSeconds($CommandWindow))
                if ($c) { Write-Host ("[drake] heard '{0}' ({1:N2})" -f $c.Text, $c.Confidence) }
                if ($c -and $c.Confidence -ge $Threshold) { Run-Command $c.Text }
                Reset-Grammars
            }
        }
    } catch {
        # A bad command (missing file, closed app...) must not kill the listener.
        Log-Error $_.Exception.Message
        try { Reset-Grammars } catch {}
        if (++$fails -ge 5) { throw "5 consecutive errors, restarting: $($_.Exception.Message)" }
        Start-Sleep -Seconds 2
    }
}

} catch {
    Log-Error "fatal: $($_.Exception.Message)"
    Start-Sleep -Seconds 10
    Restart-Drake
}
