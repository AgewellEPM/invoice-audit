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
                .preferredColorScheme(.dark)
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
    @Published var marketURL: URL?
    @Published var rulesURL: URL?
    @Published var sourceAPIURL = ""
    @Published var connectorStatus = "Local folder, network folder, email export, and API/Zapier sources are supported."
    @Published var analystQuestion = "show overcharges"
    @Published var analystAnswer = "Run an audit, then ask about overcharges, policy exceptions, OCR evidence, missing history, or a specific invoice."
    @Published var analystIsRunning = false
    @Published var webhookURL = ""
    @Published var shareStatus = "Generate an email draft or paste a Zapier webhook URL."
    @Published var shareIsRunning = false

    private let repoRoot: URL
    private let receiptURL: URL
    private let dbURL: URL
    private let reportURL: URL
    private let emailDraftURL: URL
    private let integrationPayloadURL: URL
    private let connectorConfigURL: URL
    private let connectorWorkspaceURL: URL

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
        emailDraftURL = repoRoot
            .appendingPathComponent(".invoice-audit-app", isDirectory: true)
            .appendingPathComponent("boss-summary.eml")
        integrationPayloadURL = repoRoot
            .appendingPathComponent(".invoice-audit-app", isDirectory: true)
            .appendingPathComponent("integration-payload.json")
        connectorConfigURL = repoRoot
            .appendingPathComponent(".invoice-audit-app", isDirectory: true)
            .appendingPathComponent("source-connector.json")
        connectorWorkspaceURL = repoRoot
            .appendingPathComponent(".invoice-audit-app", isDirectory: true)
            .appendingPathComponent("connector-workspace", isDirectory: true)
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

    var canShare: Bool {
        hasBusinessDatabase && !shareIsRunning
    }

    var canSendWebhook: Bool {
        canShare && !webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    func chooseNetworkFolder() {
        chooseInvoiceFolder()
        connectorStatus = "Network/mounted folder selected. Choose price history, then run audit."
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

    func chooseMarket() {
        let panel = NSOpenPanel()
        panel.title = "Choose Optional Market Benchmark"
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
            marketURL = panel.url
            status = "Market benchmark selected"
        }
    }

    func clearMarket() {
        marketURL = nil
        status = "Market benchmark cleared"
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
        marketURL = nil
        rulesURL = repoRoot.appendingPathComponent("demo/floor-rules.json")
        status = "Sample data selected"
    }

    func pullAPIConnector() async {
        let url = sourceAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            connectorStatus = "Paste an API/Zapier URL first."
            return
        }
        isRunning = true
        connectorStatus = "Pulling source data..."
        do {
            try FileManager.default.createDirectory(
                at: connectorConfigURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try await runPython([
                "-m", "invoice_audit", "connector-init",
                "--kind", "api-json",
                "--name", "API Source",
                "--url", url,
                "--out", connectorConfigURL.path
            ])
            let output = try await runPython([
                "-m", "invoice_audit", "connector-sync",
                "--config", connectorConfigURL.path,
                "--workspace", connectorWorkspaceURL.path
            ])
            transcript += output
            try loadConnectorManifest(from: output)
            connectorStatus = "Source data pulled. Run audit when ready."
            status = "Connector data ready"
        } catch {
            connectorStatus = "Connector pull failed"
            transcript += "\nConnector pull failed: \(error.localizedDescription)"
        }
        isRunning = false
    }

    private func loadConnectorManifest(from text: String) throws {
        guard let data = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError("Connector sync did not return JSON")
        }
        if let scans = json["scans_dir"] as? String {
            invoiceFolderURL = URL(fileURLWithPath: scans)
        }
        if let pricebook = json["pricebook"] as? String {
            pricebookURL = URL(fileURLWithPath: pricebook)
        }
        if let floor = json["floor"] as? String, !floor.isEmpty {
            rulesURL = URL(fileURLWithPath: floor)
        }
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
            if let marketURL {
                args.append(contentsOf: ["--market", marketURL.path])
            }
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

    func generateEmailDraft() async {
        guard hasBusinessDatabase else {
            shareStatus = "Run an audit first."
            return
        }
        shareIsRunning = true
        shareStatus = "Preparing email draft..."
        await generateReport()
        do {
            let output = try await runPython([
                "-m", "invoice_audit", "email-draft",
                "--db", dbURL.path,
                "--out", emailDraftURL.path,
                "--attach-report", reportURL.path
            ])
            transcript += output
            shareStatus = "Email draft ready"
            NSWorkspace.shared.open(emailDraftURL)
        } catch {
            shareStatus = "Email draft failed"
            transcript += "\nEmail draft failed: \(error.localizedDescription)"
        }
        shareIsRunning = false
    }

    func exportIntegrationPayload() async {
        guard hasBusinessDatabase else {
            shareStatus = "Run an audit first."
            return
        }
        shareIsRunning = true
        shareStatus = "Preparing API payload..."
        do {
            let output = try await runPython([
                "-m", "invoice_audit", "integration-payload",
                "--db", dbURL.path,
                "--out", integrationPayloadURL.path
            ])
            transcript += output
            shareStatus = "API payload ready"
            NSWorkspace.shared.activateFileViewerSelecting([integrationPayloadURL])
        } catch {
            shareStatus = "API payload failed"
            transcript += "\nAPI payload failed: \(error.localizedDescription)"
        }
        shareIsRunning = false
    }

    func sendWebhook() async {
        guard hasBusinessDatabase else {
            shareStatus = "Run an audit first."
            return
        }
        let url = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            shareStatus = "Paste a webhook URL first."
            return
        }
        shareIsRunning = true
        shareStatus = "Sending to webhook..."
        do {
            let output = try await runPython([
                "-m", "invoice_audit", "send-webhook",
                "--db", dbURL.path,
                "--url", url
            ])
            transcript += output
            shareStatus = output.localizedCaseInsensitiveContains("\"ok\": true")
                ? "Webhook sent"
                : "Webhook returned a non-success response"
        } catch {
            shareStatus = "Webhook send failed"
            transcript += "\nWebhook send failed: \(error.localizedDescription)"
        }
        shareIsRunning = false
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
                marketURL = receipt.marketURL
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
    let marketURL: URL?
    let rulesURL: URL?
    let pricebookRows: Int
    let marketRows: Int?
    let ruleCount: Int?
    let totals: Totals
    let invoices: [InvoiceView]
    let findings: [FindingView]

    init(json: [String: Any], repoRoot: URL) {
        let engine = json["engine"] as? [String: Any] ?? [:]
        let pricebook = json["pricebook"] as? [String: Any] ?? [:]
        let market = json["marketPricebook"] as? [String: Any]
        let floorRules = json["floorRules"] as? [String: Any]
        let scans = json["scans"] as? [[String: Any]] ?? []
        generatedAt = json["generatedAt"] as? String ?? "Unknown"
        ocrEngine = engine["ocr"] as? String ?? "Unknown"
        extractionEngine = engine["extraction"] as? String ?? "Unknown"
        signature = String((json["signature"] as? String ?? "").prefix(16))
        pricebookURL = Self.url(from: pricebook["path"] as? String, repoRoot: repoRoot)
        pricebookRows = pricebook["rows"] as? Int ?? 0
        marketURL = Self.url(from: market?["path"] as? String, repoRoot: repoRoot)
        marketRows = market?["rows"] as? Int
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

enum WorkflowStep: String, CaseIterable, Identifiable {
    case sources = "Sources"
    case audit = "Audit"
    case review = "Review"
    case query = "Query"

    var id: String { rawValue }

    var index: Int {
        switch self {
        case .sources: 1
        case .audit: 2
        case .review: 3
        case .query: 4
        }
    }

    var subtitle: String {
        switch self {
        case .sources: "point to data"
        case .audit: "run checks"
        case .review: "inspect risk"
        case .query: "ask analyst"
        }
    }

    var systemImage: String {
        switch self {
        case .sources: "folder.badge.gearshape"
        case .audit: "play.circle.fill"
        case .review: "checklist.checked"
        case .query: "bubble.left.and.text.bubble.right"
        }
    }
}

enum AppTheme {
    static let bg = Color(red: 0.012, green: 0.024, blue: 0.040)
    static let panel = Color(red: 0.030, green: 0.054, blue: 0.078)
    static let panel2 = Color(red: 0.050, green: 0.078, blue: 0.110)
    static let stroke = Color(red: 0.105, green: 0.180, blue: 0.250)
    static let blue = Color(red: 0.075, green: 0.480, blue: 0.980)
    static let green = Color(red: 0.100, green: 0.820, blue: 0.430)
    static let orange = Color(red: 1.000, green: 0.620, blue: 0.080)
    static let red = Color(red: 1.000, green: 0.280, blue: 0.320)
    static let muted = Color(red: 0.560, green: 0.620, blue: 0.700)
}

struct DashboardView: View {
    @EnvironmentObject private var model: AuditModel
    @State private var step: WorkflowStep = .sources
    @State private var showingSettings = false

    var body: some View {
        HStack(spacing: 0) {
            WizardSidebar(selected: $step)
                .frame(width: 240)

            VStack(spacing: 0) {
                WizardTopBar(step: $step, showingSettings: $showingSettings)
                    .frame(height: 68)

                Divider()
                    .overlay(AppTheme.stroke)

                ZStack {
                    AppTheme.bg.ignoresSafeArea()
                    Group {
                        switch step {
                        case .sources:
                            SourcesStepView {
                                step = .audit
                            }
                        case .audit:
                            AuditStepView {
                                step = .review
                            }
                        case .review:
                            ReviewStepView()
                        case .query:
                            QueryStepView()
                        }
                    }
                    .padding(24)
                }
            }
        }
        .background(AppTheme.bg)
        .sheet(isPresented: $showingSettings) {
            SettingsSheet()
                .environmentObject(model)
                .frame(width: 720, height: 660)
        }
    }
}

struct WizardSidebar: View {
    @EnvironmentObject private var model: AuditModel
    @Binding var selected: WorkflowStep

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(AppTheme.blue, lineWidth: 2)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle()
                            .fill(AppTheme.blue)
                            .frame(width: 6, height: 6)
                    )
                Text("INVOICE")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("AUDIT")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.blue)
            }
            .padding(.top, 24)

            VStack(alignment: .leading, spacing: 8) {
                SidebarStatusDot(color: model.invoiceFolderURL == nil ? AppTheme.orange : AppTheme.green, text: "Invoices")
                SidebarStatusDot(color: model.pricebookURL == nil ? AppTheme.orange : AppTheme.green, text: "Price history")
                SidebarStatusDot(color: model.receipt == nil ? AppTheme.orange : AppTheme.green, text: "Audit receipt")
                SidebarStatusDot(color: model.hasBusinessDatabase ? AppTheme.green : AppTheme.orange, text: "SQL evidence")
            }
            .padding(12)
            .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 8) {
                Text("WORKFLOW")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.muted)
                ForEach(WorkflowStep.allCases) { item in
                    Button {
                        selected = item
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(item.index)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .frame(width: 22, height: 22)
                                .background(selected == item ? AppTheme.blue : AppTheme.panel2, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.rawValue)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(item.subtitle)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(AppTheme.muted)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(selected == item ? AppTheme.blue.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Text("SYSTEM STATUS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.muted)
                Text(model.isRunning ? "Processing" : "Ready")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.isRunning ? AppTheme.orange : AppTheme.green)
                Text(model.status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .background(Color(red: 0.006, green: 0.030, blue: 0.045))
    }
}

struct SidebarStatusDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
    }
}

