import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

struct HeaderView: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Financial Ops Copilot")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(model.status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusPill(label: model.verification, systemImage: "checkmark.seal.fill")

            Button {
                model.revealReceipt()
            } label: {
                Label("Receipt", systemImage: "doc.badge.ellipsis")
            }
            .disabled(model.receipt == nil)

            Button {
                model.revealDatabase()
            } label: {
                Label("Database", systemImage: "cylinder.split.1x2")
            }
            .disabled(model.receipt == nil)

            Button {
                model.revealReport()
            } label: {
                Label("Report", systemImage: "chart.bar.xaxis")
            }
            .disabled(!model.hasReport)

            Button {
                Task { await model.verifyReceipt() }
            } label: {
                Label("Verify", systemImage: "checkmark.shield")
            }
            .disabled(model.isRunning || model.receipt == nil)

            Button {
                model.useSampleData()
            } label: {
                Label("Sample Data", systemImage: "shippingbox")
            }
            .disabled(model.isRunning)

            Button {
                Task { await model.runAudit() }
            } label: {
                Label(model.isRunning ? "Auditing" : "Run Audit", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canRunAudit)
        }
        .buttonStyle(.bordered)
    }
}

struct SourceSetupView: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Data Sources")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Choose invoices and Excel/CSV price sheets before running an audit.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.useSampleData()
                } label: {
                    Label("Use Sample", systemImage: "shippingbox")
                }
                .disabled(model.isRunning)
            }

            HStack(spacing: 10) {
                SourceCard(
                    title: "Invoices",
                    detail: model.invoiceFolderURL?.path(percentEncoded: false)
                        ?? "No folder selected",
                    systemImage: "folder",
                    isReady: model.invoiceFolderURL != nil,
                    actionTitle: "Choose Folder",
                    action: model.chooseInvoiceFolder
                )
                SourceCard(
                    title: "Excel Sheets",
                    detail: model.pricebookURL?.lastPathComponent
                        ?? ".xlsx, CSV, or SQLite required",
                    systemImage: "tablecells",
                    isReady: model.pricebookURL != nil,
                    actionTitle: "Choose File",
                    action: model.choosePricebook
                )
                SourceCard(
                    title: "Market",
                    detail: model.marketURL?.lastPathComponent
                        ?? "Optional market benchmark",
                    systemImage: "chart.line.uptrend.xyaxis",
                    isReady: model.marketURL != nil,
                    actionTitle: model.marketURL == nil ? "Choose File" : "Change",
                    action: model.chooseMarket,
                    secondaryTitle: model.marketURL == nil ? nil : "Clear",
                    secondaryAction: model.clearMarket
                )
                SourceCard(
                    title: "Rules",
                    detail: model.rulesURL?.lastPathComponent
                        ?? "Optional policy/rule file",
                    systemImage: "slider.horizontal.3",
                    isReady: model.rulesURL != nil,
                    actionTitle: model.rulesURL == nil ? "Choose File" : "Change",
                    action: model.chooseRules,
                    secondaryTitle: model.rulesURL == nil ? nil : "Clear",
                    secondaryAction: model.clearRules
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Source Connectors", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button {
                        model.chooseNetworkFolder()
                    } label: {
                        Label("Network Folder", systemImage: "externaldrive.connected.to.line.below")
                    }
                    .disabled(model.isRunning)
                }

                HStack(spacing: 8) {
                    TextField("Paste API/Zapier source URL", text: $model.sourceAPIURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.isRunning)
                    Button {
                        Task { await model.pullAPIConnector() }
                    } label: {
                        Label("Pull Data", systemImage: "arrow.down.doc")
                    }
                    .disabled(model.isRunning || model.sourceAPIURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text(model.connectorStatus)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            .background(.white.opacity(0.66), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
        .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SourceCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let isReady: Bool
    let actionTitle: String
    let action: () -> Void
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(isReady ? Color.green : Color.orange)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(isReady ? Color.green : Color.orange)
            }
            Text(detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Button(actionTitle, action: action)
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AuditModel
    let receipt: ReceiptSummary

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            SidebarView(receipt: receipt)
                .frame(width: 300)

            EvidenceView(invoice: model.selectedInvoice)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            RightRail(receipt: receipt)
                .frame(width: 390)
        }
    }
}

