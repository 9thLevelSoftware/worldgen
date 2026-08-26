# Builds the Rust GDExtension and installs the dll into the Godot addon.
# Run from anywhere: powershell -File scripts\build_windows.ps1 [-Debug] [-Builder]
# -Builder also copies the DLL into godot/builder/addons/derelict/bin/win64/
# (no symlink; the smoke path copy always happens).
param(
    [switch]$Debug,
    [switch]$Builder
)

$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    $cargoArgs = @("build", "-p", "derelict_godot")
    if (-not $Debug) { $cargoArgs += "--release" }
    $profileDir = if ($Debug) { "debug" } else { "release" }
    & cargo @cargoArgs
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
    $dll = Join-Path $root "target\$profileDir\derelict_godot.dll"
    $dest = Join-Path $root "godot\addons\derelict\bin\win64"
    New-Item -ItemType Directory -Force $dest | Out-Null
    Copy-Item $dll $dest -Force
    Write-Host "Installed derelict_godot.dll ($profileDir) -> $dest"
    if ($Builder) {
        $builderDest = Join-Path $root "godot\builder\addons\derelict\bin\win64"
        New-Item -ItemType Directory -Force $builderDest | Out-Null
        Copy-Item $dll $builderDest -Force
        Write-Host "Installed derelict_godot.dll ($profileDir) -> $builderDest"
    }
} finally {
    Pop-Location
}
