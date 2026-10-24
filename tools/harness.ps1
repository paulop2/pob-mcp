# Run the pob-mcp harnesses against a Path of Building checkout on Windows.
#
# Path of Building ships a patched LuaJIT runtime (lua51.dll) with compound
# assignment support. Stock luajit binaries cannot load Launch.lua, so this
# script routes POB_CMD through tools/pob_luajit.py, which hosts PoB's own
# lua51.dll with Python's ctypes.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools\harness.ps1
#   powershell -ExecutionPolicy Bypass -File tools\harness.ps1 -Full
#   powershell -ExecutionPolicy Bypass -File tools\harness.ps1 -PobPath C:\src\PathOfBuilding\src
#
# Note: POB_ARGS is split on whitespace by the server, so neither the repo path
# nor the PoB path may contain spaces.

param(
    [string]$PobPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "..\PathOfBuilding\src"),
    [string]$Python = "python",
    [string]$BuildsDir = "",
    [switch]$Full,
    [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path -LiteralPath $PobPath)) {
    throw "Path of Building src not found: $PobPath"
}
$PobPath = (Resolve-Path -LiteralPath $PobPath).Path
if (-not (Test-Path -LiteralPath (Join-Path $PobPath "HeadlessWrapper.lua"))) {
    throw "POB_PATH must point at the PoB src directory (HeadlessWrapper.lua missing): $PobPath"
}

$runtime = Join-Path (Split-Path -Parent $PobPath) "runtime"
$luaDll = Join-Path $runtime "lua51.dll"
if (-not (Test-Path -LiteralPath $luaDll)) {
    throw "PoB runtime not found: $luaDll"
}

if ($repo -match '\s' -or $PobPath -match '\s') {
    throw "Paths with spaces are not supported by POB_ARGS: '$repo' / '$PobPath'"
}

$pythonExe = (Get-Command $Python -ErrorAction Stop).Source
$shim = Join-Path $repo "tools\pob_luajit.py"
$bridge = Join-Path $repo "lua\vanilla_stdio_bridge.lua"
if (-not (Test-Path -LiteralPath $shim)) { throw "Missing shim: $shim" }
if (-not (Test-Path -LiteralPath $bridge)) { throw "Missing bridge: $bridge" }

$env:POB_PATH = $PobPath
$env:POB_LUA_DLL = (Resolve-Path -LiteralPath $luaDll).Path
$env:POB_CMD = $pythonExe
$env:POB_ARGS = "$shim $bridge"
$env:POB_LUA_ENABLED = "true"
$env:POB_TIMEOUT_MS = "60000"
if ($BuildsDir) { $env:POB_DIRECTORY = (Resolve-Path -LiteralPath $BuildsDir).Path }

Push-Location $repo
try {
    if (-not $SkipInstall) {
        npm ci
        if ($LASTEXITCODE -ne 0) { throw "npm ci failed" }
    }

    npm run build
    if ($LASTEXITCODE -ne 0) { throw "npm run build failed" }

    npm run test:smoke
    if ($LASTEXITCODE -ne 0) { throw "npm run test:smoke failed" }

    if ($Full) {
        npm run test:smoke:full
        if ($LASTEXITCODE -ne 0) { throw "npm run test:smoke:full failed" }
    }
}
finally {
    Pop-Location
}

Write-Output ""
Write-Output "Harness passed. Environment for MCP clients:"
Write-Output "  POB_PATH=$env:POB_PATH"
Write-Output "  POB_LUA_DLL=$env:POB_LUA_DLL"
Write-Output "  POB_CMD=$env:POB_CMD"
Write-Output "  POB_ARGS=$env:POB_ARGS"
Write-Output "  POB_LUA_ENABLED=$env:POB_LUA_ENABLED"
if ($env:POB_DIRECTORY) { Write-Output "  POB_DIRECTORY=$env:POB_DIRECTORY" }
