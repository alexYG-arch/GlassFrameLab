// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GlassFrameLab",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GlassFrameLab", targets: ["GlassFrameLab"])],
    targets: [
        .target(name: "LabSupport"),
        .executableTarget(name: "GlassFrameLab", dependencies: ["LabSupport"]),
        .executableTarget(name: "LabSupportChecks", dependencies: ["LabSupport"], path: "Tests/LabSupportTests"),
        .executableTarget(name: "LifecycleChecks", dependencies: ["LabSupport"], path: "Tests/LifecycleChecks")
    ]
)