struct WizardTopBar: View {
    @Binding var step: WorkflowStep
    @Binding var showingSettings: Bool

    var body: some View {
        HStack(spacing: 16) {
            ForEach(WorkflowStep.allCases) { item in
                Button {
                    step = item
                } label: {
                    Label(item.rawValue, systemImage: item.systemImage)
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(step == item ? AppTheme.blue : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.muted)
                Text("Search invoices, vendors, findings, and memory...")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.muted)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(width: 430, height: 36)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.blue.opacity(0.65), lineWidth: 2))

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(AppTheme.panel, in: Circle())
                    .overlay(Circle().stroke(AppTheme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .background(Color(red: 0.014, green: 0.026, blue: 0.043))
    }
}

struct SourcesStepView: View {
    @EnvironmentObject private var model: AuditModel
    let continueAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            WizardTitle(
                eyebrow: "Step 1",
                title: "Point the system at the data",
                subtitle: "Keep this simple: invoices plus price history. Market benchmarks, rules, API connectors, and share tools live in Settings."
            )

            HStack(spacing: 14) {
                WizardSourceCard(
                    number: "1",
                    title: "Invoices / receipts",
                    detail: model.invoiceFolderURL?.path(percentEncoded: false) ?? "Choose a folder of PDFs, scans, or receipt images.",
                    systemImage: "folder",
                    isReady: model.invoiceFolderURL != nil,
                    actionTitle: "Choose Folder",
                    action: model.chooseInvoiceFolder
                )
                WizardSourceCard(
                    number: "2",
                    title: "Price history",
                    detail: model.pricebookURL?.lastPathComponent ?? "Choose CSV or SQLite customer history.",
                    systemImage: "tablecells",
                    isReady: model.pricebookURL != nil,
                    actionTitle: "Choose File",
                    action: model.choosePricebook
                )
                WizardSourceCard(
                    number: "3",
                    title: "Ready check",
                    detail: model.canRunAudit ? "Sources are ready. Continue to run the audit." : "Choose invoices and price history to continue.",
                    systemImage: "checkmark.seal",
                    isReady: model.canRunAudit,
                    actionTitle: "Use Sample",
                    action: model.useSampleData
                )
            }

            HStack {
                Text("Advanced source connectors, market benchmarks, rules, and share/export are under the gear.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.muted)
                Spacer()
                Button {
                    continueAction()
                } label: {
                    Label("Continue", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRunAudit)
            }
            Spacer()
        }
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
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .disabled(false)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(isReady ? AppTheme.green.opacity(0.45) : AppTheme.stroke, lineWidth: 1))
    }
}

struct AuditStepView: View {
    @EnvironmentObject private var model: AuditModel
    let reviewAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            WizardTitle(
                eyebrow: "Step 2",
                title: "Run the audit",
                subtitle: "OCR extracts line items, checks customer history and optional market/rule layers, then sends costly uncertainty to human review."
            )

