import Foundation

/// Grapheme-aware edit distance owned by the Rust core.
enum StringDistance {
    static func levenshtein(_ a: String, _ b: String) -> Int {
        Int(coreLevenshtein(a: a, b: b))
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        coreSimilarity(a: a, b: b)
    }
}
