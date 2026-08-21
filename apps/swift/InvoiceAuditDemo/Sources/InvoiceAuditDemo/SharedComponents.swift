import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

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

struct MorningMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(color)
                .tracking(0.8)
            Text(value)
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(detail)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .background(AppTheme.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(color.opacity(0.42), lineWidth: 1)
        )
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
