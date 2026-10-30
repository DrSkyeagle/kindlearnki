# Windows wrapper for the KindleAnki eink-emulator harness.
#
#   D:\ankindle\harness\emu\emu.cmd up
#   D:\ankindle\harness\emu\emu.cmd push
#   D:\ankindle\harness\emu\emu.cmd shot study-card
#   D:\ankindle\harness\emu\emu.cmd nav study
#   D:\ankindle\harness\emu\emu.cmd nav answer
#   D:\ankindle\harness\emu\emu.cmd refresh study-card --nav study --answer
#   D:\ankindle\harness\emu\emu.cmd status
#   D:\ankindle\harness\emu\emu.cmd evidence
#   D:\ankindle\harness\emu\emu.cmd guest 'uname -a'
#
# Everything runs inside WSL distro KO-test; this wrapper only translates the
# repo path (D:\ankindle -> /mnt/d/ankindle) and forwards the arguments.

param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$distro = 'KO-test'

$scripts = @{
    'up'      = 'emu_up.sh'
    'push'    = 'emu_push_plugin.sh'
    'shot'    = 'emu_shot.sh'
    'nav'     = 'emu_nav.sh'
    'refresh' = 'emu_refresh.sh'
    'status'  = 'emu_status.sh'
    'evidence'= 'emu_evidence.sh'
    'down'    = 'emu_down.sh'
    'stop'    = 'emu_down.sh'
    'guest'   = 'guest.sh'
}

function Show-Usage {
    Get-Content -LiteralPath $PSCommandPath |
        Select-String -Pattern '^# ' |
        Select-Object -Skip 1 -First 12 |
        ForEach-Object { $_.Line -replace '^# ', '' }
}

if (-not $Command -or $Command -in @('-h', '--help', 'help')) {
    Show-Usage
    exit $(if ($Command) { 0 } else { 2 })
}

$key = $Command.ToLowerInvariant()
if (-not $scripts.ContainsKey($key)) {
    Write-Host "unknown command: $Command" -ForegroundColor Red
    Show-Usage
    exit 2
}

# D:\ankindle\harness\emu -> /mnt/d/ankindle/harness/emu
$here = $PSScriptRoot.TrimEnd('\')
if ($here -notmatch '^([A-Za-z]):\\(.*)$') {
    Write-Host "cannot map Windows path to WSL: $here" -ForegroundColor Red
    exit 2
}
$wslHere = '/mnt/' + $matches[1].ToLowerInvariant() + '/' + ($matches[2] -replace '\\', '/')

$wslArgs = @('-d', $distro, '--', 'bash', "$wslHere/$($scripts[$key])") + $Rest
& wsl.exe @wslArgs
exit $LASTEXITCODE
