import Foundation

/// Deterministic test environment for the command pipeline.
///
/// The pipeline delegates rule decisions (validator, safety, planner fast
/// paths) to the Rust core when `JARVIS_RUST_PIPELINE=1` or the matching
/// UserDefaults flag is on. Without pinning, a suite silently exercises a
/// different engine on each machine. Suites that assert Swift-engine
/// behavior call `pinRustPipelineOff()` in `setUp` and restore in
/// `tearDown`.
enum TestSupport {
    static func pinRustPipelineOff() {
        setenv("JARVIS_RUST_PIPELINE", "0", 1)
    }

    static func unpinRustPipeline() {
        unsetenv("JARVIS_RUST_PIPELINE")
    }
}
