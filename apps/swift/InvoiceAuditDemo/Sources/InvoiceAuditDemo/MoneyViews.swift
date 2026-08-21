import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

struct SourcesStepView: View {
    @EnvironmentObject private var model: AuditModel
    let continueAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                WizardTitle(
                    eyebrow: "Money",
                    title: "Build the financial map",
                    subtitle: "Connect receipts/invoices, Excel price sheets, SQL evidence, and legacy VM/RM sources. This is the graph behind dollar → transaction → invoice → vendor → line item → source evidence."
                )

                HStack(spacing: 14) {
                    WizardSourceCard(
                        number: "1",
                        title: "Invoices / receipts",
                        detail: model.invoiceFolderURL?.path(percentEncoded: false) ?? "Choose a folder of PDFs, scans, or receipt images.",
                        systemImage: "folder",
                        isReady: model.invoiceFolderURL != nil,
                        actionTitle: "Choose Folder",
                        action: model.chooseInvoiceFolder,
                        runTitle: model.isRunning ? "Running" : "Run",
                        runAction: runCapturePipeline,
                        runDisabled: !model.canRunAudit
                    )
                    WizardSourceCard(
                        number: "2",
                        title: "Excel sheets / price data",
                        detail: model.pricebookURL?.lastPathComponent ?? "Choose .xlsx, .csv, or SQLite customer price data.",
                        systemImage: "tablecells",
                        isReady: model.pricebookURL != nil,
                        actionTitle: "Choose Sheet",
                        action: model.choosePricebook,
                        runTitle: model.isRunning ? "Running" : "Run",
                        runAction: runCapturePipeline,
                        runDisabled: !model.canRunAudit
                    )
                    WizardSourceCard(
                        number: "3",
                        title: "Connected database",
                        detail: model.hasBusinessDatabase ? "SQLite evidence store exists and is queryable." : "No connected database yet. Run an audit after choosing data.",
                        systemImage: "cylinder.split.1x2",
                        isReady: model.hasBusinessDatabase,
                        actionTitle: model.hasBusinessDatabase ? "Open Database" : "Create Database",
                        action: {
                            if model.hasBusinessDatabase {
                                model.revealDatabase()
                            } else if model.canRunAudit {
                                runCapturePipeline()
                            } else {
                                model.status = "Choose invoices and Excel sheets first"
                            }
                        },
                        runTitle: model.isRunning ? "Running" : "Run",
                        runAction: runCapturePipeline,
                        runDisabled: !model.canRunAudit
                    )
                }

                MoneyCaptureControlPanel()

                if model.showExtractionWorkspace || model.isRunning || model.receipt != nil {
                    MoneyExtractionWorkspace()
                }

                // Industry-benchmark overpay + savings story (see BenchmarkFeature.swift).
                FinanceValueSection()

                LegacyBridgePanel()

                HStack {
                    Text("Market benchmarks, rules, API connectors, and share/export still live under the gear for advanced setup. The living CSV grid is generated from the SQL invoice_lines table.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.muted)
                    Spacer()
                    Button {
                        model.useSampleData()
                    } label: {
                        Label("Use Sample", systemImage: "shippingbox")
                    }
                    Button {
                        model.showExtractionWorkspace = true
                        Task { await model.runAudit() }
                    } label: {
                        Label(model.isRunning ? "Running Pipeline" : "Run Capture Pipeline", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRunAudit)
                    Button {
                        model.openInvoiceLinesCSV()
                    } label: {
                        Label("Open CSV Grid", systemImage: "tablecells")
                    }
                    .disabled(!model.hasBusinessDatabase && model.csvGridRows.isEmpty)
                }
                Spacer(minLength: 12)
            }
        }
    }

    private func runCapturePipeline() {
        model.showExtractionWorkspace = true
        guard model.canRunAudit else {
            model.status = "Choose invoices and Excel sheets first"
            return
        }
        Task { await model.runAudit() }
    }
}

