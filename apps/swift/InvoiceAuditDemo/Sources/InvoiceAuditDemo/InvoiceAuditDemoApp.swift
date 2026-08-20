import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct InvoiceAuditDemoApp: App {
    @StateObject private var model = AuditModel()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .frame(minWidth: 1180, minHeight: 760)
                .task {
                    await model.loadExistingReceipt()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Run Audit") {
                    Task { await model.runAudit() }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Use Sample Data") {
                    model.useSampleData()
                }

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
    @Published var status = "Choose invoice and price-history sources"
    @Published var verification = "Not verified"
    @Published var transcript = ""
    @Published var invoiceFolderURL: URL?
    @Published var pricebookURL: URL?
    @Published var rulesURL: URL?
    @Published var analystQuestion = "show overcharges"
    @Published var analystAnswer = "Run an audit, then ask about overcharges, policy exceptions, OCR evidence, missing history, or a specific invoice."
    @Published var analystIsRunning = false

    private let repoRoot: URL
    private let receiptURL: URL
    private let dbURL: URL
    private let reportURL: URL

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
        dbURL = repoRoot
            .appendingPathComponent(".invoice-audit-app", isDirectory: true)
            .appendingPathComponent("business.sqlite")
        reportURL = repoRoot
            .appendingPathComponent(".invoice-audit-app", isDirectory: true)
            .appendingPathComponent("business-report.html")
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
            if hasBusinessDatabase {
                await generateReport()
                await askAnalyst()
            }
        }
    }

    var canRunAudit: Bool {
        invoiceFolderURL != nil && pricebookURL != nil && !isRunning
    }

    var canAskAnalyst: Bool {
        hasBusinessDatabase
            && !analystIsRunning
            && !analystQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasBusinessDatabase: Bool {
        FileManager.default.fileExists(atPath: dbURL.path)
    }

    var hasReport: Bool {
        FileManager.default.fileExists(atPath: reportURL.path)
    }

    var dbPathForUI: String {
        dbURL.path
    }

    func chooseInvoiceFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Invoice Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            invoiceFolderURL = panel.url
            status = "Invoice folder selected"
        }
    }

    func choosePricebook() {
        let panel = NSOpenPanel()
        panel.title = "Choose Price History"
        panel.allowedContentTypes = [
            UTType.commaSeparatedText,
            UTType(filenameExtension: "sqlite"),
            UTType(filenameExtension: "sqlite3"),
            UTType(filenameExtension: "db")
        ].compactMap { $0 }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            pricebookURL = panel.url
            status = "Price history selected"
        }
    }

    func chooseRules() {
        let panel = NSOpenPanel()
        panel.title = "Choose Optional Rules File"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            rulesURL = panel.url
            status = "Rules file selected"
        }
    }

    func clearRules() {
        rulesURL = nil
        status = "Rules cleared"
    }

    func useSampleData() {
        invoiceFolderURL = repoRoot.appendingPathComponent("demo/scans", isDirectory: true)
        pricebookURL = repoRoot.appendingPathComponent("demo/pricebook.csv")
        rulesURL = repoRoot.appendingPathComponent("demo/floor-rules.json")
        status = "Sample data selected"
    }

    func runDemoAudit() async {
        useSampleData()
        await runAudit()
    }

    func runAudit() async {
        guard !isRunning else { return }
        guard let invoiceFolderURL, let pricebookURL else {
            status = "Choose invoices and price history first"
            return
        }
        isRunning = true
        status = "Auditing selected invoices"
        verification = "Pending"
        transcript = ""

        do {
            try FileManager.default.createDirectory(
                at: receiptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var args = [
                "-m", "invoice_audit", "audit-db", invoiceFolderURL.path,
                "--pricebook", pricebookURL.path,
                "--db", dbURL.path,
                "--out", receiptURL.path
            ]
            if let rulesURL {
                args.append(contentsOf: ["--floor", rulesURL.path])
            }
            let output = try await runPython(args)
            transcript += output
            await loadReceipt(from: receiptURL)
            await verifyReceipt()
            await generateReport()
            await askAnalyst()
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

    func revealDatabase() {
        NSWorkspace.shared.activateFileViewerSelecting([dbURL])
    }

    func revealReport() {
        if FileManager.default.fileExists(atPath: reportURL.path) {
            NSWorkspace.shared.open(reportURL)
        } else {
            status = "Run an audit to generate the report"
        }
    }

    func generateReport() async {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return }
        do {
            let output = try await runPython([
                "-m", "invoice_audit", "report",
                "--db", dbURL.path,
                "--out", reportURL.path
            ])
            transcript += output
        } catch {
            transcript += "\nReport generation failed: \(error.localizedDescription)"
        }
    }

    func askAnalyst() async {
        let question = analystQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            analystAnswer = "No business database yet. Choose sources and run an audit first."
            return
        }
        analystIsRunning = true
        analystAnswer = "Thinking from the SQL evidence store..."
        do {
            let output = try await runPython([
                "-m", "invoice_audit", "ask",
                "--db", dbURL.path,
                question
            ])
            analystAnswer = output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            analystAnswer = error.localizedDescription
        }
        analystIsRunning = false
    }

    private func loadReceipt(from url: URL) async {
        do {
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let json else { throw AppError("Receipt is not a JSON object") }
            receipt = ReceiptSummary(json: json, repoRoot: repoRoot)
            if let receipt {
                invoiceFolderURL = receipt.invoiceFolderURL
                pricebookURL = receipt.pricebookURL
                rulesURL = receipt.rulesURL
            }
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
    let invoiceFolderURL: URL?
    let pricebookURL: URL?
    let rulesURL: URL?
    let pricebookRows: Int
    let ruleCount: Int?
    let totals: Totals
    let invoices: [InvoiceView]
    let findings: [FindingView]

    init(json: [String: Any], repoRoot: URL) {
        let engine = json["engine"] as? [String: Any] ?? [:]
        let pricebook = json["pricebook"] as? [String: Any] ?? [:]
        let floorRules = json["floorRules"] as? [String: Any]
        let scans = json["scans"] as? [[String: Any]] ?? []
        generatedAt = json["generatedAt"] as? String ?? "Unknown"
        ocrEngine = engine["ocr"] as? String ?? "Unknown"
        extractionEngine = engine["extraction"] as? String ?? "Unknown"
        signature = String((json["signature"] as? String ?? "").prefix(16))
        pricebookURL = Self.url(from: pricebook["path"] as? String, repoRoot: repoRoot)
        pricebookRows = pricebook["rows"] as? Int ?? 0
        rulesURL = Self.url(from: floorRules?["path"] as? String, repoRoot: repoRoot)
        ruleCount = floorRules?["rules"] as? Int
        invoiceFolderURL = Self.invoiceFolder(from: scans, repoRoot: repoRoot)
        totals = Totals(json: json["totals"] as? [String: Any] ?? [:])

        let invoiceRows = json["invoices"] as? [[String: Any]] ?? []
        let parsedInvoices = invoiceRows.map { InvoiceView(json: $0, repoRoot: repoRoot) }
        invoices = parsedInvoices

        let queue = json["reviewQueue"] as? [[String: Any]] ?? []
        findings = queue.enumerated().map { index, row in
            FindingView(index: index, json: row, invoices: parsedInvoices)
        }
    }

    private static func url(from path: String?, repoRoot: URL) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, relativeTo: repoRoot).standardizedFileURL
    }

    private static func invoiceFolder(from scans: [[String: Any]], repoRoot: URL) -> URL? {
        guard let first = scans.first?["path"] as? String else { return nil }
        return url(from: first, repoRoot: repoRoot)?.deletingLastPathComponent()
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
    let category: String
    let disposition: String
    let lineCount: Int
    let lines: [InvoiceLineView]
    let imageURL: URL?

    init(json: [String: Any], repoRoot: URL) {
        let lineRows = json["lines"] as? [[String: Any]] ?? []
        file = json["file"] as? String ?? "invoice"
        id = file
        vendor = json["vendor"] as? String ?? "Unknown vendor"
        invoiceNo = json["invoice_no"] as? String ?? "Unknown"
        category = json["category"] as? String ?? "Uncategorized"
        disposition = json["disposition"] as? String ?? "unknown"
        lines = lineRows.enumerated().map { InvoiceLineView(index: $0.offset, json: $0.element) }
        lineCount = lines.count
        if let path = json["path"] as? String {
            let url = URL(fileURLWithPath: path, relativeTo: repoRoot).standardizedFileURL
            imageURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
        } else {
            imageURL = nil
        }
    }
}

struct InvoiceLineView: Identifiable {
    let id: Int
    let sku: String
    let description: String
    let qty: Double
    let unitPrice: Double
    let lineTotal: Double
    let ocrRowText: String
    let confidence: Double
    let category: String
    let policyExposure: Double
    let grounding: String
    let verdict: String

    init(index: Int, json: [String: Any]) {
        id = index
        sku = json["sku"] as? String ?? ""
        description = json["description"] as? String ?? ""
        qty = json["qty"] as? Double ?? 0
        unitPrice = json["unit_price"] as? Double ?? 0
        lineTotal = json["line_total"] as? Double ?? 0
        ocrRowText = json["ocr_row_text"] as? String ?? "\(qty) \(description) \(unitPrice) \(lineTotal)"
        confidence = json["ocr_min_confidence"] as? Double ?? 0
        category = json["category"] as? String ?? "Uncategorized"
        policyExposure = json["policy_delta_total"] as? Double ?? 0
        let groundingObj = json["grounding"] as? [String: Any] ?? [:]
        grounding = groundingObj["verdict"] as? String ?? "unknown"
        verdict = json["verdict"] as? String ?? "unknown"
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
                SourceSetupView()
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
                    Text("Choose the invoices and customer price history before running an audit.")
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
                    title: "Price History",
                    detail: model.pricebookURL?.lastPathComponent
                        ?? "CSV or SQLite required",
                    systemImage: "tablecells",
                    isReady: model.pricebookURL != nil,
                    actionTitle: "Choose File",
                    action: model.choosePricebook
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
            AnalystPanel()
                .frame(height: 255)
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
        "summary",
        "show overcharges",
        "policy exceptions",
        "OCR evidence issues",
        "missing price history",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Business Analyst", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if model.analystIsRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                TextField("Ask about discrepancies, vendors, evidence...", text: $model.analystQuestion)
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
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
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
            FactRow("Source", receipt.invoiceFolderURL?.lastPathComponent ?? "Unknown")
            FactRow("Prices", "\(receipt.pricebookRows) rows")
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
            Text("Select an invoice folder and a customer price-history file, or load the sample data.")
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

func dollars(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? "$0"
}

func money(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
}

func number(_ value: Double) -> String {
    if value.rounded() == value {
        return String(Int(value))
    }
    return String(format: "%.2f", value)
}

struct AppError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
