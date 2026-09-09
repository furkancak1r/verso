// desktop-smoke.swift — Bounded AppKit/AX/CGEvent smoke runner for Verso.
// All waits yield the main runloop via @MainActor async Task.sleep.
// No Thread.sleep in app main. No private APIs. No dependencies.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - CF-identity wrapper for cycle-safe AX traversal

struct AXID: Hashable {
    let r: AXUIElement
    static func == (l: Self, r: Self) -> Bool { CFEqual(l.r, r.r) }
    func hash(into h: inout Hasher) { h.combine(CFHash(r)) }
}

// MARK: - Safe AX helpers

func ax(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(el, 0.2)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
    return v
}
func axS(_ el: AXUIElement, _ a: String) -> String? { ax(el, a) as? String }
func axRole(_ el: AXUIElement) -> String? { axS(el, kAXRoleAttribute as String) }
func axTitle(_ el: AXUIElement) -> String? { axS(el, kAXTitleAttribute as String) }
func axVal(_ el: AXUIElement) -> String? { axS(el, kAXValueAttribute as String) }
func axFrontmost(_ el: AXUIElement) -> Bool { (ax(el, kAXFrontmostAttribute as String) as? NSNumber)?.boolValue ?? false }

func axElement(_ raw: CFTypeRef?) -> AXUIElement? {
    guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    return (raw as! AXUIElement)
}
func axElements(_ el: AXUIElement, _ attribute: String, allowMissing: Bool = false) -> [AXUIElement] {
    AXUIElementSetMessagingTimeout(el, 0.2)
    var raw: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(el, attribute as CFString, &raw)
    if allowMissing && (error == .attributeUnsupported || error == .noValue) { return [] }
    guard error == .success, let raw, CFGetTypeID(raw) == CFArrayGetTypeID(),
          let elements = raw as? [AXUIElement],
          elements.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else {
        abortRun("ax_read", "\(attribute) unavailable or malformed (\(error.rawValue))")
    }
    return elements
}
func axWins(_ app: AXUIElement) -> [AXUIElement] {
    let windows = axElements(app, kAXWindowsAttribute)
    guard windows.allSatisfy({ axRole($0) == "AXWindow" }) else {
        abortRun("ax_windows", "Windows are not actionable; unlock the desktop")
    }
    return windows
}
func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    axElements(el, kAXChildrenAttribute, allowMissing: true)
}
func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let pR = ax(el, kAXPositionAttribute as String), let sR = ax(el, kAXSizeAttribute as String),
          CFGetTypeID(pR) == AXValueGetTypeID(), CFGetTypeID(sR) == AXValueGetTypeID(),
          AXValueGetType(pR as! AXValue) == .cgPoint, AXValueGetType(sR as! AXValue) == .cgSize else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(pR as! AXValue, .cgPoint, &p), AXValueGetValue(sR as! AXValue, .cgSize, &s) else { return nil }
    guard p.x.isFinite, p.y.isFinite, s.width.isFinite, s.height.isFinite,
          s.width > 0, s.height > 0 else { return nil }
    return CGRect(origin: p, size: s)
}
func axFocusedWin(_ app: AXUIElement) -> AXUIElement? {
    guard let r = axElement(ax(app, kAXFocusedWindowAttribute)), axRole(r) == "AXWindow" else { return nil }
    return r
}

// Find editor: AXTextArea or AXGroup(desc=translated "Note editor"). CFEqual cycle detection, max256 nodes/depth 8.
// ponytail: only the two shipped localizations are accepted; unrelated groups never match.
let editorGroupLabels: Set<String> = ["Note editor", "Not düzenleyici"]
func findEditor(_ el: AXUIElement, _ depth: Int = 0, _ vis: inout Set<AXID>) -> AXUIElement? {
    guard vis.insert(AXID(r: el)).inserted else { return nil }
    guard depth < 12, vis.count <= 256, let role = axRole(el) else {
        abortRun("ax_tree", "Accessibility tree could not be inspected within its bound")
    }
    if role == "AXTextArea" { return el }
    if role == "AXGroup", let d = axS(el, kAXDescriptionAttribute as String), editorGroupLabels.contains(d) { return el }
    if role == "AXApplication" || role == "AXMenuBar" || role == "AXMenu" {
        abortRun("ax_tree", "Unexpected application/menu element in window tree")
    }
    for c in axChildren(el) { if let f = findEditor(c, depth + 1, &vis) { return f } }
    return nil
}
func hasEditor(_ el: AXUIElement) -> Bool { var v = Set<AXID>(); return findEditor(el, 0, &v) != nil }

func framesClose(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 2) -> Bool {
    abs(a.origin.x - b.origin.x) <= tol && abs(a.origin.y - b.origin.y) <= tol &&
    abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
}

// Build a complete pair before posting. Unicode is UTF-16, including surrogate pairs.
func keyPair(_ code: CGKeyCode, _ flags: CGEventFlags = [], text: String? = nil) -> (CGEvent, CGEvent)? {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return nil }
    down.flags = flags; up.flags = flags
    if let text {
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
        }
    }
    return (down, up)
}
let kZ: CGKeyCode = 6, kF: CGKeyCode = 3, kEsc: CGKeyCode = 53

// MARK: - Results

final class Results: @unchecked Sendable {
    private(set) var s: [[String: Any]] = []
    var inputPairsSubmitted = 0
    var windowsCreated = 0
    private let l = NSLock()
    func add(_ d: [String: Any]) { l.lock(); s.append(d); l.unlock() }
}
let res = Results()
func emit(_ stage: String, _ status: String, _ x: [String: Any] = [:]) {
    var d: [String: Any] = ["stage": stage, "status": status]
    for (k, v) in x { d[k] = v }
    res.add(d)
    if status != "ok" {
        printResults()
        // Process exit closes only this runner's own synthetic windows.
        Darwin.exit(1)
    }
}
func abortRun(_ stage: String, _ reason: String) -> Never {
    emit(stage, "fail", ["reason": reason])
    Darwin.exit(1)
}
func stagesPass(_ stages: [[String: Any]]) -> Bool {
    !stages.isEmpty && stages.allSatisfy { $0["status"] as? String == "ok" }
}

