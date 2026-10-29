// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AllDrop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AllDrop", targets: ["AllDrop"]),
        .library(name: "QuickShare", targets: ["QuickShare"]),
    ],
    dependencies: [
        // Keep in step with the protoc-gen-swift that generated Sources/QuickShare/Generated.
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
    ],
    targets: [
        .target(
            name: "QuickShare",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AllDrop",
            dependencies: ["QuickShare"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "QuickShareTests",
            dependencies: ["QuickShare"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
