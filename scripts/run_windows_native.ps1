<#
  Native Windows 11 launcher for the invoice-audit demo.

  This is intentionally a thin WinForms shell over the same Python engine used
  by scripts/run_windows.ps1. It gives a non-terminal demo surface on Windows
  while keeping the audit, receipt, and Tesseract path identical.
#>
param([switch]$Setup)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
$env:INVOICE_AUDIT_OCR = "tesseract"

if ($Setup) {
    & "$PSScriptRoot\run_windows.ps1" -Setup
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Find-Python {
    foreach ($pattern in @(
            "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
            "$env:ProgramFiles\Python3*\python.exe",
            "C:\Python3*\python.exe")) {
        $candidate = Get-ChildItem $pattern -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    $command = Get-Command python -ErrorAction SilentlyContinue
    if ($command -and $command.Source -notmatch "\\WindowsApps\\") {
        return $command.Source
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

function Run-ProcessText {
    param([string]$File, [string[]]$ProcessArgs)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    foreach ($arg in $ProcessArgs) { [void]$psi.ArgumentList.Add($arg) }
    $psi.WorkingDirectory = $Root
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Environment["INVOICE_AUDIT_OCR"] = "tesseract"
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw ($out + "`n" + $err) }
    return $out + $err
}

$Python = Find-Python
$Tesseract = Find-Tesseract
if (-not $Python -or -not $Tesseract) {
    [System.Windows.Forms.MessageBox]::Show(
        "Python or Tesseract is missing. Re-run with -Setup first.",
        "Invoice Audit",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    return
}
$env:Path = (Split-Path -Parent $Tesseract) + ";" + $env:Path

$Receipt = Join-Path $Root "demo\scans\audit-receipt-windows.json"

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$font = New-Object System.Drawing.Font("Segoe UI", 10)
$titleFont = New-Object System.Drawing.Font("Segoe UI Semibold", 22)
$metricFont = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
$muted = [System.Drawing.Color]::FromArgb(94, 101, 111)
$ink = [System.Drawing.Color]::FromArgb(28, 33, 40)
$paper = [System.Drawing.Color]::FromArgb(246, 247, 249)
$card = [System.Drawing.Color]::White

$form = New-Object System.Windows.Forms.Form
$form.Text = "Invoice Audit"
$form.MinimumSize = New-Object System.Drawing.Size(1180, 760)
$form.Size = New-Object System.Drawing.Size(1280, 820)
$form.BackColor = $paper
$form.Font = $font
$form.StartPosition = "CenterScreen"

$header = New-Object System.Windows.Forms.Panel
$header.Dock = "Top"
$header.Height = 88
$header.Padding = New-Object System.Windows.Forms.Padding(22, 18, 22, 12)
$header.BackColor = $paper
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Invoice Audit"
$title.Font = $titleFont
$title.ForeColor = $ink
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(22, 16)
$header.Controls.Add($title)

$status = New-Object System.Windows.Forms.Label
$status.Text = "Ready"
$status.ForeColor = $muted
$status.AutoSize = $true
$status.Location = New-Object System.Drawing.Point(26, 54)
$header.Controls.Add($status)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "Run Audit"
$runButton.Width = 120
$runButton.Height = 36
$runButton.Anchor = "Top,Right"
$runButton.Location = New-Object System.Drawing.Point(1008, 24)
$header.Controls.Add($runButton)

$verifyButton = New-Object System.Windows.Forms.Button
$verifyButton.Text = "Verify"
$verifyButton.Width = 94
$verifyButton.Height = 36
$verifyButton.Anchor = "Top,Right"
$verifyButton.Location = New-Object System.Drawing.Point(1136, 24)
$header.Controls.Add($verifyButton)

$body = New-Object System.Windows.Forms.TableLayoutPanel
$body.Dock = "Fill"
$body.ColumnCount = 3
$body.RowCount = 1
$body.Padding = New-Object System.Windows.Forms.Padding(22, 0, 22, 22)
$body.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 300))) | Out-Null
$body.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$body.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 390))) | Out-Null
$form.Controls.Add($body)

$left = New-Object System.Windows.Forms.Panel
$left.Dock = "Fill"
$left.BackColor = $paper
$body.Controls.Add($left, 0, 0)

$preview = New-Object System.Windows.Forms.PictureBox
$preview.Dock = "Fill"
$preview.BackColor = $card
$preview.SizeMode = "Zoom"
$preview.BorderStyle = "FixedSingle"
$body.Controls.Add($preview, 1, 0)

