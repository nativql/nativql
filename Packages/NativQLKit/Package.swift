// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NativQLKit",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NativQLKit"),
        .testTarget(name: "NativQLKitTests", dependencies: ["NativQLKit"]),
    ]
)
