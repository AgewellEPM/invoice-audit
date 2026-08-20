// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InvoiceAuditDemo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "InvoiceAuditDemo", targets: ["InvoiceAuditDemo"])
    ],
    targets: [
        .executableTarget(name: "InvoiceAuditDemo")
    ]
)
