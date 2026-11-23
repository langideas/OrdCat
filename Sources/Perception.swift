// OrdCat — desktop perception layer.
// 1) AXUIElement tree of the focused window (cheap, exact, with screen coordinates)
// 2) OCR fallback via ScreenCaptureKit + Vision when the AX tree is too thin (canvas apps, images, games)
// 3) Local redaction and noise filtering before anything is stored or sent.
//
// Coordinates everywhere in this file: global screen points, origin at the top-left of the primary display
// (the same space the Accessibility API and CGWindow use).

import Cocoa
import Vision
import ScreenCaptureKit

struct ScreenElement {
    let role: String      // 按钮 / 文本 / 输入框 / 链接 / 标题 / 文字(OCR)…
    let text: String
    let rect: CGRect      // global, top-left origin
    /// Browser / app chrome (toolbars, tab strip, bookmarks bar) outside the page content. Never a highlight target.
    var chrome: Bool = false
}

struct ContextCard {
    let date: Date
    let app: String
    let bundleID: String
    let pid: pid_t
    let windowTitle: String
    let windowRect: CGRect
    let source: String    // "AX" | "OCR" | "AX+OCR"
    var elements: [ScreenElement]
    var screenshot: CGImage?

    /// Plain text used for storage, search and dedupe (no coordinates).
    var plainText: String {
        var seen = Set<String>()
        var lines: [String] = []
        for e in elements where !e.text.isEmpty {
            if seen.insert(e.text).inserted { lines.append(e.text) }
        }
        return lines.joined(separator: "\n")
    }

    var lineSet: Set<String> { Set(elements.map { $0.text }) }
}

// MARK: - Redaction (runs before storage and before any model call)

enum Redactor {
    private static let rules: [(NSRegularExpression, String)] = {
        let raw: [(String, String)] = [
            ("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----", "«私钥已脱敏»"),
            ("\\bsk-(?:ant-|proj-)?[A-Za-z0-9_\\-]{16,}", "«API Key 已脱敏»"),
            ("\\bgsk_[A-Za-z0-9]{20,}", "«API Key 已脱敏»"),
            ("\\bAKIA[0-9A-Z]{16}\\b", "«AWS Key 已脱敏»"),
            ("\\bgh[pousr]_[A-Za-z0-9]{30,}", "«GitHub Token 已脱敏»"),
            ("\\bgithub_pat_[A-Za-z0-9_]{20,}", "«GitHub Token 已脱敏»"),
            ("\\bxox[abprs]-[A-Za-z0-9-]{10,}", "«Slack Token 已脱敏»"),
            ("\\bAIza[0-9A-Za-z_\\-]{30,}", "«Google Key 已脱敏»"),
            ("\\beyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}", "«JWT 已脱敏»"),
            ("(?i)\\b(password|passwd|pwd|token|secret|api[_-]?key|access[_-]?key)\\b(\\s*[:=：]\\s*)\\S+", "$1$2«已脱敏»"),
            ("(密码|口令|验证码|密钥)(\\s*[:=：]\\s*)\\S+", "$1$2«已脱敏»"),
            ("\\b(?:\\d[ -]?){15,18}\\d\\b", "«卡号已脱敏»"),
            ("/Users/[^/\\s]+", "/Users/~")
        ]
        return raw.compactMap { p in
            (try? NSRegularExpression(pattern: p.0, options: [])).map { ($0, p.1) }
        }
    }()

    static func clean(_ s: String) -> String {
        var out = s
        for (re, tpl) in rules {
            out = re.stringByReplacingMatches(in: out, options: [], range: NSRange(out.startIndex..., in: out), withTemplate: tpl)
        }
        return out
    }
}

// MARK: - Screen reader

