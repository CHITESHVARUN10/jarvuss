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
        // C shim that exposes private IOAVService symbols for DDC/CI on Apple Silicon.
        .target(
            name: "CDDCShim",
            path: "Sources/CDDCShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "JarvisMacOS",
            dependencies: ["CDDCShim"],
            path: "Sources/JarvisMacOS"
        ),
        .testTarget(
            name: "JarvisMacOSTests",
            dependencies: ["JarvisMacOS"],
            path: "Tests/JarvisMacOSTests"
        )
    ]
)