// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenClean",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "TestSupport",
            dependencies: ["ScanEngine", "ProcessKit", "Privilege", "Quarantine", "Updater"],
            path: "Packages/OpenCleanKit/Sources/TestSupport"
        ),
        .target(
            name: "ProcessKit",
            path: "Packages/OpenCleanKit/Sources/ProcessKit"
        ),
        .target(
            name: "Probes",
            dependencies: ["ScanEngine", "ProcessKit", "RuleKit"],
            path: "Packages/OpenCleanKit/Sources/Probes"
        ),
        .target(
            name: "RuleKit",
            dependencies: [.product(name: "Yams", package: "Yams")],
            path: "Packages/OpenCleanKit/Sources/RuleKit"
        ),
        .target(
            name: "ScanEngine",
            dependencies: ["RuleKit"],
            path: "Packages/OpenCleanKit/Sources/ScanEngine"
        ),
        .testTarget(
            name: "RuleKitTests",
            dependencies: ["RuleKit", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/RuleKitTests"
        ),
        .testTarget(
            name: "ScanEngineTests",
            dependencies: ["ScanEngine", "RuleKit", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/ScanEngineTests"
        ),
        .testTarget(
            name: "ProcessKitTests",
            dependencies: ["ProcessKit"],
            path: "Packages/OpenCleanKit/Tests/ProcessKitTests"
        ),
        .testTarget(
            name: "ProbesTests",
            dependencies: ["Probes", "ScanEngine", "ProcessKit", "RuleKit", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/ProbesTests"
        ),
        .target(
            name: "Privilege",
            dependencies: ["ProcessKit", "RuleKit"],
            path: "Packages/OpenCleanKit/Sources/Privilege"
        ),
        .testTarget(
            name: "PrivilegeTests",
            dependencies: ["Privilege", "ProcessKit", "RuleKit", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/PrivilegeTests"
        ),
        .target(
            name: "Quarantine",
            dependencies: ["RuleKit", "ScanEngine", "Privilege", "ProcessKit"],
            path: "Packages/OpenCleanKit/Sources/Quarantine"
        ),
        .testTarget(
            name: "QuarantineTests",
            dependencies: ["Quarantine", "RuleKit", "ScanEngine", "Privilege", "ProcessKit", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/QuarantineTests"
        ),
        .target(
            name: "AppInventory",
            dependencies: ["RuleKit", "ScanEngine", "ProcessKit"],
            path: "Packages/OpenCleanKit/Sources/AppInventory"
        ),
        .testTarget(
            name: "AppInventoryTests",
            dependencies: ["AppInventory", "Quarantine", "RuleKit", "ScanEngine", "ProcessKit", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/AppInventoryTests"
        ),
        .target(
            name: "SpaceKit",
            dependencies: ["RuleKit", "ScanEngine", "Quarantine"],
            path: "Packages/OpenCleanKit/Sources/SpaceKit"
        ),
        .testTarget(
            name: "SpaceKitTests",
            dependencies: ["SpaceKit", "Quarantine", "RuleKit", "ScanEngine", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/SpaceKitTests"
        ),
        .target(
            name: "Permissions",
            path: "Packages/OpenCleanKit/Sources/Permissions"
        ),
        .testTarget(
            name: "PermissionsTests",
            dependencies: ["Permissions", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/PermissionsTests"
        ),
        .target(
            name: "SystemMonitor",
            path: "Packages/OpenCleanKit/Sources/SystemMonitor"
        ),
        .testTarget(
            name: "SystemMonitorTests",
            dependencies: ["SystemMonitor"],
            path: "Packages/OpenCleanKit/Tests/SystemMonitorTests"
        ),
        .target(
            name: "Maintenance",
            dependencies: ["RuleKit", "ProcessKit", "Privilege", "Quarantine"],
            path: "Packages/OpenCleanKit/Sources/Maintenance"
        ),
        .testTarget(
            name: "MaintenanceTests",
            dependencies: ["Maintenance", "RuleKit", "ProcessKit", "Privilege", "Quarantine", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/MaintenanceTests"
        ),
        .target(
            name: "Updater",
            dependencies: ["ProcessKit", "RuleKit"],
            path: "Packages/OpenCleanKit/Sources/Updater"
        ),
        .testTarget(
            name: "UpdaterTests",
            dependencies: ["Updater", "ProcessKit", "RuleKit", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/UpdaterTests"
        ),
        .target(
            name: "OpenCleanKit",
            dependencies: [
                "RuleKit", "ScanEngine", "Probes", "Privilege", "Quarantine", "Permissions", "ProcessKit",
                "AppInventory", "SystemMonitor", "Maintenance", "SpaceKit", "Updater",
            ],
            path: "Packages/OpenCleanKit/Sources/OpenCleanKit"
        ),
        .testTarget(
            name: "OpenCleanKitTests",
            dependencies: [
                "OpenCleanKit", "RuleKit", "ScanEngine", "Probes", "Quarantine", "Permissions", "TestSupport",
                "AppInventory", "Maintenance", "SpaceKit", "Updater", "ProcessKit",
            ],
            path: "Packages/OpenCleanKit/Tests/OpenCleanKitTests"
        ),
        .target(
            name: "OpenCleanCLI",
            dependencies: [
                "OpenCleanKit", "RuleKit", "ScanEngine", "Quarantine", "Permissions", "AppInventory", "SpaceKit",
                "SystemMonitor", .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Apps/openclean-cli/Sources/OpenCleanCLI"
        ),
        .executableTarget(
            name: "openclean",
            dependencies: ["OpenCleanCLI"],
            path: "Apps/openclean-cli/Sources/openclean"
        ),
        .testTarget(
            name: "OpenCleanCLITests",
            dependencies: [
                "OpenCleanCLI", "OpenCleanKit", "RuleKit", "ScanEngine", "Quarantine", "AppInventory", "SpaceKit",
                "SystemMonitor", "TestSupport",
            ],
            path: "Apps/openclean-cli/Tests/OpenCleanCLITests",
            exclude: ["Golden"]
        ),
        .target(
            name: "OpenCleanAppModel",
            dependencies: [
                "OpenCleanKit", "RuleKit", "ScanEngine", "Quarantine", "Permissions", "AppInventory", "SystemMonitor",
                "Maintenance", "SpaceKit", "Updater",
            ],
            path: "Apps/OpenClean/Sources/OpenCleanAppModel"
        ),
        .testTarget(
            name: "OpenCleanAppModelTests",
            dependencies: [
                "OpenCleanAppModel", "OpenCleanKit", "RuleKit", "ScanEngine", "Permissions", "TestSupport",
                "AppInventory", "SystemMonitor", "Maintenance", "SpaceKit", "Updater",
            ],
            path: "Apps/OpenClean/Tests/OpenCleanAppModelTests"
        ),
        .testTarget(
            name: "OpenCleanAppUITests",
            dependencies: [
                "OpenCleanApp", "OpenCleanAppModel", "OpenCleanKit", "RuleKit", "ScanEngine", "Quarantine",
                "Permissions", "TestSupport", "Updater",
            ],
            path: "Apps/OpenClean/Tests/OpenCleanAppUITests"
        ),
        .executableTarget(
            name: "OpenCleanApp",
            dependencies: [
                "OpenCleanAppModel", "OpenCleanKit", "RuleKit", "ScanEngine", "Quarantine", "Permissions",
                "AppInventory", "SystemMonitor", "Maintenance", "SpaceKit", "Updater",
            ],
            path: "Apps/OpenClean/Sources/OpenCleanApp"
        ),
    ]
)