func monotonic() -> Double { ProcessInfo.processInfo.systemUptime }
func wait(_ t: Double) async { try? await Task.sleep(nanoseconds: UInt64(t * 1e9)) }

@MainActor
func poll(_ timeout: Double, _ every: Double = 0.25, _ f: @MainActor () -> Bool) async -> Bool {
    let dl = monotonic() + timeout
    while monotonic() < dl { if f() { return true }; await wait(every) }
    return f()
}

// Validate AXUIElementCopyElementAtPosition hits our synthetic window
func clickValid(_ pt: CGPoint, _ synthWin: AXUIElement, frame: CGRect) -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
          let actual = axFrame(synthWin), framesClose(actual, frame) else { return false }
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.2)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, Float(pt.x), Float(pt.y), &hit) == .success,
          let h = hit else { return false }
    var hitPID: pid_t = 0
    guard AXUIElementGetPid(h, &hitPID) == .success, hitPID == getpid() else { return false }
    var cur: AXUIElement? = h; var d = 0
    while let c = cur, d < 8 {
        if axRole(c) == "AXWindow" { return CFEqual(c, synthWin) }
        cur = axElement(ax(c, kAXParentAttribute)); d += 1
    }
    return false
}

// Verify Verso overlay: frontmost, focused window matches title/frame, has editor
func versoReady(_ vax: AXUIElement, _ title: String, _ frame: CGRect, allowFind: Bool = false) -> AXUIElement? {
    guard axFrontmost(vax), let fw = axFocusedWin(vax), axTitle(fw) == title,
          let ff = axFrame(fw), framesClose(ff, frame) else { return nil }
    var s = Set<AXID>()
    guard let editor = findEditor(fw, 0, &s),
          let focused = axElement(ax(vax, kAXFocusedUIElementAttribute)) else { return nil }
    if CFEqual(focused, editor) { return editor }
    if allowFind, ["AXTextField", "AXSearchField"].contains(axRole(focused) ?? ""),
       let window = axElement(ax(focused, kAXWindowAttribute)), CFEqual(window, fw) { return editor }
    return nil
}

// Only inspect controls inside the already-validated synthetic note window.
func identifiedControl(in window: AXUIElement, id: String) -> AXUIElement? {
    guard axRole(window) == "AXWindow" else { abortRun("control_tree", "Expected synthetic window") }
    var seen = Set<AXID>()
    var matches: [AXUIElement] = []
    func visit(_ element: AXUIElement, _ depth: Int) {
        guard seen.insert(AXID(r: element)).inserted else { return }
        guard depth < 12, seen.count <= 256 else { abortRun("control_tree", "Synthetic control tree bound exceeded") }
        let role = axRole(element)
        if role == "AXApplication" || role == "AXMenuBar" || role == "AXMenu" {
            abortRun("control_tree", "Unexpected application/menu in synthetic window")
        }
        if axS(element, "AXIdentifier") == id { matches.append(element) }
        if role == "AXTextArea" { return }
        for child in axChildren(element) { visit(child, depth + 1) }
    }
    visit(window, 0)
    guard matches.count <= 1 else { abortRun("control_tree", "Ambiguous synthetic control") }
    return matches.first
}

// MARK: - Self-check (pure, no GUI, no project root)

func selfCheck() -> Int32 {
    var ok = true
    let t = "Verso 🌍\nçğıöşü ÇĞİÖŞÜ"
    let u = Array(t.utf16)
    let rt = String(utf16CodeUnits: u, count: u.count) == t && u.count > t.count
    print("selfcheck surrogate_roundtrip: \(rt ? "ok" : "FAIL") (\(u.count) utf16)")
    ok = ok && rt
    if let (down, up) = keyPair(0, text: t) {
        let encoded = [down, up].allSatisfy { event in
            var count = 0
            var buffer = [UniChar](repeating: 0, count: u.count + 1)
            event.keyboardGetUnicodeString(maxStringLength: buffer.count,
                                           actualStringLength: &count, unicodeString: &buffer)
            return count == u.count && String(decoding: buffer.prefix(count), as: UTF16.self) == t
        }
        print("selfcheck native_event_unicode: \(encoded ? "ok" : "FAIL")")
        ok = ok && encoded
    } else { print("selfcheck native_event_unicode: FAIL"); ok = false }
    let geo = framesClose(CGRect(x: 100, y: 200, width: 600, height: 400),
                          CGRect(x: 101, y: 199, width: 601, height: 401)) &&
              !framesClose(CGRect(x: 100, y: 200, width: 600, height: 400),
                          CGRect(x: 105, y: 200, width: 600, height: 400))
    print("selfcheck geometry: \(geo ? "ok" : "FAIL")")
    ok = ok && geo
    let agg = stagesPass([["status": "ok"]]) &&
        ["fail", "not_available", "not_observed", "observed_no_change"].allSatisfy {
            !stagesPass([["status": "ok"], ["status": $0]])
        } && !stagesPass([])
    print("selfcheck aggregation: \(agg ? "ok" : "FAIL")")
    ok = ok && agg
    let reference = CGRect(x: 100, y: 200, width: 600, height: 400)
    let changed = [CGRect(x: 105, y: 200, width: 600, height: 400),
                   CGRect(x: 100, y: 205, width: 600, height: 400),
                   CGRect(x: 100, y: 200, width: 605, height: 400),
                   CGRect(x: 100, y: 200, width: 600, height: 405)]
    let allAxes = changed.allSatisfy { !framesClose(reference, $0) }
    print("selfcheck all_geometry_components: \(allAxes ? "ok" : "FAIL")")
    ok = ok && allAxes
    // Pure parser cases: no GUI, no project root needed, no desktop input.
    let fakeDerived = "/tmp/verso-smoke-parser-root"
    func expectRun(_ a: [String]) -> ParsedRun? {
        let (cfg, err) = parseRunArgs(a, derivedRoot: fakeDerived)
        return err == nil ? cfg : nil
    }
    func expectErr(_ a: [String]) -> Bool { parseRunArgs(a, derivedRoot: fakeDerived).1 != nil }
    var argOk = true
    if let c = expectRun(["--run"]) {
        argOk = argOk && c.root == canonicalPath(fakeDerived) && c.appPath.hasSuffix("/build/Verso.app")
    } else { argOk = false }
    argOk = argOk && expectRun(["--run", "--project-root", fakeDerived]) != nil
    argOk = argOk && expectRun(["--run", "--app-path", fakeDerived + "/build/Verso.app"]) != nil
    argOk = argOk && expectErr(["--run", "--project-root"]) // missing value
    argOk = argOk && expectErr(["--run", "--app-path"]) // missing value
    argOk = argOk && expectErr(["--run", "--project-root", fakeDerived, "--project-root", fakeDerived]) // duplicate
    argOk = argOk && expectErr(["--run", "--app-path", fakeDerived + "/a.app", "--app-path", fakeDerived + "/b.app"]) // duplicate
    argOk = argOk && expectErr(["--run", "--bogus"]) // unknown
    argOk = argOk && expectErr(["--project-root", fakeDerived]) // missing --run
    argOk = argOk && expectErr([]) // empty
    argOk = argOk && expectErr(["--run", "--project-root", "relative/path"]) // relative root
    argOk = argOk && expectErr(["--run", "--app-path", "Verso.app"]) // relative app
    argOk = argOk && expectErr(["--run", "--project-root", "/tmp/verso-smoke-other-root"]) // root mismatch
    argOk = argOk && expectErr(["--run", "--app-path", "/tmp/Foo.bundle"]) // invalid app suffix
    argOk = argOk && validateAppBundle("/tmp/verso-no-such-app-xyz.app") != nil // nonexistent bundle
    do { // valid skeleton bundle passes filesystem validation, then is removed
        let skel = FileManager.default.temporaryDirectory
            .appendingPathComponent("verso-smoke-valid-\(UUID().uuidString).app").path
        let macOS = skel + "/Contents/MacOS"
        try FileManager.default.createDirectory(atPath: macOS, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: macOS + "/Verso", contents: Data("x".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOS + "/Verso")
        argOk = argOk && validateAppBundle(skel) != nil
        let info: [String: String] = ["CFBundleIdentifier": "com.verso.app", "CFBundleExecutable": "Verso", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: skel + "/Contents/Info.plist"))
        argOk = argOk && validateAppBundle(skel) == nil
        try? FileManager.default.removeItem(atPath: skel)
    } catch { argOk = false }
    let trAccepted = editorGroupLabels == ["Note editor", "Not düzenleyici"]
    print("selfcheck arg_parsing: \(argOk ? "ok" : "FAIL")")
    print("selfcheck editor_labels: \(trAccepted ? "ok" : "FAIL")")
    ok = ok && argOk && trAccepted
    print("selfcheck overall: \(ok ? "PASS" : "FAIL")")
    return ok ? 0 : 1
}

