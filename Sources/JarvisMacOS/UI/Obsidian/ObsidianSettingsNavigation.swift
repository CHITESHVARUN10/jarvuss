/// Shared navigation lets links open the correct settings group or speech tab.
enum GeneralSettingsGroup { case display, projects, services, advanced }
enum VoiceSettingsTab: String, CaseIterable {
    case recognition = "Recognition"
    case dictation = "Dictation"
}
