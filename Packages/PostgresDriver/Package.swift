// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PostgresDriver",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PostgresDriver", targets: ["PostgresDriver"])],
    dependencies: [
        .package(path: "../NativQLKit"),
    ],
    targets: [
        .target(name: "PostgresDriver", dependencies: [
            .product(name: "NativQLKit", package: "NativQLKit"),
        ]),
    ]
)