            HStack(spacing: 16) {
                DarkMetricCard(title: "Invoices", value: model.receipt.map { "\($0.totals.invoices)" } ?? "—", color: AppTheme.blue)
                DarkMetricCard(title: "Findings", value: model.receipt.map { "\($0.totals.flagged)" } ?? "—", color: AppTheme.orange)
                DarkMetricCard(title: "Exposure", value: model.receipt.map { dollars($0.totals.potentialOvercharge) } ?? "—", color: AppTheme.red)
                DarkMetricCard(title: "Verified", value: model.verification, color: model.verification == "Verified" ? AppTheme.green : AppTheme.orange)
            }

            DarkPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.status)
                        .font(.system(size: 17, weight: .semibold))
                    Text("The app will create a signed receipt, SQLite evidence store, visual report, and review queue.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.muted)

                    HStack(spacing: 10) {
                        Button {
                            Task { await model.runAudit() }
                        } label: {
                            Label(model.isRunning ? "Auditing..." : "Run Audit", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRunAudit)

                        Button {
                            Task { await model.verifyReceipt() }
                        } label: {
                            Label("Verify", systemImage: "checkmark.shield")
                        }
                        .disabled(model.receipt == nil)

                        Button {
                            model.revealReport()
                        } label: {
                            Label("Open Report", systemImage: "chart.bar.xaxis")
                        }
                        .disabled(!model.hasReport)

                        Spacer()

                        Button {
                            reviewAction()
                        } label: {
                            Label("Review Findings", systemImage: "arrow.right")
                        }
                        .disabled(model.receipt == nil)
                    }
                }
            }

