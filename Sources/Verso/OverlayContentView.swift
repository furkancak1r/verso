import AppKit

#if SWIFT_PACKAGE
import VersoCore
#endif

@MainActor
final class OverlayContentView: NSView {
    private var backAction: (() -> Void)?

    // Non-clipping wrappers for procedural shadow that rotates with the face.
    private final class NonClippingView: NSView {
        override var wantsDefaultClipping: Bool { false }
    }

    private let flipContainerView = NonClippingView()
    private let frontFaceOuterView = NonClippingView()
    private let backFaceOuterView = NonClippingView()
    private let frontSurfaceView = NSView()
    private let neutralFrontView = NSView()
    private let screenshotLayer = CALayer()
    // AppKit resets backing-view anchors during layout. Own the animated layers;
    // the real editor stays in its native view hierarchy and is shown at rest.
    private let animationContainer = CALayer()
    private let animationFront = CALayer()
    private let animationBack = CALayer()
    private let noteBitmapLayer = CALayer()
    private let noteSurfaceView: OverlayNoteSurfaceView
    private let backdropCaptureLayer = CALayer()
    private var neutralAppNameLabel: NSTextField?
    private var neutralTitleLabel: NSTextField?

    // Manual frame override for flipContainer; nil = fill bounds.
    private var flipContainerFrameOverride: CGRect?

    // Root does not clip so expanded face shadows are visible.
    override var wantsDefaultClipping: Bool { false }

    var flipContainerLayer: CALayer { animationContainer }
    var frontFaceLayer: CALayer { animationFront }
    var frontCaptureLayer: CALayer { screenshotLayer }
    var noteSurfaceLayer: CALayer { animationBack }
    var backdropLayer: CALayer { backdropCaptureLayer }

