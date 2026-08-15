import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Grok Use helper. Native macOS driver: window list, screenshot,
// AX tree, AX press, and CGEventPostToPid click/type (background path).
// Independent of Cua Driver and Codex SkyComputerUse.

struct CUError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

let home = FileManager.default.homeDirectoryForCurrentUser
let stateDir = home.appendingPathComponent(".grok/grok-use/state")
let snapshotURL = stateDir.appendingPathComponent("snapshot.json")

func ensureStateDir() throws {
    try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
}

func jsonObject(_ obj: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8)!
}

func emit(_ obj: Any) {
    fputs(jsonObject(obj) + "\n", stdout)
}

func die(_ message: String, extra: [String: Any] = [:]) -> Never {
    var payload: [String: Any] = ["ok": false, "error": message]
    for (k, v) in extra { payload[k] = v }
    fputs(jsonObject(payload) + "\n", stderr)
    exit(1)
}

func argValue(_ name: String) -> String? {
    let flag = "--\(name)"
    guard let i = CommandLine.arguments.firstIndex(of: flag) else { return nil }
    let j = i + 1
    guard j < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[j]
}

func requireArg(_ name: String) -> String {
    guard let v = argValue(name), !v.isEmpty else { die("missing --\(name)") }
    return v
}

func intArg(_ name: String) -> Int? {
    guard let v = argValue(name) else { return nil }
    return Int(v)
}

func requireInt(_ name: String) -> Int {
    guard let v = intArg(name) else { die("missing or invalid --\(name)") }
    return v
}

func doubleArg(_ name: String) -> Double? {
    guard let v = argValue(name) else { return nil }
    return Double(v)
}

func hasFlag(_ name: String) -> Bool {
    CommandLine.arguments.contains("--\(name)")
}

// MARK: - Permissions

func axTrusted() -> Bool {
    AXIsProcessTrusted()
}

func requestAX() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
}

func screenCaptureAllowed() -> Bool {
    if #available(macOS 11.0, *) {
        return CGPreflightScreenCaptureAccess()
    }
    return true
}

func cmdPermissions() {
    let ax = axTrusted()
    let screen = screenCaptureAllowed()
    emit([
        "ok": true,
        "accessibility": ax,
        "screen_recording": screen,
        "helper": CommandLine.arguments[0],
        "note": ax && screen
            ? "ready"
            : "Grant Accessibility and Screen Recording to this helper (or the parent Grok/Terminal app) in System Settings → Privacy & Security.",
    ])
}

func cmdGrant() {
    requestAX()
    if #available(macOS 11.0, *) {
        _ = CGRequestScreenCaptureAccess()
    }
    cmdPermissions()
}

// MARK: - Windows

struct WinInfo {
    let windowID: Int
    let pid: Int
    let title: String
    let appName: String
    let bundleID: String
    let bounds: CGRect
    let onScreen: Bool
    let layer: Int
}

func cgBounds(_ dict: [String: Any]) -> CGRect {
    guard let b = dict[kCGWindowBounds as String] as? [String: Any] else { return .zero }
    return CGRect(
        x: (b["X"] as? NSNumber)?.doubleValue ?? 0,
        y: (b["Y"] as? NSNumber)?.doubleValue ?? 0,
        width: (b["Width"] as? NSNumber)?.doubleValue ?? 0,
        height: (b["Height"] as? NSNumber)?.doubleValue ?? 0
    )
}

