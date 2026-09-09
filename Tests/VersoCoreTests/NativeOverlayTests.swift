import AppKit
import Testing
import VersoCore
@testable import Verso

@MainActor
@Suite("Native overlay controls")
struct NativeOverlayTests {
    @Test("Header buttons do not trigger return while noninteractive labels still do")
    func headerControlExclusions() throws {
        _ = NSApplication.shared
        let content = OverlayContentView(
            appName: "Synthetic app", windowTitle: "Synthetic note", appIcon: nil,
            backAction: {}, onPin: {}, onArchive: {}
        )
        content.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        content.revealNoteSurface()
        content.layoutSubtreeIfNeeded()
        let views = descendants(content)
        let buttons = views.compactMap { $0 as? NSButton }
        #expect(buttons.count == 6)
        for button in buttons {
            #expect(!content.isHeaderClickTarget(at: center(of: button, in: content)))
        }
        let label = try #require(views.compactMap { $0 as? NSTextField }.first {
            $0.stringValue == "Synthetic note" && !$0.isHiddenOrHasHiddenAncestor
        })
        #expect(content.isHeaderClickTarget(at: center(of: label, in: content)))
        #expect(!content.isHeaderClickTarget(at: NSPoint(x: 300, y: 30)))
        content.clearAction()
    }

    @Test("Surface CGColors refresh when the view appearance changes")
    func surfaceColorsFollowEffectiveAppearance() {
        _ = NSApplication.shared
        let content = OverlayContentView(
            appName: "Synthetic app", windowTitle: "Synthetic note", appIcon: nil,
            backAction: {}
        )

        content.appearance = NSAppearance(named: .aqua)
        let lightColor = content.frontFaceLayer.backgroundColor

        content.appearance = NSAppearance(named: .darkAqua)
        let darkColor = content.frontFaceLayer.backgroundColor
        var expectedDarkColor: CGColor?
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            expectedDarkColor = NSColor.windowBackgroundColor.cgColor
        }

        #expect(lightColor != nil)
        #expect(lightColor != darkColor)
        #expect(darkColor == expectedDarkColor)
        #expect(content.noteSurfaceLayer.backgroundColor == darkColor)
        content.clearAction()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func center(of view: NSView, in content: NSView) -> NSPoint {
        content.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
    }

    @Test("Expanded canvas keeps the full face centered on its target and restores the editor")
    func expandedLayoutFaceOffset() {
        _ = NSApplication.shared
        let content = OverlayContentView(appName: "Test app", windowTitle: nil,
                                         appIcon: nil, backAction: {})
        content.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        content.layoutSubtreeIfNeeded()
        let faceFrame = CGRect(x: 0, y: 150, width: 640, height: 462)
        content.installExpandedLayout(faceFrame: faceFrame)
        #expect(content.flipContainerLayer.frame == faceFrame)
        #expect(content.frontFaceLayer.bounds.size == faceFrame.size)
        #expect(content.frontFaceLayer.anchorPoint == CGPoint(x: 0.5, y: 0.5))
        #expect(content.noteSurfaceLayer.anchorPoint == CGPoint(x: 0.5, y: 0.5))
        #expect(content.frontFaceLayer.position == CGPoint(x: 320, y: 231))
        #expect(content.noteSurfaceLayer.position == CGPoint(x: 320, y: 231))
        content.restoreTightLayout()
        #expect(content.flipContainerLayer.frame == content.bounds)
        #expect(content.noteSurfaceLayer.bounds.size == content.bounds.size)
        #expect(content.flipContainerLayer.isHidden)
        #expect(!content.hasNoteSnapshot)
        content.clearAction()
    }

    @Test("Face shadow configures and removes shadow on wrapper layers")
    func faceShadowLifecycle() {
        _ = NSApplication.shared
        let content = OverlayContentView(
            appName: "Test app", windowTitle: nil, appIcon: nil,
            backAction: {}
        )
        content.frame = NSRect(x: 0, y: 0, width: 640, height: 462)
        content.layoutSubtreeIfNeeded()

        content.configureFaceShadow()
        let frontLayer = content.frontFaceLayer
        let backLayer = content.noteSurfaceLayer
        #expect(frontLayer.shadowOpacity > 0)
        #expect(frontLayer.shadowPath != nil)
        #expect(backLayer.shadowOpacity > 0)
        #expect(backLayer.shadowPath != nil)

        content.removeFaceShadow()
        #expect(frontLayer.shadowOpacity == 0)
        #expect(frontLayer.shadowPath == nil)
        #expect(backLayer.shadowOpacity == 0)
        #expect(backLayer.shadowPath == nil)
        content.clearAction()
    }

    @Test("Backdrop installs and clears correctly")
    func backdropLifecycle() {
        _ = NSApplication.shared
        let content = OverlayContentView(
            appName: "Test app", windowTitle: nil, appIcon: nil,
            backAction: {}
        )
        content.frame = NSRect(x: 0, y: 0, width: 640, height: 462)
        content.layoutSubtreeIfNeeded()

        #expect(content.backdropLayer.contents == nil)

        let image = makeTestImage()
        let capture = TemporaryCaptureResource()
        capture.attach(image, to: content.backdropLayer)
        content.showBackdrop()
        #expect(content.backdropLayer.contents != nil)

        capture.clear()
        #expect(capture.image == nil)
        #expect(content.backdropLayer.contents == nil)
        content.clearBackdrop()
        #expect(content.backdropLayer.isHidden)
        content.clearAction()
    }

    @Test("Pin icon, tooltip and accessibility follow persisted state")
    func pinStateDrivesChrome() throws {
        _ = NSApplication.shared
        let pinned = OverlayContentView(
            appName: "Synthetic app", windowTitle: "Synthetic note", appIcon: nil,
            initialText: "Saved note", isPinned: true,
            backAction: {}, onPin: {}, onArchive: {}
        )
        pinned.frame = NSRect(x: 0, y: 0, width: 640, height: 462)
        pinned.revealNoteSurface()
        pinned.layoutSubtreeIfNeeded()
        #expect(pinned.pinStateForTests)
        #expect(pinned.pinSymbolNameForTests == "pin.fill")
        let pinnedButtons = descendants(pinned).compactMap { $0 as? NSButton }
        let pinnedButton = try #require(pinnedButtons.first {
            $0.toolTip == L("overlay.unpinTooltip")
        })
        #expect(pinnedButton.state == .off)
        let actualPinnedImage = try #require(pinnedButton.image?.tiffRepresentation)
        let expectedPinnedImage = try #require(NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?.tiffRepresentation)
        #expect(actualPinnedImage == expectedPinnedImage)
        #expect(pinnedButton.accessibilityLabel() == L("overlay.unpinNote"))
        pinned.clearAction()

        let unpinned = OverlayContentView(
            appName: "Synthetic app", windowTitle: "Synthetic note", appIcon: nil,
            initialText: "Saved note", isPinned: false,
            backAction: {}, onPin: {}, onArchive: {}
        )
        unpinned.frame = NSRect(x: 0, y: 0, width: 640, height: 462)
        unpinned.revealNoteSurface()
        unpinned.layoutSubtreeIfNeeded()
        #expect(!unpinned.pinStateForTests)
        #expect(unpinned.pinSymbolNameForTests == "pin")
        let unpinnedButtons = descendants(unpinned).compactMap { $0 as? NSButton }
        let unpinnedButton = try #require(unpinnedButtons.first {
            $0.toolTip == L("overlay.pinTooltip")
        })
        #expect(unpinnedButton.state == .off)
        let actualUnpinnedImage = try #require(unpinnedButton.image?.tiffRepresentation)
        let expectedUnpinnedImage = try #require(NSImage(systemSymbolName: "pin", accessibilityDescription: nil)?.tiffRepresentation)
        #expect(actualUnpinnedImage == expectedUnpinnedImage)
        #expect(actualPinnedImage != actualUnpinnedImage)
        #expect(unpinnedButton.accessibilityLabel() == L("overlay.pinNote"))
        unpinned.clearAction()
    }

    @Test("Pin feedback replaces, expires and cleans up without touching the editor")
    func pinFeedbackLifecycle() throws {
        _ = NSApplication.shared
        let content = OverlayContentView(
            appName: "Synthetic app", windowTitle: "Synthetic note", appIcon: nil,
            initialText: "editor text",
            backAction: {}, onPin: {}, onArchive: {}
        )
        content.frame = NSRect(x: 0, y: 0, width: 640, height: 462)
        content.revealNoteSurface()
        content.layoutSubtreeIfNeeded()
        let editor = try #require(
            descendants(content).compactMap { $0 as? NativeNoteEditor }.first
        )
        let editorFrame = editor.frame
        let undo = editor.textView.undoManager

        content.showPinSuccess(pinned: true)
        #expect(content.isPinFeedbackVisibleForTests)
        #expect(content.pinFeedbackTextForTests == L("overlay.pinnedFeedback"))
        #expect(content.pinSymbolNameForTests == "pin.fill")

        // A newer message replaces the pending one; failure keeps the icon.
        content.showPinFailure()
        #expect(content.pinFeedbackTextForTests == L("overlay.pinSaveFailed"))
        #expect(content.pinSymbolNameForTests == "pin.fill")
        let label = try #require(
            descendants(content).compactMap { $0 as? NSTextField }.first {
                $0.stringValue == L("overlay.pinSaveFailed")
            }
        )
        #expect(label.refusesFirstResponder)
        #expect(label.hitTest(.zero) == nil)
        #expect(label.accessibilityIdentifier() == "overlay.pinFeedback")
        content.layoutSubtreeIfNeeded()
        #expect(!content.convert(label.bounds, from: label).intersects(content.convert(editor.bounds, from: editor)))
        content.layoutSubtreeIfNeeded()
        var ancestor = label.superview
        while let parent = ancestor {
            #expect(parent.bounds.contains(parent.convert(label.bounds, from: label)))
            ancestor = parent.superview
        }

        content.clearPinFeedback()
        #expect(!content.isPinFeedbackVisibleForTests)
        #expect(content.pinFeedbackTextForTests == nil)
        content.layoutSubtreeIfNeeded()
        #expect(editor.frame == editorFrame)
        #expect(editor.text == "editor text")
        #expect(editor.textView.undoManager === undo)

        content.showPinSuccess(pinned: false)
        #expect(content.isPinFeedbackVisibleForTests)
        content.clearAction()
        #expect(!content.isPinFeedbackVisibleForTests)
    }

    @Test("Blank notes disable pin/archive until text is entered")
    func emptyNoteActions() throws {
        _ = NSApplication.shared
        let content = OverlayContentView(appName: "Synthetic", windowTitle: "Blank", appIcon: nil,
                                         initialText: "", backAction: {})
        defer { content.clearAction() }
        let views = descendants(content)
        let editor = try #require(views.compactMap { $0 as? NativeNoteEditor }.first)
        let pin = try #require(views.compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "overlay.pin"
        })
        let archive = try #require(views.compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == L("overlay.archiveNote")
        })
        #expect(!pin.isEnabled && !archive.isEnabled)
        #expect(pin.toolTip == L("overlay.emptyNoteHelp"))
        editor.textView.string = "Not / Note"
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: editor.textView))
        #expect(pin.isEnabled && archive.isEnabled)
        editor.textView.string = " \n\t "
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: editor.textView))
        #expect(!pin.isEnabled && !archive.isEnabled)
    }

    @Test("Pin feedback keeps the editor first responder and preserves real undo and redo")
    func pinFeedbackEditingHistory() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = OverlayContentView(appName: "Synthetic", windowTitle: "Undo QA", appIcon: nil,
                                         initialText: "draft", backAction: {})
        window.contentView = content
        content.revealNoteSurface()
        content.layoutSubtreeIfNeeded()
        defer { content.clearAction(); window.close() }
        let editor = try #require(descendants(content).compactMap { $0 as? NativeNoteEditor }.first)
        #expect(window.makeFirstResponder(editor.textView))
        let manager = try #require(editor.textView.undoManager)
        editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        editor.textView.insertText(" changed", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.textView.breakUndoCoalescing()
        #expect(editor.text == "draft changed")
        content.showPinSuccess(pinned: true)
        content.showPinFailure()
        #expect(window.firstResponder === editor.textView)
        #expect(manager.canUndo)
        manager.undo()
        #expect(editor.text == "draft")
        manager.redo()
        #expect(editor.text == "draft changed")
    }

    @Test("Pin feedback uses real 2s and 5s deadlines and replaces pending dismissal")
    func pinFeedbackDeadlines() async throws {
        _ = NSApplication.shared
        let content = OverlayContentView(appName: "Synthetic", windowTitle: "Timer QA", appIcon: nil, backAction: {})
        defer { content.clearAction() }
        content.showPinSuccess(pinned: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(content.isPinFeedbackVisibleForTests)
        content.showPinFailure()
        // The original success deadline must not dismiss the replacement.
        try await Task.sleep(for: .milliseconds(2000))
        #expect(content.pinFeedbackTextForTests == L("overlay.pinSaveFailed"))
        try await Task.sleep(for: .milliseconds(3300))
        #expect(!content.isPinFeedbackVisibleForTests)
        content.showPinSuccess(pinned: false)
        try await Task.sleep(for: .milliseconds(2250))
        #expect(!content.isPinFeedbackVisibleForTests)
    }

    @Test("Pin feedback fits a narrow overlay without moving the editor")
    func pinFeedbackNarrowLayout() throws {
        _ = NSApplication.shared
        let content = OverlayContentView(
            appName: "Synthetic app", windowTitle: "Synthetic note", appIcon: nil,
            initialText: "narrow text",
            backAction: {}, onPin: {}, onArchive: {}
        )
        content.frame = NSRect(x: 0, y: 0, width: 320, height: 462)
        content.revealNoteSurface()
        content.layoutSubtreeIfNeeded()
        let editor = try #require(
            descendants(content).compactMap { $0 as? NativeNoteEditor }.first
        )
        let editorFrame = editor.frame
        #expect(editorFrame.width > 0)

        content.showPinSuccess(pinned: true)
        content.layoutSubtreeIfNeeded()
        #expect(content.isPinFeedbackVisibleForTests)
        #expect(editor.frame == editorFrame)
        #expect(editor.text == "narrow text")

        content.clearPinFeedback()
        content.layoutSubtreeIfNeeded()
        #expect(editor.frame == editorFrame)
        content.clearAction()
    }
}