    init(
        appName: String,
        windowTitle: String?,
        appIcon: NSImage?,
        initialText: String = "",
        isPinned: Bool = false,
        backAction: @escaping () -> Void,
        onTextChange: ((String) -> Void)? = nil,
        onPin: (() -> Void)? = nil,
        onArchive: (() -> Void)? = nil
    ) {
        self.backAction = backAction
        self.noteSurfaceView = OverlayNoteSurfaceView(
            appName: appName,
            windowTitle: windowTitle,
            appIcon: appIcon,
            initialText: initialText,
            isPinned: isPinned,
            backAction: backAction,
            onTextChange: onTextChange,
            onPin: onPin,
            onArchive: onArchive
        )
        super.init(frame: .zero)

        wantsLayer = true
        flipContainerView.wantsLayer = true
        frontFaceOuterView.wantsLayer = true
        backFaceOuterView.wantsLayer = true
        frontSurfaceView.wantsLayer = true
        noteSurfaceView.wantsLayer = true

        flipContainerView.translatesAutoresizingMaskIntoConstraints = true
        frontFaceOuterView.translatesAutoresizingMaskIntoConstraints = false
        backFaceOuterView.translatesAutoresizingMaskIntoConstraints = false
        frontSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        neutralFrontView.translatesAutoresizingMaskIntoConstraints = false
        noteSurfaceView.translatesAutoresizingMaskIntoConstraints = false

        screenshotLayer.contentsGravity = .resizeAspect
        screenshotLayer.actions = [
            "contents": NSNull(), "bounds": NSNull(),
            "position": NSNull(), "contentsScale": NSNull()
        ]
        screenshotLayer.shouldRasterize = false
        screenshotLayer.needsDisplayOnBoundsChange = false

        // Backdrop: full-canvas stationary layer, behind flip content.
        backdropCaptureLayer.contentsGravity = .resizeAspectFill
        backdropCaptureLayer.actions = [
            "contents": NSNull(), "bounds": NSNull(),
            "position": NSNull(), "contentsScale": NSNull()
        ]
        backdropCaptureLayer.isHidden = true

        // Rounded content clips for inner views; outer wrappers stay open
        // for procedural shadow.
        frontSurfaceView.layer?.cornerRadius = 10
        frontSurfaceView.layer?.masksToBounds = true
        noteSurfaceView.layer?.cornerRadius = 10
        noteSurfaceView.layer?.masksToBounds = true

        noteSurfaceView.isHidden = true
        backFaceOuterView.isHidden = true
        noteSurfaceLayer.isHidden = true

        refreshSurfaceColors()

        layer?.addSublayer(backdropCaptureLayer)
        layer?.addSublayer(animationContainer)
        animationContainer.zPosition = 1
        for ownedLayer in [animationContainer, animationFront, animationBack] {
            ownedLayer.actions = ["hidden": NSNull(), "position": NSNull(),
                                  "bounds": NSNull(), "transform": NSNull()]
        }
        backdropCaptureLayer.actions?["hidden"] = NSNull()
        animationContainer.isHidden = true
        animationContainer.addSublayer(animationFront)
        animationContainer.addSublayer(animationBack)
        animationFront.cornerRadius = 10
        animationBack.cornerRadius = 10
        noteBitmapLayer.cornerRadius = 10
        noteBitmapLayer.masksToBounds = true
        screenshotLayer.cornerRadius = 10
        screenshotLayer.masksToBounds = true
        noteBitmapLayer.actions = screenshotLayer.actions
        animationBack.addSublayer(noteBitmapLayer)
        addSubview(flipContainerView)
        flipContainerView.addSubview(frontFaceOuterView)
        flipContainerView.addSubview(backFaceOuterView)
        frontFaceOuterView.addSubview(frontSurfaceView)
        frontSurfaceView.addSubview(neutralFrontView)
        animationFront.addSublayer(screenshotLayer)
        backFaceOuterView.addSubview(noteSurfaceView)

        configureNeutralFront(
            appName: appName,
            windowTitle: windowTitle,
            appIcon: appIcon
        )

        NSLayoutConstraint.activate([
            frontFaceOuterView.leadingAnchor.constraint(equalTo: flipContainerView.leadingAnchor),
            frontFaceOuterView.trailingAnchor.constraint(equalTo: flipContainerView.trailingAnchor),
            frontFaceOuterView.topAnchor.constraint(equalTo: flipContainerView.topAnchor),
            frontFaceOuterView.bottomAnchor.constraint(equalTo: flipContainerView.bottomAnchor),
            backFaceOuterView.leadingAnchor.constraint(equalTo: flipContainerView.leadingAnchor),
            backFaceOuterView.trailingAnchor.constraint(equalTo: flipContainerView.trailingAnchor),
            backFaceOuterView.topAnchor.constraint(equalTo: flipContainerView.topAnchor),
            backFaceOuterView.bottomAnchor.constraint(equalTo: flipContainerView.bottomAnchor),
            frontSurfaceView.leadingAnchor.constraint(equalTo: frontFaceOuterView.leadingAnchor),
            frontSurfaceView.trailingAnchor.constraint(equalTo: frontFaceOuterView.trailingAnchor),
            frontSurfaceView.topAnchor.constraint(equalTo: frontFaceOuterView.topAnchor),
            frontSurfaceView.bottomAnchor.constraint(equalTo: frontFaceOuterView.bottomAnchor),
            neutralFrontView.leadingAnchor.constraint(equalTo: frontSurfaceView.leadingAnchor),
            neutralFrontView.trailingAnchor.constraint(equalTo: frontSurfaceView.trailingAnchor),
            neutralFrontView.topAnchor.constraint(equalTo: frontSurfaceView.topAnchor),
            neutralFrontView.bottomAnchor.constraint(equalTo: frontSurfaceView.bottomAnchor),
            noteSurfaceView.leadingAnchor.constraint(equalTo: backFaceOuterView.leadingAnchor),
            noteSurfaceView.trailingAnchor.constraint(equalTo: backFaceOuterView.trailingAnchor),
            noteSurfaceView.topAnchor.constraint(equalTo: backFaceOuterView.topAnchor),
            noteSurfaceView.bottomAnchor.constraint(equalTo: backFaceOuterView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        flipContainerView.frame = flipContainerFrameOverride ?? bounds
        flipContainerView.layoutSubtreeIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropCaptureLayer.frame = bounds
        animationContainer.frame = flipContainerView.frame
        animationFront.frame = animationContainer.bounds
        animationBack.frame = animationContainer.bounds
        screenshotLayer.frame = animationFront.bounds
        noteBitmapLayer.frame = animationBack.bounds
        screenshotLayer.contentsScale = window?.backingScaleFactor ?? 1
        noteBitmapLayer.contentsScale = window?.backingScaleFactor ?? 1
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSurfaceColors()
    }

    private func refreshSurfaceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let color = NSColor.windowBackgroundColor.cgColor
            frontSurfaceView.layer?.backgroundColor = color
            noteSurfaceView.layer?.backgroundColor = color
            animationFront.backgroundColor = color
            animationBack.backgroundColor = color
            // Wrappers need the color too for the test contract on
            // frontFaceLayer.backgroundColor.
            frontFaceOuterView.layer?.backgroundColor = color
            backFaceOuterView.layer?.backgroundColor = color
            CATransaction.commit()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        backAction?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            backAction?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Surface visibility

    var hasNoteSnapshot: Bool { noteBitmapLayer.contents != nil }

    func revealNoteSurface() {
        let transitioning = flipContainerFrameOverride != nil
        frontSurfaceView.isHidden = true
        frontFaceOuterView.isHidden = true
        noteSurfaceView.isHidden = transitioning
        backFaceOuterView.isHidden = transitioning
        animationContainer.isHidden = !transitioning
        animationFront.isHidden = true
        animationBack.isHidden = false
        if !transitioning { noteBitmapLayer.contents = nil }
    }

    func revealFrontSurface() {
        frontFaceOuterView.isHidden = true
        backFaceOuterView.isHidden = true
        noteSurfaceView.isHidden = true
        animationContainer.isHidden = flipContainerFrameOverride == nil
        animationFront.isHidden = false
        animationBack.isHidden = true
    }

    func prepareFront(hasSnapshot: Bool) {
        if hasSnapshot { snapshotNoteSurface() }
        revealFrontSurface()
    }

    /// Keep the real editor visible until both fresh external captures are ready.
    func prepareReverse(hasSnapshot: Bool) {
        if hasSnapshot { snapshotNoteSurface() }
        revealNoteSurface()
    }

    private func snapshotNoteSurface() {
        backFaceOuterView.isHidden = false
        noteSurfaceView.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        noteBitmapLayer.contents = nil
        if let bitmap = noteSurfaceView.bitmapImageRepForCachingDisplay(in: noteSurfaceView.bounds) {
            noteSurfaceView.cacheDisplay(in: noteSurfaceView.bounds, to: bitmap)
            noteBitmapLayer.contents = bitmap.cgImage
        }
        backFaceOuterView.isHidden = true
        noteSurfaceView.isHidden = true
    }

    // MARK: - Expanded / tight canvas layout

    /// Position flipContainer at faceFrame inside the expanded canvas.
    func installExpandedLayout(faceFrame: CGRect) {
        flipContainerFrameOverride = faceFrame
        flipContainerView.frame = faceFrame
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Restore flipContainer to fill the content view (tight target frame).
    func restoreTightLayout() {
        flipContainerFrameOverride = nil
        clearBackdrop()
        noteBitmapLayer.contents = nil
        needsLayout = true
        layoutSubtreeIfNeeded()
        revealNoteSurface()
    }

    // MARK: - Backdrop

    func showBackdrop() {
        backdropCaptureLayer.isHidden = false
    }

    func clearBackdrop() {
        backdropCaptureLayer.contents = nil
        backdropCaptureLayer.isHidden = true
    }

    // MARK: - Procedural face shadow

    /// Add a procedural shadow on both outer face wrappers that follows the
    /// 3D rotation. Call after layout so bounds are correct.
    func configureFaceShadow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [animationFront, animationBack] {
            layer.shadowPath = CGPath(
                roundedRect: layer.bounds,
                cornerWidth: 10, cornerHeight: 10, transform: nil
            )
            layer.shadowRadius = 20
            layer.shadowOpacity = 0.35
            layer.shadowOffset = CGSize(width: 0, height: -4)
            layer.shadowColor = NSColor.black.cgColor
        }
        CATransaction.commit()
    }

    func removeFaceShadow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [animationFront, animationBack] {
            layer.shadowPath = nil
            layer.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    // MARK: - Note surface delegation

    func commitEditingForReturn() {
        noteSurfaceView.commitMarkedText()
        noteSurfaceView.setEditingEnabled(false)
    }

    func commitEditing() {
        noteSurfaceView.commitMarkedText()
    }

    func setEditingEnabled(_ enabled: Bool) {
        noteSurfaceView.setEditingEnabled(enabled)
    }

    func focusEditor() {
        noteSurfaceView.focusEditor()
    }

    /// Read the actual current editor text, including any just-committed input.
    func currentEditorText() -> String {
        noteSurfaceView.currentEditorText()
    }

    func setPinState(_ pinned: Bool) {
        noteSurfaceView.setPinState(pinned)
    }

    func showPinSuccess(pinned: Bool) {
        noteSurfaceView.showPinSuccess(pinned: pinned)
    }

    func showPinFailure() {
        noteSurfaceView.showPinFailure()
    }

    func clearPinFeedback() {
        noteSurfaceView.clearPinFeedback()
    }

    var pinStateForTests: Bool { noteSurfaceView.pinStateForTests }
    var pinSymbolNameForTests: String { noteSurfaceView.pinSymbolNameForTests }
    var pinFeedbackTextForTests: String? { noteSurfaceView.pinFeedbackTextForTests }
    var isPinFeedbackVisibleForTests: Bool { noteSurfaceView.isPinFeedbackVisibleForTests }

    func updateTargetMetadata(appName: String, windowTitle: String?) {
        noteSurfaceView.updateTargetMetadata(
            appName: appName,
            windowTitle: windowTitle
        )

        let displayAppName = appName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty ? L("overlay.appFallback") : appName
        let trimmedTitle = windowTitle?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        let displayTitle = trimmedTitle.isEmpty ? L("overlay.untitledWindow") : trimmedTitle
        neutralAppNameLabel?.stringValue = displayAppName
        neutralTitleLabel?.stringValue = displayTitle
        neutralAppNameLabel?.setAccessibilityLabel(
            L("overlay.appLabel", displayAppName)
        )
        neutralTitleLabel?.setAccessibilityLabel(
            L("overlay.titleLabel", displayTitle)
        )
    }

    /// Phase 16A: traffic-light state and inline operation errors.
    /// The note surface view owns the same NSTextView across hide/restore,
    /// so undo/selection survive minimize and Space transitions.
    func setWindowControls(
        canMinimize: Bool, minimizeReason: String? = nil,
        canFullscreen: Bool = true, fullscreenReason: String? = nil,
        canZoom: Bool = true, zoomReason: String? = nil,
        onClose: (() -> Void)? = nil, onMinimize: (() -> Void)? = nil,
        onZoom: ((Bool) -> Void)? = nil
    ) {
        noteSurfaceView.setWindowControls(
            canMinimize: canMinimize, minimizeReason: minimizeReason,
            canFullscreen: canFullscreen, fullscreenReason: fullscreenReason,
            canZoom: canZoom, zoomReason: zoomReason,
            onClose: onClose, onMinimize: onMinimize, onZoom: onZoom)
    }

    func showWindowOperationError(_ message: String) {
        noteSurfaceView.showWindowOperationError(message)
    }

    func clearWindowOperationError() { noteSurfaceView.clearWindowOperationError() }

    var windowOperationErrorForTests: String? { noteSurfaceView.windowOperationErrorForTests }
    var isMinimizeEnabledForTests: Bool { noteSurfaceView.isMinimizeEnabledForTests }
    var isFullscreenEnabledForTests: Bool { noteSurfaceView.isFullscreenEnabledForTests }
    var isZoomEnabledForTests: Bool { noteSurfaceView.isZoomEnabledForTests }
    var trafficLightCountForTests: Int { noteSurfaceView.trafficLightCountForTests }

        func isHeaderClickTarget(at pointInWindow: NSPoint) -> Bool {
        guard !noteSurfaceView.isHidden else { return false }
        let point = noteSurfaceView.convert(pointInWindow, from: nil)
        return noteSurfaceView.isHeaderClickTarget(at: point)
    }

    func clearAction() {
        noteBitmapLayer.contents = nil
        clearBackdrop()
        animationContainer.isHidden = true
        backAction = nil
        noteSurfaceView.clearAction()
    }

    private func configureNeutralFront(
        appName: String,
        windowTitle: String?,
        appIcon: NSImage?
    ) {
        let trimmedAppName = appName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let displayAppName = trimmedAppName.isEmpty
            ? L("overlay.appFallback")
            : trimmedAppName
        let trimmedTitle = windowTitle?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        let displayTitle = trimmedTitle.isEmpty
            ? L("overlay.untitledWindow")
            : trimmedTitle

        let iconView = NSImageView()
        iconView.image = appIcon ?? NSImage(
            systemSymbolName: "app.fill",
            accessibilityDescription: L("overlay.appIconDesc", displayAppName)
        )
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityLabel(L("overlay.appIconLabel", displayAppName))

        let appNameLabel = NSTextField(labelWithString: displayAppName)
        appNameLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        appNameLabel.alignment = .center
        appNameLabel.lineBreakMode = .byTruncatingTail
        appNameLabel.setAccessibilityLabel(L("overlay.appLabel", displayAppName))
        neutralAppNameLabel = appNameLabel

        let titleLabel = NSTextField(labelWithString: displayTitle)
        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.setAccessibilityLabel(L("overlay.titleLabel", displayTitle))
        neutralTitleLabel = titleLabel

        let labels = NSStackView(views: [appNameLabel, titleLabel])
        labels.orientation = .vertical
        labels.alignment = .centerX
        labels.spacing = 4

        let stack = NSStackView(views: [iconView, labels])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        neutralFrontView.addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: neutralFrontView.leadingAnchor,
                constant: 24
            ),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: neutralFrontView.trailingAnchor,
                constant: -24
            ),
            stack.centerXAnchor.constraint(equalTo: neutralFrontView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: neutralFrontView.centerYAnchor)
        ])
    }
}

