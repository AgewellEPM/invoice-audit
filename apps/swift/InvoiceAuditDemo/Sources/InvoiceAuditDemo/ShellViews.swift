import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

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
                VStack(alignment: .leading, spacing: 0) {
                    Text("FINANCIAL")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("OPS COPILOT")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.blue)
                }
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
                Text("AREAS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.muted)
                ForEach(WorkflowStep.allCases) { item in
                    Button {
                        selected = item
                    } label: {
                        HStack(spacing: 10) {
                            Text(item.badge)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .frame(width: item == .pulse ? 50 : 24, height: 22)
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
                Text("Search money, vendors, jobs, findings, and memory...")
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
