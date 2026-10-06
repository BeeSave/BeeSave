// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BeeSave",
    platforms: [.macOS("26.0")],
    products: [.library(name: "BudgetCore", targets: ["BudgetCore"]), .library(name: "BudgetPresentation", targets: ["BudgetPresentation"])],
    targets: [
        .target(name: "CArgon2", path: "Vendor/Argon2", sources: ["src/argon2.c", "src/core.c", "src/encoding.c", "src/ref.c", "src/thread.c", "src/blake2/blake2b.c"], publicHeadersPath: "include", cSettings: [.headerSearchPath("src"), .define("ARGON2_NO_THREADS")]),
        .target(name: "BudgetCore", dependencies: ["CArgon2"], resources: [.process("Resources")]),
        .target(name: "BudgetPresentation", dependencies: ["BudgetCore"]),
        .testTarget(name: "BudgetCoreTests", dependencies: ["BudgetCore"]),
        .testTarget(name: "BudgetPresentationTests", dependencies: ["BudgetPresentation"])
    ],
    swiftLanguageModes: [.v5]
)