            if !model.transcript.isEmpty {
                ScrollView {
                    Text(model.transcript)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 14))
            }
            Spacer()
        }
    }
}

struct ReviewStepView: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WizardTitle(
                eyebrow: "Step 3",
                title: "Review what needs human judgment",
                subtitle: "High-cost uncertainty stays visible: invoice image, OCR read, digital line items, evidence, policy, and price findings."
            )
            if let receipt = model.receipt {
                ContentView(receipt: receipt)
            } else {
                EmptyDarkState(text: "No audit receipt yet. Run Step 2 first.")
            }
        }
    }
}

struct QueryStepView: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WizardTitle(
                eyebrow: "Query mode",
                title: "Ask the business analyst",
                subtitle: "Ask plain-English questions after the audit. Answers cite SQL evidence, categories, vendors, findings, and reports."
            )
            AnalystPanel()
                .frame(maxWidth: 820, minHeight: 360)
            Spacer()
        }
    }
}

struct SettingsSheet: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Advanced sources, rules, and share/connect live here.")
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(AppTheme.blue)
            }

            TabView {
                AdvancedSourcesSettings()
                    .tabItem { Label("Sources", systemImage: "folder.badge.gearshape") }
                SharePanel()
                    .tabItem { Label("Share", systemImage: "square.and.arrow.up") }
                ArtifactSettings()
                    .tabItem { Label("Artifacts", systemImage: "doc.text.magnifyingglass") }
            }
        }
        .padding(22)
        .background(AppTheme.bg)
    }
}

