import AppKit

#if SWIFT_PACKAGE
import VersoCore
#endif

/// A plain AppKit text editor used by the temporary note surface.
///
/// NSTextView owns editing, selection, input methods, undo and find. This
/// wrapper only supplies the scroll view, safe note loading and the callback
/// boundary used by the persistence coordinator.
@MainActor
final class NativeNoteEditor: NSView, NSTextViewDelegate {
    let scrollView: NSScrollView
    let textView: NSTextView

    var onTextChange: ((String) -> Void)?

    private var isLoading = false

    init(
        initialText: String = "",
        onTextChange: ((String) -> Void)? = nil
    ) {
        let nativeScrollView = NSTextView
            .scrollablePlainDocumentContentTextView()
        self.scrollView = nativeScrollView
        self.textView = nativeScrollView.documentView as! NSTextView
        self.onTextChange = onTextChange
        super.init(frame: .zero)

        configureTextView()
        configureScrollView()
        load(initialText)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    var text: String {
        textView.string
    }

    /// Load a different note without carrying undo actions or an invalid
    /// selection into it. NSTextView ranges are UTF-16 based, so NSString's
    /// length is used for the insertion point.
    func load(_ text: String) {
        commitMarkedText()
        isLoading = true
        textView.string = text
        textView.setSelectedRange(
            NSRange(location: (text as NSString).length, length: 0)
        )
        textView.undoManager?.removeAllActions()
        isLoading = false
    }

    /// Commit an active input-method composition without discarding its text.
    func commitMarkedText() {
        if textView.hasMarkedText() {
            textView.unmarkText()
        }
        textView.breakUndoCoalescing()
    }

    func setEditingEnabled(_ enabled: Bool) {
        textView.isEditable = enabled
        textView.needsDisplay = true
    }

    func clearCallback() {
        onTextChange = nil
        textView.delegate = nil
    }

    func focus() {
        guard let window else { return }
        _ = window.makeFirstResponder(textView)
    }

    private func configureTextView() {
        textView.delegate = self
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.usesFindPanel = false
        textView.usesFindBar = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.setAccessibilityLabel(L("editor.axLabel"))
        textView.setAccessibilityHelp(
            L("editor.axHelp")
        )
    }

    private func configureScrollView() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.setAccessibilityLabel(L("editor.axScroll"))

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func textDidChange(_ notification: Notification) {
        guard !isLoading else { return }
        onTextChange?(textView.string)
    }
}
