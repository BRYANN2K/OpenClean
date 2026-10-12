// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenClean",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "TestSupport",
            dependencies: ["ScanEngine", "ProcessKit", "Privilege", "Quarantine"],
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
            dependencies: ["Probes", "ScanEngine", "ProcessKit", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/ProbesTests"
        ),
        .target(
            name: "Privilege",
            dependencies: ["ProcessKit"],
            path: "Packages/OpenCleanKit/Sources/Privilege"
        ),
        .testTarget(
            name: "PrivilegeTests",
            dependencies: ["Privilege", "ProcessKit", "TestSupport"],
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
            name: "Permissions",
            path: "Packages/OpenCleanKit/Sources/Permissions"
        ),
        .testTarget(
            name: "PermissionsTests",
            dependencies: ["Permissions", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/PermissionsTests"
        ),
        .target(
            name: "OpenCleanKit",
            dependencies: ["RuleKit", "ScanEngine", "Probes", "Privilege", "Quarantine", "Permissions", "ProcessKit"],
            path: "Packages/OpenCleanKit/Sources/OpenCleanKit"
        ),
        .testTarget(
            name: "OpenCleanKitTests",
            dependencies: ["OpenCleanKit", "RuleKit", "ScanEngine", "Probes", "Quarantine", "Permissions", "TestSupport"],
            path: "Packages/OpenCleanKit/Tests/OpenCleanKitTests"
        ),
    ]
)
