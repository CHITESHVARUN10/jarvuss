import AppKit
import SwiftUI

/// Native single-line editor with first-click activation. Binding refreshes do
/// not replace its field editor or reset the caret while the user types.
struct ObsidianCommandField: NSViewRepresentable {
    @Binding var text: String
    var focusRequest: Int
    var onFocus: (Bool) -> Void
    var onSubmit: () -> Void
    @Environment(\.obsidianWindowWidth) private var width

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> FirstClickCommandField {
        let field = FirstClickCommandField()
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.isEditable = true; field.isSelectable = true
        field.focusRingType = .none; field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.textColor = NSColor(white: 0.97, alpha: 1)
        field.identifier = NSUserInterfaceItemIdentifier("assistant.commandInput")
        field.setAccessibilityIdentifier("assistant.commandInput")
        field.setAccessibilityLabel("Command")
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: FirstClickCommandField, context: Context) {
        context.coordinator.parent = self
        let size = ObsidianTypography.pointSize(14, width: width, preference: AppAppearance.shared.textSize)
        if field.font?.pointSize != size { field.font = .systemFont(ofSize: size) }
        field.placeholderAttributedString = NSAttributedString(string: "What would you like to do?", attributes: [.foregroundColor: NSColor(white: 0.57, alpha: 1), .font: NSFont.systemFont(ofSize: size)])
        if field.stringValue != text {
            field.stringValue = text
            if let editor = field.currentEditor() as? NSTextView {
                editor.string = text
                editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            field.focusWhenAttached = true
            DispatchQueue.main.async { [weak field] in field?.focusIfRequested() }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ObsidianCommandField
        var lastFocusRequest: Int?
        init(_ parent: ObsidianCommandField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField, let editor = field.currentEditor() as? NSTextView {
                editor.insertionPointColor = .white
                editor.selectedTextAttributes = [.backgroundColor: AppAppearance.shared.accent.nsColor.withAlphaComponent(0.35), .foregroundColor: NSColor.white]
            }
            DispatchQueue.main.async { self.parent.onFocus(true) }
        }
        func controlTextDidEndEditing(_ notification: Notification) { DispatchQueue.main.async { self.parent.onFocus(false) } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}

final class FirstClickCommandField: NSTextField {
    var focusWhenAttached = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusIfRequested() }
    func focusIfRequested() {
        guard focusWhenAttached, let window else { return }
        focusWhenAttached = false
        window.makeFirstResponder(self)
    }
    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        super.mouseDown(with: event)
    }
}