// MARK: - Argument parsing (pure: no GUI, no writes; failures exit 64 before NSApp starts)

struct ParsedRun {
    let root: String
    let appPath: String
}
func canonicalPath(_ p: String) -> String {
    URL(fileURLWithPath: p).resolvingSymlinksInPath().path
}
func parseRunArgs(_ args: [String], derivedRoot: String) -> (ParsedRun?, String?) {
    let usage = "Use --self-check or --run [--project-root PATH] [--app-path PATH]. No GUI was started."
    guard !args.isEmpty, args[0] == "--run" else { return (nil, usage) }
    var root: String? = nil
    var app: String? = nil
    var i = 1
    while i < args.count {
        let a = args[i]
        guard a == "--project-root" || a == "--app-path" else { return (nil, "Unknown argument: \(a). " + usage) }
        guard i + 1 < args.count, !args[i + 1].isEmpty, args[i + 1].hasPrefix("/") else {
            return (nil, "Missing absolute PATH value for \(a). " + usage)
        }
        if a == "--project-root" {
            guard root == nil else { return (nil, "Duplicate --project-root. " + usage) }
            root = args[i + 1]
        } else {
            guard app == nil else { return (nil, "Duplicate --app-path. " + usage) }
            app = args[i + 1]
        }
        i += 2
    }
    let canonDerived = canonicalPath(derivedRoot)
    let finalRoot = root.map { canonicalPath($0) } ?? canonDerived
    guard finalRoot == canonDerived else {
        return (nil, "Project root must match the generated test bundle. " + usage)
    }
    let rawApp = app ?? (canonDerived + "/build/Verso.app")
    guard rawApp.hasSuffix(".app") else {
        return (nil, "Invalid --app-path: expected an absolute .app bundle path. " + usage)
    }
    return (ParsedRun(root: canonDerived, appPath: canonicalPath(rawApp)), nil)
}
func validateAppBundle(_ appPath: String) -> String? {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: appPath, isDirectory: &isDir), isDir.boolValue else {
        return "Invalid --app-path: bundle not found at \(appPath)."
    }
    let exec = appPath + "/Contents/MacOS/Verso"
    var isFileDir: ObjCBool = false
    guard fm.fileExists(atPath: exec, isDirectory: &isFileDir), !isFileDir.boolValue,
          fm.isExecutableFile(atPath: exec) else {
        return "Invalid --app-path: expected executable at \(exec)."
    }
    guard let info = NSDictionary(contentsOf: URL(fileURLWithPath: appPath + "/Contents/Info.plist")),
          info["CFBundleIdentifier"] as? String == "com.verso.app",
          info["CFBundleExecutable"] as? String == "Verso" else {
        return "Invalid --app-path: expected the com.verso.app bundle and Verso executable."
    }
    return nil
}

// MARK: - Async smoke runner (runs on MainActor so NSWindow/AX calls are valid)

