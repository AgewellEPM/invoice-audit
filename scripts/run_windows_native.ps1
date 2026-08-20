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

$AppState = Join-Path $Root ".invoice-audit-app"
New-Item -ItemType Directory -Force -Path $AppState | Out-Null
$Receipt = Join-Path $AppState "latest-receipt-windows.json"
$Database = Join-Path $AppState "business-windows.sqlite"
$Report = Join-Path $AppState "business-report-windows.html"
$EmailDraft = Join-Path $AppState "boss-summary-windows.eml"
$IntegrationPayload = Join-Path $AppState "integration-payload-windows.json"
$InvoiceFolder = $null
$Pricebook = $null
$Rules = $null
$ScanPaths = @{}

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

$emailButton = New-Object System.Windows.Forms.Button
$emailButton.Text = "Email Draft"
$emailButton.Width = 112
$emailButton.Height = 36
$emailButton.Anchor = "Top,Right"
$emailButton.Location = New-Object System.Drawing.Point(786, 24)
$header.Controls.Add($emailButton)

$reportButton = New-Object System.Windows.Forms.Button
$reportButton.Text = "Report"
$reportButton.Width = 94
$reportButton.Height = 36
$reportButton.Anchor = "Top,Right"
$reportButton.Location = New-Object System.Drawing.Point(906, 24)
$header.Controls.Add($reportButton)

$verifyButton = New-Object System.Windows.Forms.Button
$verifyButton.Text = "Verify"
$verifyButton.Width = 94
$verifyButton.Height = 36
$verifyButton.Anchor = "Top,Right"
$verifyButton.Location = New-Object System.Drawing.Point(1136, 24)
$header.Controls.Add($verifyButton)

$sourcePanel = New-Object System.Windows.Forms.Panel
$sourcePanel.Dock = "Top"
$sourcePanel.Height = 148
$sourcePanel.Padding = New-Object System.Windows.Forms.Padding(22, 4, 22, 12)
$sourcePanel.BackColor = $paper
$form.Controls.Add($sourcePanel)

$sourceTitle = New-Object System.Windows.Forms.Label
$sourceTitle.Text = "Data Sources"
$sourceTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
$sourceTitle.ForeColor = $ink
$sourceTitle.AutoSize = $true
$sourceTitle.Location = New-Object System.Drawing.Point(22, 4)
$sourcePanel.Controls.Add($sourceTitle)

$sourceStatus = New-Object System.Windows.Forms.Label
$sourceStatus.Text = "Choose an invoice folder and customer price history before running an audit."
$sourceStatus.ForeColor = $muted
$sourceStatus.AutoSize = $true
$sourceStatus.Location = New-Object System.Drawing.Point(22, 28)
$sourcePanel.Controls.Add($sourceStatus)

$chooseInvoicesButton = New-Object System.Windows.Forms.Button
$chooseInvoicesButton.Text = "Choose Invoices"
$chooseInvoicesButton.Width = 138
$chooseInvoicesButton.Height = 32
$chooseInvoicesButton.Location = New-Object System.Drawing.Point(22, 60)
$sourcePanel.Controls.Add($chooseInvoicesButton)

$choosePricebookButton = New-Object System.Windows.Forms.Button
$choosePricebookButton.Text = "Choose Price History"
$choosePricebookButton.Width = 166
$choosePricebookButton.Height = 32
$choosePricebookButton.Location = New-Object System.Drawing.Point(170, 60)
$sourcePanel.Controls.Add($choosePricebookButton)

$chooseRulesButton = New-Object System.Windows.Forms.Button
$chooseRulesButton.Text = "Choose Rules"
$chooseRulesButton.Width = 120
$chooseRulesButton.Height = 32
$chooseRulesButton.Location = New-Object System.Drawing.Point(346, 60)
$sourcePanel.Controls.Add($chooseRulesButton)

$sampleButton = New-Object System.Windows.Forms.Button
$sampleButton.Text = "Use Sample Data"
$sampleButton.Width = 138
$sampleButton.Height = 32
$sampleButton.Location = New-Object System.Drawing.Point(476, 60)
$sourcePanel.Controls.Add($sampleButton)

