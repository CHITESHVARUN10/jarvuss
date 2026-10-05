import Foundation

/// Single home for edit-distance fuzzy matching. Replaces three
/// copy-pasted Levenshtein implementations (AppState, AppController,
/// JarvisFileManager) that had drifted apart — including an empty-string
/// crash (`1...0` range) the copies all shared.
enum StringDistance {
    /// Levenshtein edit distance between two strings. Safe on empty input.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aArr = Array(a)
        let bArr = Array(b)
        guard !aArr.isEmpty else { return bArr.count }
        guard !bArr.isEmpty else { return aArr.count }

        var dist = Array(
            repeating: Array(repeating: 0, count: bArr.count + 1),
            count: aArr.count + 1
        )
        for i in 0...aArr.count { dist[i][0] = i }
        for j in 0...bArr.count { dist[0][j] = j }
        for i in 1...aArr.count {
            for j in 1...bArr.count {
                let cost = aArr[i - 1] == bArr[j - 1] ? 0 : 1
                dist[i][j] = Swift.min(
                    dist[i - 1][j] + 1,
                    Swift.min(dist[i][j - 1] + 1, dist[i - 1][j - 1] + cost)
                )
            }
        }
        return dist[aArr.count][bArr.count]
    }

    /// Normalized similarity in 0...1 (1 = identical).
    static func similarity(_ a: String, _ b: String) -> Double {
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1.0 }
        return max(0.0, 1.0 - Double(levenshtein(a, b)) / Double(maxLen))
    }
}