final class ScreenReader {
    /// Apps we never look at, whatever the user does.
    static let alwaysExcluded: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.bitwarden.desktop",
        "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "in.sinew.Enpass-Desktop"
    ]

    private var manualAXSet = Set<pid_t>()
    private let manualAXLock = NSLock()
    private var manualAXEnabled: Set<pid_t> {
        get { manualAXLock.lock(); defer { manualAXLock.unlock() }; return manualAXSet }
        set { manualAXLock.lock(); manualAXSet = newValue; manualAXLock.unlock() }
    }
    static let chromiumBrowsers: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "org.chromium.Chromium"]

    static func screenRecordingAllowed() -> Bool { CGPreflightScreenCaptureAccess() }
    static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    func isExcluded(_ bundleID: String) -> Bool {
        if ScreenReader.alwaysExcluded.contains(bundleID) { return true }
        let user = Prefs.excludedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return user.contains(bundleID)
    }

    // MARK: AX helpers
    private func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }
    private func str(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = attr(el, name) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber, name == kAXValueAttribute as String { return n.stringValue }
        return nil
    }
    private func rect(_ el: AXUIElement) -> CGRect? {
        guard let pv = attr(el, kAXPositionAttribute as String), CFGetTypeID(pv) == AXValueGetTypeID(),
              let sv = attr(el, kAXSizeAttribute as String), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
    private func children(_ el: AXUIElement) -> [AXUIElement] {
        guard let v = attr(el, kAXChildrenAttribute as String) else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    private func roleName(_ role: String) -> String? {
        switch role {
        case "AXButton", "AXPopUpButton", "AXMenuButton", "AXRadioButton", "AXCheckBox": return "按钮"
        case "AXStaticText": return "文本"
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": return "输入框"
        case "AXLink": return "链接"
        case "AXHeading": return "标题"
        case "AXTab", "AXTabGroup": return "标签页"
        case "AXCell", "AXRow": return "列表项"
        case "AXImage": return "图片"
        case "AXMenuItem": return "菜单项"
        default: return nil
        }
    }

    /// Walk the focused window's accessibility tree. Budgeted so it never stalls the UI.
    /// Ask the app to build its full accessibility tree (Electron apps and Chromium browsers only do this on request).
    func ensureTree(pid: pid_t) {
        guard !manualAXEnabled.contains(pid) else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        if ScreenReader.chromiumBrowsers.contains(bid) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        manualAXEnabled.insert(pid)
    }

    /// The web page inside a browser window: its AXWebArea (to read only the page, not the browser UI)
    /// and its address (AXURL on the web area, or the address bar's text as a fallback).
    func webPage(pid: pid_t) -> (web: AXUIElement?, url: String) {
        ensureTree(pid: pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let wv = attr(app, kAXFocusedWindowAttribute as String), CFGetTypeID(wv) == AXUIElementGetTypeID() else {
            return (nil, "")
        }
        var queue: [(AXUIElement, Int)] = [(wv as! AXUIElement, 0)]
        var i = 0
        var barURL = ""
        let deadline = Date().addingTimeInterval(0.4)
        while i < queue.count && i < 600 && Date() < deadline {
            let (el, depth) = queue[i]; i += 1
            let role = str(el, kAXRoleAttribute as String) ?? ""
            if role == "AXWebArea" {
                var url = ""
                if let v = attr(el, "AXURL") {
                    if let u = v as? URL { url = u.absoluteString } else if let s2 = v as? String { url = s2 }
                }
                return (el, url.isEmpty ? barURL : url)
            }
            if role == "AXSecureTextField" { continue }
            if barURL.isEmpty, role == "AXTextField" || role == "AXComboBox",
               let v = str(el, kAXValueAttribute as String), !v.contains(" "), v.contains(".") , v.count < 400 {
                barURL = v
            }
            if depth < 14 { for c in children(el) { queue.append((c, depth + 1)) } }
        }
        return (nil, barURL)
    }

    /// Cheap re-read of a web area's address (one AX call), so page changes inside X are noticed at once.
    /// Returns nil when the element went stale (tab closed, page replaced): then probe again.
    func url(of web: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(web, 0.12)
        guard let role = str(web, kAXRoleAttribute as String), role == "AXWebArea" else { return nil }
        guard let v = attr(web, "AXURL") else { return "" }
        if let u = v as? URL { return u.absoluteString }
        return v as? String ?? ""
    }

    /// The text box that has keyboard focus in an app (role, label/placeholder, screen rect). Never reads its content.
    func focusedField(pid: pid_t) -> (role: String, hint: String, rect: CGRect)? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let fv = attr(app, kAXFocusedUIElementAttribute as String), CFGetTypeID(fv) == AXUIElementGetTypeID() else { return nil }
        let el = fv as! AXUIElement
        var role = str(el, kAXRoleAttribute as String) ?? ""
        let textRole = role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox"
        // Rich editors in web pages (X's reply box) often show up as a group inside an editable area.
        let editable = attr(el, "AXEditableAncestor") != nil || (attr(el, "AXEditable") as? Bool ?? false)
        guard textRole || editable else { return nil }
        if !textRole { role = "AXTextArea" }
        let hint = [str(el, "AXPlaceholderValue"), str(el, kAXDescriptionAttribute as String), str(el, kAXTitleAttribute as String)]
            .compactMap { $0 }.joined(separator: " ")
        return (role, hint, rect(el) ?? .zero)
    }

    /// X's reply editor: the focused editable box, or else the page's box whose placeholder says reply.
    /// Returns the element and its screen rect (top-left origin). Only used to put a reply draft in; never to send.
    func replyEditor(pid: pid_t) -> (el: AXUIElement, rect: CGRect, focused: Bool)? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        func editable(_ e: AXUIElement) -> Bool {
            let r = str(e, kAXRoleAttribute as String) ?? ""
            if r == "AXTextField" || r == "AXSearchField" { return false }   // address bar, search box
            return r == "AXTextArea" || (attr(e, "AXEditable") as? Bool ?? false)
        }
        if let fv = attr(app, kAXFocusedUIElementAttribute as String), CFGetTypeID(fv) == AXUIElementGetTypeID() {
            let el = fv as! AXUIElement
            if editable(el) || attr(el, "AXEditableAncestor") != nil {
                var target = el
                if !editable(el), let a = attr(el, "AXEditableAncestor"), CFGetTypeID(a) == AXUIElementGetTypeID() { target = a as! AXUIElement }
                return (target, rect(target) ?? .zero, true)
            }
        }
        guard let wv = attr(app, kAXFocusedWindowAttribute as String), CFGetTypeID(wv) == AXUIElementGetTypeID() else { return nil }
        let hints = ["回覆", "回复", "reply", "返信", "답글"]
        var stack: [AXUIElement] = [wv as! AXUIElement]
        var n = 0
        let start = Date()
        while let e = stack.popLast(), n < 6000, Date().timeIntervalSince(start) < 0.8 {
            n += 1
            if editable(e) {
                let h = [str(e, "AXPlaceholderValue"), str(e, kAXDescriptionAttribute as String), str(e, kAXTitleAttribute as String)]
                    .compactMap { $0 }.joined(separator: " ").lowercased()
                if hints.contains(where: { h.contains($0) }), let r = rect(e), r.width > 40 { return (e, r, false) }
            }
            for c in children(e).reversed() { stack.append(c) }
        }
        return nil
    }

    /// The text now in an editor (only the reply box we just filled).
    func editorText(_ el: AXUIElement) -> String {
        if let v = str(el, kAXValueAttribute as String), !v.isEmpty { return v }
        // Rich editors keep the text in child nodes.
        var out = ""
        var stack = [el]
        var n = 0
        while let e = stack.popLast(), n < 300 {
            n += 1
            if let v = str(e, kAXValueAttribute as String) { out += v }
            for c in children(e).reversed() { stack.append(c) }
        }
        return out
    }

    /// Focus an editor; returns true when it took focus.
    func focus(_ el: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// Insert text at the cursor of a focused editor (accessibility path, no keystrokes).
    func insert(_ text: String, into el: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    func readAX(pid: pid_t, maxNodes: Int = 1600, budget: TimeInterval = 0.25,
                root: AXUIElement? = nil) -> (title: String, frame: CGRect, elements: [ScreenElement]) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)   // a frozen app must never freeze the cat
        if (Prefs.perception || Prefs.pageShare || Prefs.xMode) && !manualAXEnabled.contains(pid) {
            // Electron apps (VS Code, Slack, Notion…) only expose their tree when asked.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            // Chromium browsers build the web-page tree only for assistive clients.
            let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            if ScreenReader.chromiumBrowsers.contains(bid) {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
            manualAXEnabled.insert(pid)
        }
        guard let wv = attr(app, kAXFocusedWindowAttribute as String), CFGetTypeID(wv) == AXUIElementGetTypeID() else {
            return ("", .zero, [])
        }
        let win = wv as! AXUIElement
        let title = str(win, kAXTitleAttribute as String) ?? ""
        let frame = rect(win) ?? .zero
        let bidNow = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let browser = ScreenReader.chromiumBrowsers.contains(bidNow) || ["com.apple.Safari", "org.mozilla.firefox",
            "com.apple.SafariTechnologyPreview"].contains(bidNow)
        var out: [ScreenElement] = []
        // Each node carries whether it sits inside page content (AXWebArea) and whether it sits in window chrome
        // (toolbar, tab strip, bookmarks bar) — chrome is kept as context but never ringed.
        var stack: [(AXUIElement, Int, Bool, Bool)] = [(root ?? win, 0, false, false)]
        var visited = 0
        var sawWeb = false
        let deadline = Date().addingTimeInterval(budget)
        while let (el, depth, inWeb0, chrome0) = stack.popLast() {
            visited += 1
            if visited > maxNodes || Date() > deadline { break }
            let role = str(el, kAXRoleAttribute as String) ?? ""
            if role == "AXSecureTextField" { continue }                // never read password fields
            if role == "AXMenuBar" || role == "AXMenuBarItem" { continue } // noise
            let inWeb = inWeb0 || role == "AXWebArea"
            if role == "AXWebArea" { sawWeb = true }
            let chrome = chrome0 || (!inWeb && ["AXToolbar", "AXTabGroup", "AXMenuButton", "AXPopUpButton", "AXRadioGroup"].contains(role))
            if let name = roleName(role) {
                var text = ""
                for a in [kAXValueAttribute as String, kAXTitleAttribute as String, kAXDescriptionAttribute as String] {
                    if let s = str(el, a)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { text = s; break }
                }
                if !text.isEmpty, let r = rect(el), r.width > 1, r.height > 1, frame == .zero || frame.insetBy(dx: -4, dy: -4).intersects(r) {
                    let clipped = text.count > 1200 ? String(text.prefix(1200)) + "…" : text
                    // Outside the web page in a browser counts as chrome too (address bar, bookmarks, tabs).
                    out.append(ScreenElement(role: name, text: Redactor.clean(clipped), rect: r,
                                             chrome: chrome || (!inWeb && browser)))
                }
            }
            if depth < 30 {
                for c in children(el).reversed() { stack.append((c, depth + 1, inWeb, chrome)) }
            }
        }
        if browser && !sawWeb { for i in out.indices { out[i].chrome = false } }   // tree had no web area: don't drop everything
        // Reading order: top-to-bottom, left-to-right.
        out.sort { a, b in abs(a.rect.minY - b.rect.minY) > 6 ? a.rect.minY < b.rect.minY : a.rect.minX < b.rect.minX }
        return (Redactor.clean(title), frame, out)
    }

    // MARK: OCR fallback (macOS 14+, needs Screen Recording permission)
    func captureWindowImage(pid: pid_t, maxWidth: CGFloat = 1600) async -> (CGImage, CGRect)? {
        guard #available(macOS 14.0, *), ScreenReader.screenRecordingAllowed() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let wins = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 120 && $0.frame.height > 80
            }
            guard let win = wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let cfg = SCStreamConfiguration()
            let scale = min(2.0, maxWidth / max(1, win.frame.width))
            cfg.width = max(64, Int(win.frame.width * scale))
            cfg.height = max(64, Int(win.frame.height * scale))
            cfg.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return (img, win.frame)
        } catch {
            return nil
        }
    }

    func ocr(_ img: CGImage, frame: CGRect, accurate: Bool) -> [ScreenElement] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = accurate ? .accurate : .fast
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        req.usesLanguageCorrection = accurate
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        var out: [ScreenElement] = []
        for obs in req.results ?? [] {
            guard let s = obs.topCandidates(1).first?.string, s.count >= 2 else { continue }
            let bb = obs.boundingBox   // normalized, bottom-left origin
            let r = CGRect(x: frame.minX + bb.minX * frame.width,
                           y: frame.minY + (1 - bb.maxY) * frame.height,
                           width: bb.width * frame.width, height: bb.height * frame.height)
            out.append(ScreenElement(role: "文字", text: Redactor.clean(s), rect: r))
        }
        out.sort { a, b in abs(a.rect.minY - b.rect.minY) > 6 ? a.rect.minY < b.rect.minY : a.rect.minX < b.rect.minX }
        return out
    }

    /// Build one context card for the given app. `deep` = on-demand (accurate OCR, keep screenshot).
    func capture(app: NSRunningApplication, deep: Bool, wantScreenshot: Bool,
                 maxNodes: Int = 1600, axBudget: TimeInterval = 0.25) async -> ContextCard? {
        let bid = app.bundleIdentifier ?? ""
        if isExcluded(bid) || bid == Bundle.main.bundleIdentifier { return nil }
        let pid = app.processIdentifier
        let ax = await MainActor.run { self.readAX(pid: pid, maxNodes: maxNodes, budget: axBudget) }
        var elements = ax.elements
        var source = "AX"
        var shot: CGImage?
        let axChars = elements.reduce(0) { $0 + $1.text.count }
        let needOCR = Prefs.ocrFallback && axChars < 300
        if needOCR || (deep && wantScreenshot) {
            if let (img, frame) = await captureWindowImage(pid: pid, maxWidth: deep ? 1800 : 1280) {
                if needOCR {
                    var o = ocr(img, frame: frame, accurate: deep)
                    // OCR text above the bottom of the window chrome (tabs, address bar, bookmarks) is chrome too.
                    let chromeBottom = ax.elements.filter { $0.chrome && $0.rect.minY < frame.minY + 200 }.map { $0.rect.maxY }.max()
                    if let cb = chromeBottom { for i in o.indices where o[i].rect.midY < cb + 2 { o[i].chrome = true } }
                    if !o.isEmpty { elements += o; source = axChars > 0 ? "AX+OCR" : "OCR" }
                }
                if deep && wantScreenshot { shot = img }
            }
        }
        return ContextCard(date: Date(), app: app.localizedName ?? bid, bundleID: bid, pid: pid,
                           windowTitle: ax.title, windowRect: ax.frame, source: source,
                           elements: elements, screenshot: shot)
    }
}

