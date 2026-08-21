import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

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
    let marketOvercharge: Double
    let policyOverage: Double

    init(json: [String: Any]) {
        invoices = json["invoices"] as? Int ?? 0
        lines = json["linesChecked"] as? Int ?? 0
        flagged = json["flagged"] as? Int ?? 0
        potentialOvercharge = json["potentialOverchargeUSD"] as? Double ?? 0
        marketOvercharge = json["marketOverchargeUSD"] as? Double ?? 0
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

struct FinanceNote: Identifiable, Codable {
    let id: String
    let timestamp: String
    let text: String

    init(
        id: String = UUID().uuidString,
        timestamp: String,
        text: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
    }
}

struct CSVGridRow: Identifiable {
    let id = UUID()
    let cells: [String: String]

    func value(_ key: String) -> String {
        cells[key] ?? ""
    }
}

struct LegacyProcessItem: Identifiable {
    let id: String
    let pid: Int
    let kind: String
    let label: String
    let name: String?
    let qmpSocket: String?
    let commandPreview: String?

    init(json: [String: Any]) {
        pid = jsonInt(json, "pid") ?? 0
        kind = json["kind"] as? String ?? "process"
        label = json["label"] as? String ?? kind
        name = LegacyBridgeSnapshot.optionalString(json["name"])
        qmpSocket = LegacyBridgeSnapshot.optionalString(json["qmpSocket"])
        commandPreview = LegacyBridgeSnapshot.optionalString(json["commandPreview"])
        id = "\(pid)-\(kind)-\(name ?? label)"
    }

    var displayName: String {
        name ?? label
    }
}

struct LegacyBridgeSnapshot {
    let checkedAt: String
    let baseUrl: String
    let error: String?
    let consoleReachable: Bool
    let activeVmStage: Bool
    let perslisRuntime: Bool
    let perslisBridge: Bool
    let rmBridge: Bool
    let win11Vm: Bool
    let legacyVm: Bool
    let stageOs: String?
    let stageKind: String?
    let readyHint: String?
    let sessionUrl: String?
    let qmpSocket: String?
    let scanQueried: Bool
    let scanOk: Bool
    let elementCount: Int?
    let safeMode: Bool?
    let processItems: [LegacyProcessItem]

    static let empty = LegacyBridgeSnapshot(
        checkedAt: "",
        baseUrl: "http://127.0.0.1:8765",
        error: nil,
        consoleReachable: false,
        activeVmStage: false,
        perslisRuntime: false,
        perslisBridge: false,
        rmBridge: false,
        win11Vm: false,
        legacyVm: false,
        stageOs: nil,
        stageKind: nil,
        readyHint: nil,
        sessionUrl: nil,
        qmpSocket: nil,
        scanQueried: false,
        scanOk: false,
        elementCount: nil,
        safeMode: nil,
        processItems: []
    )

    static func unavailable(_ message: String) -> LegacyBridgeSnapshot {
        LegacyBridgeSnapshot(
            checkedAt: appTimestamp(),
            baseUrl: "http://127.0.0.1:8765",
            error: message,
            consoleReachable: false,
            activeVmStage: false,
            perslisRuntime: false,
            perslisBridge: false,
            rmBridge: false,
            win11Vm: false,
            legacyVm: false,
            stageOs: nil,
            stageKind: nil,
            readyHint: nil,
            sessionUrl: nil,
            qmpSocket: nil,
            scanQueried: false,
            scanOk: false,
            elementCount: nil,
            safeMode: nil,
            processItems: []
        )
    }

    init(
        checkedAt: String,
        baseUrl: String,
        error: String?,
        consoleReachable: Bool,
        activeVmStage: Bool,
        perslisRuntime: Bool,
        perslisBridge: Bool,
        rmBridge: Bool,
        win11Vm: Bool,
        legacyVm: Bool,
        stageOs: String?,
        stageKind: String?,
        readyHint: String?,
        sessionUrl: String?,
        qmpSocket: String?,
        scanQueried: Bool,
        scanOk: Bool,
        elementCount: Int?,
        safeMode: Bool?,
        processItems: [LegacyProcessItem]
    ) {
        self.checkedAt = checkedAt
        self.baseUrl = baseUrl
        self.error = error
        self.consoleReachable = consoleReachable
        self.activeVmStage = activeVmStage
        self.perslisRuntime = perslisRuntime
        self.perslisBridge = perslisBridge
        self.rmBridge = rmBridge
        self.win11Vm = win11Vm
        self.legacyVm = legacyVm
        self.stageOs = stageOs
        self.stageKind = stageKind
        self.readyHint = readyHint
        self.sessionUrl = sessionUrl
        self.qmpSocket = qmpSocket
        self.scanQueried = scanQueried
        self.scanOk = scanOk
        self.elementCount = elementCount
        self.safeMode = safeMode
        self.processItems = processItems
    }

    init(json: [String: Any]) {
        let summary = json["summary"] as? [String: Any] ?? [:]
        let console = json["console"] as? [String: Any] ?? [:]
        let processes = json["processes"] as? [String: Any] ?? [:]
        let items = processes["items"] as? [[String: Any]] ?? []

        checkedAt = json["checkedAt"] as? String ?? appTimestamp()
        baseUrl = json["baseUrl"] as? String ?? "http://127.0.0.1:8765"
        error = LegacyBridgeSnapshot.optionalString(json["error"])
            ?? LegacyBridgeSnapshot.optionalString(console["error"])
        consoleReachable = LegacyBridgeSnapshot.bool(console, "reachable")
            || LegacyBridgeSnapshot.bool(summary, "desktopVision")
        activeVmStage = LegacyBridgeSnapshot.bool(summary, "activeVmStage")
        perslisRuntime = LegacyBridgeSnapshot.bool(summary, "perslisRuntime")
        perslisBridge = LegacyBridgeSnapshot.bool(summary, "perslisBridge")
        rmBridge = LegacyBridgeSnapshot.bool(summary, "rmBridge")
        win11Vm = LegacyBridgeSnapshot.bool(summary, "win11Vm")
        legacyVm = LegacyBridgeSnapshot.bool(summary, "legacyVm")
        stageOs = LegacyBridgeSnapshot.optionalString(summary["stageOs"])
        stageKind = LegacyBridgeSnapshot.optionalString(summary["stageKind"])
        readyHint = LegacyBridgeSnapshot.optionalString(summary["readyHint"])
        sessionUrl = LegacyBridgeSnapshot.optionalString(summary["sessionUrl"])
        qmpSocket = LegacyBridgeSnapshot.optionalString(summary["qmpSocket"])
        scanQueried = LegacyBridgeSnapshot.bool(summary, "scanQueried")
        scanOk = LegacyBridgeSnapshot.bool(summary, "scanOk")
        elementCount = jsonInt(summary, "elementCount")
        safeMode = LegacyBridgeSnapshot.optionalBool(summary["safeMode"])
        processItems = Array(items.map(LegacyProcessItem.init).prefix(8))
    }

    var hasChecked: Bool {
        !checkedAt.isEmpty
    }

    var isOperational: Bool {
        consoleReachable && activeVmStage && (win11Vm || legacyVm || rmBridge || perslisRuntime)
    }

    var headline: String {
        if !hasChecked {
            return "Legacy VM/RM bridge not checked."
        }
        if let error, !consoleReachable {
            return "Bridge not reachable: \(error)"
        }
        if isOperational {
            return "Live bridge connected: VM-stage active, Perslis/RM detected."
        }
        if consoleReachable {
            return "Kist bridge reachable; VM/RM attachment still needs review."
        }
        return "Bridge not reachable. Start Kist Work Agent / desktop-vision-console first."
    }

    var stageDescription: String {
        guard activeVmStage else {
            return "No active VM-stage endpoint is confirmed yet."
        }
        var parts = [stageOs ?? "unknown OS"]
        if let stageKind { parts.append(stageKind) }
        if let readyHint { parts.append(readyHint) }
        if let qmpSocket { parts.append(qmpSocket) }
        return "Active VM-stage: " + parts.joined(separator: " · ")
    }

    var scanDescription: String {
        guard scanQueried else {
            return "Vision scan not queried yet."
        }
        let count = elementCount.map { "\($0) elements" } ?? "element count unknown"
        let safe = safeMode.map { $0 ? "safe mode on" : "safe mode off" } ?? "safe mode unknown"
        return "Vision scan \(scanOk ? "ok" : "needs review") · \(count) · \(safe)"
    }

    var activityDetail: String {
        [
            "console=\(consoleReachable)",
            "stage=\(activeVmStage)",
            "perslis=\(perslisRuntime)",
            "rm=\(rmBridge)",
            "win11=\(win11Vm)",
            "legacy=\(legacyVm)",
            qmpSocket.map { "qmp=\($0)" },
            elementCount.map { "elements=\($0)" },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    static func optionalString(_ value: Any?) -> String? {
        if value == nil || value is NSNull {
            return nil
        }
        if let string = value as? String, !string.isEmpty {
            return string
        }
        return nil
    }

    private static func bool(_ dict: [String: Any], _ key: String) -> Bool {
        optionalBool(dict[key]) ?? false
    }

    private static func optionalBool(_ value: Any?) -> Bool? {
        if value == nil || value is NSNull {
            return nil
        }
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            if ["true", "yes", "1"].contains(value.lowercased()) {
                return true
            }
            if ["false", "no", "0"].contains(value.lowercased()) {
                return false
            }
        }
        return nil
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
    let referenceMedian: Double?
    let priceExposure: Double
    let grounding: String
    let verdict: String
    // Industry-benchmark comparison (researched by kist, checked deterministically).
    let marketVerdict: String
    let marketReferenceMedian: Double?
    let marketExposure: Double

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
        referenceMedian = jsonDoubleOptional(json, "reference_median")
        priceExposure = json["delta_total"] as? Double ?? 0
        let groundingObj = json["grounding"] as? [String: Any] ?? [:]
        grounding = groundingObj["verdict"] as? String ?? "unknown"
        verdict = json["verdict"] as? String ?? "unknown"
        let marketObj = json["market"] as? [String: Any] ?? [:]
        marketVerdict = marketObj["verdict"] as? String ?? "not-configured"
        marketReferenceMedian = jsonDoubleOptional(marketObj, "reference_median")
        marketExposure = marketObj["delta_total"] as? Double ?? 0
    }
}

struct FindingView: Identifiable {
    let id: String
    let invoice: String
    let kind: String
    let line: String
    let lineIndex: Int?
    let detail: String
    let severity: Severity
    let invoiceImageURL: URL?

    init(index: Int, json: [String: Any], invoices: [InvoiceView]) {
        invoice = json["invoice"] as? String ?? "Unknown"
        kind = json["kind"] as? String ?? "review"
        if let n = json["line"] as? Int {
            line = "Line \(n + 1)"
            lineIndex = n
        } else {
            line = "Invoice"
            lineIndex = nil
        }
        detail = json["detail"] as? String ?? "Needs review"
        id = "\(invoice)-\(kind)-\(index)"
        severity = Severity(kind: kind)
        let invoiceFile = invoice
        invoiceImageURL = invoices.first(where: { $0.file == invoiceFile })?.imageURL
    }
}

enum Severity: Equatable {
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
    case pulse = "Today"
    case sources = "Money"
    case audit = "Investigate"
    case review = "Review"
    case saveExport = "Work"
    case query = "Ask"

    static var allCases: [WorkflowStep] {
        [.pulse, .sources, .audit, .saveExport, .query]
    }

    var id: String { rawValue }

    var badge: String {
        switch self {
        case .pulse: "TODAY"
        case .sources: "1"
        case .audit: "2"
        case .review: "2A"
        case .saveExport: "3"
        case .query: "4"
        }
    }

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
        case .pulse: "morning brief"
        case .sources: "map data"
        case .audit: "find leakage"
        case .review: "inspect evidence"
        case .saveExport: "act/export"
        case .query: "ask analyst"
        }
    }

    var systemImage: String {
        switch self {
        case .pulse: "sun.max.fill"
        case .sources: "dollarsign.circle"
        case .audit: "point.3.connected.trianglepath.dotted"
        case .review: "checklist.checked"
        case .saveExport: "checkmark.seal"
        case .query: "bubble.left.and.text.bubble.right"
        }
    }
}

struct CapturedFinanceItem: Identifiable {
    let id: String
    let timestamp: String
    let kind: String
    let title: String
    let detail: String
    let footer: String
    let systemImage: String
    let color: Color
}

struct FinanceTopic {
    let label: String
    let color: Color
}

struct MoneyTrace {
    let finding: FindingView
    let invoice: InvoiceView
    let line: InvoiceLineView?

    var exposure: Double {
        if let line {
            return max(line.priceExposure + line.policyExposure, 0)
        }
        return 0
    }

    var lineText: String {
        guard let line else {
            return finding.line
        }
        return "\(line.sku.isEmpty ? line.description : line.sku) · qty \(number(line.qty)) · unit \(dollars(line.unitPrice)) · total \(dollars(line.lineTotal))"
    }

    var evidenceText: String {
        guard let line else {
            return "Original scan and review finding"
        }
        if let reference = line.referenceMedian, reference > 0 {
            let variance = ((line.unitPrice - reference) / reference) * 100
            return "Unit \(dollars(line.unitPrice)) vs median \(dollars(reference)) · variance \(signedPercent(variance)) · scan + SQL line"
        }
        return "No reference median connected for this line · scan + SQL line"
    }
}
