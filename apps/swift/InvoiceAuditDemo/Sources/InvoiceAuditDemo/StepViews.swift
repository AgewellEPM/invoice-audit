import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

struct AuditStepView: View {
    @EnvironmentObject private var model: AuditModel
    let reviewAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            WizardTitle(
                eyebrow: "Investigate",
                title: "Find leakage with deterministic checks",
                subtitle: "OCR and AI help extract and normalize. Software calculates price variance, policy exposure, grounding, and source evidence before anything reaches human review."
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
                    Text("The app will create a signed receipt, SQLite evidence store, visual report, follow-the-dollar trace, and review queue.")
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
                eyebrow: "Evidence detail",
                title: "Review the source trail",
                subtitle: "High-cost uncertainty stays visible: invoice image, OCR read, digital line items, deterministic calculation, evidence, policy, and price findings."
            )
            if let receipt = model.receipt {
                ContentView(receipt: receipt)
            } else {
                EmptyDarkState(text: "No audit receipt yet. Run Investigate first.")
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
                    eyebrow: "Work",
                    title: "Act, export, and verify",
                    subtitle: "Turn discoveries into outputs and actions: report, CSVs, email draft, API/Zapier payload, webhook send, review records, and full app/query journals."
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
                    eyebrow: "Ask",
                    title: "Ask the financial analyst and review the work journal",
                    subtitle: "Ask normal business questions. Answers must drill into receipts, calculations, transactions, and source records; every question/action is saved with time, outcome, what was learned, and what failed."
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