@MainActor
func smoke(root: String, appPath: String, pid: pid_t) async -> Bool {
    let bid = "com.verso.app"
    let execURL = URL(fileURLWithPath: appPath + "/Contents/MacOS/Verso")
    let uid = String(UUID().uuidString.prefix(8))
    let title = "SmokeTarget-\(uid)-\(pid)"
    let fixPath = root + "/.build/desktop-smoke/fixture-\(uid).txt"
    let selfAX = AXUIElementCreateApplication(pid)
    emit("init", "ok", ["uuid": uid, "pid": Int(pid)])

    // ---- Prerequisites (before window creation) ----
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    guard AXIsProcessTrustedWithOptions(opts) else { emit("prereq", "fail", ["why": "ax_trust"]); return false }
    guard CGPreflightPostEventAccess() else { emit("prereq", "fail", ["why": "cg_events"]); return false }
    guard !NSScreen.screens.isEmpty else { emit("prereq", "fail", ["why": "no_screen"]); return false }
    guard let fg = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
        emit("prereq", "fail", ["why": "foreground_unknown"]); return false
    }
    if fg == "com.apple.loginwindow" { emit("prereq", "fail", ["why": "loginwindow"]); return false }
    let procs = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
    guard procs.count == 1 else { emit("prereq", "fail", ["why": "verso_count", "n": procs.count]); return false }
    let versoApp = procs[0]
    guard let eu = versoApp.executableURL,
          eu.resolvingSymlinksInPath() == execURL.resolvingSymlinksInPath() else {
        emit("prereq", "fail", ["why": "verso_exec_mismatch"]); return false
    }
    let vax = AXUIElementCreateApplication(versoApp.processIdentifier)
    for w in axWins(vax) { if hasEditor(w) { emit("prereq", "fail", ["why": "existing_editor"]); return false } }
    guard let version = Bundle(path: appPath)?
        .infoDictionary?["CFBundleShortVersionString"] as? String else {
        emit("prereq", "fail", ["why": "verso_version_unavailable"]); return false
    }
    emit("prereq", "ok", ["verso_pid": Int(versoApp.processIdentifier), "verso_version": version,
                           "build_path": execURL.path])

    // ---- Create fixture file then synthetic window ----
    let fm = FileManager.default
    do {
        try fm.createDirectory(atPath: (fixPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(title.utf8).write(to: URL(fileURLWithPath: fixPath), options: .withoutOverwriting)
    } catch { abortRun("fixture", "Could not create the unique synthetic fixture") }
    NSApp.setActivationPolicy(.regular)
    let sw = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    res.windowsCreated += 1
    sw.collectionBehavior = [.fullScreenPrimary]
    sw.title = title; sw.isReleasedWhenClosed = false; sw.representedURL = URL(fileURLWithPath: fixPath)
    sw.contentView = NSTextField(labelWithString: "Smoke synthetic target")
    sw.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)

    guard await poll(3.0, 0.25, { axFrontmost(selfAX) }) else {
        emit("synth_frontmost", "fail"); sw.close(); return false
    }
    guard let synthWin = axWins(selfAX).first(where: { axTitle($0) == title }),
          let sf = axFrame(synthWin) else {
        emit("synth_window", "fail"); sw.close(); return false
    }
    let click = CGPoint(x: sf.midX, y: sf.origin.y + 20)
    emit("synth_window", "ok", ["x": Double(sf.origin.x), "w": Double(sf.width)])

    // ---- Option-click (validate hit target before posting events) ----
    guard clickValid(click, synthWin, frame: sf) else {
        emit("opt_click", "fail", ["why": "hit_validation"]); sw.close(); return false
    }
    guard let optDn = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: click, mouseButton: .left),
          let optUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: click, mouseButton: .left) else {
        abortRun("opt_click", "Cannot construct a complete mouse pair")
    }
    // Synthetic input needs the owning fixture app to allow the focus handoff.
    NSApp.yieldActivation(to: versoApp)
    await wait(0.15)
    guard !versoApp.isTerminated, clickValid(click, synthWin, frame: sf) else {
        abortRun("focus_handoff", "Target changed while activation handoff settled")
    }
    optDn.flags = .maskAlternate
    optUp.flags = .maskAlternate
    res.inputPairsSubmitted += 1
    optDn.post(tap: .cghidEventTap); optUp.post(tap: .cghidEventTap)
    emit("opt_click", "ok")
    if ProcessInfo.processInfo.environment["VERSO_SMOKE_REQUIRE_CAPTURE"] == "1" {
        // Only a successful window+backdrop capture expands this synthetic target's canvas.
        // Metadata only: no pixels are read or written by this observation.
        let captured = await poll(8.0, 0.02, {
            guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
            return windows.contains { item in
                guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == versoApp.processIdentifier,
                      item[kCGWindowName as String] as? String == title,
                      let bounds = item[kCGWindowBounds as String] as? [String: Any],
                      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
                return frame.width > sf.width + 10 && frame.height > sf.height + 10
            }
        })
        emit("capture_animation", captured ? "ok" : "fail")
        guard captured else { sw.close(); return false }
    }
    await wait(0.15)

    // ---- Wait for overlay with editor ----
    var ow: AXUIElement?
    var of: CGRect?
    let gotOverlay = await poll(8.0, 0.3, {
        for w in axWins(vax) {
            if axTitle(w) == title, let frame = axFrame(w), framesClose(frame, sf),
               versoReady(vax, title, sf) != nil { ow = w; of = frame; return true }
        }
        return false
    })
    guard gotOverlay, let ew = ow, let of else {
        emit("overlay", "fail", ["wins": axWins(vax).count]); sw.close(); return false
    }
    let oTitle = title
    emit("overlay", "ok", ["title": oTitle, "x": Double(of.origin.x), "w": Double(of.width)])

    // All data under this dedicated fixture bundle belongs to smoke tests.
    // Start a fresh tab so repeated app-scoped runs never overwrite prior fixtures.
    if identifiedControl(in: ew, id: "overlay.newTab") != nil {
        guard versoReady(vax, oTitle, of) != nil,
              let (down, up) = keyPair(17, .maskCommand) else {
            abortRun("new_fixture_tab", "Cannot construct a guarded tab shortcut")
        }
        res.inputPairsSubmitted += 1
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        await wait(0.3)
    }
    var ev = Set<AXID>()
    guard let editor = findEditor(ew, 0, &ev) else {
        emit("editor", "fail"); sw.close(); return false
    }
    emit("editor", "ok", ["role": axRole(editor) ?? "?"])

    // ---- Type Unicode text (initially empty, exact equality, one event pair = one undo group) ----
    guard let initText = axVal(editor), initText.isEmpty else {
        emit("editor_empty", "fail"); sw.close(); return false
    }
    guard versoReady(vax, oTitle, of) != nil else {
        emit("type_ready", "fail"); sw.close(); return false
    }
    func sendKey(_ code: CGKeyCode, _ flags: CGEventFlags = [], text: String? = nil, allowFind: Bool = false) {
        guard let (down, up) = keyPair(code, flags, text: text),
              !versoApp.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == versoApp.processIdentifier,
              versoReady(vax, title, sf, allowFind: allowFind) != nil else {
            abortRun("input_guard", "Expected synthetic overlay/editor is no longer focused")
        }
        res.inputPairsSubmitted += 1
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    let text = "Verso QA \(uid) 🌍\nçğıöşü ÇĞİÖŞÜ\n✅ 日本語"
    let u16Count = Array(text.utf16).count
    sendKey(0, text: text)
    let typedOk = await poll(3.0, 0.2, { axVal(editor) == text })
    guard typedOk else {
        emit("typed_text", "fail", ["exp_chars": text.count, "got_chars": (axVal(editor) ?? "").count])
        sw.close(); return false
    }
    emit("typed_text", "ok", ["chars": text.count, "utf16": u16Count])

    // ---- Pin feedback; every press remains scoped to this generated note ----
    let pinnedMessages: Set<String> = ["Not sabitlendi", "Note pinned"]
    let unpinnedMessages: Set<String> = ["Notun sabiti kaldırıldı", "Note unpinned"]
    func pinState(_ window: AXUIElement) -> Bool? {
        guard let button = identifiedControl(in: window, id: "overlay.pin"),
              ["AXButton", "AXCheckBox"].contains(axRole(button) ?? "") else { return nil }
        let value = ax(button, kAXValueAttribute)
        if let message = value as? String {
            if pinnedMessages.contains(message) { return true }
            if unpinnedMessages.contains(message) { return false }
        }
        return (value as? NSNumber)?.boolValue
    }
    func pinFeedback(_ window: AXUIElement) -> String? {
        guard let label = identifiedControl(in: window, id: "overlay.pinFeedback") else { return nil }
        return axVal(label)
    }
    func pressPin(_ window: AXUIElement, frame: CGRect, expected: Bool, stage: String) async {
        guard !versoApp.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == versoApp.processIdentifier,
              versoReady(vax, title, frame) != nil,
              axTitle(window) == title,
              axFrame(window).map({ framesClose($0, frame) }) == true,
              pinState(window) == !expected,
              let button = identifiedControl(in: window, id: "overlay.pin"),
              (ax(button, kAXEnabledAttribute) as? NSNumber)?.boolValue == true else {
            abortRun(stage, "Synthetic pin control/focus/state could not be verified")
        }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            abortRun(stage, "Synthetic pin press failed")
        }
        let accepted = expected ? pinnedMessages : unpinnedMessages
        let ok = await poll(1.0, 0.1, {
            pinState(window) == expected && accepted.contains(pinFeedback(window) ?? "") &&
                versoReady(vax, title, frame) != nil
        })
        emit(stage, ok ? "ok" : "fail", ["pinned": pinState(window) ?? !expected, "feedback_and_focus": ok])
    }
    guard pinState(ew) == false else { abortRun("pin_initial", "Unique new note must start unpinned") }
    await pressPin(ew, frame: of, expected: true, stage: "pin_on")
    await wait(2.25)
    let feedbackCleared = await poll(0.75, 0.1, { (pinFeedback(ew) ?? "").isEmpty })
    emit("pin_feedback_expiry", feedbackCleared ? "ok" : "fail")
    await pressPin(ew, frame: of, expected: false, stage: "pin_off")
    await pressPin(ew, frame: of, expected: true, stage: "pin_on_before_reopen")

    // ---- Undo (changes text) ----
    guard versoReady(vax, oTitle, of) != nil else {
        emit("undo", "fail", ["why": "focus_lost"]); sw.close(); return false
    }
    sendKey(kZ, .maskCommand)
    let undoOk = await poll(2.0, 0.2, {
        guard let value = axVal(editor) else { abortRun("undo", "Editor value unavailable") }
        return value != text
    })
    emit("undo", undoOk ? "ok" : "fail", ["changed": undoOk])

    // ---- Redo (restores exact text) ----
    guard versoReady(vax, oTitle, of) != nil else {
        emit("redo", "fail", ["why": "focus_lost"]); sw.close(); return false
    }
    sendKey(kZ, [.maskCommand, .maskShift])
    let redoOk = await poll(2.0, 0.2, { axVal(editor) == text })
    emit("redo", redoOk ? "ok" : "fail", ["restored": redoOk])

    // ---- Cmd+F find bar ----
    guard versoReady(vax, oTitle, of) != nil else {
        emit("cmdf", "fail", ["why": "focus_lost"]); sw.close(); return false
    }
    sendKey(kF, .maskCommand)
    let findOk = await poll(2.0, 0.2, {
        var fv = Set<AXID>()
        func findField(_ el: AXUIElement, _ d: Int = 0) -> AXUIElement? {
            guard fv.insert(AXID(r: el)).inserted else { return nil }
            guard d < 12, fv.count <= 256 else { abortRun("find_tree", "Accessibility traversal bound exceeded") }
            let r = axRole(el); if r == "AXTextField" || r == "AXSearchField" { return el }
            for c in axChildren(el) { if let ff = findField(c, d + 1) { return ff } }
            return nil
        }
        return findField(ew) != nil
    })
    emit("cmd_f_find", findOk ? "ok" : "not_available", ["found": findOk])

    // ---- Escape: BOTH overlay disappearance AND target refocus ----
    sendKey(kEsc, allowFind: true)
    let overlayGone = await poll(3.0, 0.2, { !axWins(vax).contains(where: { hasEditor($0) }) })
    let targetBack = await poll(2.0, 0.2, {
        guard axFrontmost(selfAX), let focused = axFocusedWin(selfAX) else { return false }
        return CFEqual(focused, synthWin)
    })
    emit("escape", (overlayGone && targetBack) ? "ok" : "fail", ["gone": overlayGone, "refocused": targetBack])

    // ---- Reopen: same title/frame/editor + exact text ----
    guard clickValid(click, synthWin, frame: sf) else {
        emit("reopen", "fail", ["why": "click_invalid"]); sw.close(); return false
    }
    guard let reDn = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: click, mouseButton: .left),
          let reUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: click, mouseButton: .left) else {
        abortRun("reopen", "Cannot construct a complete mouse pair")
    }
    NSApp.yieldActivation(to: versoApp)
    await wait(0.15)
    guard !versoApp.isTerminated, clickValid(click, synthWin, frame: sf) else {
        abortRun("focus_handoff", "Target changed while activation handoff settled")
    }
    reDn.flags = .maskAlternate
    reUp.flags = .maskAlternate
    res.inputPairsSubmitted += 1
    reDn.post(tap: .cghidEventTap); reUp.post(tap: .cghidEventTap)
    await wait(0.15)
    var rw: AXUIElement?, rf: CGRect?
    let reopened = await poll(8.0, 0.3, {
        for w in axWins(vax) where axTitle(w) == title {
            if versoReady(vax, title, sf) != nil { rw = w; rf = axFrame(w); return true }
        }
        return false
    })
    guard reopened, let rw2 = rw else {
        emit("reopen", "fail", ["why": "no_overlay"]); sw.close(); return false
    }
    var rv2 = Set<AXID>()
    guard let reEditor = findEditor(rw2, 0, &rv2) else {
        emit("reopen", "fail", ["why": "no_editor"]); sw.close(); return false
    }
    let reopenText = axVal(reEditor) ?? ""
    let reopenFrameMatch = rf.map { framesClose($0, of) } ?? false
    let reopenTextMatch = reopenText == text
    emit("reopen", (reopenFrameMatch && reopenTextMatch) ? "ok" : "fail", [
        "frame_match": reopenFrameMatch, "text_match": reopenTextMatch
    ])

    let pinRestored = pinState(rw2) == true && (pinFeedback(rw2) ?? "").isEmpty
    emit("pin_reopen", pinRestored ? "ok" : "fail", ["pinned_restored_without_stale_message": pinRestored])
    await pressPin(rw2, frame: of, expected: false, stage: "pin_off_after_reopen")

    if ProcessInfo.processInfo.environment["VERSO_SMOKE_TABS_ONLY"] == "1" {
        await exerciseApplicationTabs(source: sw, sourceAX: synthWin, verso: versoApp,
                                      appAX: vax, selfAX: selfAX, title: title, text: text)
        sw.close()
        let gone = await poll(3, 0.1) { !axWins(vax).contains { axTitle($0) == title } }
        emit("tabs_cleanup", gone ? "ok" : "fail")
        return stagesPass(res.s)
    }
    // ---- Movement/resize: compare ALL frame components within 2pt ----
    let origF = sw.frame
    await exerciseWindowControls(source: sw, sourceAX: synthWin, verso: versoApp,
                                 appAX: vax, title: title, editor: reEditor, text: text)
    let resized = CGRect(x: origF.minX + 50, y: origF.minY + 50,
                         width: origF.width + 40, height: origF.height + 30)
    sw.setFrame(resized, display: true)
    // Let the fixture serve Verso's AX callback before querying Verso synchronously.
    await wait(0.15)
    guard let screen = NSScreen.screens.first else { abortRun("movement", "Display disappeared") }
    let expectedMoved = CGRect(x: resized.minX, y: screen.frame.height - resized.maxY,
                               width: resized.width, height: resized.height)
    let moveOk = await poll(3.0, 0.2, {
        axWins(vax).contains { axTitle($0) == title && axFrame($0).map { framesClose($0, expectedMoved) } == true }
    })
    emit("movement", moveOk ? "ok" : "fail", ["frame_match_2pt": moveOk])

    // ---- Close target: successful AX read proves editor absent ----
    guard versoReady(vax, title, expectedMoved) != nil else {
        abortRun("cleanup_guard", "Expected moved synthetic overlay/editor is no longer focused")
    }
    sw.close()
    await wait(0.5)
    let editorGone = await poll(3.0, 0.2, { !axWins(vax).contains { axTitle($0) == title } })
    emit("cleanup", editorGone ? "ok" : "fail", ["synthetic_window_absent": editorGone])

    return stagesPass(res.s)
}

