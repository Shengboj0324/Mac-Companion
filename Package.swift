// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Companion",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
        .executable(name: "Companion", targets: ["CompanionApp"]),
    ],
    targets: [
        // Platform-neutral domain logic: persistence, indexing, memory, policy,
        // providers, Google connectors, calendar, organization. No UI code.
        .target(
            name: "CompanionCore",
            path: "Sources/CompanionCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
                .linkedFramework("PDFKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("CoreServices"),
            ]
        ),
        // Native AppKit + SwiftUI shell: floating companion, workspace panel,
        // onboarding, approvals. Thin layer over CompanionCore.
        .executableTarget(
            name: "CompanionApp",
            dependencies: ["CompanionCore"],
            path: "Sources/CompanionApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("Quartz"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "CompanionCoreTests",
            dependencies: ["CompanionCore"],
            path: "Tests/CompanionCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