struct LegacyBridgePanel: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        let bridge = model.legacyBridge
        DarkPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Legacy VM / RM bridge", systemImage: "display.and.arrow.down")
                            .font(.system(size: 16, weight: .bold))
                        Text("For old payroll, RM, ERP, or plant computers that cannot export cleanly. This panel detects the live Kist bridge, Perslis/RM runtime, active QMP VM-stage, and legacy QEMU systems before you extract screens/files/database exports.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.legacyBridgeStatus)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(bridge.isOperational ? AppTheme.green : AppTheme.orange)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 8) {
                        Button {
                            Task { await model.checkLegacyBridge() }
                        } label: {
                            Label("Check Bridge", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        Button {
                            model.openLegacyBridge()
                        } label: {
                            Label("Open Kist Agent", systemImage: "safari")
                        }
                        Button {
                            model.openLegacyStage()
                        } label: {
                            Label("Open Active Stage", systemImage: "display")
                        }
                        .disabled(bridge.sessionUrl == nil)
                        Button {
                            model.copyLegacyBridgeInstructions()
                        } label: {
                            Label("Copy Handoff", systemImage: "doc.on.clipboard")
                        }
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        LegacyStatusPill(title: "Console", ready: bridge.consoleReachable)
                        LegacyStatusPill(title: "Perslis", ready: bridge.perslisRuntime)
                        LegacyStatusPill(title: "RM", ready: bridge.rmBridge)
                    }
                    HStack(spacing: 8) {
                        LegacyStatusPill(title: "VM stage", ready: bridge.activeVmStage)
                        LegacyStatusPill(title: "Win11", ready: bridge.win11Vm)
                        LegacyStatusPill(title: "Legacy VM", ready: bridge.legacyVm)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(bridge.stageDescription)
                    Text(bridge.scanDescription)
                    if bridge.perslisBridge {
                        Text("Perslis Bridge process detected locally.")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.muted)

                if !bridge.processItems.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Detected runtimes")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.88))
                        ForEach(bridge.processItems.prefix(5)) { item in
                            LegacyProcessRow(item: item)
                        }
                    }
                }
            }
        }
        .task {
            if !model.legacyBridge.hasChecked {
                await model.checkLegacyBridge(auto: true)
            }
        }
    }
}

struct LegacyStatusPill: View {
    let title: String
    let ready: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ready ? AppTheme.green : AppTheme.orange)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 11, weight: .bold))
            Text(ready ? "ready" : "missing")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ready ? AppTheme.green : AppTheme.orange)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppTheme.panel2, in: Capsule())
        .overlay(Capsule().stroke(ready ? AppTheme.green.opacity(0.35) : AppTheme.orange.opacity(0.25), lineWidth: 1))
    }
}

struct LegacyProcessRow: View {
    let item: LegacyProcessItem

    var body: some View {
        HStack(spacing: 8) {
            Text(item.label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 110, alignment: .leading)
            Text("pid \(item.pid)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.muted)
            Text(item.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.muted)
                .lineLimit(1)
            if let qmpSocket = item.qmpSocket {
                Text(qmpSocket)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.blue)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

struct MoneyCaptureControlPanel: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        DarkPanel {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Capture pipeline", systemImage: "arrow.down.doc.fill")
                        .font(.system(size: 16, weight: .bold))
                    Text("Press Run and keep this screen open: the app shows the real source image, OCR extraction, normalized digital rows, SQL evidence, and the living CSV grid as the pipeline completes.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                PipelineStatusPill(title: "Sources", ready: model.invoiceFolderURL != nil && model.pricebookURL != nil)
                PipelineStatusPill(title: "SQL", ready: model.hasBusinessDatabase)
                PipelineStatusPill(title: "CSV grid", ready: !model.csvGridRows.isEmpty)

                Button {
                    model.showExtractionWorkspace = true
                    Task { await model.runAudit() }
                } label: {
                    Label(model.isRunning ? "Running..." : "Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRunAudit)
            }
        }
    }
}

struct PipelineStatusPill: View {
    let title: String
    let ready: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ready ? AppTheme.green : AppTheme.orange)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 11, weight: .bold))
            Text(ready ? "ready" : "needed")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ready ? AppTheme.green : AppTheme.orange)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppTheme.panel2, in: Capsule())
        .overlay(Capsule().stroke(ready ? AppTheme.green.opacity(0.35) : AppTheme.orange.opacity(0.35), lineWidth: 1))
    }
}

struct MoneyExtractionWorkspace: View {
    @EnvironmentObject private var model: AuditModel

    private var activeInvoice: InvoiceView? {
        model.selectedInvoice ?? model.receipt?.invoices.first
    }

