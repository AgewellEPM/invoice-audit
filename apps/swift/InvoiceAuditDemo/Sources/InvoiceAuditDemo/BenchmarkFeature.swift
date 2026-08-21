// BenchmarkFeature.swift
// "Overpay vs industry standards" + "How we saved you money".
//
// This is intentionally a SEPARATE file from the (already oversized)
// InvoiceAuditDemoApp.swift monolith — new feature surface goes in its own
// file. It adds: (1) an AuditModel extension that drives kist research through
// the python CLI, and (2) two SwiftUI panels that read the receipt the audit
// already produced. The overpay numbers here are the DETERMINISTIC market
// verdicts from the engine; kist only researches the reference price. Nothing
// on this screen decides money.
//
// FOLLOW-UP: InvoiceAuditDemoApp.swift is a hard-stop monolith and still needs
// a split plan (views/model/decoding into separate files). This feature was
// added without piling onto it; that split is tracked separately.

import SwiftUI
import Foundation

// MARK: - Model: kist research data flow

extension AuditModel {
    /// Refresh the industry-benchmark cache by researching every audited item
    /// with kist, then re-run the deterministic overpay check against it.
    /// Cache-aware: reuses fresh researched prices unless `force`.
    func refreshBenchmarks(force: Bool = false) async {
        guard !benchmarkIsRunning else { return }
        guard FileManager.default.fileExists(atPath: receiptURL.path) else {
            benchmarkStatus = "Run an audit first — kist benchmarks the items you actually bought."
            return
        }
        benchmarkIsRunning = true
        benchmarkStatus = force
            ? "Forcing fresh kist research (best models, cross-compared)…"
            : "Researching industry pricing with kist (best models, cross-compared)…"
        do {
            try FileManager.default.createDirectory(at: benchmarksDir, withIntermediateDirectories: true)
            var args = ["-m", "invoice_audit", "benchmark-refresh",
                        "--receipt", receiptURL.path,
                        "--cache-dir", benchmarksDir.path,
                        "--region", benchmarkRegion,
                        "--mode", "dig", "--json"]
            if force { args.append("--force") }
            let out = try await runPython(args)
            let s = Self.parseBenchmarkSummary(out)
            if s.priced > 0 {
                // Point the deterministic auditor at the researched prices and
                // re-audit — the overpay flags come from the engine, not kist.
                marketURL = benchmarksDir.appendingPathComponent("market-pricebook.csv")
                await runAudit()
                let src = s.kistAvailable ? "kist" : "fixture"
                benchmarkStatus = "\(src) priced \(s.priced) item(s) · \(s.failures) unpriced (kept as 'no industry reference') · overpay checked below."
            } else if !s.kistAvailable {
                benchmarkStatus = "kist binary not on PATH — enable kist to research industry pricing. Nothing invented; items stay 'no industry reference'."
            } else {
                benchmarkStatus = "kist found no defensible price for these items (\(s.failures) unpriced). Nothing invented."
            }
        } catch {
            benchmarkStatus = "Benchmark refresh failed: \(error.localizedDescription)"
        }
        benchmarkIsRunning = false
    }

    /// Force a fresh live kist dig for ONE item, then re-check overpay.
    func checkBenchmarkLive(sku: String, description: String) async {
        guard !benchmarkIsRunning else { return }
        benchmarkIsRunning = true
        let label = sku.isEmpty ? description : sku
        benchmarkStatus = "Live kist dig for \(label)…"
        do {
            let out = try await runPython([
                "-m", "invoice_audit", "benchmark-item",
                "--sku", sku, "--description", description,
                "--cache-dir", benchmarksDir.path,
                "--region", benchmarkRegion, "--mode", "dig"])
            if let data = out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if (obj["ok"] as? Bool) == true {
                    marketURL = benchmarksDir.appendingPathComponent("market-pricebook.csv")
                    await runAudit()
                    let price = obj["unit_price_usd"] as? Double ?? 0
                    benchmarkStatus = "Live kist median for \(label): \(dollars(price)). Overpay re-checked below."
                } else {
                    benchmarkStatus = "Live kist could not price \(label): \(obj["reason"] as? String ?? "unknown"). Nothing invented."
                }
            } else {
                benchmarkStatus = "Live kist returned unexpected output."
            }
        } catch {
            benchmarkStatus = "Live kist failed: \(error.localizedDescription)"
        }
        benchmarkIsRunning = false
    }

    struct BenchmarkSummary {
        var priced = 0
        var failures = 0
        var researched = 0
        var reused = 0
        var kistAvailable = false
    }

    static func parseBenchmarkSummary(_ output: String) -> BenchmarkSummary {
        var s = BenchmarkSummary()
        guard let start = output.range(of: "{"),
              let data = String(output[start.lowerBound...]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return s }
        s.priced = obj["priced"] as? Int ?? 0
        s.researched = obj["researched"] as? Int ?? 0
        s.reused = obj["reused"] as? Int ?? 0
        s.kistAvailable = obj["kistAvailable"] as? Bool ?? false
        s.failures = (obj["failures"] as? [[String: Any]])?.count ?? 0
        return s
    }
}

