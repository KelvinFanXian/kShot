// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KShot",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "KShot", targets: ["KShot"])
    ],
    targets: [
        .executableTarget(
            name: "KShot",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(
            name: "KShotTests",
            dependencies: ["KShot"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
