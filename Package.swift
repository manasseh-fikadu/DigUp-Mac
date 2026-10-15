// swift-tools-version: 6.2
import PackageDescription

// One native macOS app, one indexing/query helper, and Apple's system frameworks.
let vendor = "\(Context.packageDirectory)/Vendor"

let package = Package(
    name: "DigUp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DigUpApp", targets: ["DigUpApp"]),
        .executable(name: "digup", targets: ["digup"]),
        .library(name: "DigUpKit", targets: ["DigUpKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "DigUpKit"),
        // Static llama.cpp with Metal; scripts/build-llama.sh prepares Vendor/llama.
        .systemLibrary(name: "CLlama"),
        .target(name: "LlamaRuntime", dependencies: ["CLlama", "DigUpKit"],
                linkerSettings: [.unsafeFlags(["-L\(vendor)/llama/lib"])]),
        .executableTarget(name: "digup", dependencies: ["DigUpKit", "LlamaRuntime"]),
        // A different executable name avoids colliding with digup on case-insensitive disks.
        .executableTarget(
            name: "DigUpApp",
            dependencies: ["DigUpKit", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "DigUpKitTests", dependencies: ["DigUpKit"], exclude: ["Pictures", "Videos"]),
        .testTarget(name: "LlamaRuntimeTests", dependencies: ["LlamaRuntime"], exclude: ["Reference"]),
        .testTarget(name: "DigUpAppTests", dependencies: ["DigUpApp"]),
    ]
)
