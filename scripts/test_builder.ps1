<#
Runs the complete standalone Derelict Builder headless check set.

The release extension is built and installed by default. Use -SkipBuild when a
locked Godot editor already has the extension installed (for example, during a
local interactive session).
#>
[CmdletBinding()]
param(
    [string]$GodotPath,
    [string]$SynapticSeaRoot,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$root = (Split-Path $PSScriptRoot -Parent)
$builderRoot = Join-Path $root (Join-Path "godot" "builder")

# PowerShell 7 exposes $IsWindows/$IsMacOS, but Windows PowerShell 5.1 does
# not. Initialize explicit flags once so platform selection works in both.
$platformIsWindows = $false
$platformIsMacOS = $false
$isWindowsVariable = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
$isMacOSVariable = Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue
if ($null -ne $isWindowsVariable) { $platformIsWindows = [bool]$isWindowsVariable.Value }
if ($null -ne $isMacOSVariable) { $platformIsMacOS = [bool]$isMacOSVariable.Value }
if (-not $platformIsWindows -and -not $platformIsMacOS) {
    $platformId = [System.Environment]::OSVersion.Platform
    $platformIsWindows = $platformId -eq [System.PlatformID]::Win32NT
    $platformIsMacOS = $platformId -eq [System.PlatformID]::MacOSX -or $env:OSTYPE -like "darwin*"
}

function Resolve-Godot {
    param([string]$Requested)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Requested)) { $candidates += $Requested }
    if (-not [string]::IsNullOrWhiteSpace($env:GODOT_PATH)) { $candidates += $env:GODOT_PATH }

    $command = Get-Command godot -ErrorAction SilentlyContinue
    if ($null -ne $command) { $candidates += $command.Source }
    $command = Get-Command godot4 -ErrorAction SilentlyContinue
    if ($null -ne $command) { $candidates += $command.Source }

    if ($platformIsWindows) {
        $candidates += @(
            "$env:ProgramFiles\Godot\Godot.exe",
            "$env:LOCALAPPDATA\Godot\Godot.exe"
        )
    } elseif ($platformIsMacOS) {
        $candidates += "/Applications/Godot.app/Contents/MacOS/Godot"
    } else {
        $candidates += @("/usr/bin/godot4", "/usr/bin/godot")
    }

    foreach ($candidate in ($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $resolved = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $resolved) { return $resolved.Source }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw "Godot 4 executable not found. Pass -GodotPath, set GODOT_PATH, or install godot/godot4 on PATH."
}

function Resolve-ContentRoot {
    param([string]$Requested)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Requested)) { $candidates += $Requested }
    if (-not [string]::IsNullOrWhiteSpace($env:SYNAPTIC_SEA_ROOT)) { $candidates += $env:SYNAPTIC_SEA_ROOT }
    $candidates += (Join-Path (Join-Path $root "..") "the-synaptic-sea")

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw "The Synaptic Sea content root was not found. Pass -SynapticSeaRoot or set SYNAPTIC_SEA_ROOT."
}

function Install-Extension {
    Push-Location $root
    try {
        & cargo build --release -p derelict_godot
        if ($LASTEXITCODE -ne 0) { throw "cargo build --release -p derelict_godot failed (exit $LASTEXITCODE)." }

        if ($platformIsWindows) {
            $artifact = Join-Path $root (Join-Path (Join-Path "target" "release") "derelict_godot.dll")
            $platform = "win64"
        } elseif ($platformIsMacOS) {
            $artifact = Join-Path $root (Join-Path (Join-Path "target" "release") "libderelict_godot.dylib")
            $platform = "macos"
        } else {
            $artifact = Join-Path $root (Join-Path (Join-Path "target" "release") "libderelict_godot.so")
            $platform = "linux64"
        }
        if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
            throw "Built extension is missing: $artifact"
        }

        $destination = Join-Path $builderRoot ("addons/derelict/bin/{0}" -f $platform)
        New-Item -ItemType Directory -Force -Path $destination | Out-Null
        Copy-Item -LiteralPath $artifact -Destination (Join-Path $destination (Split-Path $artifact -Leaf)) -Force
        Write-Host ("Installed {0} -> {1}" -f (Split-Path $artifact -Leaf), $destination)
    } finally {
        Pop-Location
    }
}

$godot = Resolve-Godot $GodotPath
$contentRoot = Resolve-ContentRoot $SynapticSeaRoot
$env:SYNAPTIC_SEA_ROOT = $contentRoot
$env:DERELICT_PREVIEW_GODOT = $godot
Write-Host "Godot: $godot"
Write-Host "SYNAPTIC_SEA_ROOT: $env:SYNAPTIC_SEA_ROOT"

if (-not $SkipBuild) { Install-Extension }

Write-Host "Importing builder project..."
& $godot --headless --editor --path $builderRoot --quit
if ($LASTEXITCODE -ne 0) {
    throw "Godot builder project import failed (exit $LASTEXITCODE)."
}

$checks = @(
    "guided_workspace_check.gd",
    "builder_session_check.gd",
    "document_lifecycle_check.gd",
    "export_bundle_check.gd",
    "lattice_hydration_check.gd",
    "hazard_zone_check.gd",
    "module_picker_check.gd",
    "prop_palette_check.gd",
    "structural_preview_check.gd",
    "run_in_game_check.gd"
)
foreach ($check in $checks) {
    Write-Host "Running builder check: $check"
    & $godot --headless --path $builderRoot -s ("tests/{0}" -f $check)
    if ($LASTEXITCODE -ne 0) {
        throw "Builder check failed: $check (exit $LASTEXITCODE)."
    }
}
Write-Host ("All builder checks passed ({0})." -f $checks.Count)