// Application tabs QA touches only generated windows and this fixture bundle's notes.
@MainActor
func exerciseApplicationTabs(source: NSWindow, sourceAX: AXUIElement,
                             verso: NSRunningApplication, appAX: AXUIElement,
                             selfAX: AXUIElement, title: String, text: String) async {
    var expectedTitle = title
    func note() -> AXUIElement {
        guard !verso.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == verso.processIdentifier,
              let w = axFocusedWin(appAX), axTitle(w) == expectedTitle,
              let f = axFrame(w), versoReady(appAX, expectedTitle, f) != nil else {
            abortRun("tabs_guard", "Synthetic note window is not focused")
        }
        return w
    }
    func currentEditor() -> AXUIElement {
        var seen = Set<AXID>()
        guard let editor = findEditor(note(), 0, &seen) else { abortRun("tabs_editor", "Missing synthetic editor") }
        return editor
    }
    func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], text: String? = nil) async {
        _ = note()
        guard let (down, up) = keyPair(code, flags, text: text) else { abortRun("tabs_key", "Incomplete input pair") }
        res.inputPairsSubmitted += 1
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        // Native tab switching replaces AX children. Yield before traversing them.
        await wait(0.3)
    }
    func tabIDs() -> [String] {
        var ids: [String] = [], seen = Set<AXID>()
        func visit(_ e: AXUIElement, _ depth: Int) {
            guard depth < 16, seen.insert(AXID(r: e)).inserted else { return }
            if let id = ax(e, kAXIdentifierAttribute) as? String, id.hasPrefix("overlay.tab.") { ids.append(id) }
            for child in axChildren(e) { visit(child, depth + 1) }
        }
        visit(note(), 0)
        return ids
    }
    let initialIDs = tabIDs()
    let firstEditor = currentEditor()
    await key(0, .maskCommand)
    await key(0, text: "A-" + text)
    emit("tabs_first_edit", await poll(3, 0.1) { axVal(firstEditor) == "A-" + text } ? "ok" : "fail")
    await key(17, .maskCommand)
    await wait(0.2)
    let addedIDs = tabIDs().filter { !initialIDs.contains($0) }
    guard addedIDs.count == 1, axVal(currentEditor()) == "" else { abortRun("tabs_new", "New tab is not uniquely empty") }
    emit("tabs_new", "ok")
    let secondID = addedIDs[0]
    let secondEditor = currentEditor()
    let secondText = "B-" + text
    await key(0, text: secondText)
    emit("tabs_second_edit", await poll(3, 0.1) { axVal(secondEditor) == secondText } ? "ok" : "fail")
    // New tabs append after the first generated tab, so Ctrl+Shift+Tab returns to it.
    await key(48, [.maskControl, .maskShift])
    emit("tabs_switch_back", await poll(3, 0.1) { axVal(currentEditor()) == "A-" + text } ? "ok" : "fail")
    await key(6, .maskCommand)
    emit("tabs_independent_undo", await poll(3, 0.1) { axVal(currentEditor()) != "A-" + text } ? "ok" : "fail")
    await key(6, [.maskCommand, .maskShift])
    emit("tabs_independent_redo", await poll(3, 0.1) { axVal(currentEditor()) == "A-" + text } ? "ok" : "fail")
    await key(48, .maskControl)
    await wait(0.2)
    emit("tabs_second_retained", axVal(currentEditor()) == secondText ? "ok" : "fail")
    await key(53)
    emit("tabs_return", await poll(4, 0.1) { !axWins(appAX).contains { axTitle($0) == title } } ? "ok" : "fail")

    let other = NSWindow(contentRect: NSRect(x: 280, y: 180, width: 600, height: 400),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    other.title = title + " SECOND WINDOW"
    other.contentView = NSTextField(labelWithString: "Same application second synthetic window")
    res.windowsCreated += 1
    other.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    guard await poll(3, 0.1, { axFrontmost(selfAX) }),
          let target = axWins(selfAX).first(where: { axTitle($0) == other.title }),
          let frame = axFrame(target) else { abortRun("tabs_second_window", "Missing second fixture window") }
    let point = CGPoint(x: frame.midX, y: frame.minY + 20)
    guard clickValid(point, target, frame: frame),
          let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
        abortRun("tabs_second_hit", "Second fixture window failed hit validation")
    }
    NSApp.yieldActivation(to: verso)
    await wait(0.15)
    guard clickValid(point, target, frame: frame), !verso.isTerminated else { abortRun("tabs_second_hit", "Second fixture changed") }
    expectedTitle = other.title
    down.flags = .maskAlternate; up.flags = .maskAlternate
    res.inputPairsSubmitted += 1
    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    emit("tabs_same_app_second_window", await poll(8, 0.2) { versoReady(appAX, other.title, frame) != nil } ? "ok" : "fail")
    emit("tabs_shared_selection_text", axVal(currentEditor()) == secondText && tabIDs().contains(secondID) ? "ok" : "fail")
    await key(13, .maskCommand)
    emit("tabs_close_archives", await poll(3, 0.1) { !tabIDs().contains(secondID) && axVal(currentEditor()) == "A-" + text } ? "ok" : "fail")
    let beforeBlank = tabIDs()
    await key(17, .maskCommand)
    emit("tabs_blank_new", await poll(3, 0.1) { tabIDs().count == beforeBlank.count + 1 && axVal(currentEditor()) == "" } ? "ok" : "fail")
    await key(13, .maskCommand)
    emit("tabs_blank_close", await poll(3, 0.1) { tabIDs() == beforeBlank && axVal(currentEditor()) == "A-" + text } ? "ok" : "fail")
    await key(53)
    emit("tabs_final_return", await poll(4, 0.1) { !axWins(appAX).contains { axTitle($0) == other.title } } ? "ok" : "fail")
    other.close()
}

