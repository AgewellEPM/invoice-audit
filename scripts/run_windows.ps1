<#
  run_windows.ps1 — run the invoice-audit demo on Windows 11.

  Only OCR is OS-specific: Windows uses Tesseract (it emits per-word confidence,
  which the grounding layer needs). Everything else is the same Python pipeline
  that runs on macOS. This is the exact demo, translated to Windows.

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\run_windows.ps1 -Setup
    powershell -ExecutionPolicy Bypass -File scripts\run_windows.ps1
#>
param([switch]$Setup)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
$env:INVOICE_AUDIT_OCR = "tesseract"

function Find-Python {
    foreach ($pattern in @(
            "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
            "$env:ProgramFiles\Python3*\python.exe",
            "C:\Python3*\python.exe")) {
        $candidate = Get-ChildItem $pattern -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($candidate) {
            $version = & $candidate.FullName --version 2>$null
            if ($LASTEXITCODE -eq 0 -and $version) { return $candidate.FullName }
        }
    }
    $command = Get-Command python -ErrorAction SilentlyContinue
    if ($command -and $command.Source -notmatch "\\WindowsApps\\") {
        $version = & $command.Source --version 2>$null
        if ($LASTEXITCODE -eq 0 -and $version) { return $command.Source }
    }
    return $null
}

function Find-Tesseract {
    $known = "C:\Program Files\Tesseract-OCR\tesseract.exe"
    if (Test-Path $known) { return $known }
    $command = Get-Command tesseract -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Run-Python {
    & $Python @args
    if ($LASTEXITCODE -ne 0) {
        throw "Python command failed with exit code $LASTEXITCODE: $args"
    }
}

$Python = Find-Python
$Tesseract = Find-Tesseract

if ($Setup) {
    Write-Host "== Setup =="
    if (-not $Python) {
        winget install -e --id Python.Python.3.12 --silent --scope user `
            --accept-package-agreements --accept-source-agreements
        Start-Sleep 3
        $Python = Find-Python
    }
    if (-not $Python) { throw "Python 3.10+ installation failed" }

    if (-not $Tesseract) {
        winget install -e --id UB-Mannheim.TesseractOCR --silent `
            --accept-package-agreements --accept-source-agreements
        Start-Sleep 3
        $Tesseract = Find-Tesseract
    }
    if (-not $Tesseract) { throw "Tesseract installation failed" }

    Run-Python -m pip install --upgrade pip
    Run-Python -m pip install pillow
    & $Python -m pip install --only-binary :all: cryptography
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "No cryptography wheel; the pinned pure-Python Ed25519 fallback will be used."
    }
    Write-Host "Setup done. Re-run without -Setup to execute the demo."
    return
}

if (-not $Python) { throw "Python not found. Run this script with -Setup first." }
if (-not $Tesseract) { throw "Tesseract not found. Run this script with -Setup first." }
$env:Path = (Split-Path -Parent $Tesseract) + ";" + $env:Path

Write-Host "== Render fixtures (real PNG scans) =="
Run-Python demo\make_fixtures.py

Write-Host "`n== Audit (Windows OCR = Tesseract) =="
Run-Python -m invoice_audit audit demo\scans --pricebook demo\pricebook.csv `
    --floor demo\floor-rules.json --out demo\scans\audit-receipt-windows.json

Write-Host "`n== Verify signed receipt =="
Run-Python -m invoice_audit verify demo\scans\audit-receipt-windows.json

Write-Host "`n== Tests =="
Run-Python tests\test_invoice_audit.py
