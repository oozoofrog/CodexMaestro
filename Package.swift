// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "CodexMaestro",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexMaestro", targets: ["CodexMaestro"]), .executable(name: "MaestroProbe", targets: ["MaestroProbe"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "MaestroCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "CodexMaestro", dependencies: ["MaestroCore"]),
        .executableTarget(name: "MaestroProbe", dependencies: ["MaestroCore"]),
        .testTarget(name: "MaestroCoreTests", dependencies: ["MaestroCore", "CSQLite"]),
        .testTarget(name: "MaestroAppTests", dependencies: ["CodexMaestro", "MaestroCore"])
    ], swiftLanguageModes: [.v5]
)