struct AdvancedSourcesSettings: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Advanced source setup")
                .font(.system(size: 17, weight: .bold))

            HStack(spacing: 12) {
                SourceCard(
                    title: "Market",
                    detail: model.marketURL?.lastPathComponent ?? "Optional benchmark CSV/SQLite",
                    systemImage: "chart.line.uptrend.xyaxis",
                    isReady: model.marketURL != nil,
                    actionTitle: model.marketURL == nil ? "Choose File" : "Change",
                    action: model.chooseMarket,
                    secondaryTitle: model.marketURL == nil ? nil : "Clear",
                    secondaryAction: model.clearMarket
                )
                SourceCard(
                    title: "Rules",
                    detail: model.rulesURL?.lastPathComponent ?? "Optional policy/rule file",
                    systemImage: "slider.horizontal.3",
                    isReady: model.rulesURL != nil,
                    actionTitle: model.rulesURL == nil ? "Choose File" : "Change",
                    action: model.chooseRules,
                    secondaryTitle: model.rulesURL == nil ? nil : "Clear",
                    secondaryAction: model.clearRules
                )
            }

            DarkPanel {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Source Connectors", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 15, weight: .bold))
                    Text("Use this for network folders, API/Zapier pull sources, and future QuickBooks/NetSuite presets.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.muted)
                    HStack {
                        Button {
                            model.chooseNetworkFolder()
                        } label: {
                            Label("Network Folder", systemImage: "externaldrive.connected.to.line.below")
                        }
                        TextField("Paste API/Zapier source URL", text: $model.sourceAPIURL)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            Task { await model.pullAPIConnector() }
                        } label: {
                            Label("Pull Data", systemImage: "arrow.down.doc")
                        }
                        .disabled(model.sourceAPIURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRunning)
                    }
                    Text(model.connectorStatus)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.muted)
                }
            }
            Spacer()
        }
        .padding(.top, 12)
    }
}

struct ArtifactSettings: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audit artifacts")
                .font(.system(size: 17, weight: .bold))
            Button("Reveal Receipt") { model.revealReceipt() }
                .disabled(model.receipt == nil)
            Button("Reveal Database") { model.revealDatabase() }
                .disabled(model.receipt == nil)
            Button("Open Report") { model.revealReport() }
                .disabled(!model.hasReport)
            Button("Verify Receipt") {
                Task { await model.verifyReceipt() }
            }
            .disabled(model.receipt == nil)
            Spacer()
        }
        .padding(.top, 12)
    }
}

struct WizardTitle: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("✦ \(eyebrow.uppercased())")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AppTheme.blue)
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.muted)
                .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

struct DarkMetricCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AppTheme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.stroke, lineWidth: 1))
    }
}

struct DarkPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.stroke, lineWidth: 1))
    }
}

struct EmptyDarkState: View {
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 42))
                .foregroundStyle(AppTheme.blue)
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 18))
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
