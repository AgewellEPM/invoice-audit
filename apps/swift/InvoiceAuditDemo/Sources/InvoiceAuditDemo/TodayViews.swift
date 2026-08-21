import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

struct PulseStepView: View {
    @EnvironmentObject private var model: AuditModel
    let sourceAction: () -> Void
    let auditAction: () -> Void
    let reviewAction: () -> Void
    let advisorAction: () -> Void
    // Shared day selection: the calendar rail drives it, the journal reads it.
    @State private var selectedDay = Date()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Persistent full-height calendar rail — its own column, like LIST.
            FinanceCalendarRail(selectedDay: $selectedDay)
                .frame(width: 272)

            Divider()
                .overlay(AppTheme.stroke)

            ScrollView {
                content
                    .padding(.leading, 22)
                    .padding(.bottom, 24)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    WizardTitle(
                        eyebrow: "Today",
                        title: "Good morning. Here's what needs attention.",
                        subtitle: "A financial morning briefing from connected evidence: deterministic money risk first, missing feeds called out clearly, and every AI explanation traceable back to source records."
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
                    MorningMetricCard(
                        title: "AT RISK",
                        value: dollars(model.journal.overview.totalExposure),
                        detail: "Deterministic price + policy exposure",
                        color: model.journal.overview.totalExposure > 0 ? AppTheme.red : AppTheme.green
                    )
                    MorningMetricCard(
                        title: "DUE",
                        value: "Connect AP",
                        detail: "Payables feed not connected yet",
                        color: AppTheme.orange
                    )
                    MorningMetricCard(
                        title: "INCOMING",
                        value: "Connect AR",
                        detail: "Receivables feed not connected yet",
                        color: AppTheme.blue
                    )
                    MorningMetricCard(
                        title: "CASH IMPACT",
                        value: cashImpactText,
                        detail: "Known leakage only until AP/AR is live",
                        color: model.journal.overview.totalExposure > 0 ? AppTheme.red : AppTheme.green
                    )
                }

                FinanceDailyJournalPanel(selectedDay: $selectedDay)

                MoneyLineagePanel(reviewAction: reviewAction)

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
                                SectionHeader(title: "Ask anything about the money", systemImage: "bubble.left.and.text.bubble.right.fill")
                                Text("The advisor answers from SQL evidence. Ask: what should I deal with today, trace this dollar, where are we leaking money, compare vendors, or what should I tell the owner.")
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
    }

    private var statusColor: Color {
        model.journal.status.localizedCaseInsensitiveContains("SOS") ? AppTheme.red :
            (model.journal.status.localizedCaseInsensitiveContains("clear") ? AppTheme.green : AppTheme.orange)
    }

    private var dataRotText: String {
        guard let count = model.journal.dataQualityIssues else { return "—" }
        return "\(count)"
    }

    private var cashImpactText: String {
        let exposure = model.journal.overview.totalExposure
        if exposure <= 0 {
            return "$0"
        }
        return "-\(dollars(exposure))"
    }
}

struct MoneyLineagePanel: View {
    @EnvironmentObject private var model: AuditModel
    let reviewAction: () -> Void

    var body: some View {
        DarkPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Follow the dollar", systemImage: "arrow.triangle.branch")
                    Spacer()
                    Button {
                        model.analystQuestion = "trace this dollar"
                        Task { await model.askAnalyst() }
                    } label: {
                        Label("Ask trace", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.canAskAnalyst)
                }

                if let trace = currentTrace {
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(dollars(trace.exposure))
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(trace.exposure > 0 ? AppTheme.red : AppTheme.green)
                            Text("potential exposure")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(AppTheme.muted)
                            Text("Software calculates the variance. The AI explains and helps navigate the evidence.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.76))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: 220, alignment: .leading)

                        VStack(alignment: .leading, spacing: 8) {
                            LineageNode(label: "Dollar", value: "\(dollars(trace.exposure)) flagged exposure")
                            LineageNode(label: "Invoice", value: "\(trace.invoice.invoiceNo) · \(trace.invoice.file)")
                            LineageNode(label: "Vendor", value: "\(trace.invoice.vendor) · \(trace.invoice.category)")
                            LineageNode(label: "Line", value: trace.lineText)
                            LineageNode(label: "Evidence", value: trace.evidenceText)
                            LineageNode(label: "Next layers", value: "PO → job/customer → payment/bank → recovery status")
                        }
                    }

                    HStack {
                        Text(trace.finding.detail)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            reviewAction()
                        } label: {
                            Label("Trace in Review", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                } else {
                    Text("Run an audit to create the first traceable dollar path. AP/AR, job, customer, payroll, and bank layers become available as those sources are connected.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.muted)
                }
            }
        }
    }

    private var currentTrace: MoneyTrace? {
        guard let receipt = model.receipt else { return nil }
        let finding = receipt.findings.first(where: { $0.severity == .money }) ?? receipt.findings.first
        guard let finding,
              let invoice = receipt.invoices.first(where: { $0.file == finding.invoice }) else {
            return nil
        }
        let line = finding.lineIndex.flatMap { index in
            invoice.lines.first(where: { $0.id == index })
        } ?? invoice.lines.first(where: { $0.verdict == "overcharge-flag" }) ?? invoice.lines.first
        return MoneyTrace(finding: finding, invoice: invoice, line: line)
    }
}

struct FinanceDailyJournalPanel: View {
    @EnvironmentObject private var model: AuditModel
    // Day is chosen in the calendar rail; this panel only reads it.
    @Binding var selectedDay: Date