$webhookLabel = New-Object System.Windows.Forms.Label
$webhookLabel.Text = "Zapier/API webhook"
$webhookLabel.ForeColor = $muted
$webhookLabel.AutoSize = $true
$webhookLabel.Location = New-Object System.Drawing.Point(22, 105)
$sourcePanel.Controls.Add($webhookLabel)

$webhookBox = New-Object System.Windows.Forms.TextBox
$webhookBox.Width = 760
$webhookBox.Height = 28
$webhookBox.Location = New-Object System.Drawing.Point(170, 100)
$webhookBox.Anchor = "Top,Left,Right"
$sourcePanel.Controls.Add($webhookBox)

$sendApiButton = New-Object System.Windows.Forms.Button
$sendApiButton.Text = "Send"
$sendApiButton.Width = 70
$sendApiButton.Height = 30
$sendApiButton.Anchor = "Top,Right"
$sendApiButton.Location = New-Object System.Drawing.Point(948, 99)
$sourcePanel.Controls.Add($sendApiButton)

$apiFileButton = New-Object System.Windows.Forms.Button
$apiFileButton.Text = "API File"
$apiFileButton.Width = 90
$apiFileButton.Height = 30
$apiFileButton.Anchor = "Top,Right"
$apiFileButton.Location = New-Object System.Drawing.Point(1028, 99)
$sourcePanel.Controls.Add($apiFileButton)

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

function Update-SourceStatus {
    $inv = if ($InvoiceFolder) { Split-Path -Leaf $InvoiceFolder } else { "no invoice folder" }
    $pb = if ($Pricebook) { Split-Path -Leaf $Pricebook } else { "no price history" }
    $rulesText = if ($Rules) { Split-Path -Leaf $Rules } else { "no rules" }
    $sourceStatus.Text = "Invoices: $inv    Price history: $pb    Rules: $rulesText"
    $runButton.Enabled = [bool]($InvoiceFolder -and $Pricebook)
    $reportButton.Enabled = Test-Path $Report
    $emailButton.Enabled = Test-Path $Database
    $apiFileButton.Enabled = Test-Path $Database
    $sendApiButton.Enabled = (Test-Path $Database) -and ($webhookBox.Text.Trim().Length -gt 0)
}

function Generate-Report {
    if (-not (Test-Path $Database)) { return }
    Run-ProcessText $Python @(
        "-m", "invoice_audit", "report",
        "--db", $Database,
        "--out", $Report
    ) | Out-Null
    $reportButton.Enabled = Test-Path $Report
}

function Generate-EmailDraft {
    if (-not (Test-Path $Database)) { return }
    Generate-Report
    Run-ProcessText $Python @(
        "-m", "invoice_audit", "email-draft",
        "--db", $Database,
        "--out", $EmailDraft,
        "--attach-report", $Report
    ) | Out-Null
    $emailButton.Enabled = Test-Path $EmailDraft
}

function Export-IntegrationPayload {
    if (-not (Test-Path $Database)) { return }
    Run-ProcessText $Python @(
        "-m", "invoice_audit", "integration-payload",
        "--db", $Database,
        "--out", $IntegrationPayload
    ) | Out-Null
    $apiFileButton.Enabled = Test-Path $IntegrationPayload
}

function Send-Webhook {
    $url = $webhookBox.Text.Trim()
    if (-not (Test-Path $Database)) {
        [System.Windows.Forms.MessageBox]::Show("Run an audit first.", "Invoice Audit") | Out-Null
        return
    }
    if ($url.Length -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Paste a Zapier or webhook URL first.", "Invoice Audit") | Out-Null
        return
    }
    $status.Text = "Sending to webhook..."
    [System.Windows.Forms.Application]::DoEvents()
    $out = Run-ProcessText $Python @(
        "-m", "invoice_audit", "send-webhook",
        "--db", $Database,
        "--url", $url
    )
    $status.Text = "Webhook sent: " + $out.Trim()
}

