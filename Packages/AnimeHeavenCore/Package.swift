// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnimeHeavenCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AnimeHeavenCore",
            targets: ["AnimeHeavenCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.5")
    ],
    targets: [
        .target(
            name: "AnimeHeavenCore",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AnimeHeavenCoreSelfTest",
            dependencies: ["AnimeHeavenCore"]
        ),
        .testTarget(
            name: "AnimeHeavenCoreTests",
            dependencies: ["AnimeHeavenCore"]
        )
    ]
)
