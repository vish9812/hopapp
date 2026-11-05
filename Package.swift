// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "hopapp",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "hopapp", targets: ["hopapp"]),
        .executable(name: "hopappDiagnostic", targets: ["hopappDiagnostic"]),
    ],
    targets: [
        .target(name: "DiagnosticCore"),
        .executableTarget(name: "hopapp", dependencies: ["DiagnosticCore"]),
        .executableTarget(name: "hopappDiagnostic", dependencies: ["DiagnosticCore"]),
        .testTarget(name: "hopappTests", dependencies: ["hopapp", "DiagnosticCore"]),
    ]
)
