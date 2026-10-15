//! Single pattern table for instant time/date/day/month/year queries.
use crate::SystemInfoAction;

pub fn match_query(lower: &str) -> Option<SystemInfoAction> {
    if [
        "what is the time",
        "what's the time",
        "what time is it",
        "tell me the time",
        "current time",
        "time right now",
        "what is time",
        "whats the time",
        "show me the time",
        "the time",
        "time please",
    ]
    .iter()
    .any(|pattern| lower.contains(pattern))
    {
        return Some(SystemInfoAction::CurrentTime);
    }
    if [
        "what is today's date",
        "what is the date",
        "today's date",
        "what day is today",
        "what is today",
        "what date is it",
        "tell me the date",
        "current date",
        "todays date",
        "what's today's date",
        "whats todays date",
        "show me the date",
        "date today",
        "date right now",
    ]
    .iter()
    .any(|pattern| lower.contains(pattern))
    {
        return Some(SystemInfoAction::CurrentDate);
    }
    if [
        "what day is it",
        "what day is this",
        "which day is it",
        "which day is today",
        "tell me the day",
        "what day",
    ]
    .iter()
    .any(|pattern| lower.contains(pattern))
    {
        return Some(SystemInfoAction::CurrentDay);
    }
    if [
        "what month is it",
        "what month",
        "which month",
        "tell me the month",
        "current month",
    ]
    .iter()
    .any(|pattern| lower.contains(pattern))
    {
        return Some(SystemInfoAction::CurrentMonth);
    }
    if ["what year is it", "what year", "current year", "which year"]
        .iter()
        .any(|pattern| lower.contains(pattern))
    {
        return Some(SystemInfoAction::CurrentYear);
    }
    None
}