@MainActor
@Suite("Phase 16A window controls")
struct Phase16AWindowControlTests {
    @Test("Traffic lights exist with accessible labels and are header-excluded")
    func trafficLightsPresent() {
        _ = NSApplication.shared
        let content = OverlayContentView(
            appName: "Synthetic app", windowTitle: "Synthetic note", appIcon: nil,
            backAction: {}, onPin: {}, onArchive: {}
        )
        content.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        content.revealNoteSurface()
        content.layoutSubtreeIfNeeded()
        defer { content.clearAction() }
        #expect(content.trafficLightCountForTests == 3)
        content.setWindowControls(canMinimize: true, canFullscreen: true, canZoom: true,
                                  onClose: {}, onMinimize: {}, onZoom: { _ in })
        #expect(content.isMinimizeEnabledForTests)
        #expect(content.isFullscreenEnabledForTests)
        #expect(content.isZoomEnabledForTests)
        // Every NSButton (traffic + header) is excluded from Option-header return.
        for b in descendants(content).compactMap({ $0 as? NSButton }) {
            let c = content.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), from: b)
            #expect(!content.isHeaderClickTarget(at: c))
        }
    }

    @Test("Unsupported controls disable with localized reason and failures announce")
    func unsupportedControlsDisabled() {
        _ = NSApplication.shared
        let content = OverlayContentView(
            appName: "Synthetic app", windowTitle: nil, appIcon: nil, backAction: {})
        content.revealNoteSurface()
        content.layoutSubtreeIfNeeded()
        defer { content.clearAction() }
        content.setWindowControls(canMinimize: false, minimizeReason: L("overlay.minimizeUnsupported"),
                                  canFullscreen: false, fullscreenReason: L("overlay.fullscreenUnsupported"),
                                  canZoom: false, zoomReason: L("overlay.zoomUnsupported"),
                                  onClose: {}, onMinimize: {}, onZoom: { _ in })
        #expect(!content.isMinimizeEnabledForTests)
        #expect(!content.isFullscreenEnabledForTests)
        content.showWindowOperationError(L("overlay.windowOpFailed"))
        #expect(content.windowOperationErrorForTests == L("overlay.windowOpFailed"))
        content.clearWindowOperationError()
        #expect(content.windowOperationErrorForTests == nil)
    }

    @Test("Window failures replace pin feedback in the same fixed row")
    func sharedWindowFeedbackDoesNotMoveEditor() throws {
        _ = NSApplication.shared
        let content = OverlayContentView(appName: "Synthetic", windowTitle: "Test", appIcon: nil,
                                         initialText: "keep", backAction: {}, onPin: {}, onArchive: {})
        content.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
        content.revealNoteSurface()
        content.layoutSubtreeIfNeeded()
        defer { content.clearAction() }
        let editor = try #require(descendants(content).compactMap { $0 as? NativeNoteEditor }.first)
        let frame = editor.frame
        content.showPinSuccess(pinned: true)
        content.showWindowOperationError(L("overlay.windowOpFailed"))
        content.layoutSubtreeIfNeeded()
        #expect(content.pinFeedbackTextForTests == L("overlay.windowOpFailed"))
        #expect(editor.frame == frame)
        #expect(editor.text == "keep")
        content.showPinSuccess(pinned: false)
        #expect(content.windowOperationErrorForTests == nil)
        content.clearWindowOperationError()
        #expect(content.pinFeedbackTextForTests == L("overlay.unpinnedFeedback"))
    }

    @Test("Pin feedback and editor text survive control updates")
    func editorSurvivesControlUpdates() {
        _ = NSApplication.shared
        let content = OverlayContentView(
            appName: "Synthetic app", windowTitle: nil, appIcon: nil,
            initialText: "keep me", backAction: {}, onPin: {}, onArchive: {})
        content.frame = NSRect(x: 0, y: 0, width: 640, height: 462)
        content.revealNoteSurface()
        content.layoutSubtreeIfNeeded()
        defer { content.clearAction() }
        let editor = descendants(content).compactMap { $0 as? NativeNoteEditor }.first
        #expect(editor?.text == "keep me")
        content.setWindowControls(canMinimize: true, canFullscreen: true, canZoom: true,
                                  onClose: {}, onMinimize: {}, onZoom: { _ in })
        content.showPinSuccess(pinned: true)
        #expect(editor?.text == "keep me")
        #expect(content.isPinFeedbackVisibleForTests)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

@MainActor
private func makeTestImage() -> CGImage {
    let bytes: [UInt8] = [0, 0, 0, 255]
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

extension NativeOverlayTests {
    @Test("Application tabs retain independent native editors, selection, undo and redo")
    func tabEditorHistory() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let first = UUID(), second = UUID()
        let tabs = [OverlayNoteTab(id: first, text: "Bir", pinned: false), OverlayNoteTab(id: second, text: "İki", pinned: true)]
        var changes: [String] = []
        let content = OverlayContentView(appName: "Synthetic", windowTitle: nil, appIcon: nil, initialText: "Bir", backAction: {}, onTextChange: { changes.append($0) })
        window.contentView = content
        content.revealNoteSurface()
        defer { content.clearAction(); window.close() }
        func select(_ id: UUID) {
            content.commitEditing()
            content.configureTabs(tabs, selectedID: id, onAdd: {}, onSelect: { _ in }, onClose: { _ in })
            content.layoutSubtreeIfNeeded()
        }
        select(first)
        let a = try #require(descendants(content).compactMap { $0 as? NativeNoteEditor }.first)
        let undoA = try #require(a.textView.undoManager)
        undoA.groupsByEvent = false
        undoA.beginUndoGrouping()
        a.textView.insertText(" Türkçe", replacementRange: NSRange(location: 3, length: 0))
        undoA.endUndoGrouping()
        a.textView.setSelectedRange(NSRange(location: 1, length: 2))
        select(second)
        let b = try #require(descendants(content).compactMap { $0 as? NativeNoteEditor }.first)
        let undoB = try #require(b.textView.undoManager)
        #expect(a !== b && undoA !== undoB)
        #expect(content.pinStateForTests)
        undoB.groupsByEvent = false
        undoB.beginUndoGrouping()
        b.textView.insertText(" English", replacementRange: NSRange(location: 3, length: 0))
        undoB.endUndoGrouping()
        select(first)
        #expect(window.firstResponder === a.textView)
        #expect(a.textView.selectedRange() == NSRange(location: 1, length: 2))
        #expect(a.text == "Bir Türkçe")
        #expect(!content.pinStateForTests)
        undoA.undo()
        #expect(a.text == "Bir" && b.text == "İki English")
        #expect(changes.last == "Bir")
        undoA.redo()
        #expect(a.text == "Bir Türkçe")
        select(second)
        undoB.undo()
        #expect(b.text == "İki" && a.text == "Bir Türkçe")
        #expect(changes.last == "İki")
    }

    @Test("Tab shortcuts cycle and close the selected tab without returning the window")
    func tabShortcutsAndOverflow() throws {
        _ = NSApplication.shared
        let tabs = (0..<12).map { OverlayNoteTab(id: UUID(), text: "Uzun Türkçe başlık \($0) " + String(repeating: "abcçğıöşü", count: 12), pinned: false) }
        let content = OverlayContentView(appName: "Synthetic", windowTitle: nil, appIcon: nil, backAction: { Issue.record("Unexpected return") })
        content.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
        content.revealNoteSurface()
        defer { content.clearAction() }
        var added = 0, selected: UUID?, closed: UUID?
        content.configureTabs(tabs, selectedID: tabs[0].id, onAdd: { added += 1 }, onSelect: { selected = $0 }, onClose: { closed = $0 })
        content.layoutSubtreeIfNeeded()
        func key(_ text: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        #expect(content.handleTabShortcut(try key("t", 17, .command)))
        #expect(added == 1)
        #expect(content.handleTabShortcut(try key("w", 13, .command)))
        #expect(closed == tabs[0].id)
        #expect(content.handleTabShortcut(try key("\t", 48, .control)))
        #expect(selected == tabs[1].id)
        #expect(content.handleTabShortcut(try key("\t", 48, [.control, .shift])))
        #expect(selected == tabs.last?.id)
        content.setEditingEnabled(false)
        #expect(!content.handleTabShortcut(try key("t", 17, .command)))
        let add = try #require(descendants(content).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "overlay.newTab" })
        #expect(!add.isEnabled)
        #expect(add.toolTip == L("tabs.newHelp"))
        content.setEditingEnabled(true)
        add.performClick(nil)
        #expect(added == 2)
        let selectButton = try #require(descendants(content).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "overlay.tab.\(tabs[1].id.uuidString)"
        })
        selectButton.performClick(nil)
        #expect(selected == tabs[1].id)
        #expect(!content.isHeaderClickTarget(at: center(of: add, in: content)))
        let editor = try #require(descendants(content).compactMap { $0 as? NativeNoteEditor }.first)
        #expect(editor.frame.width > 0 && editor.frame.height > 0)
        let scroll = try #require(descendants(content).compactMap { $0 as? NSScrollView }.first { $0.accessibilityLabel() == L("tabs.list") })
        #expect(scroll.documentView!.frame.width > scroll.contentView.bounds.width)
    }
}