@MainActor
private final class OverlayNoteSurfaceView: NSView {
    private var backAction: (() -> Void)?
    private let headerView = NSView()
    private let backButton = NSButton(title: L("overlay.back"), target: nil, action: nil)
    private let noteEditor: NativeNoteEditor
    private var appNameLabel: NSTextField?
    private var windowTitleLabel: NSTextField?
    private var pinTarget: ClosureTarget?
    private var archiveTarget: ClosureTarget?
    private let pinButton = NSButton()
    private final class PinFeedbackLabel: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private let pinFeedbackLabel = PinFeedbackLabel(labelWithString: "")
    private var pinFeedbackWork: DispatchWorkItem?
    private var pinState = false
    private let closeButton = NSButton()
    private let minimizeButton = NSButton()
    private let zoomButton = NSButton()
    private var onCloseHandler: (() -> Void)?
    private var onMinimizeHandler: (() -> Void)?
    private var onZoomHandler: ((Bool) -> Void)?
    private var windowOperationMessage: String?

    init(
        appName: String,
        windowTitle: String?,
        appIcon: NSImage?,
        initialText: String,
        isPinned: Bool = false,
        backAction: @escaping () -> Void,
        onTextChange: ((String) -> Void)?,
        onPin: (() -> Void)?,
        onArchive: (() -> Void)?
    ) {
        self.backAction = backAction
        self.noteEditor = NativeNoteEditor(
            initialText: initialText,
            onTextChange: onTextChange
        )
        super.init(frame: .zero)

        headerView.translatesAutoresizingMaskIntoConstraints = false
        noteEditor.translatesAutoresizingMaskIntoConstraints = false
        headerView.setAccessibilityElement(false)

        backButton.target = self
        backButton.action = #selector(backPressed(_:))
        backButton.bezelStyle = .rounded
        backButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        backButton.image = NSImage(
            systemSymbolName: "chevron.left",
            accessibilityDescription: L("overlay.back")
        )
        backButton.imagePosition = .imageLeading
        backButton.imageScaling = .scaleProportionallyDown
        backButton.setAccessibilityLabel(L("overlay.back"))
        backButton.setAccessibilityHelp(
            L("overlay.backHelp")
        )

        // ponytail: borderless window keeps its flip silhouette; these are
        // plain circular color dots, not standardWindowButton, so no title
        // bar or style change is implied.
        configureTrafficButton(closeButton, color: .systemRed, label: L("overlay.closeNote"), help: L("overlay.closeHelp"), id: "overlay.close")
        configureTrafficButton(minimizeButton, color: .systemYellow, label: L("overlay.minimizeNote"), help: L("overlay.minimizeHelp"), id: "overlay.minimize")
        configureTrafficButton(zoomButton, color: .systemGreen, label: L("overlay.fullscreenNote"), help: L("overlay.fullscreenHelp"), id: "overlay.fullscreen")
        closeButton.target = self
        closeButton.action = #selector(closePressed(_:))
        minimizeButton.target = self
        minimizeButton.action = #selector(minimizePressed(_:))
        zoomButton.target = self
        zoomButton.action = #selector(zoomPressed(_:))

        let iconView = NSImageView()
        iconView.image = appIcon ?? NSImage(
            systemSymbolName: "app.fill",
            accessibilityDescription: L("overlay.appIconAlt")
        )
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setAccessibilityLabel(L("overlay.axAppIcon"))

        let displayAppName = appName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty ? L("overlay.appFallback") : appName
        let appNameLabel = NSTextField(labelWithString: displayAppName)
        appNameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        appNameLabel.lineBreakMode = .byTruncatingTail
        appNameLabel.setAccessibilityLabel(L("overlay.appLabel", displayAppName))
        self.appNameLabel = appNameLabel

        let displayWindowTitle = windowTitle?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        let titleLabel = NSTextField(
            labelWithString: displayWindowTitle.isEmpty
                ? L("overlay.untitledWindow")
                : displayWindowTitle
        )
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityLabel(
            L("overlay.titleLabel", displayWindowTitle.isEmpty ? L("overlay.untitledWindow") : displayWindowTitle)
        )
        self.windowTitleLabel = titleLabel

        let titleStack = NSStackView(views: [appNameLabel, titleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        appNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        pinButton.bezelStyle = .inline
        pinButton.isBordered = false
        pinButton.setContentHuggingPriority(.required, for: .horizontal)
        pinButton.setAccessibilityIdentifier("overlay.pin")
        setPinState(isPinned)
        if let onPin {
            let target = ClosureTarget(onPin)
            pinTarget = target
            pinButton.target = target
            pinButton.action = #selector(ClosureTarget.fire)
        }

        let archiveButton = NSButton(
            image: NSImage(
                systemSymbolName: "archivebox",
                accessibilityDescription: L("overlay.archiveAlt")
            )!,
            target: nil,
            action: nil
        )
        archiveButton.bezelStyle = .inline
        archiveButton.isBordered = false
        archiveButton.setContentHuggingPriority(.required, for: .horizontal)
        archiveButton.setAccessibilityLabel(L("overlay.archiveNote"))
        if let onArchive {
            let target = ClosureTarget(onArchive)
            archiveTarget = target
            archiveButton.target = target
            archiveButton.action = #selector(ClosureTarget.fire)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let trafficStack = NSStackView(views: [closeButton, minimizeButton, zoomButton])
        trafficStack.orientation = .horizontal
        trafficStack.alignment = .centerY
        trafficStack.spacing = 6
        trafficStack.translatesAutoresizingMaskIntoConstraints = false
        let topBar = NSStackView(views: [
            trafficStack,
            backButton,
            iconView,
            titleStack,
            spacer,
            pinButton,
            archiveButton
        ])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        pinFeedbackLabel.font = .systemFont(ofSize: 11)
        pinFeedbackLabel.textColor = .secondaryLabelColor
        pinFeedbackLabel.alignment = .right
        pinFeedbackLabel.lineBreakMode = .byTruncatingTail
        pinFeedbackLabel.isHidden = true
        pinFeedbackLabel.refusesFirstResponder = true
        pinFeedbackLabel.translatesAutoresizingMaskIntoConstraints = false
        pinFeedbackLabel.setAccessibilityElement(true)
        pinFeedbackLabel.setAccessibilityIdentifier("overlay.pinFeedback")

        headerView.addSubview(topBar)
        headerView.addSubview(divider)
        addSubview(headerView)
        addSubview(noteEditor)
        addSubview(pinFeedbackLabel)

        NSLayoutConstraint.activate([
            pinFeedbackLabel.trailingAnchor.constraint(
                equalTo: headerView.trailingAnchor,
                constant: -12
            ),
            pinFeedbackLabel.topAnchor.constraint(
                equalTo: headerView.bottomAnchor,
                constant: 1
            ),
            pinFeedbackLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: headerView.leadingAnchor,
                constant: 12
            )
        ])

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            topBar.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -12),
            topBar.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            divider.heightAnchor.constraint(equalToConstant: 1),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.bottomAnchor.constraint(equalTo: divider.bottomAnchor),
            noteEditor.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            noteEditor.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            noteEditor.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 18),
            noteEditor.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    func setEditingEnabled(_ enabled: Bool) {
        noteEditor.setEditingEnabled(enabled)
    }

    func commitMarkedText() {
        noteEditor.commitMarkedText()
    }

    func focusEditor() {
        noteEditor.focus()
    }

    func currentEditorText() -> String { noteEditor.text }

    /// Drive the pin icon purely from persisted state. Never from selection.
    func setPinState(_ pinned: Bool) {
        pinState = pinned
        // ponytail: icon follows the stored model; button selection is always
        // cleared so there is no second source of truth.
        pinButton.state = .off
        pinButton.image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: L(pinned ? "overlay.unpinNote" : "overlay.pinAlt")
        )
        pinButton.toolTip = L(pinned ? "overlay.unpinTooltip" : "overlay.pinTooltip")
        pinButton.setAccessibilityLabel(
            L(pinned ? "overlay.unpinNote" : "overlay.pinNote")
        )
        pinButton.setAccessibilityValue(
            L(pinned ? "overlay.pinnedFeedback" : "overlay.unpinnedFeedback")
        )
    }

