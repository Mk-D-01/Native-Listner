# Drake: tiny offline voice launcher.
#   "hey drake, start youtube"          -> one-shot
#   "hey drake" ... (beep) "open steam" -> two-step: wake, then command within $CommandWindow seconds
#   "hey drake quit"                    -> exit
# Apps are defined in apps.json (name -> URL, URI, or executable path).

$ErrorActionPreference = 'Stop'
$Threshold     = 0.70   # min recognizer confidence; raise if false triggers, lower if it ignores you
$CommandWindow = 6      # seconds to wait for a command after "hey drake"

Add-Type -AssemblyName System.Speech
$apps    = Get-Content (Join-Path $PSScriptRoot 'apps.json') -Raw | ConvertFrom-Json
$names   = @($apps.PSObject.Properties.Name)
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

$verbs = Choice 'start', 'open', 'launch'
$appCh = Choice $names

$wake = New-Gram 'wake' @('hey drake')
$full = New-Gram 'full' @('hey drake', $verbs, $appCh)
$cmd  = New-Gram 'cmd'  @($verbs, $appCh)
$quit = New-Gram 'quit' @('hey drake quit')
$cmd.Enabled = $false
$engine.LoadGrammar($wake); $engine.LoadGrammar($full)
$engine.LoadGrammar($cmd);  $engine.LoadGrammar($quit)

function Launch($text) {
    $app = $names | Where-Object { $text -match "\b$([regex]::Escape($_))$" } | Select-Object -First 1
    if ($app) {
        Write-Host "[drake] launching $app"
        Start-Process $apps.$app
    }
}

Write-Host "[drake] listening. Apps: $($names -join ', ')"
while ($true) {
    $r = $engine.Recognize([TimeSpan]::FromHours(1))
    if ($r) { Write-Host ("[drake] heard '{0}' ({1:N2})" -f $r.Text, $r.Confidence) }
    if (-not $r -or $r.Confidence -lt $Threshold) { continue }
    switch ($r.Grammar.Name) {
        'quit' { Write-Host '[drake] bye'; return }
        'full' { Launch $r.Text }
        'wake' {
            [console]::Beep(880, 120)
            $wake.Enabled = $false; $full.Enabled = $false; $cmd.Enabled = $true
            $c = $engine.Recognize([TimeSpan]::FromSeconds($CommandWindow))
            if ($c) { Write-Host ("[drake] heard '{0}' ({1:N2})" -f $c.Text, $c.Confidence) }
            if ($c -and $c.Confidence -ge $Threshold) { Launch $c.Text }
            $cmd.Enabled = $false; $wake.Enabled = $true; $full.Enabled = $true
        }
    }
}
