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
    @Published var status = "Choose invoice sources and Excel price sheets"
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
    @Published var journal = BusinessJournal.empty
    @Published var activityJournal: [ActivityEvent] = []
    @Published var queryHistory: [QueryHistoryItem] = []
    @Published var legacyBridgeStatus = "Legacy VM/RM bridge not checked."

    private let repoRoot: URL
    private let receiptURL: URL
    private let dbURL: URL
    private let reportURL: URL
    private let exportsURL: URL
    private let emailDraftURL: URL
    private let integrationPayloadURL: URL
    private let connectorConfigURL: URL
    private let connectorWorkspaceURL: URL
    private let activityJournalURL: URL
    private let queryHistoryURL: URL

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
        exportsURL = repoRoot
            .appendingPathComponent(".invoice-audit-app", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
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
        activityJournalURL = repoRoot
            .appendingPathComponent(".invoice-audit-app", isDirectory: true)
            .appendingPathComponent("activity-journal.jsonl")
        queryHistoryURL = repoRoot
            .appendingPathComponent(".invoice-audit-app", isDirectory: true)
            .appendingPathComponent("query-history.jsonl")
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
        loadAppJournal()
        logActivity(
            kind: "app-open",
            title: "Opened Invoice Audit",
            detail: "Loaded the native workspace and checked for prior evidence.",
            outcome: "started"
        )
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            await loadReceipt(from: receiptURL)
            if hasBusinessDatabase {
                await loadBusinessJournal()
                await generateReport()
                await askAnalyst()
            }
        } else if hasBusinessDatabase {
            await loadBusinessJournal()
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
        if panel.runModal() == .OK, let url = panel.url {
            invoiceFolderURL = url
            status = "Invoice folder selected"
            logActivity(
                kind: "source",
                title: "Selected invoice source",
                detail: url.path,
                outcome: "learned source location"
            )
        }
    }

    func chooseNetworkFolder() {
        chooseInvoiceFolder()
        connectorStatus = "Network/mounted folder selected. Choose Excel/CSV price sheets, then run audit."
    }

    func choosePricebook() {
        let panel = NSOpenPanel()
        panel.title = "Choose Excel/CSV Price Sheet"
        panel.allowedContentTypes = [
            UTType.commaSeparatedText,
            UTType(filenameExtension: "xlsx"),
            UTType(filenameExtension: "xlsm"),
            UTType(filenameExtension: "sqlite"),
            UTType(filenameExtension: "sqlite3"),
            UTType(filenameExtension: "db")
        ].compactMap { $0 }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            pricebookURL = url
            status = "Excel/CSV price sheet selected"
            logActivity(
                kind: "source",
                title: "Selected Excel/price data",
                detail: url.path,
                outcome: "learned pricing source"
            )
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
        if panel.runModal() == .OK, let url = panel.url {
            marketURL = url
            status = "Market benchmark selected"
            logActivity(
                kind: "source",
                title: "Selected market benchmark",
                detail: url.path,
                outcome: "optional benchmark connected"
            )
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
        if panel.runModal() == .OK, let url = panel.url {
            rulesURL = url
            status = "Rules file selected"
            logActivity(
                kind: "source",
                title: "Selected policy/rules file",
                detail: url.path,
                outcome: "learned rule source"
            )
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
        logActivity(
            kind: "source",
            title: "Loaded sample data",
            detail: "Demo scans, pricebook.csv, and floor-rules.json selected.",
            outcome: "demo source ready"
        )
    }

    func pullAPIConnector() async {
        let url = sourceAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            connectorStatus = "Paste an API/Zapier URL first."
            logActivity(
                kind: "source",
                title: "API connector blocked",
                detail: "No API/Zapier URL was provided.",
                outcome: "failed"
            )
            return
        }
        isRunning = true
        connectorStatus = "Pulling source data..."
        logActivity(
            kind: "source",
            title: "Started API source pull",
            detail: url,
            outcome: "started"
        )
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
            logActivity(
                kind: "source",
                title: "Pulled API source data",
                detail: output.trimmingCharacters(in: .whitespacesAndNewlines),
                outcome: "learned source payload"
            )
        } catch {
            connectorStatus = "Connector pull failed"
            transcript += "\nConnector pull failed: \(error.localizedDescription)"
            logActivity(
                kind: "source",
                title: "API connector failed",
                detail: error.localizedDescription,
                outcome: "failed"
            )
        }
        isRunning = false
    }

    func openLegacyBridge() {
        guard let url = URL(string: "http://127.0.0.1:8765") else { return }
        NSWorkspace.shared.open(url)
        legacyBridgeStatus = "Opened Kist Work Agent bridge in the browser."
        logActivity(
            kind: "legacy-bridge",
            title: "Opened Legacy VM/RM bridge",
            detail: "Opened http://127.0.0.1:8765 for VM/RM screen/database extraction.",
            outcome: "handoff opened"
        )
    }

    func checkLegacyBridge() async {
        guard let url = URL(string: "http://127.0.0.1:8765") else { return }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<500).contains(code) {
                legacyBridgeStatus = "Kist Work Agent bridge is reachable on 127.0.0.1:8765."
                logActivity(
                    kind: "legacy-bridge",
                    title: "Checked Legacy VM/RM bridge",
                    detail: "Local bridge responded with HTTP \(code).",
                    outcome: "reachable"
                )
            } else {
                legacyBridgeStatus = "Bridge responded unexpectedly: HTTP \(code)."
                logActivity(
                    kind: "legacy-bridge",
                    title: "Legacy bridge check returned unexpected status",
                    detail: "HTTP \(code)",
                    outcome: "needs review"
                )
            }
        } catch {
            legacyBridgeStatus = "Bridge not reachable. Start Kist Work Agent / desktop-vision-console first."
            logActivity(
                kind: "legacy-bridge",
                title: "Legacy VM/RM bridge not reachable",
                detail: error.localizedDescription,
                outcome: "failed"
            )
        }
    }

    func copyLegacyBridgeInstructions() {
        let text = """
        Legacy VM/RM extraction handoff:
        1. Open Kist Work Agent at http://127.0.0.1:8765.
        2. Log into the legacy VM/RM system and extract invoices, payroll, or database exports.
        3. Save extracted PDFs/images/CSV/Excel/API JSON into a source folder.
        4. Return to Invoice Audit > Sources and choose the extracted folder + Excel price data.
        5. Run Audit to create signed receipts, SQL evidence, and exportable reports.
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        legacyBridgeStatus = "Legacy bridge instructions copied."
        logActivity(
            kind: "legacy-bridge",
            title: "Copied legacy bridge instructions",
            detail: "Copied VM/RM extraction handoff steps to the clipboard.",
            outcome: "saved instructions"
        )
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
            status = "Choose invoices and Excel sheets first"
            return
        }
        isRunning = true
        status = "Auditing selected invoices"
        verification = "Pending"
        transcript = ""
        logActivity(
            kind: "audit",
            title: "Started audit",
            detail: "Invoices: \(invoiceFolderURL.path); price data: \(pricebookURL.path)",
            outcome: "started"
        )

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
            await loadBusinessJournal()
            await askAnalyst()
            status = "Audit complete"
            if let receipt {
                logActivity(
                    kind: "audit",
                    title: "Completed audit",
                    detail: "\(receipt.totals.invoices) invoices, \(receipt.totals.lines) lines, \(receipt.totals.flagged) findings, \(dollars(receipt.totals.potentialOvercharge + receipt.totals.policyOverage)) potential exposure.",
                    outcome: "achieved"
                )
            }
        } catch {
            status = "Audit failed"
            verification = "Failed"
            transcript += "\n\(error.localizedDescription)"
            logActivity(
                kind: "audit",
                title: "Audit failed",
                detail: error.localizedDescription,
                outcome: "failed"
            )
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
            logActivity(
                kind: "verification",
                title: "Verified receipt",
                detail: output.trimmingCharacters(in: .whitespacesAndNewlines),
                outcome: verification
            )
        } catch {
            verification = "Failed"
            transcript += "\n\(error.localizedDescription)"
            logActivity(
                kind: "verification",
                title: "Receipt verification failed",
                detail: error.localizedDescription,
                outcome: "failed"
            )
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
            logActivity(
                kind: "report",
                title: "Generated visual report",
                detail: reportURL.path,
                outcome: "saved report"
            )
        } catch {
            transcript += "\nReport generation failed: \(error.localizedDescription)"
            logActivity(
                kind: "report",
                title: "Report generation failed",
                detail: error.localizedDescription,
                outcome: "failed"
            )
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
            logActivity(
                kind: "export",
                title: "Generated boss email draft",
                detail: emailDraftURL.path,
                outcome: "saved export"
            )
        } catch {
            shareStatus = "Email draft failed"
            transcript += "\nEmail draft failed: \(error.localizedDescription)"
            logActivity(
                kind: "export",
                title: "Email draft failed",
                detail: error.localizedDescription,
                outcome: "failed"
            )
        }
        shareIsRunning = false
    }

    func exportCSVs() async {
        guard hasBusinessDatabase else {
            shareStatus = "Run an audit first."
            logActivity(
                kind: "export",
                title: "CSV export blocked",
                detail: "No connected database exists yet.",
                outcome: "failed"
            )
            return
        }
        shareIsRunning = true
        shareStatus = "Preparing CSV exports..."
        do {
            let output = try await runPython([
                "-m", "invoice_audit", "export",
                "--db", dbURL.path,
                "--out", exportsURL.path
            ])
            transcript += output
            shareStatus = "CSV exports ready"
            NSWorkspace.shared.activateFileViewerSelecting([exportsURL])
            logActivity(
                kind: "export",
                title: "Exported CSV data",
                detail: output.trimmingCharacters(in: .whitespacesAndNewlines),
                outcome: "saved export"
            )
        } catch {
            shareStatus = "CSV export failed"
            transcript += "\nCSV export failed: \(error.localizedDescription)"
            logActivity(
                kind: "export",
                title: "CSV export failed",
                detail: error.localizedDescription,
                outcome: "failed"
            )
        }
        shareIsRunning = false
    }

    func exportIntegrationPayload() async {
        guard hasBusinessDatabase else {
            shareStatus = "Run an audit first."
            logActivity(
                kind: "export",
                title: "API payload blocked",
                detail: "No connected database exists yet.",
                outcome: "failed"
            )
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
            logActivity(
                kind: "export",
                title: "Generated API/Zapier payload",
                detail: integrationPayloadURL.path,
                outcome: "saved export"
            )
        } catch {
            shareStatus = "API payload failed"
            transcript += "\nAPI payload failed: \(error.localizedDescription)"
            logActivity(
                kind: "export",
                title: "API payload failed",
                detail: error.localizedDescription,
                outcome: "failed"
            )
        }
        shareIsRunning = false
    }

    func sendWebhook() async {
        guard hasBusinessDatabase else {
            shareStatus = "Run an audit first."
            logActivity(
                kind: "webhook",
                title: "Webhook blocked",
                detail: "No connected database exists yet.",
                outcome: "failed"
            )
            return
        }
        let url = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            shareStatus = "Paste a webhook URL first."
            logActivity(
                kind: "webhook",
                title: "Webhook blocked",
                detail: "No webhook URL was supplied.",
                outcome: "failed"
            )
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
            logActivity(
                kind: "webhook",
                title: shareStatus,
                detail: output.trimmingCharacters(in: .whitespacesAndNewlines),
                outcome: output.localizedCaseInsensitiveContains("\"ok\": true") ? "sent" : "needs review"
            )
        } catch {
            shareStatus = "Webhook send failed"
            transcript += "\nWebhook send failed: \(error.localizedDescription)"
            logActivity(
                kind: "webhook",
                title: "Webhook send failed",
                detail: error.localizedDescription,
                outcome: "failed"
            )
        }
        shareIsRunning = false
    }

    func loadBusinessJournal() async {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            journal = .empty
            return
        }
        do {
            let output = try await runPython([
                "-m", "invoice_audit", "history",
                "--db", dbURL.path,
                "--json"
            ])
            guard let data = output.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AppError("History command did not return JSON")
            }
            journal = BusinessJournal(json: json)
        } catch {
            journal = BusinessJournal.error(error.localizedDescription)
            transcript += "\nHistory load failed: \(error.localizedDescription)"
        }
    }

    func askAnalyst() async {
        let question = analystQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            analystAnswer = "No business database yet. Choose sources and run an audit first."
            logActivity(
                kind: "query",
                title: "Query blocked",
                detail: question,
                outcome: "no connected database"
            )
            return
        }
        analystIsRunning = true
        analystAnswer = "Thinking from the SQL evidence store..."
        logActivity(
            kind: "query",
            title: "Asked business analyst",
            detail: question,
            outcome: "started"
        )
        do {
            let output = try await runPython([
                "-m", "invoice_audit", "ask",
                "--db", dbURL.path,
                question
            ])
            analystAnswer = output.trimmingCharacters(in: .whitespacesAndNewlines)
            logQuery(question: question, answer: analystAnswer, outcome: "answered")
            logActivity(
                kind: "query",
                title: "Answered business query",
                detail: question,
                outcome: "learned from SQL evidence"
            )
        } catch {
            analystAnswer = error.localizedDescription
            logQuery(question: question, answer: analystAnswer, outcome: "failed")
            logActivity(
                kind: "query",
                title: "Business query failed",
                detail: "\(question) — \(error.localizedDescription)",
                outcome: "failed"
            )
        }
        analystIsRunning = false
    }

    func revealActivityJournal() {
        NSWorkspace.shared.activateFileViewerSelecting([activityJournalURL])
    }

    func revealQueryHistory() {
        NSWorkspace.shared.activateFileViewerSelecting([queryHistoryURL])
    }

    private func loadAppJournal() {
        activityJournal = loadJSONLines(ActivityEvent.self, from: activityJournalURL, limit: 300)
        queryHistory = loadJSONLines(QueryHistoryItem.self, from: queryHistoryURL, limit: 120)
    }

    private func logActivity(kind: String, title: String, detail: String, outcome: String) {
        let event = ActivityEvent(
            timestamp: appTimestamp(),
            kind: kind,
            title: title,
            detail: detail,
            outcome: outcome
        )
        activityJournal.insert(event, at: 0)
        if activityJournal.count > 300 {
            activityJournal.removeLast(activityJournal.count - 300)
        }
        appendJSONLine(event, to: activityJournalURL)
    }

    private func logQuery(question: String, answer: String, outcome: String) {
        let item = QueryHistoryItem(
            timestamp: appTimestamp(),
            question: question,
            answer: answer,
            outcome: outcome
        )
        queryHistory.insert(item, at: 0)
        if queryHistory.count > 120 {
            queryHistory.removeLast(queryHistory.count - 120)
        }
        appendJSONLine(item, to: queryHistoryURL)
    }

    private func loadJSONLines<T: Decodable>(_ type: T.Type, from url: URL, limit: Int) -> [T] {
        guard FileManager.default.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        let decoded = text
            .split(separator: "\n")
            .suffix(limit)
            .compactMap { line -> T? in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? decoder.decode(T.self, from: data)
            }
        return Array(decoded.reversed())
    }

    private func appendJSONLine<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(value)
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            transcript += "\nJournal write failed: \(error.localizedDescription)"
        }
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

struct BusinessJournal {
    let generatedAt: String
    let status: String
    let overview: JournalOverview
    let attention: [AttentionItem]
    let nextActions: [String]
    let recentRuns: [RecentRun]
    let topCategories: [ExposureRow]
    let topVendors: [ExposureRow]
    let dataQualityIssues: Int?

    static let empty = BusinessJournal(
        generatedAt: "",
        status: "Setup needed",
        overview: .empty,
        attention: [
            AttentionItem(
                priority: "high",
                title: "No audit data connected",
                detail: "Choose invoice/receipt sources and Excel price sheets, then run the first audit.",
                action: "Connect sources"
            )
        ],
        nextActions: [
            "Choose invoice/PDF/receipt sources.",
            "Choose Excel/CSV price sheets.",
            "Run the audit to create the connected database."
        ],
        recentRuns: [],
        topCategories: [],
        topVendors: [],
        dataQualityIssues: nil
    )

    static func error(_ message: String) -> BusinessJournal {
        BusinessJournal(
            generatedAt: "",
            status: "Journal unavailable",
            overview: .empty,
            attention: [
                AttentionItem(
                    priority: "high",
                    title: "Could not load attention journal",
                    detail: message,
                    action: "Check the database artifact"
                )
            ],
            nextActions: ["Open Settings > Artifacts and verify the database exists."],
            recentRuns: [],
            topCategories: [],
            topVendors: [],
            dataQualityIssues: nil
        )
    }

    init(
        generatedAt: String,
        status: String,
        overview: JournalOverview,
        attention: [AttentionItem],
        nextActions: [String],
        recentRuns: [RecentRun],
        topCategories: [ExposureRow],
        topVendors: [ExposureRow],
        dataQualityIssues: Int?
    ) {
        self.generatedAt = generatedAt
        self.status = status
        self.overview = overview
        self.attention = attention
        self.nextActions = nextActions
        self.recentRuns = recentRuns
        self.topCategories = topCategories
        self.topVendors = topVendors
        self.dataQualityIssues = dataQualityIssues
    }

    init(json: [String: Any]) {
        generatedAt = json["generated_at"] as? String ?? ""
        status = json["status"] as? String ?? "Unknown"
        overview = JournalOverview(json: json["overview"] as? [String: Any] ?? [:])
        attention = (json["attention"] as? [[String: Any]] ?? []).map(AttentionItem.init)
        nextActions = json["next_actions"] as? [String] ?? []
        recentRuns = (json["recent_runs"] as? [[String: Any]] ?? []).map(RecentRun.init)
        topCategories = (json["top_categories"] as? [[String: Any]] ?? []).map {
            ExposureRow(json: $0, nameKey: "category")
        }
        topVendors = (json["top_vendors"] as? [[String: Any]] ?? []).map {
            ExposureRow(json: $0, nameKey: "vendor")
        }
        let dq = json["data_quality"] as? [String: Any] ?? [:]
        dataQualityIssues = jsonInt(dq, "issue_count")
    }
}

struct JournalOverview {
    let invoices: Int
    let lines: Int
    let spend: Double
    let priceExposure: Double
    let policyExposure: Double
    let totalExposure: Double
    let findings: Int

    static let empty = JournalOverview(
        invoices: 0,
        lines: 0,
        spend: 0,
        priceExposure: 0,
        policyExposure: 0,
        totalExposure: 0,
        findings: 0
    )

    init(json: [String: Any]) {
        invoices = jsonInt(json, "invoices") ?? 0
        lines = jsonInt(json, "lines") ?? 0
        spend = jsonDouble(json, "spend")
        priceExposure = jsonDouble(json, "price_exposure")
        policyExposure = jsonDouble(json, "policy_exposure")
        totalExposure = jsonDouble(json, "total_exposure")
        findings = jsonInt(json, "findings") ?? 0
    }

    init(
        invoices: Int,
        lines: Int,
        spend: Double,
        priceExposure: Double,
        policyExposure: Double,
        totalExposure: Double,
        findings: Int
    ) {
        self.invoices = invoices
        self.lines = lines
        self.spend = spend
        self.priceExposure = priceExposure
        self.policyExposure = policyExposure
        self.totalExposure = totalExposure
        self.findings = findings
    }
}

struct AttentionItem: Identifiable {
    let id: String
    let priority: String
    let title: String
    let detail: String
    let action: String

    init(priority: String, title: String, detail: String, action: String) {
        self.priority = priority
        self.title = title
        self.detail = detail
        self.action = action
        id = "\(priority)-\(title)-\(detail)"
    }

    init(json: [String: Any]) {
        priority = json["priority"] as? String ?? "normal"
        title = json["title"] as? String ?? "Needs attention"
        detail = json["detail"] as? String ?? ""
        action = json["action"] as? String ?? "Review"
        id = "\(priority)-\(title)-\(detail)"
    }
}

struct RecentRun: Identifiable {
    let id: Int
    let generatedAt: String
    let invoices: Int
    let findings: Int
    let exposure: Double

    init(json: [String: Any]) {
        id = jsonInt(json, "receipt_id") ?? 0
        generatedAt = json["generated_at"] as? String ?? "Unknown"
        invoices = jsonInt(json, "invoices") ?? 0
        findings = jsonInt(json, "findings") ?? 0
        exposure = jsonDouble(json, "total_exposure")
    }
}

struct ExposureRow: Identifiable {
    let id: String
    let name: String
    let spend: Double
    let exposure: Double
    let findings: Int

    init(json: [String: Any], nameKey: String) {
        name = json[nameKey] as? String ?? "Unknown"
        spend = jsonDouble(json, "spend")
        exposure = jsonDouble(json, "total_exposure")
        findings = jsonInt(json, "findings") ?? 0
        id = name
    }
}

struct ActivityEvent: Identifiable, Codable {
    let id: String
    let timestamp: String
    let kind: String
    let title: String
    let detail: String
    let outcome: String

    init(
        id: String = UUID().uuidString,
        timestamp: String,
        kind: String,
        title: String,
        detail: String,
        outcome: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.detail = detail
        self.outcome = outcome
    }
}

struct QueryHistoryItem: Identifiable, Codable {
    let id: String
    let timestamp: String
    let question: String
    let answer: String
    let outcome: String

    init(
        id: String = UUID().uuidString,
        timestamp: String,
        question: String,
        answer: String,
        outcome: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.question = question
        self.answer = answer
        self.outcome = outcome
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
    case pulse = "Pulse"
    case sources = "Sources"
    case audit = "Audit"
    case review = "Review"
    case saveExport = "Save / Export"
    case query = "Query"

    var id: String { rawValue }

    var index: Int {
        switch self {
        case .pulse: 0
        case .sources: 1
        case .audit: 2
        case .review: 3
        case .saveExport: 4
        case .query: 5
        }
    }

    var subtitle: String {
        switch self {
        case .pulse: "SOS attention"
        case .sources: "connect data"
        case .audit: "run checks"
        case .review: "inspect risk"
        case .saveExport: "save data"
        case .query: "ask analyst"
        }
    }

    var systemImage: String {
        switch self {
        case .pulse: "dot.radiowaves.left.and.right"
        case .sources: "folder.badge.gearshape"
        case .audit: "play.circle.fill"
        case .review: "checklist.checked"
        case .saveExport: "square.and.arrow.up"
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
    @State private var step: WorkflowStep = .pulse
    @State private var showingSettings = false
    @State private var showingAdvisor = false

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                WizardSidebar(selected: $step)
                    .frame(width: 240)

                VStack(spacing: 0) {
                    WizardTopBar(
                        step: $step,
                        showingSettings: $showingSettings,
                        showingAdvisor: $showingAdvisor
                    )
                    .frame(height: 68)

                    Divider()
                        .overlay(AppTheme.stroke)

                    ZStack {
                        AppTheme.bg.ignoresSafeArea()
                        Group {
                            switch step {
                            case .pulse:
                                PulseStepView(
                                    sourceAction: { step = .sources },
                                    auditAction: { step = .audit },
                                    reviewAction: { step = .review },
                                    advisorAction: { showingAdvisor = true }
                                )
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
                            case .saveExport:
                                SaveExportStepView()
                            case .query:
                                QueryStepView()
                            }
                        }
                        .padding(24)
                    }
                }
            }

            if showingAdvisor {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .onTapGesture {
                        showingAdvisor = false
                    }

                AdvisorDrawer(isOpen: $showingAdvisor)
                    .frame(width: 440)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(AppTheme.bg)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showingAdvisor)
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
                SidebarStatusDot(color: model.pricebookURL == nil ? AppTheme.orange : AppTheme.green, text: "Excel sheets")
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
                            Text(item == .pulse ? "SOS" : "\(item.index)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .frame(width: item == .pulse ? 34 : 22, height: 22)
                                .background(selected == item ? AppTheme.blue : AppTheme.panel2, in: Capsule())
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
    @Binding var showingAdvisor: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WorkflowStep.allCases) { item in
                Button {
                    step = item
                } label: {
                    Label(item.rawValue, systemImage: item.systemImage)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(step == item ? AppTheme.blue : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .fixedSize(horizontal: true, vertical: false)
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
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(width: 290, height: 36)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.blue.opacity(0.65), lineWidth: 2))

            Button {
                showingAdvisor = true
            } label: {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(AppTheme.panel, in: Circle())
                    .overlay(Circle().stroke(AppTheme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)

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

struct PulseStepView: View {
    @EnvironmentObject private var model: AuditModel
    let sourceAction: () -> Void
    let auditAction: () -> Void
    let reviewAction: () -> Void
    let advisorAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    WizardTitle(
                        eyebrow: "SOS attention",
                        title: "What needs your pulse right now",
                        subtitle: "This is the first screen: current money risk, data rot, review priorities, recent audit history, and the next concrete action."
                    )
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(model.journal.status)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(statusColor)
                        Text(model.journal.generatedAt.isEmpty ? "No journal yet" : model.journal.generatedAt)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(AppTheme.muted)
                    }
                }

                HStack(spacing: 14) {
                    DarkMetricCard(title: "Money at risk", value: dollars(model.journal.overview.totalExposure), color: model.journal.overview.totalExposure > 0 ? AppTheme.red : AppTheme.green)
                    DarkMetricCard(title: "Scanned spend", value: dollars(model.journal.overview.spend), color: AppTheme.blue)
                    DarkMetricCard(title: "Open findings", value: "\(model.journal.overview.findings)", color: model.journal.overview.findings > 0 ? AppTheme.orange : AppTheme.green)
                    DarkMetricCard(title: "Data rot", value: dataRotText, color: (model.journal.dataQualityIssues ?? 0) > 0 ? AppTheme.red : AppTheme.green)
                }

                HStack(alignment: .top, spacing: 16) {
                    DarkPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Needs attention now", systemImage: "exclamationmark.triangle.fill")
                            ForEach(model.journal.attention) { item in
                                AttentionRow(item: item)
                                    .onTapGesture {
                                        if model.receipt != nil {
                                            reviewAction()
                                        }
                                    }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    VStack(spacing: 16) {
                        DarkPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader(title: "Do next", systemImage: "checklist")
                                ForEach(Array(model.journal.nextActions.enumerated()), id: \.offset) { index, action in
                                    HStack(alignment: .top, spacing: 9) {
                                        Text("\(index + 1)")
                                            .font(.system(size: 11, weight: .bold, design: .rounded))
                                            .frame(width: 21, height: 21)
                                            .background(AppTheme.blue.opacity(0.9), in: Circle())
                                        Text(action)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.88))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }

                                HStack {
                                    Button {
                                        sourceAction()
                                    } label: {
                                        Label("Connect Data", systemImage: "folder.badge.gearshape")
                                    }
                                    Button {
                                        auditAction()
                                    } label: {
                                        Label("Run Audit", systemImage: "play.fill")
                                    }
                                    .disabled(!model.canRunAudit)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }

                        DarkPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader(title: "Advisor", systemImage: "bubble.left.and.text.bubble.right.fill")
                                Text("Open the side advisor while you set up sources, review evidence, or prepare the boss report.")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AppTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button {
                                    advisorAction()
                                } label: {
                                    Label("Ask Business Advisor", systemImage: "sparkles")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .frame(width: 360)
                }

                HStack(alignment: .top, spacing: 16) {
                    DarkPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Recent audit history", systemImage: "clock.arrow.circlepath")
                            if model.journal.recentRuns.isEmpty {
                                Text("No completed audit runs yet.")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppTheme.muted)
                            } else {
                                ForEach(model.journal.recentRuns.prefix(5)) { run in
                                    RecentRunRow(run: run)
                                }
                            }
                        }
                    }

                    DarkPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Where exposure is coming from", systemImage: "chart.bar.xaxis")
                            if model.journal.topCategories.isEmpty {
                                EmptyDarkText("Run an audit to build category exposure.")
                            } else {
                                ForEach(model.journal.topCategories.prefix(5)) { row in
                                    ExposureRowView(row: row)
                                }
                            }
                        }
                    }

                    DarkPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Vendor focus", systemImage: "building.2")
                            if model.journal.topVendors.isEmpty {
                                EmptyDarkText("Vendor exposure appears after the first audit.")
                            } else {
                                ForEach(model.journal.topVendors.prefix(5)) { row in
                                    ExposureRowView(row: row)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    private var statusColor: Color {
        model.journal.status.localizedCaseInsensitiveContains("SOS") ? AppTheme.red :
            (model.journal.status.localizedCaseInsensitiveContains("clear") ? AppTheme.green : AppTheme.orange)
    }

    private var dataRotText: String {
        guard let count = model.journal.dataQualityIssues else { return "—" }
        return "\(count)"
    }
}

struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.blue)
            Text(title)
                .font(.system(size: 14, weight: .bold))
            Spacer()
        }
    }
}

struct AttentionRow: View {
    let item: AttentionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.priority.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(priorityColor)
                Spacer()
                Text(item.action)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.muted)
            }
            Text(item.title)
                .font(.system(size: 16, weight: .bold, design: .rounded))
            Text(item.detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(priorityColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(priorityColor.opacity(0.45), lineWidth: 1))
    }

    private var priorityColor: Color {
        switch item.priority.lowercased() {
        case "high", "money": return AppTheme.red
        case "policy": return Color.purple
        case "evidence": return AppTheme.orange
        case "reference": return AppTheme.blue
        default: return AppTheme.green
        }
    }
}

struct RecentRunRow: View {
    let run: RecentRun

    var body: some View {
        HStack(spacing: 10) {
            Text("#\(run.id)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.generatedAt)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Text("\(run.invoices) invoices · \(run.findings) findings")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
            }
            Spacer()
            Text(dollars(run.exposure))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(run.exposure > 0 ? AppTheme.red : AppTheme.green)
        }
        .padding(10)
        .background(AppTheme.panel2.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ExposureRowView: View {
    let row: ExposureRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.name)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                Spacer()
                Text(dollars(row.exposure))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(row.exposure > 0 ? AppTheme.red : AppTheme.green)
            }
            Text("\(dollars(row.spend)) spend · \(row.findings) findings")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.muted)
        }
        .padding(10)
        .background(AppTheme.panel2.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EmptyDarkText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AppTheme.muted)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.panel2.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AdvisorDrawer: View {
    @Binding var isOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Business Financial Advisor")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Ask while you connect, audit, or review.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Button {
                    isOpen = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(AppTheme.panel2, in: Circle())
                }
                .buttonStyle(.plain)
            }

            AnalystPanel()

            Spacer()
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.010, green: 0.025, blue: 0.040))
        .overlay(Rectangle().stroke(AppTheme.stroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 24, x: -12, y: 0)
    }
}

struct SourcesStepView: View {
    @EnvironmentObject private var model: AuditModel
    let continueAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                WizardTitle(
                    eyebrow: "Step 1",
                    title: "Point the system at the data",
                    subtitle: "Keep this simple: receipts/invoices, Excel price sheets, connected SQL evidence, and legacy VM/RM handoffs when the source system cannot export cleanly."
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
                        title: "Excel sheets / price data",
                        detail: model.pricebookURL?.lastPathComponent ?? "Choose .xlsx, .csv, or SQLite customer price data.",
                        systemImage: "tablecells",
                        isReady: model.pricebookURL != nil,
                        actionTitle: "Choose Sheet",
                        action: model.choosePricebook
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
                                Task { await model.runAudit() }
                            } else {
                                model.status = "Choose invoices and Excel sheets first"
                            }
                        }
                    )
                }

                LegacyBridgePanel()

                HStack {
                    Text("Market benchmarks, rules, API connectors, and share/export still live under the gear for advanced setup.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.muted)
                    Spacer()
                    Button {
                        model.useSampleData()
                    } label: {
                        Label("Use Sample", systemImage: "shippingbox")
                    }
                    Button {
                        continueAction()
                    } label: {
                        Label("Continue", systemImage: "arrow.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRunAudit)
                }
                Spacer(minLength: 12)
            }
        }
    }
}

struct LegacyBridgePanel: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        DarkPanel {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Legacy VM / RM bridge", systemImage: "display.and.arrow.down")
                        .font(.system(size: 16, weight: .bold))
                    Text("For old payroll, RM, ERP, or plant computers that cannot export cleanly: open Kist Work Agent, log into the legacy system, extract screens/files/database exports, then bring the extracted PDFs, CSV, Excel, or API JSON back into this audit.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.legacyBridgeStatus)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.legacyBridgeStatus.localizedCaseInsensitiveContains("reachable") ? AppTheme.green : AppTheme.orange)
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
                        model.copyLegacyBridgeInstructions()
                    } label: {
                        Label("Copy Handoff", systemImage: "doc.on.clipboard")
                    }
                }
                .buttonStyle(.bordered)
            }
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

struct SaveExportStepView: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WizardTitle(
                    eyebrow: "Step 4",
                    title: "Save, export, and send the data",
                    subtitle: "Create the outputs leadership and downstream systems need: report, CSVs, email draft, API/Zapier payload, webhook send, and full app/query journals."
                )

                HStack(spacing: 14) {
                    ExportActionCard(
                        title: "Visual report",
                        detail: model.hasReport ? "HTML business map is ready." : "Generate after the connected database exists.",
                        systemImage: "chart.bar.xaxis",
                        isReady: model.hasReport,
                        actionTitle: "Open Report",
                        action: model.revealReport
                    )
                    ExportActionCard(
                        title: "CSV data",
                        detail: "Exports categories, vendors, findings, line items, and top findings for finance/ops.",
                        systemImage: "tablecells",
                        isReady: model.hasBusinessDatabase,
                        actionTitle: "Export CSVs",
                        action: { Task { await model.exportCSVs() } }
                    )
                    ExportActionCard(
                        title: "Journal files",
                        detail: "App activity and analyst query history are saved locally as JSONL.",
                        systemImage: "book.closed",
                        isReady: !model.activityJournal.isEmpty || !model.queryHistory.isEmpty,
                        actionTitle: "Reveal Journal",
                        action: model.revealActivityJournal
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    DarkPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Boss-ready outputs", systemImage: "square.and.arrow.up")
                            SharePanel()
                        }
                    }

                    DarkPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "What will be sent", systemImage: "checkmark.shield")
                            ExportFact("Report", "Standalone HTML visual map from SQLite evidence.")
                            ExportFact("CSV", "Finance/ops tables for spreadsheet review.")
                            ExportFact("Email", "Executive summary draft with optional report attachment.")
                            ExportFact("API/Zapier", "Generic JSON payload; webhook only sends when a URL is supplied.")
                            ExportFact("Journal", "Local JSONL record of app work, queries, outcomes, and failures.")
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }
}

struct ExportActionCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let isReady: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(isReady ? AppTheme.green : AppTheme.orange)
                Spacer()
                Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(isReady ? AppTheme.green : AppTheme.orange)
            }
            Text(title)
                .font(.system(size: 17, weight: .bold))
            Text(detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(isReady ? AppTheme.green.opacity(0.45) : AppTheme.stroke, lineWidth: 1))
    }
}

struct ExportFact: View {
    let title: String
    let detail: String

    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.panel2.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct QueryStepView: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WizardTitle(
                    eyebrow: "Query mode",
                    title: "Ask the business analyst and review the work journal",
                    subtitle: "Every analyst question and system action is saved with time, outcome, what was learned, and what failed. This is the LIST-style memory layer for the demo."
                )

                HStack(alignment: .top, spacing: 16) {
                    AnalystPanel()
                        .frame(minWidth: 420, maxWidth: 560, minHeight: 420)
                    QueryHistoryPanel()
                        .frame(maxWidth: .infinity, minHeight: 420)
                }

                ActivityJournalPanel()
            }
            .padding(.bottom, 24)
        }
    }
}

struct QueryHistoryPanel: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        DarkPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "Past searches", systemImage: "magnifyingglass.circle")
                    Button("Reveal") {
                        model.revealQueryHistory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if model.queryHistory.isEmpty {
                    EmptyDarkText("No saved analyst searches yet.")
                } else {
                    ForEach(model.queryHistory.prefix(10)) { item in
                        QueryHistoryRow(item: item)
                    }
                }
            }
        }
    }
}

struct QueryHistoryRow: View {
    let item: QueryHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(item.timestamp)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.muted)
                Spacer()
                Text(item.outcome.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(item.outcome == "answered" ? AppTheme.green : AppTheme.orange)
            }
            Text(item.question)
                .font(.system(size: 13, weight: .bold))
            Text(item.answer)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(5)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.panel2.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ActivityJournalPanel: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        DarkPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "Daily work journal", systemImage: "book.pages")
                    Button("Reveal JSONL") {
                        model.revealActivityJournal()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if model.activityJournal.isEmpty {
                    EmptyDarkText("No app activity logged yet.")
                } else {
                    ForEach(model.activityJournal.prefix(30)) { event in
                        ActivityEventRow(event: event)
                    }
                }
            }
        }
    }
}

struct ActivityEventRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 4) {
                Circle()
                    .fill(outcomeColor)
                    .frame(width: 9, height: 9)
                Rectangle()
                    .fill(AppTheme.stroke)
                    .frame(width: 1, height: 42)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(event.title)
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text(event.timestamp)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.muted)
                }
                Text(event.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(3)
                HStack {
                    Text(event.kind.uppercased())
                    Text("·")
                    Text(event.outcome)
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(outcomeColor)
            }
        }
        .padding(10)
        .background(AppTheme.panel2.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
    }

    private var outcomeColor: Color {
        event.outcome.localizedCaseInsensitiveContains("fail") ? AppTheme.red :
            (event.outcome.localizedCaseInsensitiveContains("started") ? AppTheme.orange : AppTheme.green)
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

func appTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

func jsonDouble(_ dict: [String: Any], _ key: String) -> Double {
    if let number = dict[key] as? NSNumber {
        return number.doubleValue
    }
    if let value = dict[key] as? Double {
        return value
    }
    if let value = dict[key] as? String, let parsed = Double(value) {
        return parsed
    }
    return 0
}

func jsonInt(_ dict: [String: Any], _ key: String) -> Int? {
    if dict[key] is NSNull {
        return nil
    }
    if let number = dict[key] as? NSNumber {
        return number.intValue
    }
    if let value = dict[key] as? Int {
        return value
    }
    if let value = dict[key] as? String, let parsed = Int(value) {
        return parsed
    }
    return nil
}

struct AppError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