$right = New-Object System.Windows.Forms.Panel
$right.Dock = "Fill"
$right.BackColor = $paper
$body.Controls.Add($right, 2, 0)

$metrics = New-Object System.Windows.Forms.Label
$metrics.Dock = "Top"
$metrics.Height = 120
$metrics.Font = $metricFont
$metrics.ForeColor = $ink
$metrics.BackColor = $card
$metrics.Padding = New-Object System.Windows.Forms.Padding(16)
$left.Controls.Add($metrics)

$invoiceList = New-Object System.Windows.Forms.ListBox
$invoiceList.Dock = "Fill"
$invoiceList.BorderStyle = "None"
$invoiceList.Font = $font
$left.Controls.Add($invoiceList)

$findingsLabel = New-Object System.Windows.Forms.Label
$findingsLabel.Text = "Review Queue"
$findingsLabel.Dock = "Top"
$findingsLabel.Height = 36
$findingsLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 15)
$findingsLabel.ForeColor = $ink
$right.Controls.Add($findingsLabel)

$findingsList = New-Object System.Windows.Forms.ListView
$findingsList.Dock = "Fill"
$findingsList.View = "Details"
$findingsList.FullRowSelect = $true
$findingsList.BorderStyle = "None"
$findingsList.Columns.Add("Type", 118) | Out-Null
$findingsList.Columns.Add("Line", 68) | Out-Null
$findingsList.Columns.Add("Detail", 320) | Out-Null
$right.Controls.Add($findingsList)

function Load-Receipt {
    if (-not (Test-Path $Receipt)) { return }
    $r = Get-Content $Receipt -Raw | ConvertFrom-Json
    $metrics.Text = ("{0:C0} Exposure`n{1:C0} Policy`n{2} Findings    {3} Lines" -f `
        $r.totals.potentialOverchargeUSD,
        $r.totals.policyOverageUSD,
        $r.totals.flagged,
        $r.totals.linesChecked)
    $invoiceList.Items.Clear()
    foreach ($inv in $r.invoices) {
        [void]$invoiceList.Items.Add($inv.file)
    }
    $findingsList.Items.Clear()
    foreach ($f in $r.reviewQueue) {
        $line = if ($null -ne $f.line) { "Line " + ([int]$f.line + 1) } else { "Invoice" }
        $item = New-Object System.Windows.Forms.ListViewItem($f.kind)
        [void]$item.SubItems.Add($line)
        [void]$item.SubItems.Add($f.detail)
        $item.Tag = $f.invoice
        [void]$findingsList.Items.Add($item)
    }
    if ($invoiceList.Items.Count -gt 0) { $invoiceList.SelectedIndex = 0 }
    $status.Text = "Loaded receipt. Signature: " + $r.signature.Substring(0, 16) + "..."
}

function Show-Invoice($Name) {
    $path = Join-Path $Root ("demo\scans\" + $Name)
    if (Test-Path $path) {
        if ($preview.Image) { $preview.Image.Dispose() }
        $stream = [System.IO.File]::OpenRead($path)
        try { $preview.Image = [System.Drawing.Image]::FromStream($stream) }
        finally { $stream.Close() }
    }
}

$invoiceList.Add_SelectedIndexChanged({
    if ($invoiceList.SelectedItem) { Show-Invoice $invoiceList.SelectedItem.ToString() }
})

$findingsList.Add_SelectedIndexChanged({
    if ($findingsList.SelectedItems.Count -gt 0) {
        Show-Invoice $findingsList.SelectedItems[0].Tag
    }
})

$runButton.Add_Click({
    try {
        $status.Text = "Rendering fixtures..."
        [System.Windows.Forms.Application]::DoEvents()
        Run-ProcessText $Python @("demo\make_fixtures.py") | Out-Null
        $status.Text = "Auditing invoices..."
        [System.Windows.Forms.Application]::DoEvents()
        Run-ProcessText $Python @(
            "-m", "invoice_audit", "audit", "demo\scans",
            "--pricebook", "demo\pricebook.csv",
            "--floor", "demo\floor-rules.json",
            "--out", $Receipt
        ) | Out-Null
        Load-Receipt
    } catch {
        $status.Text = "Audit failed"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Invoice Audit") | Out-Null
    }
})

$verifyButton.Add_Click({
    try {
        $out = Run-ProcessText $Python @("-m", "invoice_audit", "verify", $Receipt)
        $status.Text = $out.Trim()
    } catch {
        $status.Text = "Verify failed"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Invoice Audit") | Out-Null
    }
})

Load-Receipt
[System.Windows.Forms.Application]::Run($form)
