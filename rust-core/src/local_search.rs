//! File-search text interpretation. No filesystem access, predicates or execution.
use crate::text_policy::*;
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum SearchMode {
    Name,
    Content,
}
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum SearchKind {
    Any,
    Folder,
    Pdf,
    Presentation,
    Document,
    Spreadsheet,
    Image,
    Audio,
    Video,
    Mail,
    Note,
}
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum SearchDate {
    Any,
    Today,
    Yesterday,
    ThisWeek,
    LastWeek,
    ThisMonth,
    LastMonth,
    Last7Days,
    Last30Days,
}
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct SearchRequest {
    pub query: String,
    pub mode: SearchMode,
    pub kind: SearchKind,
    pub scopes: Vec<String>,
    pub date: SearchDate,
    pub minimum_bytes: i64,
    pub maximum_bytes: i64,
}
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum SelectionOperation {
    Open,
    Preview,
    Reveal,
}
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct FileSelection {
    pub operation: SelectionOperation,
    pub index: u32,
}
#[uniffi::export]
pub fn clean_search_text(raw: String) -> String {
    clean_search(&raw)
}
#[uniffi::export]
pub fn parse_file_selection(raw: String) -> Option<FileSelection> {
    selection(&raw)
}
fn operation(word: &str) -> SelectionOperation {
    match word {
        "preview" | "quick look" => SelectionOperation::Preview,
        "reveal" | "show in finder" => SelectionOperation::Reveal,
        _ => SelectionOperation::Open,
    }
}
pub fn selection(raw: &str) -> Option<FileSelection> {
    let text = clean_search(raw).to_lowercase();
    if let Some(g) = captures(
        r"^(?:just )?(open|preview|quick look|reveal|show in finder)(?: (?:it|that|this|the selected (?:file|result)))?$",
        &text,
    ) {
        return Some(FileSelection {
            operation: operation(&g[0]),
            index: 0,
        });
    }
    let g = captures(
        r"^(?:(open|preview|quick look|reveal|show in finder) )?(?:the |result |file |number )?(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|[0-9]{1,3}(?:st|nd|rd|th)?)(?: one| result| file| item)?(?: in finder)?$",
        &text,
    )?;
    let ordinals = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth",
        "tenth",
    ];
    let index = ordinals
        .iter()
        .position(|s| *s == g[1])
        .map(|i| i as u32 + 1)
        .or_else(|| {
            g[1].chars()
                .filter(|c| c.is_ascii_digit())
                .collect::<String>()
                .parse()
                .ok()
        })?;
    (index > 0 && index <= 100).then(|| FileSelection {
        operation: operation(&g[0]),
        index,
    })
}
fn location_scopes(text: &str) -> Vec<String> {
    replace(r"(?i)\s+(?:or|and)\s+|,", text, "|")
        .split('|')
        .map(|s| {
            replace(r"(?i)^(?:my |the )+|\s+folders?$", s, "")
                .trim_matches(is_space)
                .to_string()
        })
        .filter(|s| !s.is_empty())
        .collect()
}
fn range(pattern: &str, text: &str) -> Option<std::ops::Range<usize>> {
    let re = rx(pattern);
    let m = re.find(text).ok()??;
    Some(m.start()..m.end())
}
#[uniffi::export]
pub fn parse_file_search(raw: String) -> Option<SearchRequest> {
    search(&raw)
}
pub fn search(raw: &str) -> Option<SearchRequest> {
    let mut remaining = clean_search(raw);
    let lower = remaining.to_lowercase();
    let explicit = has(
        r"\b(files?|folders?|documents?|pdfs?|ppts?|pptx|presentations?|powerpoints?|spreadsheets?|images?|photos?|notes?|emails?|mail|word|slides?)\b",
        &lower,
    );
    let open_docs = has(
        r"^open\s+(?:(?:all|the|my|a|an)\s+)*(?:pdfs?|ppts?|presentations?|powerpoints?|spreadsheets?|images?|photos?|word documents?|word files?|files?)\b",
        &lower,
    ) && has(
        r"\b(?:in|inside|within|under|named|called|titled)\b",
        &lower,
    );
    let verb = open_docs || has(r"^(find|locate|search|look for|show|list)\b", &lower);
    if !(explicit || lower.starts_with("find ") || lower.starts_with("locate ")) {
        return None;
    }
    if !(verb
        || has(
            r"^(pdfs?|ppts?|presentations?|documents?|files?|folders?|images?|notes?|emails?)\b",
            &lower,
        ))
    {
        return None;
    }
    if has(
        r"\b(how many|count|oldest|newest|latest|largest|total size)\b",
        &lower,
    ) {
        return None;
    }
    if !explicit && has(r"\b(google|youtube|web|internet)\b", &lower) {
        return None;
    }
    if has(
        r"\b(?:and|then)\s+(?:open|play|close|delete|run|set|search|find)\b",
        &lower,
    ) {
        return None;
    }
    let mut request = SearchRequest {
        query: String::new(),
        mode: SearchMode::Name,
        kind: SearchKind::Any,
        scopes: vec![],
        date: SearchDate::Any,
        minimum_bytes: 0,
        maximum_bytes: 0,
    };
    let mut content = String::new();
    if let Some(r) = range(
        r"(?i)\b(?:that\s+)?(?:mentions?|mentioning|contains?|containing|with text|whose contents? (?:includes?|contains?))\s+(?:the phrase\s+)?",
        &remaining,
    ) {
        content = remaining[r.end..].to_string();
        remaining = remaining[..r.start].to_string();
        request.mode = SearchMode::Content;
    }
    let explicit_name = has(
        r"^search(?: for)? (?:files?|documents?|folders?|pdfs?) (?:named|called|titled)\b",
        &lower,
    );
    if content.is_empty() && !explicit_name && lower.starts_with("search ") {
        if let Some(r) = range(r"(?i)\s+for\s+", &remaining) {
            content = remaining[r.end..].to_string();
            remaining = remaining[..r.start].to_string();
            request.mode = SearchMode::Content;
        }
    }
    let mut literal = None;
    let target = if request.mode == SearchMode::Content {
        &mut content
    } else {
        &mut remaining
    };
    let quote = rx(r#"["“]([^"”]+)["”]"#);
    if let Ok(Some(c)) = quote.captures(target) {
        let m = c.get(0)?;
        let r = m.start()..m.end();
        literal = Some(c.get(1)?.as_str().to_string());
        target.replace_range(r, "");
    }
    let dates = [
        (
            r"\b(?:from |modified |changed |updated )?last week\b",
            SearchDate::LastWeek,
        ),
        (
            r"\b(?:from |modified |changed |updated )?this week\b",
            SearchDate::ThisWeek,
        ),
        (
            r"\b(?:from |modified |changed |updated )?last month\b",
            SearchDate::LastMonth,
        ),
        (
            r"\b(?:from |modified |changed |updated )?this month\b",
            SearchDate::ThisMonth,
        ),
        (
            r"\b(?:from |modified (?:in )?|changed |updated )?(?:the )?(?:last|past) (?:7|seven) days\b",
            SearchDate::Last7Days,
        ),
        (
            r"\b(?:from |modified |changed |updated )?(?:the )?(?:last|past) (?:30|thirty) days\b",
            SearchDate::Last30Days,
        ),
        (
            r"\b(?:from |modified |changed |updated )?yesterday\b",
            SearchDate::Yesterday,
        ),
        (
            r"\b(?:from |modified |changed |updated )?today\b",
            SearchDate::Today,
        ),
    ];
    let mut filters = if request.mode == SearchMode::Content {
        content.clone()
    } else {
        remaining.clone()
    };
    for (pattern, date) in &dates {
        if remove(pattern, &mut filters).is_some() {
            request.date = date.clone();
            break;
        }
    }
    for (pattern, minimum) in [
        (
            r"\b(?:bigger|larger|greater|more) than\s+([0-9]+(?:\.[0-9]+)?)\s*(kb|mb|gb|bytes?)\b",
            true,
        ),
        (
            r"\b(?:smaller|less) than\s+([0-9]+(?:\.[0-9]+)?)\s*(kb|mb|gb|bytes?)\b",
            false,
        ),
        (
            r"\b(?:over|above|at least)\s+([0-9]+(?:\.[0-9]+)?)\s*(kb|mb|gb|bytes?)\b",
            true,
        ),
        (
            r"\b(?:under|below|at most)\s+([0-9]+(?:\.[0-9]+)?)\s*(kb|mb|gb|bytes?)\b",
            false,
        ),
    ] {
        if let Some(g) = remove(pattern, &mut filters) {
            if let Ok(amount) = g[0].parse::<f64>() {
                let multiplier = match g[1].to_lowercase().as_str() {
                    "kb" => 1_000.,
                    "mb" => 1_000_000.,
                    "gb" => 1_000_000_000.,
                    _ => 1.,
                };
                let bytes = amount * multiplier;
                if !bytes.is_finite() || bytes <= 0. || bytes >= i64::MAX as f64 {
                    return None;
                }
                if minimum {
                    request.minimum_bytes = bytes.ceil() as i64;
                } else {
                    request.maximum_bytes = bytes.floor() as i64;
                }
            }
        }
    }
    let location = r"\b(?:(?:that|which)\s+)?(?:(?:may|might|could)\s+be\s+|maybe\s+)?(?:in|inside|within|under|from(?=\s+(?:(?:my|the)\s+)?(?:downloads|documents|desktop)\b)|from(?=\s+.+\s+(?:folders?|drive)\s*$))\s+(?:either\s+)?(.+)$";
    if let Some(g) = remove(location, &mut filters) {
        request.scopes = location_scopes(&g[0]);
    }
    if request.mode == SearchMode::Content {
        content = filters;
    } else {
        remaining = filters;
    }
    if request.mode == SearchMode::Content {
        for (pattern, date) in &dates {
            if remove(pattern, &mut remaining).is_some() {
                request.date = date.clone();
                break;
            }
        }
        if let Some(g) = remove(location, &mut remaining) {
            request.scopes.extend(location_scopes(&g[0]));
        }
    }
    let kinds = [
        (r"\b(?:pdfs?)\b", SearchKind::Pdf),
        (
            r"\b(?:ppts?|pptx|powerpoints?|presentations?|slide decks?|slides?)\b",
            SearchKind::Presentation,
        ),
        (
            r"\b(?:spreadsheets?|excel files?|xlsx)\b",
            SearchKind::Spreadsheet,
        ),
        (
            r"\b(?:word documents?|word files?|docx)\b",
            SearchKind::Document,
        ),
        (r"\b(?:images?|photos?|pictures?)\b", SearchKind::Image),
        (r"\b(?:audio files?|music files?)\b", SearchKind::Audio),
        (r"\b(?:videos?|movies?)\b", SearchKind::Video),
        (r"\b(?:emails?|mail messages?|mail)\b", SearchKind::Mail),
        (r"\b(?:notes?)\b", SearchKind::Note),
        (r"\b(?:folders?)\b", SearchKind::Folder),
    ];
    let marker = range(r"(?i)\b(?:named|called|titled)\b", &remaining);
    let (mut kind_part, name_part) = marker
        .map(|r| {
            (
                remaining[..r.start].to_string(),
                remaining[r.start..].to_string(),
            )
        })
        .unwrap_or_else(|| (remaining.clone(), String::new()));
    for (pattern, kind) in kinds {
        if remove(pattern, &mut kind_part).is_some() {
            request.kind = kind;
            break;
        }
    }
    remaining = kind_part + &name_part;
    remaining = replace(
        r"(?i)^(?:find|locate|search(?: for)?|look for|show|list|open)\s+(?:me\s+)?",
        &remaining,
        "",
    );
    remaining = replace(r"(?i)\b(?:files?|documents?)\b", &remaining, "");
    remaining = replace(
        r"(?i)^(?:(?:all|my|the|a|an|any|named|called|titled|about|on|for)\s+)+",
        &remaining,
        "",
    );
    remaining = replace(r"(?i)\b(?:named|called|titled)\s+", &remaining, "");
    let query = literal.unwrap_or_else(|| {
        if request.mode == SearchMode::Content {
            content
        } else {
            remaining
        }
    });
    request.query = replace(
        r"\s+",
        query.trim_matches(|c: char| is_space(c) || "\"'“”‘’".contains(c)),
        " ",
    );
    if len(&request.query) > 512 || request.scopes.len() > 8 {
        return None;
    }
    if request.query.is_empty()
        && request.kind == SearchKind::Any
        && request.date == SearchDate::Any
        && request.minimum_bytes == 0
        && request.maximum_bytes == 0
        && request.scopes.is_empty()
    {
        return None;
    }
    Some(request)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn literals_filters_selection_and_overflow() {
        let r = search("search for files called \"yesterday in Downloads\"").unwrap();
        assert_eq!(r.query, "yesterday in Downloads");
        assert_eq!(r.date, SearchDate::Any);
        assert!(r.scopes.is_empty());
        let r = search("find PDFs mentioning curves in Downloads under 1.5 MB").unwrap();
        assert_eq!(r.query, "curves");
        assert_eq!(r.maximum_bytes, 1_500_000);
        assert_eq!(r.kind, SearchKind::Pdf);
        assert!(search("find documents under 9223372036854775808 bytes").is_none());
        assert_eq!(selection("preview the second file").unwrap().index, 2);
        assert_eq!(selection("open it").unwrap().index, 0);
        assert!(selection("101st file").is_none());
    }
}