// Actual pointer gestures on the generated note, never unrelated user windows.
@MainActor
func exerciseWindowControls(source: NSWindow, sourceAX: AXUIElement,
                            verso: NSRunningApplication, appAX: AXUIElement,
                            title: String, editor: AXUIElement, text: String) async {
    func note() -> (AXUIElement, CGRect) {
        guard !verso.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == verso.processIdentifier,
              let window = axFocusedWin(appAX), axTitle(window) == title,
              let frame = axFrame(window), versoReady(appAX, title, frame) != nil else {
            abortRun("controls_guard", "Unique synthetic note/editor is not focused")
        }
        return (window, frame)
    }
    func aligned() -> Bool {
        guard let f = axFrame(sourceAX) else { return false }
        return versoReady(appAX, title, f) != nil
    }
    func gesture(_ from: CGPoint, _ to: CGPoint, option: Bool = false, liveStage: String? = nil) async {
        let initialSourceFrame = source.frame
        var sourceMovedWhileDragging = false
        let (window, _) = note()
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(from.x), Float(from.y), &hit) == .success,
              let hit else { abortRun("controls_hit", "No synthetic hit") }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == verso.processIdentifier else {
            abortRun("controls_hit", "Pointer does not hit Verso")
        }
        var node: AXUIElement? = hit
        var matches = false
        for _ in 0..<12 {
            guard let current = node else { break }
            if axRole(current) == "AXWindow" { matches = CFEqual(current, window); break }
            node = axElement(ax(current, kAXParentAttribute))
        }
        guard matches else { abortRun("controls_hit", "Pointer hits a different window") }
        func event(_ type: CGEventType, _ point: CGPoint) -> CGEvent {
            guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else {
                abortRun("controls_event", "Could not create mouse event")
            }
            e.flags = option ? .maskAlternate : []
            return e
        }
        let down = event(.leftMouseDown, from), up = event(.leftMouseUp, to)
        let drags = (1...12).map { n -> CGEvent in
            let t = CGFloat(n) / 12
            return event(.leftMouseDragged, CGPoint(x: from.x + (to.x-from.x)*t, y: from.y + (to.y-from.y)*t))
        }
        res.inputPairsSubmitted += 1
        down.post(tap: .cghidEventTap)
        if from != to {
            for (index, drag) in drags.enumerated() {
                await wait(0.025)
                guard !verso.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == verso.processIdentifier else {
                    up.post(tap: .cghidEventTap)
                    abortRun("controls_guard", "Focus changed during drag")
                }
                drag.post(tap: .cghidEventTap)
                if index == 8 { sourceMovedWhileDragging = source.frame != initialSourceFrame }
            }
        }
        up.post(tap: .cghidEventTap)
        if let liveStage { emit(liveStage, sourceMovedWhileDragging ? "ok" : "fail") }
        await wait(0.2)
    }
    func press(_ id: String, option: Bool = false) async {
        guard let button = identifiedControl(in: note().0, id: id),
              (ax(button, kAXEnabledAttribute) as? NSNumber)?.boolValue == true,
              let f = axFrame(button) else { abortRun("controls_button", "Missing/disabled synthetic control: " + id) }
        let p = CGPoint(x: f.midX, y: f.midY)
        await gesture(p, p, option: option)
    }
    func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], text: String? = nil) {
        _ = note()
        guard let (down, up) = keyPair(code, flags, text: text) else { abortRun("controls_key", "Cannot construct key pair") }
        res.inputPairsSubmitted += 1
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    let beforeDrag = note().1
    let start = CGPoint(x: beforeDrag.minX + beforeDrag.width * 0.60, y: beforeDrag.minY + 20)
    await gesture(start, CGPoint(x: start.x + 54, y: start.y + 32), liveStage: "note_drag_live_sync")
    let dragged = await poll(3, 0.1) {
        axFrame(sourceAX).map { framesClose($0, beforeDrag.offsetBy(dx: 54, dy: 32)) } == true && aligned()
    }
    emit("note_drag", dragged ? "ok" : "fail")
    let beforeResize = note().1
    let edge = CGPoint(x: beforeResize.maxX - 2, y: beforeResize.maxY - 2)
    await gesture(edge, CGPoint(x: edge.x + 48, y: edge.y + 36), liveStage: "note_resize_live_sync")
    let resized = await poll(3, 0.1) {
        guard let f = axFrame(sourceAX) else { return false }
        return abs(f.width-beforeResize.width-48) < 3 && abs(f.height-beforeResize.height-36) < 3 && aligned()
    }
    emit("note_resize", resized ? "ok" : "fail")
    let suffix = " — window controls"
    key(0, text: suffix)
    guard await poll(2, 0.1, { axVal(editor) == text + suffix }) else { abortRun("controls_typing", "Synthetic text mismatch") }
    let oldSelection = ax(editor, kAXSelectedTextRangeAttribute)
    await press("overlay.minimize")
    let minimized = await poll(3, 0.1) { source.isMiniaturized && !axWins(appAX).contains { axTitle($0) == title } }
    emit("note_minimize", minimized ? "ok" : "fail")
    source.deminiaturize(nil)
    source.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    NSApp.yieldActivation(to: verso)
    let restored = await poll(5, 0.1) { !source.isMiniaturized && aligned() }
    let selection = ax(editor, kAXSelectedTextRangeAttribute)
    let sameSelection = oldSelection != nil && selection != nil && CFEqual(oldSelection!, selection!)
    emit("note_restore", restored && axVal(editor) == text + suffix && sameSelection ? "ok" : "fail")
    key(kZ, .maskCommand)
    let undo = await poll(2, 0.1, { axVal(editor) == text })
    key(kZ, [.maskCommand, .maskShift])
    let redo = await poll(2, 0.1, { axVal(editor) == text + suffix })
    emit("controls_undo_redo", undo && redo ? "ok" : "fail")
    let beforeZoom = note().1
    await press("overlay.fullscreen", option: true)
    let zoom = await poll(3, 0.1) { axFrame(sourceAX).map { !framesClose($0, beforeZoom) } == true && aligned() }
    emit("note_zoom", zoom && !source.styleMask.contains(.fullScreen) ? "ok" : "fail")
    await press("overlay.fullscreen", option: true)
    let unzoom = await poll(3, 0.1) { axFrame(sourceAX).map { framesClose($0, beforeZoom) } == true && aligned() }
    emit("note_unzoom", unzoom ? "ok" : "fail")
    await press("overlay.fullscreen")
    let fullscreen = await poll(8, 0.2) { source.styleMask.contains(.fullScreen) && aligned() }
    emit("note_fullscreen", fullscreen ? "ok" : "fail")
    key(0, text: " ✓")
    let typing = await poll(2, 0.1, { axVal(editor) == text + suffix + " ✓" })
    emit("fullscreen_editor", typing ? "ok" : "fail")
    await press("overlay.fullscreen")
    let exited = await poll(8, 0.2) { !source.styleMask.contains(.fullScreen) && aligned() }
    emit("note_exit_fullscreen", exited ? "ok" : "fail")
}