// MARK: - Deterministic savings story (computed from the receipt only)

struct SavingsSummary {
    let invoices: Int
    let flags: Int
    let priceHistory: Double
    let industry: Double
    let policy: Double
    let itemsSurfaced: Int
    let headline: String

    // HARD RULE — no ML touches the banked number. Banked = DETERMINISTIC-fact
    // sources only (own price history + taught policy floor). The kist-researched
    // industry benchmark is ML-retrieved — a review signal, NEVER banked.
    var moneyCaught: Double { max(priceHistory, 0) + max(policy, 0) }
    var industryReviewSignal: Double { max(industry, 0) }

    init(receipt: ReceiptSummary) {
        let t = receipt.totals
        invoices = t.invoices
        flags = t.flagged
        priceHistory = t.potentialOvercharge
        industry = t.marketOvercharge
        policy = t.policyOverage
        let surfaced: Set<String> = ["no-reference", "market-no-reference", "ungrounded", "weak-grounding"]
        itemsSurfaced = receipt.findings.filter { surfaced.contains($0.kind) }.count

        // Banked = deterministic-only; ML industry figure is NEVER folded in.
        let caught = max(t.potentialOvercharge, 0) + max(t.policyOverage, 0)
        if t.flagged == 0 {
            headline = "Reviewed \(t.invoices) invoice(s) and found nothing to recover — clean, and now proven with a signed receipt."
        } else {
            var parts = ["Found \(t.flagged) issue(s) across \(t.invoices) invoice(s) — \(dollars(caught)) in deterministic, sourced overpay exposure"]
            if t.marketOvercharge > 0 {
                parts.append("plus \(dollars(t.marketOvercharge)) flagged above industry pricing to review (kist estimate — not banked)")
            }
            if itemsSurfaced > 0 {
                parts.append("and surfaced \(itemsSurfaced) item(s) you'd otherwise have missed")
            }
            headline = parts.joined(separator: " — ") + "."
        }
    }
}

// MARK: - Views

struct FinanceValueSection: View {
    var body: some View {
        VStack(spacing: 18) {
            SavingsDashboardPanel()
            MarketBenchmarkPanel()
        }
    }
}

struct SavingsDashboardPanel: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        DarkPanel {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "How we saved you money", systemImage: "sparkles")
                if let receipt = model.receipt {
                    let s = SavingsSummary(receipt: receipt)
                    Text(s.headline)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 14) {
                        SavingsStat(label: "BANKED (SOURCED)", value: dollars(s.moneyCaught),
                                    color: s.moneyCaught > 0 ? AppTheme.green : AppTheme.muted)
                        SavingsStat(label: "FLAGS FOUND", value: "\(s.flags)",
                                    color: s.flags > 0 ? AppTheme.orange : AppTheme.green)
                        SavingsStat(label: "YOU'D HAVE MISSED", value: "\(s.itemsSurfaced)",
                                    color: AppTheme.blue)
                    }

                    // Banked = deterministic-fact sources ONLY. No ML dollar here.
                    VStack(alignment: .leading, spacing: 8) {
                        SavingsBreakdownRow(label: "Price-history overcharge",
                                            value: s.priceHistory, total: s.moneyCaught, color: AppTheme.red)
                        SavingsBreakdownRow(label: "Policy overage",
                                            value: s.policy, total: s.moneyCaught, color: Color.purple)
                    }
                    Text("Banked = deterministic, sourced flags only (own price history + taught policy), bound into a signed, re-verifiable receipt — never an ML estimate.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.muted)

                    // ML-retrieved industry overpay — a REVIEW SIGNAL, never banked.
                    if s.industryReviewSignal > 0 {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .foregroundStyle(AppTheme.orange)
                            Text("Review signal · above industry pricing — kist-researched (ML), NOT banked")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(AppTheme.orange)
                            Spacer()
                            Text(dollars(s.industryReviewSignal))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(AppTheme.orange)
                        }
                        .padding(9)
                        .background(AppTheme.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppTheme.orange.opacity(0.4), lineWidth: 1))
                    }
                } else {
                    EmptyDarkText("Run an audit to see the savings story: what we caught, what you'd have missed, and how much money it protected.")
                }
            }
        }
    }
}

struct SavingsStat: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(AppTheme.muted)
                .tracking(0.6)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppTheme.panel2.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.stroke, lineWidth: 1))
    }
}