    var body: some View {
        DarkPanel {
            VStack(alignment: .leading, spacing: 18) {
                header
                summaryAndTopics
                // Captured items + timeline span the FULL content width,
                // exactly like LIST — so the 4-column grid renders wide.
                capturedItemsSection
                activityTimeline
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Journal — \(longDateLabel(selectedDay))")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(selectedDaySubtitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.muted)
            }
            Spacer()
            if Calendar.current.isDateInToday(selectedDay) {
                Label("LIVE · \(journalTime(appTimestamp()))", systemImage: "circle.fill")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(AppTheme.green)
            }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 42) {
                JournalHeaderMetric(value: "\(capturedItems.count)", label: "Items Captured", color: AppTheme.blue)
                JournalHeaderMetric(value: "\(dayQueries.count)", label: "Queries", color: Color.purple)
                JournalHeaderMetric(value: "\(dayNotes.count)", label: "Notes", color: AppTheme.green)
                JournalHeaderMetric(value: "\(dayFailures.count)", label: "Failures", color: dayFailures.isEmpty ? AppTheme.orange : AppTheme.red)
            }
            .padding(.top, 38)
        }
        .padding(.bottom, 64)
    }

    private var summaryAndTopics: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 9) {
                Label("DAY SUMMARY", systemImage: "sparkle")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(AppTheme.blue)
                Text(daySummary)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text("TOP TOPICS")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(AppTheme.muted)
                    .tracking(0.8)
                ForEach(topicRows, id: \.label) { topic in
                    TopicChip(label: topic.label, color: topic.color)
                }
            }
            .frame(width: 170, alignment: .leading)
        }
    }

    private var capturedItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Captured finance items (\(capturedItems.count))", systemImage: "square.grid.2x2")
                Spacer()
                Button("View All") {
                    model.revealActivityJournal()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if capturedItems.isEmpty {
                EmptyDarkText("No captured items for this day. Audits, bridge checks, analyst searches, exports, failures, and manual notes will appear here.")
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(capturedItems.prefix(8)) { item in
                        CapturedFinanceCard(item: item)
                    }
                }
            }
        }
    }

    private var activityTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Activity timeline", systemImage: "circle.grid.cross")
            if capturedItems.isEmpty {
                EmptyDarkText("No timeline for this day.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(capturedItems.prefix(12)) { item in
                            TimelineBubble(item: item)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var dayEvents: [ActivityEvent] {
        model.activityJournal.filter { isSameJournalDay($0.timestamp, selectedDay) }
    }

    private var dayQueries: [QueryHistoryItem] {
        model.queryHistory.filter { isSameJournalDay($0.timestamp, selectedDay) }
    }

    private var dayNotes: [FinanceNote] {
        model.financeNotes.filter { isSameJournalDay($0.timestamp, selectedDay) }
    }

    private var dayFailures: [ActivityEvent] {
        dayEvents.filter { $0.outcome.localizedCaseInsensitiveContains("fail") }
    }

    private var capturedItems: [CapturedFinanceItem] {
        let eventItems = dayEvents.map { event in
            CapturedFinanceItem(
                id: "event-\(event.id)",
                timestamp: event.timestamp,
                kind: event.kind.capitalized,
                title: event.title,
                detail: event.detail,
                footer: event.outcome,
                systemImage: iconFor(kind: event.kind, outcome: event.outcome),
                color: colorFor(kind: event.kind, outcome: event.outcome)
            )
        }
        let queryItems = dayQueries.map { query in
            CapturedFinanceItem(
                id: "query-\(query.id)",
                timestamp: query.timestamp,
                kind: "Query",
                title: query.question,
                detail: query.answer,
                footer: query.outcome,
                systemImage: "bubble.left.and.text.bubble.right.fill",
                color: Color.purple
            )
        }
        let noteItems = dayNotes.map { note in
            CapturedFinanceItem(
                id: "note-\(note.id)",
                timestamp: note.timestamp,
                kind: "Note",
                title: note.text,
                detail: "Manual finance note",
                footer: "captured",
                systemImage: "note.text",
                color: AppTheme.green
            )
        }
        return (eventItems + queryItems + noteItems).sorted {
            (parseJournalDate($0.timestamp) ?? .distantPast) > (parseJournalDate($1.timestamp) ?? .distantPast)
        }
    }

    private var daySummary: String {
        if capturedItems.isEmpty {
            return "No finance work has been captured for this day yet. When you run audits, ask questions, check VM/RM sources, export reports, or add notes, this becomes the daily financial memory."
        }
        let topics = topicRows.prefix(3).map(\.label).joined(separator: ", ")
        let failed = dayFailures.count
        let failureText = failed == 0 ? "No failed items are logged." : "\(failed) item(s) need follow-up."
        return "Finance work centered on \(topics.isEmpty ? "connected evidence" : topics). The record contains \(capturedItems.count) captured item(s): \(dayEvents.count) system action(s), \(dayQueries.count) analyst search(es), and \(dayNotes.count) note(s). \(failureText)"
    }

    private var selectedDaySubtitle: String {
        "\(dayLabel(selectedDay)) · \(itemCount(for: selectedDay)) item(s) · \(monthDayLabel(selectedDay))"
    }

    private var topicRows: [FinanceTopic] {
        var counts: [String: Int] = [:]
        for event in dayEvents {
            counts[event.kind.capitalized, default: 0] += 1
            if event.outcome.localizedCaseInsensitiveContains("fail") {
                counts["Failed", default: 0] += 1
            }
        }
        if !dayQueries.isEmpty { counts["Query", default: 0] += dayQueries.count }
        if !dayNotes.isEmpty { counts["Notes", default: 0] += dayNotes.count }
        if model.journal.overview.totalExposure > 0 && Calendar.current.isDateInToday(selectedDay) {
            counts["At Risk", default: 0] += 1
        }
        if model.legacyBridge.isOperational && Calendar.current.isDateInToday(selectedDay) {
            counts["VM/RM", default: 0] += 1
        }
        let rows = counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(6)
            .map { FinanceTopic(label: $0.key, color: colorFor(topic: $0.key)) }
        if rows.isEmpty {
            return [FinanceTopic(label: "Finance", color: AppTheme.blue)]
        }
        return Array(rows)
    }

    private func itemCount(for day: Date) -> Int {
        model.activityJournal.filter { isSameJournalDay($0.timestamp, day) }.count
            + model.queryHistory.filter { isSameJournalDay($0.timestamp, day) }.count
            + model.financeNotes.filter { isSameJournalDay($0.timestamp, day) }.count
    }

    private func colorFor(kind: String, outcome: String) -> Color {
        if outcome.localizedCaseInsensitiveContains("fail") { return AppTheme.red }
        switch kind.lowercased() {
        case "query": return Color.purple
        case "note": return AppTheme.green
        case "audit": return AppTheme.orange
        case "legacy-bridge": return AppTheme.blue
        case "export", "share": return AppTheme.green
        default: return AppTheme.blue
        }
    }

    private func iconFor(kind: String, outcome: String) -> String {
        if outcome.localizedCaseInsensitiveContains("fail") { return "exclamationmark.triangle.fill" }
        switch kind.lowercased() {
        case "query": return "bubble.left.and.text.bubble.right.fill"
        case "note": return "note.text"
        case "audit": return "doc.text.magnifyingglass"
        case "legacy-bridge": return "display.and.arrow.down"
        case "export", "share": return "square.and.arrow.up"
        default: return "doc.badge.gearshape"
        }
    }

    private func colorFor(topic: String) -> Color {
        switch topic.lowercased() {
        case "failed": return AppTheme.red
        case "query": return Color.purple
        case "notes": return AppTheme.green
        case "at risk": return AppTheme.orange
        case "vm/rm": return AppTheme.blue
        default: return AppTheme.blue
        }
    }
}

// Persistent full-height calendar rail — its own column, exactly like LIST.

struct FinanceCalendarRail: View {
    @EnvironmentObject private var model: AuditModel
    @Binding var selectedDay: Date
    @State private var visibleMonth = Date()
    @State private var noteText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                calendarSection
                selectDaySection
                quickActionsSection
                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .frame(maxHeight: .infinity)
        .background(AppTheme.panel.opacity(0.45))
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    visibleMonth = shiftedMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)

                Text(monthYearLabel(visibleMonth))
                    .font(.system(size: 16, weight: .bold, design: .rounded))

                Spacer()

                Button {
                    visibleMonth = shiftedMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                ForEach(shortWeekdaySymbols(), id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppTheme.muted)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 5) {
                ForEach(monthGridDates(for: visibleMonth), id: \.self) { day in
                    FinanceCalendarDayCell(
                        day: day,
                        isSelected: isSelected(day),
                        isCurrentMonth: isSameMonth(day, visibleMonth),
                        isToday: Calendar.current.isDateInToday(day),
                        itemCount: itemCount(for: day),
                        action: {
                            selectedDay = day
                        }
                    )
                }
            }
        }
    }

    private var selectDaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SELECT DAY")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(AppTheme.muted)
                .tracking(0.8)
            ForEach(selectableDays, id: \.self) { day in
                FinanceDayListRow(
                    day: day,
                    count: itemCount(for: day),
                    isSelected: isSelected(day),
                    action: { selectedDay = day }
                )
            }
        }
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QUICK ACTIONS")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(AppTheme.muted)
                .tracking(0.8)
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(AppTheme.blue)
                TextField("New finance note", text: $noteText)
                    .textFieldStyle(.plain)
                    .onSubmit(saveNote)
            }
            .padding(10)
            .background(AppTheme.panel2.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("Add Note") { saveNote() }
                    .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Reveal") { model.revealFinanceNotes() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var selectableDays: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return daysInMonth(visibleMonth)
            .filter { $0 <= today || isSameMonth(visibleMonth, today) == false }
            .sorted(by: >)
            .prefix(14)
            .map { $0 }
    }

    private func saveNote() {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.addFinanceNote(trimmed)
        selectedDay = Date()
        noteText = ""
    }

    private func itemCount(for day: Date) -> Int {
        model.activityJournal.filter { isSameJournalDay($0.timestamp, day) }.count
            + model.queryHistory.filter { isSameJournalDay($0.timestamp, day) }.count
            + model.financeNotes.filter { isSameJournalDay($0.timestamp, day) }.count
    }

    private func isSelected(_ day: Date) -> Bool {
        Calendar.current.isDate(day, inSameDayAs: selectedDay)
    }

    private func shiftedMonth(_ delta: Int) -> Date {
        Calendar.current.date(byAdding: .month, value: delta, to: visibleMonth) ?? visibleMonth
    }
}

