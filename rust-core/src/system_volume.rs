//! Whole-command system-volume policy; no audio or macOS APIs.
use crate::{
    actions::{PlannedAction as A, SystemInfoAction as S, VolumeAction as V},
    text_policy::*,
};

pub fn parse(raw: &str) -> Option<A> {
    let text = replace(r"\s+", &clean_search(raw).to_lowercase(), " ");
    let text = replace(r"(?:,? please)$", &text, "");
    let text = text.as_str();
    if [
        "system volume",
        "current volume",
        "volume level",
        "what is the volume",
        "what's the volume",
        "what is the current volume",
        "what's the current volume",
        "what is the volume level",
        "what is the current volume level",
        "what's the current volume level",
        "show volume",
        "show the volume",
        "check volume",
        "how loud is the volume",
    ]
    .contains(&text)
    {
        return Some(A::SystemInfo {
            info: S::SystemVolume,
        });
    }
    if [
        "mute",
        "mute the sound",
        "mute audio",
        "mute sound",
        "mute the audio",
        "mute system audio",
        "mute system sound",
        "mute the volume",
        "sound off",
        "turn off sound",
        "turn the sound off",
        "silence",
        "go silent",
        "shut up",
        "be quiet",
    ]
    .contains(&text)
    {
        return Some(A::VolumeControl { action: V::Mute });
    }
    if [
        "unmute",
        "unmute the sound",
        "unmute audio",
        "unmute sound",
        "unmute the audio",
        "unmute system audio",
        "unmute system sound",
        "unmute the volume",
        "sound on",
        "turn on sound",
        "turn the sound on",
    ]
    .contains(&text)
    {
        return Some(A::VolumeControl { action: V::Unmute });
    }
    let noun =
        r"(?:(?:the |my )?(?:(?:system|output|speaker|mac|computer) )?(?:volume|sound|audio))";
    let amount = r"([a-z0-9 -]+?)(?:\s*(?:%|percent|percentage points?))?";
    for pattern in [
        format!(r"^(?:set|change|adjust|put|turn) {noun}(?: level)? (?:to|at) {amount}$"),
        format!(r"^{noun}(?: level)? (?:to|at) {amount}$"),
        format!(r"^set {noun} {amount}$"),
    ] {
        if let Some(g) = captures(&pattern, text) {
            if let Some(level) = number(&g[0]) {
                return Some(A::VolumeControl {
                    action: V::SetLevel { level },
                });
            }
        }
    }
    let up = format!("(?:increase|raise|boost|bump up) {noun}|turn up {noun}|turn {noun} up|{noun} up|(?:make it )?louder|volume louder|bump the volume");
    let down = format!("(?:decrease|reduce|lower) {noun}|turn down {noun}|turn {noun} down|{noun} down|(?:make it )?quieter");
    for (verbs, increasing) in [(up, true), (down, false)] {
        if let Some(g) = captures(&format!("^(?:{verbs}) to {amount}$"), text) {
            if let Some(level) = number(&g[0]) {
                return Some(A::VolumeControl {
                    action: V::SetLevel { level },
                });
            }
        }
        if let Some(g) = captures(&format!("^(?:{verbs})(?: (?:by )?{amount})?$"), text) {
            let by = if g[0].is_empty() { 10 } else { number(&g[0])? };
            return Some(A::VolumeControl {
                action: if increasing {
                    V::Increase { by }
                } else {
                    V::Decrease { by }
                },
            });
        }
    }
    None
}
pub fn number(raw: &str) -> Option<i32> {
    let text = raw.trim_matches(is_horizontal_space);
    if has(r"^[0-9]{1,3}$", text) {
        if let Ok(n) = text.parse::<i32>() {
            if (0..=100).contains(&n) {
                return Some(n);
            }
        }
    }
    let small = [
        "zero",
        "one",
        "two",
        "three",
        "four",
        "five",
        "six",
        "seven",
        "eight",
        "nine",
        "ten",
        "eleven",
        "twelve",
        "thirteen",
        "fourteen",
        "fifteen",
        "sixteen",
        "seventeen",
        "eighteen",
        "nineteen",
    ];
    if let Some(n) = small.iter().position(|s| *s == text) {
        return Some(n as i32);
    }
    if ["hundred", "one hundred"].contains(&text) {
        return Some(100);
    }
    let hyphen = text.replace('-', " ");
    let words: Vec<_> = hyphen.split(' ').filter(|s| !s.is_empty()).collect();
    let base = match *words.first()? {
        "twenty" => 20,
        "thirty" => 30,
        "forty" => 40,
        "fifty" => 50,
        "sixty" => 60,
        "seventy" => 70,
        "eighty" => 80,
        "ninety" => 90,
        _ => return None,
    };
    if words.len() == 1 {
        return Some(base);
    }
    if words.len() != 2 {
        return None;
    }
    let unit = small.iter().position(|s| *s == words[1])?;
    (1..=9).contains(&unit).then_some(base + unit as i32)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn amounts_and_boundaries() {
        assert_eq!(number("nineteen"), Some(19));
        assert_eq!(number("ninety-nine"), Some(99));
        assert_eq!(number("101"), None);
        assert_eq!(
            parse("increase volume to nineteen"),
            Some(A::VolumeControl {
                action: V::SetLevel { level: 19 }
            })
        );
        assert_eq!(
            parse("increase volume by nineteen"),
            Some(A::VolumeControl {
                action: V::Increase { by: 19 }
            })
        );
        for text in [
            "set Spotify volume to 50",
            "play Volume Up",
            "set volume to 101",
            "volume up and open Safari",
        ] {
            assert!(parse(text).is_none(), "{text}");
        }
    }
}