function Load-Receipt {
    if (-not (Test-Path $Receipt)) { return }
    $r = Get-Content $Receipt -Raw | ConvertFrom-Json
    $script:ScanPaths = @{}
    foreach ($scan in $r.scans) {
        $script:ScanPaths[$scan.file] = $scan.path
    }
    if ($r.scans.Count -gt 0) { $script:InvoiceFolder = Split-Path -Parent $r.scans[0].path }
    if ($r.pricebook.path) { $script:Pricebook = $r.pricebook.path }
    if ($r.floorRules.path) { $script:Rules = $r.floorRules.path }
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
    Update-SourceStatus
}

function Show-Invoice($Name) {
    $path = $script:ScanPaths[$Name]
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

$chooseInvoicesButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Choose the folder containing invoice scans"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:InvoiceFolder = $dialog.SelectedPath
        Update-SourceStatus
    }
})

$choosePricebookButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Choose customer price history"
    $dialog.Filter = "Price history (*.csv;*.sqlite;*.sqlite3;*.db)|*.csv;*.sqlite;*.sqlite3;*.db|All files (*.*)|*.*"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:Pricebook = $dialog.FileName
        Update-SourceStatus
    }
})

$chooseRulesButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Choose optional rules file"
    $dialog.Filter = "Rules (*.json)|*.json|All files (*.*)|*.*"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:Rules = $dialog.FileName
        Update-SourceStatus
    }
})

$sampleButton.Add_Click({
    try {
        Run-ProcessText $Python @("demo\make_fixtures.py") | Out-Null
        $script:InvoiceFolder = Join-Path $Root "demo\scans"
        $script:Pricebook = Join-Path $Root "demo\pricebook.csv"
        $script:Rules = Join-Path $Root "demo\floor-rules.json"
        $status.Text = "Sample data selected"
        Update-SourceStatus
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Invoice Audit") | Out-Null
    }
})

$runButton.Add_Click({
    try {
        if (-not $InvoiceFolder -or -not $Pricebook) {
            [System.Windows.Forms.MessageBox]::Show(
                "Choose an invoice folder and price-history file first.",
                "Invoice Audit"
            ) | Out-Null
            return
        }
        $status.Text = "Auditing invoices..."
        [System.Windows.Forms.Application]::DoEvents()
        $args = @(
            "-m", "invoice_audit", "audit-db", $InvoiceFolder,
            "--pricebook", $Pricebook,
            "--db", $Database,
            "--out", $Receipt
        )
        if ($Rules) { $args += @("--floor", $Rules) }
        Run-ProcessText $Python $args | Out-Null
        Generate-Report
        Load-Receipt
    } catch {
        $status.Text = "Audit failed"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Invoice Audit") | Out-Null
    }
})

$reportButton.Add_Click({
    try {
        if (-not (Test-Path $Report)) { Generate-Report }
        if (Test-Path $Report) {
            Start-Process $Report
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "Run an audit first to generate the report.",
                "Invoice Audit"
            ) | Out-Null
        }
    } catch {
        $status.Text = "Report failed"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Invoice Audit") | Out-Null
    }
})

$emailButton.Add_Click({
    try {
        Generate-EmailDraft
        if (Test-Path $EmailDraft) {
            Start-Process $EmailDraft
            $status.Text = "Email draft ready"
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "Run an audit first to prepare an email draft.",
                "Invoice Audit"
            ) | Out-Null
        }
    } catch {
        $status.Text = "Email draft failed"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Invoice Audit") | Out-Null
    }
})

$apiFileButton.Add_Click({
    try {
        Export-IntegrationPayload
        if (Test-Path $IntegrationPayload) {
            Start-Process (Split-Path -Parent $IntegrationPayload)
            $status.Text = "API payload ready"
        }
    } catch {
        $status.Text = "API payload failed"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Invoice Audit") | Out-Null
    }
})

$sendApiButton.Add_Click({
    try {
        Send-Webhook
    } catch {
        $status.Text = "Webhook failed"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Invoice Audit") | Out-Null
    }
})

$webhookBox.Add_TextChanged({
    Update-SourceStatus
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
Update-SourceStatus
[System.Windows.Forms.Application]::Run($form)
