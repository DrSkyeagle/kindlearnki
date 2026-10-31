# Copy the plugin to a mounted Kindle.
#
#   pwsh -File tools\deploy_to_kindle.ps1 -Drive E          # preview only
#   pwsh -File tools\deploy_to_kindle.ps1 -Drive E -Apply   # copy
#
# The script refuses to run unless <Drive>:\koreader\reader.lua exists, so a
# wrong drive letter cannot delete anything.  The previous plugin directory is
# renamed, never removed.

param(
    [Parameter(Mandatory = $true)][string]$Drive,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot '..\kindlearnki.koplugin' | Resolve-Path
$koreader = "${Drive}:\koreader"
$reader = Join-Path $koreader 'reader.lua'
$plugins = Join-Path $koreader 'plugins'
$target = Join-Path $plugins 'kindlearnki.koplugin'

if (-not (Test-Path $reader)) {
    throw "not a KOReader install: $reader is missing"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $plugins "kindlearnki.koplugin.bak-$stamp"

Write-Host "source : $source"
Write-Host "target : $target"
Write-Host "backup : $backup"

if (-not $Apply) {
    Write-Host ''
    Write-Host 'preview only; re-run with -Apply to copy'
    exit 0
}

New-Item -ItemType Directory -Force -Path $plugins | Out-Null
if (Test-Path $target) {
    Rename-Item -Path $target -NewName (Split-Path $backup -Leaf)
    Write-Host "previous version kept at $backup"
}
Copy-Item -Recurse -Path $source -Destination $target
Write-Host 'copied. Safely eject the Kindle before unplugging, then restart KOReader.'