func listWindows(onScreenOnly: Bool) -> [WinInfo] {
    var option: CGWindowListOption = [.excludeDesktopElements]
    if onScreenOnly { option.insert(.optionOnScreenOnly) }
    guard let raw = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    var out: [WinInfo] = []
    for d in raw {
        let layer = (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        if layer != 0 { continue }
        let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? 0
        let wid = (d[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
        if pid == 0 || wid == 0 { continue }
        let bounds = cgBounds(d)
        if bounds.width < 2 || bounds.height < 2 { continue }
        let app = NSRunningApplication(processIdentifier: pid_t(pid))
        out.append(WinInfo(
            windowID: wid,
            pid: pid,
            title: d[kCGWindowName as String] as? String ?? "",
            appName: d[kCGWindowOwnerName as String] as? String ?? (app?.localizedName ?? ""),
            bundleID: app?.bundleIdentifier ?? "",
            bounds: bounds,
            onScreen: (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
            layer: layer
        ))
    }
    return out
}

func winDict(_ w: WinInfo) -> [String: Any] {
    [
        "window_id": w.windowID,
        "pid": w.pid,
        "title": w.title,
        "app_name": w.appName,
        "bundle_id": w.bundleID,
        "on_screen": w.onScreen,
        "bounds": [
            "x": w.bounds.origin.x,
            "y": w.bounds.origin.y,
            "width": w.bounds.width,
            "height": w.bounds.height,
        ],
    ]
}

func findWindow(pid: Int, windowID: Int) -> WinInfo? {
    listWindows(onScreenOnly: false).first { $0.pid == pid && $0.windowID == windowID }
}

func cmdListWindows() {
    let on = hasFlag("on-screen")
    let wins = listWindows(onScreenOnly: on)
    emit(["ok": true, "windows": wins.map(winDict)])
}

// MARK: - Screenshot

func imageSize(_ url: URL) -> (Int, Int) {
    guard let img = NSImage(contentsOf: url) else { return (0, 0) }
    if let rep = img.representations.first {
        return (rep.pixelsWide, rep.pixelsHigh)
    }
    return (Int(img.size.width), Int(img.size.height))
}

func fallbackScreencapture(windowID: Int, to url: URL) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    proc.arguments = ["-l\(windowID)", "-x", "-o", url.path]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
    } catch {
        return false
    }
}

// MARK: - AX

func axString(_ el: AXUIElement, _ attr: String) -> String {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return "" }
    if let s = ref as? String { return s }
    if let n = ref as? NSNumber { return n.stringValue }
    return ""
}

func axBool(_ el: AXUIElement, _ attr: String) -> Bool {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return false }
    return (ref as? Bool) ?? false
}

func axPoint(_ el: AXUIElement) -> CGPoint? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &ref) == .success,
          let val = ref
    else { return nil }
    var pt = CGPoint.zero
    if AXValueGetValue(val as! AXValue, .cgPoint, &pt) { return pt }
    return nil
}

func axSize(_ el: AXUIElement) -> CGSize? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &ref) == .success,
          let val = ref
    else { return nil }
    var sz = CGSize.zero
    if AXValueGetValue(val as! AXValue, .cgSize, &sz) { return sz }
    return nil
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success else {
        return []
    }
    return (ref as? [AXUIElement]) ?? []
}

func axActions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success, let arr = names as? [String] else {
        return []
    }
    return arr
}

func axRole(_ el: AXUIElement) -> String {
    axString(el, kAXRoleAttribute as String)
}

func matchAXWindow(app: AXUIElement, target: WinInfo) -> AXUIElement? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
          let windows = ref as? [AXUIElement]
    else { return nil }
    var best: (AXUIElement, Double)?
    for w in windows {
        guard let p = axPoint(w), let s = axSize(w) else { continue }
        let r = CGRect(origin: p, size: s)
        let dx = abs(r.midX - target.bounds.midX) + abs(r.midY - target.bounds.midY)
        let title = axString(w, kAXTitleAttribute as String)
        let titleBonus = (!target.title.isEmpty && title == target.title) ? -20.0 : 0.0
        let score = dx + titleBonus
        if best == nil || score < best!.1 { best = (w, score) }
    }
    return best?.0
}

struct AXNode {
    let index: Int
    let role: String
    let label: String
    let value: String
    let actions: [String]
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let enabled: Bool
    let depth: Int
}