    var body: some View {
        DarkPanel {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Live capture workspace", systemImage: "rectangle.split.3x1")
                            .font(.system(size: 17, weight: .bold))
                        Text(model.pipelinePhase)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(model.isRunning ? AppTheme.orange : AppTheme.green)
                    }
                    Spacer()
                    if model.isRunning {
                        ProgressView()
                            .controlSize(.small)
                        Text("running")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(AppTheme.orange)
                    }
                    Button {
                        Task { await model.refreshCSVGrid(openInFinder: false) }
                    } label: {
                        Label("Refresh CSV", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.hasBusinessDatabase)
                    Button {
                        model.openInvoiceLinesCSV()
                    } label: {
                        Label("Open CSV", systemImage: "tablecells")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!model.hasBusinessDatabase && model.csvGridRows.isEmpty)
                }

                HStack(alignment: .top, spacing: 12) {
                    MoneySourceQueueColumn()
                        .frame(width: 210)
                    MoneySourceImageColumn(invoice: activeInvoice)
                        .frame(minWidth: 240, maxWidth: .infinity)
                    MoneyExtractionColumn(invoice: activeInvoice)
                        .frame(minWidth: 260, maxWidth: .infinity)
                    MoneyCSVGridColumn(rows: model.csvGridRows)
                        .frame(minWidth: 300, maxWidth: .infinity)
                }
                .frame(minHeight: 520)

                if !model.transcript.isEmpty {
                    DisclosureGroup("Run transcript") {
                        ScrollView {
                            Text(model.transcript)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AppTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 120)
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
            }
        }
    }
}

struct MoneySourceQueueColumn: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        PipelineColumn(title: "1 · Source queue", systemImage: "tray.full") {
            if let receipt = model.receipt {
                ForEach(receipt.invoices) { invoice in
                    Button {
                        model.selectedInvoiceID = invoice.id
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Image(systemName: invoice.disposition == "flagged" ? "exclamationmark.triangle.fill" : "doc.text.fill")
                                    .foregroundStyle(invoice.disposition == "flagged" ? AppTheme.orange : AppTheme.blue)
                                Text(invoice.file)
                                    .font(.system(size: 11, weight: .bold))
                                    .lineLimit(1)
                                Spacer()
                            }
                            Text("\(invoice.vendor) · \(invoice.lineCount) lines")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AppTheme.muted)
                                .lineLimit(2)
                        }
                        .padding(9)
                        .background(model.selectedInvoiceID == invoice.id ? AppTheme.blue.opacity(0.22) : AppTheme.panel2.opacity(0.64), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                EmptyDarkText(model.isRunning ? "Reading source folder..." : "Run capture to load source files.")
            }
        }
    }
}

struct MoneySourceImageColumn: View {
    let invoice: InvoiceView?

    var body: some View {
        PipelineColumn(title: "2 · Real source image", systemImage: "doc.viewfinder") {
            VStack(alignment: .leading, spacing: 10) {
                Text(invoice?.file ?? "Waiting for source")
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.92))
                    if let url = invoice?.imageURL,
                       let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(14)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.text.viewfinder")
                                .font(.system(size: 42))
                                .foregroundStyle(.black.opacity(0.34))
                            Text("Source preview appears here while extraction runs.")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.54))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 18)
                        }
                    }
                }
                .frame(minHeight: 430)
            }
        }
    }
}

struct MoneyExtractionColumn: View {
    let invoice: InvoiceView?

    var body: some View {
        PipelineColumn(title: "3 · OCR → digital rows", systemImage: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 12) {
                Text("OCR read")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(AppTheme.blue)
                if let invoice, !invoice.lines.isEmpty {
                    ForEach(invoice.lines.prefix(5)) { line in
                        DarkOCRLine(line: line)
                    }
                } else {
                    EmptyDarkText("OCR rows stream here after the source scan is processed.")
                }

                Divider().overlay(AppTheme.stroke)

                Text("Normalized line items")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(AppTheme.green)
                if let invoice, !invoice.lines.isEmpty {
                    ForEach(invoice.lines.prefix(5)) { line in
                        DarkDigitalLine(line: line)
                    }
                } else {
                    EmptyDarkText("Digital rows appear here with qty, unit, total, category, and risk.")
                }
            }
        }
    }
}

struct MoneyCSVGridColumn: View {
    @EnvironmentObject private var model: AuditModel
    let rows: [CSVGridRow]

    var body: some View {
        PipelineColumn(title: "4 · Living CSV / SQL grid", systemImage: "tablecells") {
            if rows.isEmpty {
                EmptyDarkText("Run capture to generate invoice_lines.csv from the SQL table.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(rows.count) rows harvested from SQLite → invoice_lines.csv")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(AppTheme.green)
                    Text(model.invoiceLinesCSVURL.path)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(1)
                }
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        CSVGridHeader()
                        ForEach(rows.prefix(18)) { row in
                            CSVGridRowView(row: row)
                        }
                    }
                }
                .frame(minHeight: 430)
            }
        }
    }
}