// MARK: - Highlight overlay (grounding guidance)

final class Highlighter {
    private var panels: [NSPanel] = []

    /// Convert a top-left global rect into Cocoa screen coordinates (bottom-left origin).
    static func cocoaRect(_ r: CGRect) -> NSRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    }

    func clear() {
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
        shown.removeAll()
    }

    func show(_ rects: [CGRect], label: String? = nil, seconds: Double = 7, limit: Int = 4) {
        show(marks: rects.prefix(limit).map { ($0, 0) }, label: label, seconds: seconds)
    }

    private var hideWork: DispatchWorkItem?
    private var shown: [CGRect] = []

    /// Rings with their numbers (① ② … matching the answer; 0 = no number). Replaces what is on screen.
    func show(marks: [(CGRect, Int)], label: String? = nil, seconds: Double = 10) {
        clear()
        shown = []
        for (i, m) in marks.prefix(8).enumerated() { add(m.0, number: m.1, label: i == 0 ? label : nil, seconds: seconds) }
    }

    /// Ring one more place right away (while the answer is still being written), keeping the others.
    func add(_ r0: CGRect, number: Int, label: String? = nil, seconds: Double = 10) {
        guard panels.count < 8, !shown.contains(where: { $0.intersects(r0) && abs($0.midY - r0.midY) < 4 }) else { return }
        shown.append(r0)
        var r = Highlighter.cocoaRect(r0).insetBy(dx: -6, dy: -5)
        if r.width < 30 { r = r.insetBy(dx: -(30 - r.width) / 2, dy: 0) }
        if r.height < 24 { r = r.insetBy(dx: 0, dy: -(24 - r.height) / 2) }
        // Room for the number badge on the top-left corner.
        let badge: CGFloat = number > 0 ? 22 : 0
        let outer = NSRect(x: r.minX - badge / 2, y: r.minY, width: r.width + badge / 2, height: r.height + badge / 2)
        let p = NSPanel(contentRect: outer, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let v = NSView(frame: NSRect(origin: .zero, size: outer.size))
        v.wantsLayer = true
        v.layer?.masksToBounds = false
        let box = NSRect(x: badge / 2, y: 0, width: r.width, height: r.height)
        let ring = CAShapeLayer()
        ring.frame = v.bounds
        ring.path = CGPath(roundedRect: box.insetBy(dx: 2, dy: 2), cornerWidth: 7, cornerHeight: 7, transform: nil)
        ring.fillColor = kAmber.withAlphaComponent(0.10).cgColor
        ring.strokeColor = kAmber.cgColor
        ring.lineWidth = 2.5
        ring.shadowColor = kAmber.cgColor
        ring.shadowOpacity = 0.8
        ring.shadowRadius = 6
        ring.shadowOffset = .zero
        v.layer?.addSublayer(ring)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Draw in once (the cat "circles" it), then breathe softly.
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0; draw.toValue = 1; draw.duration = 0.35
            draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(draw, forKey: "draw")
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.5
            pulse.beginTime = CACurrentMediaTime() + 0.35
            pulse.duration = 0.8; pulse.autoreverses = true; pulse.repeatCount = .infinity
            ring.add(pulse, forKey: "pulse")
        }
        if number > 0 {
            let marks = ["①","②","③","④","⑤","⑥","⑦","⑧","⑨","⑩"]
            let c = CATextLayer()
            c.string = number <= marks.count ? String(number) : "•"
            c.font = NSFont.systemFont(ofSize: 12, weight: .bold)
            c.fontSize = 12
            c.alignmentMode = .center
            c.foregroundColor = NSColor(srgbRed: 0.12, green: 0.13, blue: 0.13, alpha: 1).cgColor
            c.backgroundColor = kAmber.cgColor
            c.cornerRadius = 10
            c.contentsScale = 2
            c.frame = CGRect(x: 0, y: outer.height - 20, width: 20, height: 20)
            // Vertically centre the digit.
            let t = CATextLayer(); _ = t
            c.bounds = CGRect(x: 0, y: -2, width: 20, height: 20)
            v.layer?.addSublayer(c)
        }
        if let label = label, !label.isEmpty {
            let t = CATextLayer()
            t.string = " 🐾 " + label + " "
            t.fontSize = 12
            t.foregroundColor = NSColor.black.cgColor
            t.backgroundColor = kAmber.cgColor
            t.cornerRadius = 6
            t.contentsScale = 2
            t.frame = CGRect(x: badge + 2, y: outer.height - 2, width: min(260, CGFloat(label.count) * 13 + 40), height: 18)
            v.layer?.addSublayer(t)
        }
        p.contentView = v
        p.orderFrontRegardless()
        panels.append(p)
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.clear() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
}