func walkAX(root: AXUIElement, maxNodes: Int, maxDepth: Int) -> [AXNode] {
    var nodes: [AXNode] = []
    func visit(_ el: AXUIElement, depth: Int) {
        if nodes.count >= maxNodes || depth > maxDepth { return }
        let role = axRole(el)
        if role == "AXMenuBar" || role == "AXMenu" { return }
        let actions = axActions(el)
        let label = axString(el, kAXTitleAttribute as String)
        let desc = axString(el, kAXDescriptionAttribute as String)
        let ident = axString(el, kAXIdentifierAttribute as String)
        let value = axString(el, kAXValueAttribute as String)
        let name = [label, desc, ident].first { !$0.isEmpty } ?? ""
        let pt = axPoint(el) ?? .zero
        let sz = axSize(el) ?? .zero
        nodes.append(AXNode(
            index: nodes.count,
            role: role,
            label: name,
            value: value,
            actions: actions,
            x: pt.x,
            y: pt.y,
            w: sz.width,
            h: sz.height,
            enabled: true,
            depth: depth
        ))
        // store element pointer alongside later via parallel array
        boxedElements.append(el)
        for child in axChildren(el) { visit(child, depth: depth + 1) }
    }
    boxedElements.removeAll()
    visit(root, depth: 0)
    return nodes
}

var boxedElements: [AXUIElement] = []

func nodeDict(_ n: AXNode) -> [String: Any] {
    [
        "element_index": n.index,
        "role": n.role,
        "label": n.label,
        "value": n.value,
        "actions": n.actions,
        "enabled": n.enabled,
        "depth": n.depth,
        "frame": ["x": n.x, "y": n.y, "width": n.w, "height": n.h],
    ]
}

func saveSnapshot(pid: Int, windowID: Int, nodes: [AXNode], imageW: Int, imageH: Int, bounds: CGRect, path: String) {
    try? ensureStateDir()
    let payload: [String: Any] = [
        "pid": pid,
        "window_id": windowID,
        "screenshot_path": path,
        "screenshot_width": imageW,
        "screenshot_height": imageH,
        "bounds": ["x": bounds.origin.x, "y": bounds.origin.y, "width": bounds.width, "height": bounds.height],
        "elements": nodes.map(nodeDict),
        "created": ISO8601DateFormatter().string(from: Date()),
    ]
    try? jsonObject(payload).write(to: snapshotURL, atomically: true, encoding: .utf8)
}

func loadSnapshot() -> [String: Any]? {
    guard let data = try? Data(contentsOf: snapshotURL),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return obj
}

func collectAX(pid: Int, win: WinInfo) -> [AXNode] {
    let app = AXUIElementCreateApplication(pid_t(pid))
    let root = matchAXWindow(app: app, target: win) ?? app
    let maxNodes = intArg("max-nodes") ?? 800
    let maxDepth = intArg("max-depth") ?? 30
    return walkAX(root: root, maxNodes: maxNodes, maxDepth: maxDepth)
}

func markdown(from nodes: [AXNode]) -> String {
    nodes.compactMap { n in
        let interesting = !n.actions.isEmpty || ["AXButton", "AXLink", "AXTextField", "AXPopUpButton", "AXCheckBox", "AXMenuItem"].contains(n.role)
        guard interesting else { return nil }
        let lab = n.label.isEmpty ? n.value : n.label
        return "- [\(n.index)] \(n.role) \(lab)"
    }.joined(separator: "\n")
}

