import SwiftUI
import AppKit
import Foundation
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
