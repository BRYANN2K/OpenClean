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
            dependencies: ["ScanEngine"],
            path: "Packages/OpenCleanKit/Sources/TestSupport"
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
    ]
)