struct PipelineColumn<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white.opacity(0.92))
            content()
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppTheme.panel2.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.stroke, lineWidth: 1))
    }
}

struct DarkOCRLine: View {
    let line: InvoiceLineView

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(line.ocrRowText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(3)
            Text("confidence \(Int(line.confidence * 100))% · \(line.grounding.replacingOccurrences(of: "-", with: " "))")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppTheme.muted)
        }
        .padding(8)
        .background(AppTheme.bg.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DarkDigitalLine: View {
    let line: InvoiceLineView

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(line.sku.isEmpty ? line.description : line.sku)
                .font(.system(size: 11, weight: .bold))
            Text(line.category)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(AppTheme.blue)
            HStack(spacing: 8) {
                GridMiniCell(label: "qty", value: number(line.qty))
                GridMiniCell(label: "unit", value: dollars(line.unitPrice))
                GridMiniCell(label: "total", value: dollars(line.lineTotal))
            }
            if line.priceExposure > 0 || line.policyExposure > 0 {
                Text("risk \(dollars(line.priceExposure + line.policyExposure))")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(AppTheme.red)
            }
        }
        .padding(8)
        .background(AppTheme.bg.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct GridMiniCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(AppTheme.muted)
            Text(value)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CSVGridHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            CSVCell("invoice", width: 105, isHeader: true)
            CSVCell("vendor", width: 140, isHeader: true)
            CSVCell("sku", width: 95, isHeader: true)
            CSVCell("description", width: 180, isHeader: true)
            CSVCell("qty", width: 50, isHeader: true)
            CSVCell("unit", width: 78, isHeader: true)
            CSVCell("median", width: 78, isHeader: true)
            CSVCell("risk", width: 78, isHeader: true)
        }
        .background(AppTheme.blue.opacity(0.25))
    }
}

struct CSVGridRowView: View {
    let row: CSVGridRow

    var body: some View {
        HStack(spacing: 0) {
            CSVCell(row.value("invoice"), width: 105)
            CSVCell(row.value("vendor"), width: 140)
            CSVCell(row.value("sku"), width: 95)
            CSVCell(row.value("description"), width: 180)
            CSVCell(row.value("qty"), width: 50)
            CSVCell(row.value("unit_price"), width: 78)
            CSVCell(row.value("reference_median"), width: 78)
            CSVCell(row.value("price_exposure"), width: 78, tint: riskColor)
        }
    }

    private var riskColor: Color? {
        (Double(row.value("price_exposure")) ?? 0) > 0 ? AppTheme.red : nil
    }
}

struct CSVCell: View {
    let text: String
    let width: CGFloat
    let isHeader: Bool
    let tint: Color?

    init(_ text: String, width: CGFloat, isHeader: Bool = false, tint: Color? = nil) {
        self.text = text
        self.width = width
        self.isHeader = isHeader
        self.tint = tint
    }

    var body: some View {
        Text(text.isEmpty ? "—" : text)
            .font(.system(size: isHeader ? 9 : 10, weight: isHeader ? .black : .semibold, design: .monospaced))
            .foregroundStyle(tint ?? (isHeader ? .white.opacity(0.92) : .white.opacity(0.78)))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            .frame(width: width, alignment: .leading)
            .border(AppTheme.stroke.opacity(0.55), width: 0.5)
    }
}

struct WizardSourceCard: View {
    let number: String
    let title: String
    let detail: String
    let systemImage: String
    let isReady: Bool
    let actionTitle: String
    let action: () -> Void
    var runTitle: String? = nil
    var runAction: (() -> Void)? = nil
    var runDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(number)
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(isReady ? AppTheme.green : AppTheme.blue, in: Circle())
                Spacer()
                Image(systemName: isReady ? "checkmark.circle.fill" : systemImage)
                    .foregroundStyle(isReady ? AppTheme.green : AppTheme.muted)
            }
            Text(title)
                .font(.system(size: 18, weight: .bold))
            Text(detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.muted)
                .lineLimit(3)
                .frame(minHeight: 48, alignment: .topLeading)
            HStack(spacing: 8) {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .disabled(false)
                if let runTitle, let runAction {
                    Button {
                        runAction()
                    } label: {
                        Label(runTitle, systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(runDisabled)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(isReady ? AppTheme.green.opacity(0.45) : AppTheme.stroke, lineWidth: 1))
    }
}
