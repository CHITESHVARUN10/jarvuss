import XCTest
@testable import JarvisMacOS

final class StringDistanceTests: XCTestCase {
    func testIdenticalStringsHaveZeroDistance() {
        XCTAssertEqual(StringDistance.levenshtein("chrome", "chrome"), 0)
    }

    func testKnownDistance() {
        XCTAssertEqual(StringDistance.levenshtein("kitten", "sitting"), 3)
    }

    func testSingleEdit() {
        XCTAssertEqual(StringDistance.levenshtein("spotify", "spotfy"), 1)
    }

    func testEmptyInputsDoNotCrash() {
        XCTAssertEqual(StringDistance.levenshtein("", ""), 0)
        XCTAssertEqual(StringDistance.levenshtein("", "abc"), 3)
        XCTAssertEqual(StringDistance.levenshtein("abc", ""), 3)
    }

    func testSymmetric() {
        XCTAssertEqual(
            StringDistance.levenshtein("finder", "finderx"),
            StringDistance.levenshtein("finderx", "finder")
        )
    }

    func testSimilarityBounds() {
        XCTAssertEqual(StringDistance.similarity("same", "same"), 1.0, accuracy: 1e-9)
        XCTAssertEqual(StringDistance.similarity("", ""), 1.0, accuracy: 1e-9)
        let partial = StringDistance.similarity("chrome", "chroma")
        XCTAssertGreaterThan(partial, 0.0)
        XCTAssertLessThan(partial, 1.0)
    }

    func testSimilarityTracksDistance() {
        let close = StringDistance.similarity("spotify", "spotfy")
        let far = StringDistance.similarity("spotify", "terminal")
        XCTAssertGreaterThan(close, far)
    }
}