// MARK: - JSON output

func printResults(completed: Bool = false) {
    let out: [String: Any] = [
        "overall": completed && stagesPass(res.s) ? "pass" : "fail",
        "input_pairs_submitted": res.inputPairsSubmitted, "synthetic_windows_created": res.windowsCreated,
        "stage_count": res.s.count, "stages": res.s
    ]
    if let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
       let s = String(data: d, encoding: .utf8) { print(s) }
    else { print("{\"overall\":\"error\",\"stage_count\":0}") }
}

// MARK: - App delegate

@objc(SmokeAppDelegate)
final class SmokeAppDelegate: NSObject, NSApplicationDelegate {
    var projectRoot = ""
    var appPath = ""
    func applicationDidFinishLaunching(_ n: Notification) {
        let root = projectRoot
        let appPath = appPath
        Task { @MainActor in
            let ok = await smoke(root: root, appPath: appPath, pid: ProcessInfo.processInfo.processIdentifier)
            printResults(completed: ok)
            if !ok { Darwin.exit(1) }
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Entry point (before NSApp.start)

let args = Array(CommandLine.arguments.dropFirst())
if args == ["--self-check"] { exit(selfCheck()) }
// .app -> desktop-smoke -> .build -> repository. Independent of the caller's cwd.
let derivedRoot = Bundle.main.bundleURL.deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
// All argument errors (missing/duplicate/unknown/relative/invalid-app) exit here, before NSApp GUI starts.
let (cfg, parseErr) = parseRunArgs(args, derivedRoot: derivedRoot.path)
guard let cfg else { print(parseErr ?? "Invalid arguments. No GUI was started."); exit(64) }
if let appErr = validateAppBundle(cfg.appPath) { print(appErr + " No GUI was started."); exit(64) }

let delegate = SmokeAppDelegate()
delegate.projectRoot = cfg.root
delegate.appPath = cfg.appPath
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
