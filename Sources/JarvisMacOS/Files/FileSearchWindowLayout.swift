import Foundation

enum FileSearchWindowLayout {
    static func centeredPreview(in visible: CGRect, preferred: CGSize = CGSize(width: 860, height: 680)) -> CGRect {
        let margin: CGFloat = 24
        let width = min(preferred.width, max(1, visible.width - 2 * margin))
        let height = min(preferred.height, max(1, visible.height - 2 * margin))
        return CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
    }
}
