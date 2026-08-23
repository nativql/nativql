// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MySQLDriver",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MySQLDriver", targets: ["MySQLDriver"])],
    dependencies: [
        .package(path: "../NativQLKit"),
    ],
    targets: [
        .target(name: "MySQLDriver", dependencies: [
            .product(name: "NativQLKit", package: "NativQLKit"),
        ]),
    ]
)