func cmdAXTree() {
    if !axTrusted() { die("accessibility not granted", extra: ["code": "needs_accessibility"]) }
    let pid = requireInt("pid")
    let windowID = requireInt("window-id")
    guard let win = findWindow(pid: pid, windowID: windowID) else {
        die("window not found", extra: ["pid": pid, "window_id": windowID])
    }
    let nodes = collectAX(pid: pid, win: win)
    let outPath = argValue("out") ?? ""
    saveSnapshot(pid: pid, windowID: windowID, nodes: nodes, imageW: Int(win.bounds.width), imageH: Int(win.bounds.height), bounds: win.bounds, path: outPath)
    emit([
        "ok": true,
        "pid": pid,
        "window_id": windowID,
        "app_name": win.appName,
        "title": win.title,
        "bounds": ["x": win.bounds.origin.x, "y": win.bounds.origin.y, "width": win.bounds.width, "height": win.bounds.height],
        "element_count": nodes.count,
        "elements": nodes.map(nodeDict),
        "tree_markdown": markdown(from: nodes),
    ])
}

func cmdCapture() {
    if !axTrusted() { die("accessibility not granted", extra: ["code": "needs_accessibility"]) }
    let pid = requireInt("pid")
    let windowID = requireInt("window-id")
    guard let win = findWindow(pid: pid, windowID: windowID) else {
        die("window not found", extra: ["pid": pid, "window_id": windowID])
    }
    try? ensureStateDir()
    let outPath = argValue("out") ?? stateDir.appendingPathComponent("capture-\(windowID).png").path
    let outURL = URL(fileURLWithPath: outPath)

    var imageW = Int(win.bounds.width)
    var imageH = Int(win.bounds.height)
    var shotOK = fallbackScreencapture(windowID: windowID, to: outURL)
    if shotOK {
        let size = imageSize(outURL)
        imageW = size.0
        imageH = size.1
        if imageW == 0 || imageH == 0 { shotOK = false }
    }

    let nodes = collectAX(pid: pid, win: win)
    saveSnapshot(pid: pid, windowID: windowID, nodes: nodes, imageW: imageW, imageH: imageH, bounds: win.bounds, path: outURL.path)

    var payload: [String: Any] = [
        "ok": true,
        "pid": pid,
        "window_id": windowID,
        "app_name": win.appName,
        "title": win.title,
        "screenshot_path": shotOK ? outURL.path : NSNull(),
        "screenshot_ok": shotOK,
        "screenshot_width": imageW,
        "screenshot_height": imageH,
        "bounds": ["x": win.bounds.origin.x, "y": win.bounds.origin.y, "width": win.bounds.width, "height": win.bounds.height],
        "element_count": nodes.count,
        "elements": nodes.map(nodeDict),
        "tree_markdown": markdown(from: nodes),
    ]
    if !shotOK {
        payload["screenshot_error"] = "helper has no Screen Recording; MCP/CLI will capture via screencapture as Grok"
    }
    emit(payload)
}

// MARK: - Input
// Codex-style: never raise, never warp the real cursor, never post to the
// session HID tap. All input is AX or CGEventPostToPid with a private source.

func screenshotToScreen(x: Double, y: Double, imageW: Double, imageH: Double, bounds: CGRect) -> CGPoint {
    let sx = bounds.origin.x + (x / max(imageW, 1)) * bounds.width
    let sy = bounds.origin.y + (y / max(imageH, 1)) * bounds.height
    return CGPoint(x: sx, y: sy)
}

func privateSource() -> CGEventSource? {
    let src = CGEventSource(stateID: .privateState)
    src?.setLocalEventsFilterDuringSuppressionState(
        [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
        state: .eventSuppressionStateSuppressionInterval
    )
    src?.localEventsSuppressionInterval = 0
    return src
}

func coerceBackground(_ requested: String) -> (String, Bool) {
    if requested == "foreground" || requested == "steal" || requested == "hid" {
        return ("background", true)
    }
    return (requested.isEmpty ? "background" : requested, false)
}

func quartzCursor() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}

func restoreCursor(_ point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
}

/// Mouse/scroll CGEvents still warp the hardware cursor on recent macOS
/// even when posted to a pid. Always put it back.
func withRestoredCursor(_ body: () -> Void) {
    let saved = quartzCursor()
    body()
    restoreCursor(saved)
}

