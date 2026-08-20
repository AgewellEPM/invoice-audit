import SwiftUI
import AppKit

@main
struct InvoiceAuditDemoApp: App {
    @StateObject private var model = AuditModel()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 760)
                .task {
                    await model.loadExistingReceipt()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Run Demo Audit") {
                    Task { await model.runDemoAudit() }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Verify Receipt") {
                    Task { await model.verifyReceipt() }
                }
                .keyboardShortcut("v", modifiers: [.command])
            }
        }
    }
}

@MainActor
final class AuditModel: ObservableObject {
    @Published var receipt: ReceiptSummary?
    @Published var selectedInvoiceID: String?
    @Published var selectedFindingID: String?
    @Published var isRunning = false
    @Published var status = "Ready"
    @Published var verification = "Not verified"
    @Published var transcript = ""

    private let repoRoot: URL
    private let receiptURL: URL

    init() {
        let envRoot = ProcessInfo.processInfo.environment["INVOICE_AUDIT_ROOT"]
        let bundledRoot = Bundle.main.resourceURL?
            .appendingPathComponent("invoice-audit-root")
            .path
        let cwd = FileManager.default.currentDirectoryPath
        let rootPath = envRoot ?? bundledRoot.flatMap {
            try? String(contentsOfFile: $0, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? cwd
        repoRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
        receiptURL = repoRoot
            .appendingPathComponent(".invoice-audit-app", isDirectory: true)
            .appendingPathComponent("latest-receipt.json")
    }

    var selectedInvoice: InvoiceView? {
        guard let receipt else { return nil }
        if let selectedInvoiceID,
           let invoice = receipt.invoices.first(where: { $0.id == selectedInvoiceID }) {
            return invoice
        }
        return receipt.invoices.first
    }

    var selectedFinding: FindingView? {
        guard let receipt else { return nil }
        if let selectedFindingID,
           let finding = receipt.findings.first(where: { $0.id == selectedFindingID }) {
            return finding
        }
        return receipt.findings.first
    }

    func loadExistingReceipt() async {
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            await loadReceipt(from: receiptURL)
        } else {
            let bundled = repoRoot.appendingPathComponent("demo/scans/audit-receipt.json")
            if FileManager.default.fileExists(atPath: bundled.path) {
                await loadReceipt(from: bundled)
            }
        }
    }

    func runDemoAudit() async {
        guard !isRunning else { return }
        isRunning = true
        status = "Auditing demo invoices"
        verification = "Pending"
        transcript = ""

        do {
            try FileManager.default.createDirectory(
                at: receiptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try await runPython(["demo/make_fixtures.py"])
            let output = try await runPython([
                "-m", "invoice_audit", "audit", "demo/scans",
                "--pricebook", "demo/pricebook.csv",
                "--floor", "demo/floor-rules.json",
                "--out", receiptURL.path
            ])
            transcript += output
            await loadReceipt(from: receiptURL)
            await verifyReceipt()
            status = "Audit complete"
        } catch {
            status = "Audit failed"
            verification = "Failed"
            transcript += "\n\(error.localizedDescription)"
        }

        isRunning = false
    }

    func verifyReceipt() async {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else {
            verification = "No receipt"
            return
        }
        do {
            let output = try await runPython([
                "-m", "invoice_audit", "verify", receiptURL.path
            ])
            verification = output.localizedCaseInsensitiveContains("VERIFIED")
                ? "Verified"
                : "Needs attention"
            transcript += output
        } catch {
            verification = "Failed"
            transcript += "\n\(error.localizedDescription)"
        }
    }

    func revealReceipt() {
        NSWorkspace.shared.activateFileViewerSelecting([receiptURL])
    }

    private func loadReceipt(from url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let json else { throw AppError("Receipt is not a JSON object") }
            receipt = ReceiptSummary(json: json, repoRoot: repoRoot)
            selectedInvoiceID = receipt?.invoices.first?.id
            selectedFindingID = receipt?.findings.first?.id
            status = "Loaded receipt"
        } catch {
            status = "Could not load receipt"
            transcript += "\n\(error.localizedDescription)"
        }
    }

    private func runPython(_ args: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.currentDirectoryURL = self.repoRoot
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PYTHONPATH"] = self.repoRoot.path
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                throw AppError(text.isEmpty ? "Python exited with \(process.terminationStatus)" : text)
            }
            return text
        }.value
    }
}

struct ReceiptSummary {
    let generatedAt: String
    let ocrEngine: String
    let extractionEngine: String
    let signature: String
    let totals: Totals
    let invoices: [InvoiceView]
    let findings: [FindingView]

