// swift-tools-version: 6.0
import PackageDescription

// Not named "StickerKit": Apple ships an (empty, SPI-only) [system] StickerKit module in the iOS device and macOS SDKs
// but not in the simulator SDK, so a shadowing module would fail differently on device and simulator.
let package = Package(
    name: "StickerizeKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // Storage, decoding and sticker normalization. Safe for every extension (no Vision).
        .library(name: "StickerizeKit", targets: ["StickerizeKit"]),
        // Vision subject lifting and outlines. Used by the app, the Share extension and the CLI.
        .library(name: "StickerLift", targets: ["StickerLift"]),
        // WhatsApp / Telegram sticker-pack payloads (WebP via libwebp) and Signal Desktop pack prep. Used by the app and CLI.
        .library(name: "StickerExport", targets: ["StickerExport"]),
        .executable(name: "stickerize", targets: ["stickerize"]),
    ],
    dependencies: [
        // ImageIO decodes WebP but can't encode it (checked on iOS 27.2 and macOS 27.2). BSD-3-Clause.
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", exact: "1.6.0"),
    ],
    targets: [
        .target(name: "StickerizeKit"),
        .target(name: "StickerLift", dependencies: ["StickerizeKit"]),
        .target(name: "StickerExport", dependencies: [
            "StickerizeKit",
            .product(name: "libwebp", package: "libwebp-Xcode"),
        ]),
        .executableTarget(name: "stickerize", dependencies: ["StickerizeKit", "StickerLift", "StickerExport"]),
        .testTarget(name: "StickerizeKitTests", dependencies: ["StickerizeKit"]),
        .testTarget(name: "StickerLiftTests", dependencies: ["StickerizeKit", "StickerLift"]),
        .testTarget(name: "StickerExportTests", dependencies: ["StickerizeKit", "StickerExport"]),
    ]
)