struct RightRail: View {
    let receipt: ReceiptSummary

    var body: some View {
        VStack(spacing: 12) {
            FindingsPanel(receipt: receipt)
                .frame(maxHeight: .infinity)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AuditModel
    let receipt: ReceiptSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SummaryGrid(totals: receipt.totals)
            VStack(alignment: .leading, spacing: 8) {
                Text("Invoices")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(receipt.invoices) { invoice in
                    InvoiceRow(invoice: invoice, selected: model.selectedInvoiceID == invoice.id)
                        .onTapGesture {
                            model.selectedInvoiceID = invoice.id
                        }
                }
            }
            Spacer()
            ReceiptFacts(receipt: receipt)
        }
    }
}

struct SummaryGrid: View {
    let totals: Totals

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                MetricTile(title: "Exposure", value: dollars(totals.potentialOvercharge), tint: Color(red: 0.72, green: 0.18, blue: 0.13))
                MetricTile(title: "Policy", value: dollars(totals.policyOverage), tint: Color(red: 0.48, green: 0.25, blue: 0.72))
            }
            HStack(spacing: 10) {
                MetricTile(title: "Findings", value: "\(totals.flagged)", tint: Color(red: 0.81, green: 0.48, blue: 0.08))
                MetricTile(title: "Lines", value: "\(totals.lines)", tint: Color(red: 0.12, green: 0.44, blue: 0.58))
            }
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .top) {
            tint.frame(height: 3).clipShape(Capsule()).padding(.horizontal, 12)
        }
    }
}

struct InvoiceRow: View {
    let invoice: InvoiceView
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: invoice.disposition == "flagged" ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(invoice.disposition == "flagged" ? .orange : .green)
            VStack(alignment: .leading, spacing: 3) {
                Text(invoice.file)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(invoice.category) · \(invoice.lineCount) lines")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(selected ? Color.accentColor.opacity(0.13) : .white.opacity(0.64), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct EvidenceView: View {
    let invoice: InvoiceView?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(invoice?.file ?? "No invoice selected")
                        .font(.system(size: 18, weight: .semibold))
                    Text(invoice?.vendor ?? "Run an audit to load invoice evidence")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let invoice {
                    StatusPill(label: invoice.disposition.capitalized, systemImage: "doc.text.magnifyingglass")
                }
            }

