// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NativQLKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NativQLKit", targets: ["NativQLKit"]),
    ],
    targets: [
        .target(name: "NativQLKit"),
        .testTarget(name: "NativQLKitTests", dependencies: ["NativQLKit"]),
    ]
)