    init(json: [String: Any], repoRoot: URL) {
        let engine = json["engine"] as? [String: Any] ?? [:]
        generatedAt = json["generatedAt"] as? String ?? "Unknown"
        ocrEngine = engine["ocr"] as? String ?? "Unknown"
        extractionEngine = engine["extraction"] as? String ?? "Unknown"
        signature = String((json["signature"] as? String ?? "").prefix(16))
        totals = Totals(json: json["totals"] as? [String: Any] ?? [:])

        let invoiceRows = json["invoices"] as? [[String: Any]] ?? []
        let parsedInvoices = invoiceRows.map { InvoiceView(json: $0, repoRoot: repoRoot) }
        invoices = parsedInvoices

        let queue = json["reviewQueue"] as? [[String: Any]] ?? []
        findings = queue.enumerated().map { index, row in
            FindingView(index: index, json: row, invoices: parsedInvoices)
        }
    }
}

struct Totals {
    let invoices: Int
    let lines: Int
    let flagged: Int
    let potentialOvercharge: Double
    let policyOverage: Double

    init(json: [String: Any]) {
        invoices = json["invoices"] as? Int ?? 0
        lines = json["linesChecked"] as? Int ?? 0
        flagged = json["flagged"] as? Int ?? 0
        potentialOvercharge = json["potentialOverchargeUSD"] as? Double ?? 0
        policyOverage = json["policyOverageUSD"] as? Double ?? 0
    }
}

struct InvoiceView: Identifiable {
    let id: String
    let file: String
    let vendor: String
    let invoiceNo: String
    let disposition: String
    let lineCount: Int
    let imageURL: URL?

    init(json: [String: Any], repoRoot: URL) {
        file = json["file"] as? String ?? "invoice"
        id = file
        vendor = json["vendor"] as? String ?? "Unknown vendor"
        invoiceNo = json["invoice_no"] as? String ?? "Unknown"
        disposition = json["disposition"] as? String ?? "unknown"
        lineCount = (json["lines"] as? [[String: Any]] ?? []).count
        if let path = json["path"] as? String {
            let url = URL(fileURLWithPath: path, relativeTo: repoRoot).standardizedFileURL
            imageURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
        } else {
            imageURL = nil
        }
    }
}

struct FindingView: Identifiable {
    let id: String
    let invoice: String
    let kind: String
    let line: String
    let detail: String
    let severity: Severity
    let invoiceImageURL: URL?

    init(index: Int, json: [String: Any], invoices: [InvoiceView]) {
        invoice = json["invoice"] as? String ?? "Unknown"
        kind = json["kind"] as? String ?? "review"
        if let n = json["line"] as? Int {
            line = "Line \(n + 1)"
        } else {
            line = "Invoice"
        }
        detail = json["detail"] as? String ?? "Needs review"
        id = "\(invoice)-\(kind)-\(index)"
        severity = Severity(kind: kind)
        let invoiceFile = invoice
        invoiceImageURL = invoices.first(where: { $0.file == invoiceFile })?.imageURL
    }
}

enum Severity {
    case money
    case policy
    case evidence
    case reference

    init(kind: String) {
        switch kind {
        case "overcharge-flag": self = .money
        case "floor-veto": self = .policy
        case "arithmetic-mismatch", "weak-grounding", "ungrounded", "low-confidence":
            self = .evidence
        default: self = .reference
        }
    }

    var label: String {
        switch self {
        case .money: "Money"
        case .policy: "Policy"
        case .evidence: "Evidence"
        case .reference: "Reference"
        }
    }

    var color: Color {
        switch self {
        case .money: Color(red: 0.72, green: 0.18, blue: 0.13)
        case .policy: Color(red: 0.48, green: 0.25, blue: 0.72)
        case .evidence: Color(red: 0.81, green: 0.48, blue: 0.08)
        case .reference: Color(red: 0.12, green: 0.44, blue: 0.58)
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.965, green: 0.968, blue: 0.972),
                    Color(red: 0.925, green: 0.936, blue: 0.946)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                HeaderView()
                if let receipt = model.receipt {
                    ContentView(receipt: receipt)
                } else {
                    EmptyStateView()
                }
            }
            .padding(22)
        }
    }
}

struct HeaderView: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Invoice Audit")
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
                Task { await model.verifyReceipt() }
            } label: {
                Label("Verify", systemImage: "checkmark.shield")
            }
            .disabled(model.isRunning || model.receipt == nil)

            Button {
                Task { await model.runDemoAudit() }
            } label: {
                Label(model.isRunning ? "Auditing" : "Run Audit", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isRunning)
        }
        .buttonStyle(.bordered)
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

            FindingsPanel(receipt: receipt)
                .frame(width: 390)
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
                Text("\(invoice.lineCount) lines")
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
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.78))
                    if let url = invoice?.imageURL,
                       let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(22)
                            .frame(width: proxy.size.width, height: proxy.size.height)
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
            }
        }
        .padding(16)
        .background(.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 8))
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
            Text("Run the audit")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            Text("The app will read the demo invoices, produce the signed receipt, and show the review queue.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Button {
                Task { await model.runDemoAudit() }
            } label: {
                Label("Run Audit", systemImage: "play.fill")
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

func dollars(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? "$0"
}

struct AppError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
