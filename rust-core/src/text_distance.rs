//! Grapheme-aware edit distance shared by enrollment and fuzzy matching.

use unicode_segmentation::UnicodeSegmentation;
use unicode_normalization::UnicodeNormalization;

#[uniffi::export]
pub fn levenshtein(a: String, b: String) -> u32 {
    // Swift Character equality is canonical Unicode equality. Grapheme
    // segmentation alone still compares decomposed UTF-8 bytes differently.
    let a: String = a.nfc().collect();
    let b: String = b.nfc().collect();
    let a: Vec<&str> = a.graphemes(true).collect();
    let b: Vec<&str> = b.graphemes(true).collect();
    if a.is_empty() {
        return b.len() as u32;
    }
    if b.is_empty() {
        return a.len() as u32;
    }
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    let mut current = vec![0usize; b.len() + 1];
    for (i, left) in a.iter().enumerate() {
        current[0] = i + 1;
        for (j, right) in b.iter().enumerate() {
            let cost = if left == right { 0 } else { 1 };
            current[j + 1] = (previous[j + 1] + 1)
                .min(current[j] + 1)
                .min(previous[j] + cost);
        }
        std::mem::swap(&mut previous, &mut current);
    }
    previous[b.len()] as u32
}

#[uniffi::export]
pub fn similarity(a: String, b: String) -> f64 {
    let a_len = a.graphemes(true).count();
    let b_len = b.graphemes(true).count();
    let maximum = a_len.max(b_len);
    if maximum == 0 {
        return 1.0;
    }
    1.0 - (levenshtein(a, b) as f64 / maximum as f64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_distances() {
        assert_eq!(levenshtein("chrome".into(), "chrome".into()), 0);
        assert_eq!(levenshtein("kitten".into(), "sitting".into()), 3);
        assert_eq!(levenshtein("spotify".into(), "spotfy".into()), 1);
        assert_eq!(levenshtein("".into(), "".into()), 0);
        assert_eq!(levenshtein("".into(), "abc".into()), 3);
        assert_eq!(levenshtein("abc".into(), "".into()), 3);
    }

    #[test]
    fn similarity_bounds_and_order() {
        assert_eq!(similarity("same".into(), "same".into()), 1.0);
        assert_eq!(similarity("".into(), "".into()), 1.0);
        let close = similarity("spotify".into(), "spotfy".into());
        let far = similarity("spotify".into(), "terminal".into());
        assert!(close > far);
        assert!(close > 0.0 && close < 1.0);
    }

    #[test]
    fn canonically_equivalent_graphemes_match_like_swift_characters() {
        assert_eq!(levenshtein("café".into(), "cafe\u{301}".into()), 0);
        assert_eq!(similarity("café".into(), "cafe\u{301}".into()), 1.0);
        assert_eq!(levenshtein("각".into(), "\u{1100}\u{1161}\u{11a8}".into()), 0);
        // Normalization must not erase a real accent difference.
        assert_eq!(levenshtein("café".into(), "cafe".into()), 1);
    }
}