            GeometryReader { proxy in
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.78))
                        if let url = invoice?.imageURL,
                           let image = NSImage(contentsOf: url) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding(18)
                                .frame(width: proxy.size.width, height: proxy.size.height * 0.56)
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "doc.viewfinder")
                                    .font(.system(size: 42))
                                    .foregroundStyle(.secondary)
                                Text("Invoice preview unavailable")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(height: proxy.size.height * 0.56)

                    ConversionPanel(invoice: invoice)
                        .frame(height: max(190, proxy.size.height * 0.34))
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ConversionPanel: View {
    let invoice: InvoiceView?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("OCR to Digital")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        PanelLabel("OCR Read")
                        if let invoice, !invoice.lines.isEmpty {
                            ForEach(invoice.lines) { line in
                                OCRLine(line: line)
                            }
                        } else {
                            EmptyPanelText("No OCR rows loaded")
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        PanelLabel("Digital Invoice")
                        if let invoice, !invoice.lines.isEmpty {
                            ForEach(invoice.lines) { line in
                                DigitalLine(line: line)
                            }
                        } else {
                            EmptyPanelText("Run audit to build line items")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PanelLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

struct OCRLine: View {
    let line: InvoiceLineView

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(line.ocrRowText)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(3)
            HStack {
                Text("confidence \(Int(line.confidence * 100))%")
                Spacer()
                Text(line.grounding.replacingOccurrences(of: "-", with: " "))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct DigitalLine: View {
    let line: InvoiceLineView

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.sku.isEmpty ? "No SKU" : line.sku)
                    .font(.system(size: 11, weight: .semibold))
                Text(line.description)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(line.category)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.blue)
            }

            HStack {
                AmountChip(label: "Qty", value: number(line.qty))
                AmountChip(label: "Unit", value: money(line.unitPrice))
                AmountChip(label: "Total", value: money(line.lineTotal))
                if line.policyExposure > 0 {
                    AmountChip(label: "Policy risk", value: money(line.policyExposure))
                }
            }
        }
        .font(.system(size: 11, design: .rounded))
        .padding(9)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct AmountChip: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyPanelText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct FindingsPanel: View {
    @EnvironmentObject private var model: AuditModel
    let receipt: ReceiptSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Queue")
                .font(.system(size: 18, weight: .semibold))

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(receipt.findings) { finding in
                        FindingCard(finding: finding, selected: model.selectedFindingID == finding.id)
                            .onTapGesture {
                                model.selectedFindingID = finding.id
                                model.selectedInvoiceID = finding.invoice
                            }
                    }
                }
            }

            if !model.transcript.isEmpty {
                DisclosureGroup("Run Log") {
                    ScrollView {
                        Text(model.transcript)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(16)
        .background(.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AnalystPanel: View {
    @EnvironmentObject private var model: AuditModel

    private let suggestions = [
        "what should I deal with today?",
        "trace this dollar",
        "where are we leaking money?",
        "compare vendors",
        "show overcharges",
        "what should I tell the owner?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Financial Analyst", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if model.analystIsRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                TextField("Ask: what needs attention, trace this dollar, why did costs jump...", text: $model.analystQuestion)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await model.askAnalyst() }
                    }
                Button {
                    Task { await model.askAnalyst() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canAskAnalyst)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            model.analystQuestion = suggestion
                            Task { await model.askAnalyst() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!FileManager.default.fileExists(atPath: model.dbPathForUI))
                    }
                }
            }

            ScrollView {
                Text(model.analystAnswer)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(AppTheme.bg.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.stroke, lineWidth: 1))
    }
}

struct SharePanel: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Share & Connect", systemImage: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if model.shareIsRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Button {
                    Task { await model.generateEmailDraft() }
                } label: {
                    Label("Email Draft", systemImage: "envelope")
                }
                .disabled(!model.canShare)

                Button {
                    Task { await model.exportCSVs() }
                } label: {
                    Label("CSV Export", systemImage: "tablecells")
                }
                .disabled(!model.canShare)

                Button {
                    Task { await model.exportIntegrationPayload() }
                } label: {
                    Label("API File", systemImage: "doc.badge.gearshape")
                }
                .disabled(!model.canShare)
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                TextField("Paste Zapier or webhook URL", text: $model.webhookURL)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    Task { await model.sendWebhook() }
                }
                .disabled(!model.canSendWebhook)
            }

            Text(model.shareStatus)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.stroke, lineWidth: 1))
    }
}

struct FindingCard: View {
    let finding: FindingView
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(finding.severity.label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(finding.severity.color)
                Spacer()
                Text(finding.line)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(finding.kind.replacingOccurrences(of: "-", with: " ").capitalized)
                .font(.system(size: 15, weight: .semibold))
            Text(finding.detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(finding.invoice)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(13)
        .background(selected ? finding.severity.color.opacity(0.12) : .white.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? finding.severity.color.opacity(0.55) : Color.black.opacity(0.05), lineWidth: 1)
        )
    }
}

struct ReceiptFacts: View {
    let receipt: ReceiptSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            FactRow("Source", receipt.invoiceFolderURL?.lastPathComponent ?? "Unknown")
            FactRow("Prices", "\(receipt.pricebookRows) rows")
            FactRow("Market", receipt.marketRows.map { "\($0) rows" } ?? "None")
            FactRow("Rules", receipt.ruleCount.map { "\($0) rules" } ?? "None")
            FactRow("OCR", receipt.ocrEngine)
            FactRow("Engine", receipt.extractionEngine)
            FactRow("Signed", receipt.signature.isEmpty ? "Missing" : "\(receipt.signature)...")
            FactRow("Generated", receipt.generatedAt)
        }
        .padding(12)
        .background(.white.opacity(0.64), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct FactRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Choose sources to start")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            Text("Select an invoice folder and Excel/CSV price sheet, or load the sample data.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Button {
                model.useSampleData()
            } label: {
                Label("Use Sample Data", systemImage: "shippingbox")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatusPill: View {
    let label: String
    let systemImage: String

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.white.opacity(0.74), in: Capsule())
    }
}