func axHitTest(pid: Int, point: CGPoint) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid_t(pid))
    var ref: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &ref)
    return err == .success ? ref : nil
}

func axPress(_ el: AXUIElement) -> AXError {
    AXUIElementPerformAction(el, kAXPressAction as CFString)
}

func postClick(pid: Int, point: CGPoint) {
    withRestoredCursor {
        let src = privateSource()
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.postToPid(pid_t(pid))
        usleep(12_000)
        up?.postToPid(pid_t(pid))
    }
}

func cmdClick() {
    if !axTrusted() { die("accessibility not granted") }
    let pid = requireInt("pid")
    let windowID = requireInt("window-id")
    let (mode, stoleRefused) = coerceBackground(argValue("mode") ?? "background")
    guard let win = findWindow(pid: pid, windowID: windowID) else { die("window not found") }

    if let idx = intArg("index") {
        cmdAXPress(pid: pid, windowID: windowID, index: idx, stoleRefused: stoleRefused)
        return
    }
    guard let x = doubleArg("x"), let y = doubleArg("y") else {
        die("need --x/--y or --index")
    }
    let snap = loadSnapshot()
    let imageW = (snap?["screenshot_width"] as? Int).map(Double.init) ?? win.bounds.width
    let imageH = (snap?["screenshot_height"] as? Int).map(Double.init) ?? win.bounds.height
    let pt = screenshotToScreen(x: x, y: y, imageW: imageW, imageH: imageH, bounds: win.bounds)

    if let el = axHitTest(pid: pid, point: pt) {
        let err = axPress(el)
        emit([
            "ok": err == .success,
            "route": "ax_hit_test",
            "delivery_mode": mode,
            "steal_refused": stoleRefused,
            "point": ["x": pt.x, "y": pt.y],
            "ax_error": Int(err.rawValue),
            "effect": err == .success ? "unverifiable" : "failed",
        ])
        return
    }

    postClick(pid: pid, point: pt)
    emit([
        "ok": true,
        "route": "cgevent_pid_cursor_restored",
        "delivery_mode": mode,
        "steal_refused": stoleRefused,
        "point": ["x": pt.x, "y": pt.y],
        "effect": "unverifiable",
    ])
}

func rebuildElements(pid: Int, windowID: Int) -> [AXUIElement] {
    guard let win = findWindow(pid: pid, windowID: windowID) else { return [] }
    let app = AXUIElementCreateApplication(pid_t(pid))
    let root = matchAXWindow(app: app, target: win) ?? app
    _ = walkAX(root: root, maxNodes: intArg("max-nodes") ?? 800, maxDepth: 30)
    return boxedElements
}

func cmdAXPress(pid: Int, windowID: Int, index: Int, stoleRefused: Bool) {
    let els = rebuildElements(pid: pid, windowID: windowID)
    guard index >= 0, index < els.count else { die("element_index out of range", extra: ["index": index, "count": els.count]) }
    let el = els[index]
    let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
    emit([
        "ok": err == .success,
        "route": "ax_press",
        "delivery_mode": "background",
        "steal_refused": stoleRefused,
        "element_index": index,
        "ax_error": Int(err.rawValue),
        "effect": err == .success ? "unverifiable" : "failed",
    ])
}

func cmdAXPressCLI() {
    if !axTrusted() { die("accessibility not granted") }
    let (_, stoleRefused) = coerceBackground(argValue("mode") ?? "background")
    cmdAXPress(
        pid: requireInt("pid"),
        windowID: requireInt("window-id"),
        index: requireInt("index"),
        stoleRefused: stoleRefused
    )
}

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "esc": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "l": 37, "n": 45, "m": 46, "p": 35, "o": 31, "i": 34, "u": 32, "k": 40, "j": 38,
]

