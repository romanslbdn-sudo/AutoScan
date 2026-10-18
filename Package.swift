// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AutoScan",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AutoScan", targets: ["AutoScan"])
    ],
    targets: [
        // Логіка без інтерфейсу: протокол ELM327/OBD2, розбір відповідей, база помилок.
        .target(
            name: "AutoScanCore",
            path: "Sources/AutoScanCore"
        ),
        // Сама програма для macOS (SwiftUI).
        .executableTarget(
            name: "AutoScan",
            dependencies: ["AutoScanCore"],
            path: "Sources/AutoScan"
        ),
        .testTarget(
            name: "AutoScanCoreTests",
            dependencies: ["AutoScanCore"],
            path: "Tests/AutoScanCoreTests"
        )
    ]
)