    func showPinSuccess(pinned: Bool) {
        setPinState(pinned)
        showPinFeedback(
            message: L(pinned ? "overlay.pinnedFeedback" : "overlay.unpinnedFeedback"),
            duration: 2
        )
    }

    func showPinFailure() {
        // ponytail: the icon is intentionally untouched here; the persisted
        // model still holds the old value, so the old icon stays correct.
        showPinFeedback(message: L("overlay.pinSaveFailed"), duration: 5)
    }

    func clearPinFeedback() {
        windowOperationMessage = nil
        pinFeedbackWork?.cancel()
        pinFeedbackWork = nil
        pinFeedbackLabel.isHidden = true
        pinFeedbackLabel.stringValue = ""
    }

    private func showPinFeedback(message: String, duration: TimeInterval) {
        windowOperationMessage = nil
        pinFeedbackWork?.cancel()
        pinFeedbackLabel.stringValue = message
        pinFeedbackLabel.isHidden = false
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
        // ponytail: one cancellable work item, not a timer service; a newer
        // message replaces the pending hide. Clear it when the note closes.
        let work = DispatchWorkItem { [weak self] in self?.clearPinFeedback() }
        pinFeedbackWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    var pinStateForTests: Bool { pinState }
    var pinSymbolNameForTests: String { pinState ? "pin.fill" : "pin" }
    var pinFeedbackTextForTests: String? {
        pinFeedbackLabel.isHidden ? nil : pinFeedbackLabel.stringValue
    }
    var isPinFeedbackVisibleForTests: Bool { !pinFeedbackLabel.isHidden }

    func updateTargetMetadata(appName: String, windowTitle: String?) {
        let displayAppName = appName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty ? L("overlay.appFallback") : appName
        let displayWindowTitle = windowTitle?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        appNameLabel?.stringValue = displayAppName
        windowTitleLabel?.stringValue = displayWindowTitle.isEmpty
            ? L("overlay.untitledWindow")
            : displayWindowTitle
        appNameLabel?.setAccessibilityLabel(L("overlay.appLabel", displayAppName))
        windowTitleLabel?.setAccessibilityLabel(
            L("overlay.titleLabel", displayWindowTitle.isEmpty ? L("overlay.untitledWindow") : displayWindowTitle)
        )
    }

    func isHeaderClickTarget(at point: NSPoint) -> Bool {
        guard headerView.frame.contains(point) else { return false }
        let hit = headerView.hitTest(point) ?? headerView
        var current: NSView? = hit
        while let view = current {
            if view is NSButton || view === noteEditor {
                return false
            }
            current = view.superview
        }
        return true
    }

    private func configureTrafficButton(_ b: NSButton, color: NSColor, label: String, help: String, id: String) {
        b.title = ""
        b.bezelStyle = .inline
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = color.cgColor
        b.layer?.cornerRadius = 6
        b.layer?.borderWidth = 0.5
        b.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
        b.setAccessibilityLabel(label)
        b.setAccessibilityHelp(help)
        b.setAccessibilityIdentifier(id)
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 12),
            b.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    /// Wire capability-gated handlers. Nil handler = disabled control with
    /// the localized reason as tooltip/help.
    func setWindowControls(
        canMinimize: Bool, minimizeReason: String? = nil,
        canFullscreen: Bool = true, fullscreenReason: String? = nil,
        canZoom: Bool = true, zoomReason: String? = nil,
        onClose: (() -> Void)? = nil, onMinimize: (() -> Void)? = nil,
        onZoom: ((Bool) -> Void)? = nil
    ) {
        onCloseHandler = onClose
        onMinimizeHandler = canMinimize ? onMinimize : nil
        onZoomHandler = (canFullscreen || canZoom) ? onZoom : nil
        closeButton.isEnabled = onClose != nil
        minimizeButton.isEnabled = canMinimize && onMinimize != nil
        let zoomEnabled = (canFullscreen || canZoom) && onZoom != nil
        zoomButton.isEnabled = zoomEnabled
        minimizeButton.toolTip = minimizeButton.isEnabled ? L("overlay.minimizeHelp") : minimizeReason
        minimizeButton.setAccessibilityHelp(minimizeButton.toolTip)
        zoomButton.setAccessibilityLabel(L(canFullscreen ? "overlay.fullscreenNote" : "overlay.zoomNote"))
        zoomButton.toolTip = zoomEnabled ? L(canFullscreen ? "overlay.fullscreenHelp" : "overlay.zoomHelp") : (fullscreenReason ?? zoomReason)
        zoomButton.setAccessibilityHelp(zoomButton.toolTip)
        refreshTrafficColors()
    }

    private func refreshTrafficColors() {
        // ponytail: dimmed gray ceiling for disabled dots; re-enable restores color.
        closeButton.layer?.backgroundColor = (closeButton.isEnabled ? NSColor.systemRed : NSColor.systemGray).cgColor
        minimizeButton.layer?.backgroundColor = (minimizeButton.isEnabled ? NSColor.systemYellow : NSColor.systemGray).cgColor
        zoomButton.layer?.backgroundColor = (zoomButton.isEnabled ? NSColor.systemGreen : NSColor.systemGray).cgColor
    }

    func showWindowOperationError(_ message: String) {
        showPinFeedback(message: message, duration: 5)
        windowOperationMessage = message
    }

    func clearWindowOperationError() {
        if windowOperationMessage != nil { clearPinFeedback() }
    }

    var windowOperationErrorForTests: String? { windowOperationMessage }

    var isMinimizeEnabledForTests: Bool { minimizeButton.isEnabled }
    var isFullscreenEnabledForTests: Bool { zoomButton.isEnabled }
    var isZoomEnabledForTests: Bool { zoomButton.isEnabled }
    var trafficLightCountForTests: Int { [closeButton, minimizeButton, zoomButton].filter { $0.superview != nil }.count }

    /// ponytail: native AppKit borderless drag; the window delegate
    /// synchronizes moves to the target. Editor/buttons consume their own
    /// mouse events, so editing and clicks are unaffected.
    override var mouseDownCanMoveWindow: Bool { true }

    @objc
    private func closePressed(_ sender: Any?) { onCloseHandler?() }

    @objc
    private func minimizePressed(_ sender: Any?) { onMinimizeHandler?() }

    @objc
    private func zoomPressed(_ sender: Any?) {
        // ponytail: Option-green = zoom, plain green = fullscreen toggle.
        let option = NSApp?.currentEvent?.modifierFlags.contains(.option) ?? false
        onZoomHandler?(option)
    }

    @objc
    private func backPressed(_ sender: Any?) {
        backAction?()
    }

    func clearAction() {
        clearPinFeedback()
        clearWindowOperationError()
        onCloseHandler = nil
        onMinimizeHandler = nil
        onZoomHandler = nil
        backAction = nil
        backButton.target = nil
        backButton.action = nil
        pinTarget = nil
        archiveTarget = nil
        noteEditor.clearCallback()
    }
}

@MainActor
private final class ClosureTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
        super.init()
    }

    @objc func fire() { handler() }
}