func flagsFrom(_ names: [String]) -> CGEventFlags {
    var f: CGEventFlags = []
    for n in names {
        switch n.lowercased() {
        case "cmd", "command", "meta": f.insert(.maskCommand)
        case "shift": f.insert(.maskShift)
        case "option", "alt": f.insert(.maskAlternate)
        case "ctrl", "control": f.insert(.maskControl)
        case "fn": f.insert(.maskSecondaryFn)
        default: break
        }
    }
    return f
}

func postKey(pid: Int, key: String, flags: CGEventFlags) {
    guard let code = keyCodes[key.lowercased()] ?? keyCodes[String(key.lowercased().prefix(1))] else {
        die("unknown key \(key)")
    }
    let src = privateSource()
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.postToPid(pid_t(pid))
    usleep(8_000)
    up?.postToPid(pid_t(pid))
}

func postUnicode(pid: Int, text: String) {
    let src = privateSource()
    for ch in text {
        var u = Array(String(ch).utf16)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        up?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        down?.postToPid(pid_t(pid))
        usleep(8_000)
        up?.postToPid(pid_t(pid))
        usleep(12_000)
    }
}

func axSetSelectedText(pid: Int, text: String) -> Bool {
    let app = AXUIElementCreateApplication(pid_t(pid))
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let el = focused
    else { return false }
    let element = el as! AXUIElement
    return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
        || AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
}

func axSetText(el: AXUIElement, text: String) -> Bool {
    AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
        || AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef) == .success
}

func cmdType() {
    if !axTrusted() { die("accessibility not granted") }
    let pid = requireInt("pid")
    let text = requireArg("text")
    let (_, stoleRefused) = coerceBackground(argValue("mode") ?? "background")
    var axOK = false
    if let idx = intArg("index") {
        let windowID = requireInt("window-id")
        let els = rebuildElements(pid: pid, windowID: windowID)
        if idx >= 0 && idx < els.count {
            axOK = axSetText(el: els[idx], text: text)
        }
    }
    if !axOK {
        axOK = axSetSelectedText(pid: pid, text: text)
    }
    // Do not synthesize keystrokes. CG keyboard events steal the user's
    // key focus (and can land in the frontmost app if the target ignores them).
    emit([
        "ok": axOK,
        "route": axOK ? "ax_set_text" : "ax_unavailable",
        "delivery_mode": "background",
        "steal_refused": stoleRefused,
        "chars": text.count,
        "effect": axOK ? "confirmed" : "failed",
        "error": axOK ? NSNull() : "no AX text field; refusing key synthesis so the user keyboard is not hijacked",
    ])
}

func cmdHotkey() {
    if !axTrusted() { die("accessibility not granted") }
    let pid = requireInt("pid")
    let raw = requireArg("keys")
    let (_, stoleRefused) = coerceBackground(argValue("mode") ?? "background")
    let parts = raw.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    guard let key = parts.last else { die("empty --keys") }
    let mods = Array(parts.dropLast())
    postKey(pid: pid, key: key, flags: flagsFrom(mods))
    emit([
        "ok": true,
        "route": "cgevent_pid_hotkey",
        "delivery_mode": "background",
        "steal_refused": stoleRefused,
        "keys": parts,
        "effect": "unverifiable",
    ])
}

func cmdPressKey() {
    if !axTrusted() { die("accessibility not granted") }
    let pid = requireInt("pid")
    let key = requireArg("key")
    let (_, stoleRefused) = coerceBackground(argValue("mode") ?? "background")
    postKey(pid: pid, key: key, flags: [])
    emit([
        "ok": true,
        "route": "cgevent_pid_key",
        "delivery_mode": "background",
        "steal_refused": stoleRefused,
        "key": key,
        "effect": "unverifiable",
    ])
}

