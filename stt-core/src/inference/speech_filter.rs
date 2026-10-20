//! Audio evidence and conservative caption filtering before text is published.
use crate::audio::AudioCapture;

/// Trim trailing/leading quiet frames so Whisper cannot invent an outro
/// from a long silent tail. Keep 160 ms around speech to preserve consonants.
/// Every chunk, including the final overlapped tail, uses the same gate.
pub fn speech_window(samples: &[f32]) -> Option<&[f32]> {
    const FRAME: usize = 320; // 20 ms at 16 kHz
    const FLOOR: f32 = 0.004;
    const PADDING: usize = 2560;
    if samples.len() < 8000 || samples.iter().any(|value| !value.is_finite()) {
        return None;
    }
    let mut first = None;
    let mut last = 0;
    let mut voiced_frames = 0;
    for (index, frame) in samples.chunks(FRAME).enumerate() {
        if AudioCapture::rms(frame) >= FLOOR {
            first.get_or_insert(index * FRAME);
            last = ((index + 1) * FRAME).min(samples.len());
            voiced_frames += 1;
        }
    }
    // A click or one loud tap is not enough evidence to decode words.
    if voiced_frames < 6 { return None; }
    let start = first?.saturating_sub(PADDING);
    let end = (last + PADDING).min(samples.len());
    Some(&samples[start..end])
}

fn is_caption(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    let words: Vec<_> = lower.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect();
    words.len() <= 12 && words.iter().any(|word| matches!(*word,
        "music" | "sound" | "sounds" | "noise" | "silence" | "applause" |
        "laughing" | "laughter" | "footsteps" | "inaudible" | "doorbell"))
}

/// Remove marked non-speech captions, preserving ordinary prose and actual
/// spoken gratitude. Never blacklist bare phrases such as "thank you".
pub fn remove_sound_captions(text: &str) -> String {
    let mut result = String::new();
    let mut rest = text;
    while let Some((start, opening)) = rest.char_indices().find(|(_, c)| matches!(c, '[' | '(' | '*')) {
        result.push_str(&rest[..start]);
        let marker = match opening {
            '[' => "[", '(' => "(",
            _ if rest[start..].starts_with("**") => "**",
            _ => "*",
        };
        let after = &rest[start + marker.len()..];
        let closing = match opening { '[' => "]", '(' => ")", _ => marker };
        if let Some(end) = after.find(closing) {
            let content = &after[..end];
            if !is_caption(content) {
                result.push_str(marker);
                result.push_str(content);
                result.push_str(closing);
            } else if !result.ends_with(char::is_whitespace) {
                result.push(' ');
            }
            rest = &after[end + closing.len()..];
        } else {
            result.push_str(&rest[start..]);
            rest = "";
            break;
        }
    }
    result.push_str(rest);
    result.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn silence_and_a_click_are_not_speech() {
        assert!(speech_window(&vec![0.0; 160_000]).is_none());
        let mut click = vec![0.0; 16000];
        click[..320].fill(0.4);
        assert!(speech_window(&click).is_none());
        assert!(speech_window(&vec![f32::NAN; 16000]).is_none());
    }

    #[test]
    fn trims_silent_tail_but_retains_speech_and_padding() {
        let mut clip = vec![0.0; 160_000];
        clip[16000..32000].fill(0.02);
        let window = speech_window(&clip).unwrap();
        assert_eq!(window.len(), 16000 + 2 * 2560);
        assert_eq!(&window[2560..2560 + 16000], &clip[16000..32000]);
        assert!(speech_window(&clip[48000..]).is_none(), "silent final chunks must also be gated");
    }

    #[test]
    fn removes_sound_descriptions_without_removing_spoken_thanks() {
        assert_eq!(remove_sound_captions("*sad music*"), "");
        assert_eq!(remove_sound_captions("**sad music**"), "");
        assert_eq!(remove_sound_captions("[pulling a knife sound]"), "");
        assert_eq!(remove_sound_captions("Hello. (soft music) Thank you."), "Hello. Thank you.");
        assert_eq!(remove_sound_captions("Play sad music. Thank you."), "Play sad music. Thank you.");
        assert_eq!(remove_sound_captions("The value (three plus two) is *important*."), "The value (three plus two) is *important*.");
    }
}
