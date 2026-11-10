import AppKit

/// Shared by SwiftUI content and its NSPanel. Measure before resizing the panel;
/// never resize it from a SwiftUI layout callback.
enum DictationHUDLayout {
    static let recordingSize = CGSize(width: 400, height: 148)
    static let processingSize = CGSize(width: 400, height: 105)
    static let transcriptWidth: CGFloat = 460
    static let inset: CGFloat = 18
    static let maximumTextHeight: CGFloat = 220

    static func textHeight(transcript: String, original: String, showsOriginal: Bool) -> CGFloat {
        // Reserve both versions so switching Original does not move the window.
        let height = measuredHeight(transcript, fontSize: 14, lineSpacing: 6)
        let originalHeight = showsOriginal ? measuredHeight(original, fontSize: 14, lineSpacing: 6) : 0
        return min(maximumTextHeight, max(32, max(height, originalHeight)))
    }

    static func noticeHeight(_ notice: String) -> CGFloat {
        guard !notice.isEmpty else { return 0 }
        // Leave room for the icon and the Accessibility button.
        return max(30, measuredHeight(notice, fontSize: 10.5, lineSpacing: 2, reservedWidth: 94))
    }

    static func transcriptSize(transcript: String, original: String, showsOriginal: Bool, notice: String) -> CGSize {
        let text = textHeight(transcript: transcript, original: original, showsOriginal: showsOriginal)
        let notice = noticeHeight(notice)
        // Insets (36), header (24), text gap (18), divider/gaps (33), actions (32).
        return CGSize(width: transcriptWidth, height: 143 + text + (notice > 0 ? 12 + notice : 0))
    }

    private static func measuredHeight(_ text: String, fontSize: CGFloat, lineSpacing: CGFloat,
                                       reservedWidth: CGFloat = 0) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: transcriptWidth - 2 * inset - reservedWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraph])
        return ceil(bounds.height) + 4
    }
}
