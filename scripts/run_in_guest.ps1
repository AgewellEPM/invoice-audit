<#
  run_in_guest.ps1 — runs INSIDE the Win11 guest.

  Provisions Python + Tesseract, installs cryptography, runs the exact demo
  through the Windows OCR path, and writes the signed receipt + full log back
  to guest-receipt.json / guest-run-output.txt (the host pulls them).

  Robust against the Win11 "python" App-Execution-Alias stub: never trust
  `Get-Command python` (the stub answers it). Resolve a REAL interpreter by
  path and invoke it explicitly. Python installs at user scope (no UAC).
#>
$ErrorActionPreference = "Continue"
$proj = Split-Path -Parent $PSScriptRoot
Set-Location $proj
$log = Join-Path $proj "guest-run-output.txt"
"=== invoice-audit guest run $(Get-Date -Format o) ===" | Set-Content $log
function Log($m) { ($m | Out-String) | Tee-Object -FilePath $log -Append }

powercfg /change standby-timeout-ac 0 2>&1 | Out-Null
powercfg /h off 2>&1 | Out-Null

function Find-Python {
    foreach ($pat in @(
            "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
            "$env:ProgramFiles\Python3*\python.exe",
            "C:\Python3*\python.exe")) {
        $g = Get-ChildItem $pat -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($g) {
            $v = & $g.FullName --version 2>$null
            if ($LASTEXITCODE -eq 0 -and $v) { return $g.FullName }
        }
    }
    return $null
}

$py = Find-Python
if (-not $py) {
    Log "installing Python 3.12 (winget, user scope)..."
    winget install -e --id Python.Python.3.12 --silent --scope user `
        --accept-package-agreements --accept-source-agreements 2>&1 |
        Out-String | Add-Content $log
    Start-Sleep 6
    $py = Find-Python
}
if (-not $py) { Log "PYTHON INSTALL FAILED"; return }
Log ("python: " + (& $py --version 2>&1))

$tess = "C:\Program Files\Tesseract-OCR\tesseract.exe"
if (-not (Test-Path $tess)) {
    Log "installing Tesseract (winget)..."
    winget install -e --id UB-Mannheim.TesseractOCR --silent `
        --accept-package-agreements --accept-source-agreements 2>&1 |
        Out-String | Add-Content $log
    Start-Sleep 4
}
if (Test-Path $tess) {
    $env:Path += ";C:\Program Files\Tesseract-OCR"
    Log ("tesseract: " + ((& $tess --version 2>&1) | Select-Object -First 1))
} else { Log "TESSERACT NOT FOUND after install" }

# cryptography is OPTIONAL: fast wheel-only attempt; if none (e.g. Win/ARM64)
# receipt.py falls back to the vendored pure-Python Ed25519. Never source-build.
Log "trying cryptography wheel (optional; pure-Python Ed25519 fallback if none)..."
& $py -m pip install --quiet --disable-pip-version-check --only-binary :all: cryptography 2>&1 |
    Out-String | Add-Content $log

$env:INVOICE_AUDIT_OCR = "tesseract"
Log "=== AUDIT (Windows OCR = Tesseract) ==="
& $py -m invoice_audit audit demo\scans --pricebook demo\pricebook.csv `
    --floor demo\floor-rules.json --out guest-receipt.json 2>&1 |
    Out-String | Add-Content $log

Log "=== VERIFY ==="
& $py -m invoice_audit verify guest-receipt.json 2>&1 | Out-String | Add-Content $log

Log "=== DONE ==="
