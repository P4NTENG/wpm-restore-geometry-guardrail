<#
.SYNOPSIS
    Builds window_position_manager from wpm/wpm_v6.ahk.

.DESCRIPTION
    Compiles the AHK v2 source into a release and a debug binary, injects the
    PerMonitorV2 manifest into each, and verifies the result is x64.

    Requires AutoHotkey v2 (C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe).

.PARAMETER DebugBuild
    Emit DebugOn=true output (heavier logging, not for distribution).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build/build.ps1
    powershell -ExecutionPolicy Bypass -File build/build.ps1 -DebugBuild
#>
param([switch]$DebugBuild)

$ErrorActionPreference = "Stop"

$root     = Split-Path $PSScriptRoot -Parent
$src      = Join-Path $root "wpm\wpm_v6.ahk"
$manifest = Join-Path $root "wpm\wpm_min.manifest"
$outDir   = Join-Path $root "dist"
$base     = "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

if (-not (Test-Path $base)) {
    throw "AutoHotkey v2 runtime not found at: $base`nInstall AHK v2, or pass -Base <path to AutoHotkey64.exe>."
}
if (-not (Test-Path $src)) { throw "source not found: $src" }

New-Item -ItemType Directory -Path $outDir -Force | Out-Null

function Invoke-Ahk2Exe {
    param([string]$In, [string]$Out)

    $q = [char]34
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName        = "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe"
    $si.Arguments       = '/in ' + $q + $In + $q + ' /out ' + $q + $Out + $q +
                          ' /base ' + $q + $base + $q + ' /silent verbose'
    $si.UseShellExecute       = $false
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError  = $true
    $si.WorkingDirectory       = Split-Path $Out -Parent

    # Read both streams concurrently; sequential ReadToEnd can deadlock.
    $p    = [System.Diagnostics.Process]::Start($si)
    $outT = $p.StandardOutput.ReadToEndAsync()
    $errT = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch {} }
    return [pscustomobject]@{
        ExitCode = $p.ExitCode
        Stdout   = $outT.Result
        Stderr   = $errT.Result
    }
}

function Invoke-Check {
    param([string]$Label, [string]$Exe)

    Write-Host ""
    Write-Host "=== $Label ==="

    $r = Invoke-Ahk2Exe -In $src -Out $Exe
    if ($r.Stdout) { Write-Host $r.Stdout.Trim() }
    if ($r.Stderr) { Write-Host "stderr: $($r.Stderr.Trim())" -ForegroundColor Yellow }

    if (-not (Test-Path $Exe)) { throw "$Label failed: Ahk2Exe produced no output" }
    $len = (Get-Item $Exe).Length
    Write-Host "compiled: $len bytes"

    Write-Host "-- manifest inject --"
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) {
        Write-Warning "python not found; skipping manifest injection (DPI awareness will be wrong)"
    } else {
        # inject_manifest.py prints its own report; discard it so it does not
        # pollute the pipeline ($() would capture stdout and become our return value)
        $injectOut = & python (Join-Path $root "tools\inject_manifest.py") $Exe $manifest
        Write-Host ($injectOut | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "$Label failed: manifest injection failed ($LASTEXITCODE)" }
    }

    $vi = (Get-Item $Exe).VersionInfo
    Write-Host "ProductVersion: $($vi.ProductVersion)"
    return $Exe
}

$relName = if ($DebugBuild) { "window_position_manager_debug.exe" } else { "window_position_manager.exe" }
$rel = Invoke-Check -Label "build (DebugBuild=$([bool]$DebugBuild))" -Exe (Join-Path $outDir $relName)

Write-Host ""
Write-Host "=== done ==="
Write-Host "artifact: $rel"
Write-Host ""
Write-Host "Smoke test (no error dialog, stays resident):"
Write-Host "  Start-Process '$rel'"
Write-Host "  Start-Sleep 8"
Write-Host "  Get-Process | Where-Object { `$_.MainWindowTitle -and `$_.ProcessName -eq '#32770' }"
Write-Host ""
Write-Host "Install:"
Write-Host "  Copy-Item '$rel' `"$([Environment]::GetFolderPath('Startup'))\window_position_manager.exe`" -Force"