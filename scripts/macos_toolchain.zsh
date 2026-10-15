# Shared by native builds and STT tests. Keep consistent with Package.swift,
# Info.plist and .cargo/config.toml.
export MACOSX_DEPLOYMENT_TARGET=26.0
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC="$(xcrun --sdk macosx --find clang)"
export CXX="$(xcrun --sdk macosx --find clang++)"