func cmdScroll() {
    if !axTrusted() { die("accessibility not granted") }
    let pid = requireInt("pid")
    let windowID = requireInt("window-id")
    let (_, stoleRefused) = coerceBackground(argValue("mode") ?? "background")
    let direction = (argValue("direction") ?? "down").lowercased()
    let amount = max(1, intArg("amount") ?? 5)
    guard let win = findWindow(pid: pid, windowID: windowID) else { die("window not found") }

    var pt: CGPoint?
    if let idx = intArg("index") {
        let els = rebuildElements(pid: pid, windowID: windowID)
        if idx >= 0, idx < els.count, let p = axPoint(els[idx]), let s = axSize(els[idx]) {
            pt = CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
        }
    } else if let x = doubleArg("x"), let y = doubleArg("y") {
        let snap = loadSnapshot()
        let imageW = (snap?["screenshot_width"] as? Int).map(Double.init) ?? win.bounds.width
        let imageH = (snap?["screenshot_height"] as? Int).map(Double.init) ?? win.bounds.height
        pt = screenshotToScreen(x: x, y: y, imageW: imageW, imageH: imageH, bounds: win.bounds)
    } else {
        pt = CGPoint(x: win.bounds.midX, y: win.bounds.midY)
    }

    // macOS: positive line delta = scroll up (content moves down).
    var dy: Int32 = 0
    var dx: Int32 = 0
    switch direction {
    case "up": dy = Int32(amount)
    case "down": dy = -Int32(amount)
    case "left": dx = Int32(amount)
    case "right": dx = -Int32(amount)
    default: die("direction must be up, down, left, or right")
    }

    let src = privateSource()
    guard let event = CGEvent(
        scrollWheelEvent2Source: src,
        units: .line,
        wheelCount: 2,
        wheel1: dy,
        wheel2: dx,
        wheel3: 0
    ) else { die("failed to create scroll event") }
    if let pt { event.location = pt }
    withRestoredCursor {
        event.postToPid(pid_t(pid))
    }

    emit([
        "ok": true,
        "route": "cgevent_pid_scroll",
        "delivery_mode": "background",
        "steal_refused": stoleRefused,
        "direction": direction,
        "amount": amount,
        "point": pt.map { ["x": $0.x, "y": $0.y] } as Any,
        "effect": "unverifiable",
    ])
}

func cmdCursor() {
    let p = quartzCursor()
    emit(["ok": true, "x": p.x, "y": p.y])
}

func cmdDoctor() {
    let wins = listWindows(onScreenOnly: true)
    emit([
        "ok": true,
        "accessibility": axTrusted(),
        "screen_recording": screenCaptureAllowed(),
        "on_screen_windows": wins.prefix(12).map(winDict),
        "window_count": wins.count,
    ])
}

func usage() -> Never {
    fputs("""
    grok-use-helper — Grok Use native macOS driver
    commands:
      permissions | grant | doctor | cursor
      list-windows [--on-screen]
      capture --pid N --window-id N [--out PATH]
      ax-tree --pid N --window-id N
      click --pid N --window-id N (--x N --y N | --index N)
      ax-press --pid N --window-id N --index N
      type --pid N --text STR [--window-id N --index N]
      hotkey --pid N --keys cmd+l
      press-key --pid N --key return
      scroll --pid N --window-id N --direction down|up|left|right [--amount N] [--x N --y N | --index N]
    Input never raises the app, never warps the real cursor, and never uses the session HID tap.
    --mode foreground is accepted then ignored (steal_refused=true).
    """, stderr)
    exit(2)
}

let cmd = CommandLine.arguments.dropFirst().first ?? ""
switch cmd {
case "permissions": cmdPermissions()
case "grant": cmdGrant()
case "doctor": cmdDoctor()
case "cursor": cmdCursor()
case "list-windows": cmdListWindows()
case "capture": cmdCapture()
case "ax-tree": cmdAXTree()
case "click": cmdClick()
case "ax-press": cmdAXPressCLI()
case "type": cmdType()
case "hotkey": cmdHotkey()
case "press-key": cmdPressKey()
case "scroll": cmdScroll()
default: usage()
}
