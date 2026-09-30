// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KShot",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "KShot", targets: ["KShot"])
    ],
    dependencies: [
        .package(path: "Vendor/onnxruntime")
    ],
    targets: [
        .executableTarget(
            name: "KShot",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KShotTests",
            dependencies: ["KShot"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
