param(
    [Parameter(Mandatory)][string]$Name,    # the word you will say, e.g. "minecraft"
    [Parameter(Mandatory)][string]$Target   # exe/shortcut path, URL, or URI (steam://..., spotify:)
)
$file = Join-Path $PSScriptRoot 'apps.json'
$apps = [ordered]@{}
(Get-Content $file -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $apps[$_.Name] = $_.Value }

$Name = $Name.Trim().ToLower()
if ($Name -notmatch '^[a-z ]+$') { throw "Name must be letters/spaces only (it is spoken): '$Name'" }
if ($Target -notmatch '^[a-z][a-z0-9+.-]*:' -and -not (Test-Path $Target)) {
    Write-Warning "Path not found: $Target (saving anyway)"
}
$apps[$Name] = $Target
$apps | ConvertTo-Json | Set-Content $file -Encoding UTF8
Write-Host "Saved '$Name' -> $Target. Restart Drake to pick it up."
