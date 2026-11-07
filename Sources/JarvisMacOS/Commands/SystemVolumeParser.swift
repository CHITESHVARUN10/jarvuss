import Foundation

/// Pure volume interpretation lives in Rust; CoreAudio execution remains native.
enum SystemVolumeParser {
    static func route(_ raw: String) -> PlannedAction? {
        coreParseSystemVolume(raw: raw).flatMap(RustPipeline.map)
    }
    static func number(_ raw: String) -> Int? {
        coreParseVolumeNumber(raw: raw).map(Int.init)
    }
}