struct FinanceCalendarDayCell: View {
    let day: Date
    let isSelected: Bool
    let isCurrentMonth: Bool
    let isToday: Bool
    let itemCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(.system(size: 12, weight: isToday || isSelected ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? .white : (isCurrentMonth ? .white.opacity(0.88) : AppTheme.muted.opacity(0.55)))
                    .frame(width: 28, height: 28)
                    .background(isSelected ? AppTheme.blue : (isToday ? AppTheme.blue.opacity(0.20) : Color.clear), in: Circle())
                if itemCount > 0 {
                    Circle()
                        .fill(AppTheme.green)
                        .frame(width: 5, height: 5)
                        .offset(x: -3, y: -3)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .opacity(isCurrentMonth ? 1 : 0.45)
    }
}

struct FinanceDayListRow: View {
    let day: Date
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dayLabel(day))
                        .font(.system(size: 14, weight: .bold))
                    Text(monthDayLabel(day))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer()
                Text("\(count) item\(count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.muted)
            }
            .padding(11)
            .background(isSelected ? AppTheme.blue.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? AppTheme.blue.opacity(0.90) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct JournalHeaderMetric: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.muted)
        }
    }
}

struct CapturedFinanceCard: View {
    let item: CapturedFinanceItem

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(item.kind, systemImage: item.systemImage)
                    .font(.system(size: 10, weight: .black))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(item.color, in: Capsule())
                Spacer()
                Image(systemName: "ellipsis")
                    .foregroundStyle(AppTheme.muted)
            }
            Spacer(minLength: 4)
            Text(journalTime(item.timestamp))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(AppTheme.muted)
            Text(item.title)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(2)
            Text(item.detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.muted)
                .lineLimit(3)
            HStack {
                TopicChip(label: item.footer, color: item.color)
                Spacer()
            }
        }
        .padding(12)
        .frame(minHeight: 168, alignment: .topLeading)
        .background(AppTheme.panel2.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.stroke, lineWidth: 1))
    }
}

struct TimelineBubble: View {
    let item: CapturedFinanceItem

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(item.color)
                    .frame(width: 44, height: 44)
                Image(systemName: item.systemImage)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(journalTime(item.timestamp))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppTheme.muted)
                    if item.footer.localizedCaseInsensitiveContains("infer") {
                        Text("· inferred")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(AppTheme.orange)
                    }
                }
                Text(item.title)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                Text(item.kind)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .frame(width: 190, alignment: .leading)
    }
}

struct TopicChip: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.13), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.65), lineWidth: 1))
    }
}

struct LineageNode: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 82, alignment: .leading)
            Text("→")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppTheme.muted)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
