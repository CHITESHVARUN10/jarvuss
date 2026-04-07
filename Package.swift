// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JarvisMacOS",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "jarvis", targets: ["JarvisMacOS"])
    ],
    targets: [
        .executableTarget(
            name: "JarvisMacOS",
            path: "Sources/JarvisMacOS"
        ),
        .testTarget(
            name: "JarvisMacOSTests",
            dependencies: ["JarvisMacOS"],
            path: "Tests/JarvisMacOSTests"
        )
    ]
)