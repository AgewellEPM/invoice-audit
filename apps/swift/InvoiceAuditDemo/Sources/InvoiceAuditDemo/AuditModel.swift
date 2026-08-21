import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AuditModel: ObservableObject {
    @Published var receipt: ReceiptSummary?
    @Published var selectedInvoiceID: String?
    @Published var selectedFindingID: String?
    @Published var isRunning = false
    @Published var showExtractionWorkspace = false
    @Published var pipelinePhase = "Idle"
    @Published var csvGridRows: [CSVGridRow] = []
    @Published var status = "Choose invoice sources and Excel price sheets"
    @Published var verification = "Not verified"
    @Published var transcript = ""
    @Published var invoiceFolderURL: URL?
    @Published var pricebookURL: URL?
    @Published var marketURL: URL?
    @Published var rulesURL: URL?
    @Published var sourceAPIURL = ""
    @Published var connectorStatus = "Local folder, network folder, email export, and API/Zapier sources are supported."
    @Published var analystQuestion = "what should I deal with today?"
    @Published var analystAnswer = "Run an audit, then ask what needs attention, trace this dollar, compare vendors, show overcharges, or explain a specific invoice. Answers come from SQL evidence and show their calculations."
    @Published var analystIsRunning = false
    @Published var webhookURL = ""
    @Published var shareStatus = "Generate an email draft or paste a Zapier webhook URL."
    @Published var shareIsRunning = false
    @Published var journal = BusinessJournal.empty
    @Published var activityJournal: [ActivityEvent] = []
    @Published var queryHistory: [QueryHistoryItem] = []
    @Published var financeNotes: [FinanceNote] = []
    @Published var legacyBridge = LegacyBridgeSnapshot.empty
    @Published var legacyBridgeStatus = "Legacy VM/RM bridge not checked."
    // Industry-benchmark (kist research) state — see BenchmarkFeature.swift.
    @Published var benchmarkIsRunning = false
    @Published var benchmarkStatus = "Benchmarks not researched yet. Refresh to compare against industry pricing."
    @Published var benchmarkRegion = "United States"

    let repoRoot: URL
    let receiptURL: URL
    let dbURL: URL
    private let reportURL: URL
    private let exportsURL: URL
    private let emailDraftURL: URL
    private let integrationPayloadURL: URL
    private let connectorConfigURL: URL
    private let connectorWorkspaceURL: URL
    private let activityJournalURL: URL
    private let queryHistoryURL: URL
    private let financeNotesURL: URL

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
        financeNotesURL = repoRoot
            .appendingPathComponent(".invoice-audit-app", isDirectory: true)
            .appendingPathComponent("finance-notes.jsonl")
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
            title: "Opened Financial Ops Copilot",
            detail: "Loaded the native workspace and checked for prior financial evidence.",
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

    var invoiceLinesCSVURL: URL {
        exportsURL.appendingPathComponent("invoice_lines.csv")
    }

    var dbPathForUI: String {
        dbURL.path
    }

    var benchmarksDir: URL {
        repoRoot
            .appendingPathComponent(".invoice-audit-app", isDirectory: true)
            .appendingPathComponent("benchmarks", isDirectory: true)
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

    func openLegacyStage() {
        let baseURL = legacyBridge.baseUrl.isEmpty ? "http://127.0.0.1:8765" : legacyBridge.baseUrl
        let sessionPath = legacyBridge.sessionUrl ?? "/"
        guard let url = URL(string: baseURL + sessionPath) else { return }
        NSWorkspace.shared.open(url)
        logActivity(
            kind: "legacy-bridge",
            title: "Opened active VM stage",
            detail: "Opened \(url.absoluteString) for the connected VM/RM source.",
            outcome: "stage opened"
        )
    }

    func checkLegacyBridge(auto: Bool = false) async {
        do {
            let output = try await runPython([
                "-m", "invoice_audit", "legacy-status", "--json", "--scan", "--no-fail"
            ])
            guard let data = output.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AppError("Legacy status command did not return JSON")
            }
            legacyBridge = LegacyBridgeSnapshot(json: json)
            legacyBridgeStatus = legacyBridge.headline
            logActivity(
                kind: "legacy-bridge",
                title: auto ? "Auto-checked VM/RM bridge" : "Checked VM/RM bridge",
                detail: legacyBridge.activityDetail,
                outcome: legacyBridge.isOperational ? "connected" : "needs setup"
            )
        } catch {
            legacyBridge = .unavailable(error.localizedDescription)
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
        4. Return to Financial Ops Copilot > Money and choose the extracted folder + Excel price data.
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
        showExtractionWorkspace = true
        isRunning = true
        pipelinePhase = "Opening source files"
        status = "Extracting invoice data"
        verification = "Pending"
        transcript = ""
        logActivity(
            kind: "audit",
            title: "Started audit",
            detail: "Invoices: \(invoiceFolderURL.path); price data: \(pricebookURL.path)",
            outcome: "started"
        )

        do {
            pipelinePhase = "OCR reading PDFs/scans"
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
                let sidecar = benchmarksDir.appendingPathComponent("market-benchmarks.json")
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    args.append(contentsOf: ["--market-benchmarks", sidecar.path])
                }
            }
            if let rulesURL {
                args.append(contentsOf: ["--floor", rulesURL.path])
            }
            let output = try await runPython(args)
            pipelinePhase = "Normalizing lines into SQL"
            transcript += output
            await loadReceipt(from: receiptURL)
            pipelinePhase = "Verifying receipt and source hashes"
            await verifyReceipt()
            pipelinePhase = "Generating evidence report"
            await generateReport()
            pipelinePhase = "Loading morning briefing"
            await loadBusinessJournal()
            pipelinePhase = "Exporting living CSV grid"
            await refreshCSVGrid(openInFinder: false)
            pipelinePhase = "Asking financial analyst"
            await askAnalyst()
            pipelinePhase = "Complete — data extracted, verified, and exported"
            status = "Capture pipeline complete"
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
            pipelinePhase = "Failed — check transcript"
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

    func refreshCSVGrid(openInFinder: Bool = true) async {
        guard hasBusinessDatabase else {
            shareStatus = "Run an audit first."
            return
        }
        do {
            let output = try await runPython([
                "-m", "invoice_audit", "export",
                "--db", dbURL.path,
                "--out", exportsURL.path
            ])
            transcript += output
            csvGridRows = loadCSVGrid(from: invoiceLinesCSVURL)
            shareStatus = "Living CSV grid ready"
            if openInFinder {
                NSWorkspace.shared.activateFileViewerSelecting([invoiceLinesCSVURL])
            }
            logActivity(
                kind: "export",
                title: "Refreshed living CSV grid",
                detail: invoiceLinesCSVURL.path,
                outcome: "saved export"
            )
        } catch {
            shareStatus = "CSV grid refresh failed"
            transcript += "\nCSV grid refresh failed: \(error.localizedDescription)"
            logActivity(
                kind: "export",
                title: "CSV grid refresh failed",
                detail: error.localizedDescription,
                outcome: "failed"
            )
        }
    }

    func openInvoiceLinesCSV() {
        if FileManager.default.fileExists(atPath: invoiceLinesCSVURL.path) {
            NSWorkspace.shared.open(invoiceLinesCSVURL)
        } else {
            Task { await refreshCSVGrid(openInFinder: true) }
        }
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
        await refreshCSVGrid(openInFinder: true)
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

    func revealFinanceNotes() {
        NSWorkspace.shared.activateFileViewerSelecting([financeNotesURL])
    }

    func addFinanceNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let note = FinanceNote(timestamp: appTimestamp(), text: trimmed)
        financeNotes.insert(note, at: 0)
        if financeNotes.count > 300 {
            financeNotes.removeLast(financeNotes.count - 300)
        }
        appendJSONLine(note, to: financeNotesURL)
        logActivity(
            kind: "note",
            title: "Added finance note",
            detail: trimmed,
            outcome: "captured"
        )
    }

    private func loadAppJournal() {
        activityJournal = loadJSONLines(ActivityEvent.self, from: activityJournalURL, limit: 300)
        queryHistory = loadJSONLines(QueryHistoryItem.self, from: queryHistoryURL, limit: 120)
        financeNotes = loadJSONLines(FinanceNote.self, from: financeNotesURL, limit: 300)
        csvGridRows = loadCSVGrid(from: invoiceLinesCSVURL)
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

    func loadReceipt(from url: URL) async {
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

    func runPython(_ args: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.currentDirectoryURL = self.repoRoot
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PYTHONPATH"] = self.repoRoot.path
            // Finder-launched apps get a minimal PATH; make sure the kist binary
            // (usually ~/bin) and common tool dirs are resolvable for benchmarks.
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let extraPath = ["\(home)/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            let currentPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = (extraPath + [currentPath]).joined(separator: ":")
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