struct SavingsBreakdownRow: View {
    let label: String
    let value: Double
    let total: Double
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
            Spacer()
            GeometryReader { geo in
                let fraction = total > 0 ? max(0, min(1, value / total)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.panel2).frame(height: 6)
                    Capsule().fill(color).frame(width: geo.size.width * fraction, height: 6)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 120, height: 12)
            Text(dollars(value))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(value > 0 ? color : AppTheme.muted)
                .frame(width: 90, alignment: .trailing)
        }
    }
}

struct MarketBenchmarkPanel: View {
    @EnvironmentObject private var model: AuditModel

    var body: some View {
        DarkPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Overpay vs industry standards", systemImage: "chart.bar.doc.horizontal")
                    Spacer()
                    Button {
                        Task { await model.refreshBenchmarks() }
                    } label: {
                        Label(model.benchmarkIsRunning ? "Researching…" : "Refresh benchmarks (kist)",
                              systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.benchmarkIsRunning)

                    Button {
                        Task { await model.refreshBenchmarks(force: true) }
                    } label: {
                        Label("Force live", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.benchmarkIsRunning)
                }

                Text("kist researches the fair-market unit price for every item you bought — asking multiple models and cross-comparing — then the engine deterministically flags where you're paying above it.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Text(model.benchmarkStatus)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.benchmarkIsRunning ? AppTheme.blue : AppTheme.muted)

                if let receipt = model.receipt {
                    HStack {
                        Text("ABOVE INDUSTRY (TOTAL)")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(AppTheme.muted)
                            .tracking(0.6)
                        Spacer()
                        Text(dollars(receipt.totals.marketOvercharge))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(receipt.totals.marketOvercharge > 0 ? AppTheme.red : AppTheme.green)
                    }
                    .padding(.vertical, 4)

                    let rows = benchmarkRows(receipt)
                    if rows.isEmpty {
                        EmptyDarkText("No industry benchmarks yet. Press “Refresh benchmarks (kist)” to research market pricing for the items you bought.")
                    } else {
                        VStack(spacing: 8) {
                            MarketBenchmarkHeader()
                            ForEach(rows) { row in
                                MarketBenchmarkRow(row: row) {
                                    Task { await model.checkBenchmarkLive(sku: row.sku, description: row.description) }
                                }
                            }
                        }
                    }
                } else {
                    EmptyDarkText("Run an audit first, then refresh benchmarks to compare your prices against industry standards.")
                }
            }
        }
    }

    private func benchmarkRows(_ receipt: ReceiptSummary) -> [BenchmarkRowData] {
        var rows: [BenchmarkRowData] = []
        for invoice in receipt.invoices {
            for line in invoice.lines {
                rows.append(BenchmarkRowData(
                    id: "\(invoice.file)-\(line.id)",
                    file: invoice.file, sku: line.sku, description: line.description,
                    paid: line.unitPrice, marketMedian: line.marketReferenceMedian,
                    overpay: line.marketExposure, verdict: line.marketVerdict))
            }
        }
        // Overpays first, then unpriced, then within-market.
        return rows.sorted { lhs, rhs in
            if lhs.overpay != rhs.overpay { return lhs.overpay > rhs.overpay }
            return lhs.paid > rhs.paid
        }
    }
}

struct BenchmarkRowData: Identifiable {
    let id: String
    let file: String
    let sku: String
    let description: String
    let paid: Double
    let marketMedian: Double?
    let overpay: Double
    let verdict: String
}

struct MarketBenchmarkHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("ITEM").frame(maxWidth: .infinity, alignment: .leading)
            Text("PAID").frame(width: 80, alignment: .trailing)
            Text("INDUSTRY").frame(width: 90, alignment: .trailing)
            Text("OVERPAY").frame(width: 90, alignment: .trailing)
            Text("").frame(width: 64)
        }
        .font(.system(size: 9, weight: .black))
        .foregroundStyle(AppTheme.muted)
        .tracking(0.5)
    }
}

struct MarketBenchmarkRow: View {
    let row: BenchmarkRowData
    let liveAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.sku.isEmpty ? row.description : row.sku)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                Text(row.file)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(dollars(row.paid))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 80, alignment: .trailing)

            Text(row.marketMedian.map(dollars) ?? "—")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(row.marketMedian == nil ? AppTheme.muted : .white.opacity(0.85))
                .frame(width: 90, alignment: .trailing)

            Text(row.overpay > 0 ? dollars(row.overpay) : (row.marketMedian == nil ? "no ref" : "ok"))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(overpayColor)
                .frame(width: 90, alignment: .trailing)

            Button(action: liveAction) {
                Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: 64)
            .help("Force a fresh live kist dig for this item")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(row.overpay > 0 ? AppTheme.red.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var overpayColor: Color {
        if row.overpay > 0 { return AppTheme.red }
        if row.marketMedian == nil { return AppTheme.orange }
        return AppTheme.green
    }
}
