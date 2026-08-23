// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MySQLDriver",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MySQLDriver", targets: ["MySQLDriver"])],
    dependencies: [
        .package(path: "../NativQLKit"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "MySQLDriver", dependencies: [
            .product(name: "MySQLNIO", package: "mysql-nio"),
            .product(name: "NativQLKit", package: "NativQLKit"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .testTarget(name: "MySQLDriverTests", dependencies: [
            .product(name: "NativQLKit", package: "NativQLKit"),
            "MySQLDriver",
        ]),
    ]
)
