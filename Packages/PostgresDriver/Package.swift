// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PostgresDriver",
    platforms: [.macOS(.v14)],
    products: [.library(name: "PostgresDriver", targets: ["PostgresDriver"])],
    dependencies: [
        .package(path: "../NativQLKit"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.25.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "PostgresDriver", dependencies: [
            .product(name: "NativQLKit", package: "NativQLKit"),
            .product(name: "PostgresNIO", package: "postgres-nio"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .testTarget(name: "PostgresDriverTests", dependencies: [
            .product(name: "NativQLKit", package: "NativQLKit"),
            "PostgresDriver",
        ]),
    ]
)
