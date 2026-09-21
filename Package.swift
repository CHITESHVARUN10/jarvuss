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
            dependencies: ["CDDCShim", "STTCore"],
            path: "Sources/JarvisMacOS",
            linkerSettings: [
                // Native frameworks required by the STT staticlib
                // (whisper.cpp/Metal, cpal/CoreAudio, arboard) + Carbon hotkey.
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
                // whisper.cpp is C++ — the static archive needs libc++.
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "JarvisMacOSTests",
            dependencies: ["JarvisMacOS"],
            path: "Tests/JarvisMacOSTests"
        ),
        // Prebuilt Rust STT core (whisper.cpp + Metal). Rebuild via
        // ./scripts/build_stt.sh [--release] — never checked in.
        .binaryTarget(
            name: "STTCore",
            path: "STTCore.xcframework"
        ),
    ]
)