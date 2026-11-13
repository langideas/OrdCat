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

    private var manualAXEnabled = Set<pid_t>()

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
    func readAX(pid: pid_t, maxNodes: Int = 1600, budget: TimeInterval = 0.25) -> (title: String, frame: CGRect, elements: [ScreenElement]) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)   // a frozen app must never freeze the cat
        if Prefs.perception && !manualAXEnabled.contains(pid) {
            // Electron apps (VS Code, Slack, Notion…) only expose their tree when asked.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            manualAXEnabled.insert(pid)
        }
        guard let wv = attr(app, kAXFocusedWindowAttribute as String), CFGetTypeID(wv) == AXUIElementGetTypeID() else {
            return ("", .zero, [])
        }
        let win = wv as! AXUIElement
        let title = str(win, kAXTitleAttribute as String) ?? ""
        let frame = rect(win) ?? .zero
        var out: [ScreenElement] = []
        var stack: [(AXUIElement, Int)] = [(win, 0)]
        var visited = 0
        let deadline = Date().addingTimeInterval(budget)
        while let (el, depth) = stack.popLast() {
            visited += 1
            if visited > maxNodes || Date() > deadline { break }
            let role = str(el, kAXRoleAttribute as String) ?? ""
            if role == "AXSecureTextField" { continue }                // never read password fields
            if role == "AXMenuBar" || role == "AXMenuBarItem" { continue } // noise
            if let name = roleName(role) {
                var text = ""
                for a in [kAXValueAttribute as String, kAXTitleAttribute as String, kAXDescriptionAttribute as String] {
                    if let s = str(el, a)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { text = s; break }
                }
                if !text.isEmpty, let r = rect(el), r.width > 1, r.height > 1, frame == .zero || frame.insetBy(dx: -4, dy: -4).intersects(r) {
                    let clipped = text.count > 1200 ? String(text.prefix(1200)) + "…" : text
                    out.append(ScreenElement(role: name, text: Redactor.clean(clipped), rect: r))
                }
            }
            if depth < 30 {
                for c in children(el).reversed() { stack.append((c, depth + 1)) }
            }
        }
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
    func capture(app: NSRunningApplication, deep: Bool, wantScreenshot: Bool) async -> ContextCard? {
        let bid = app.bundleIdentifier ?? ""
        if isExcluded(bid) || bid == Bundle.main.bundleIdentifier { return nil }
        let pid = app.processIdentifier
        let ax = await MainActor.run { self.readAX(pid: pid) }
        var elements = ax.elements
        var source = "AX"
        var shot: CGImage?
        let axChars = elements.reduce(0) { $0 + $1.text.count }
        let needOCR = Prefs.ocrFallback && axChars < 300
        if needOCR || (deep && wantScreenshot) {
            if let (img, frame) = await captureWindowImage(pid: pid, maxWidth: deep ? 1800 : 1280) {
                if needOCR {
                    let o = ocr(img, frame: frame, accurate: deep)
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
    }

    func show(_ rects: [CGRect], label: String? = nil, seconds: Double = 7) {
        clear()
        for (i, r0) in rects.prefix(4).enumerated() {
            var r = Highlighter.cocoaRect(r0).insetBy(dx: -8, dy: -8)
            if r.width < 36 { r = r.insetBy(dx: -(36 - r.width) / 2, dy: 0) }
            if r.height < 36 { r = r.insetBy(dx: 0, dy: -(36 - r.height) / 2) }
            let p = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            let v = NSView(frame: NSRect(origin: .zero, size: r.size))
            v.wantsLayer = true
            let ring = CAShapeLayer()
            ring.frame = v.bounds
            ring.path = CGPath(roundedRect: v.bounds.insetBy(dx: 3, dy: 3), cornerWidth: 10, cornerHeight: 10, transform: nil)
            ring.fillColor = kAmber.withAlphaComponent(0.12).cgColor
            ring.strokeColor = kAmber.cgColor
            ring.lineWidth = 3
            ring.shadowColor = kAmber.cgColor
            ring.shadowOpacity = 0.8
            ring.shadowRadius = 8
            ring.shadowOffset = .zero
            v.layer?.addSublayer(ring)
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.35
            pulse.duration = 0.6; pulse.autoreverses = true; pulse.repeatCount = .infinity
            ring.add(pulse, forKey: "pulse")
            if i == 0, let label = label, !label.isEmpty {
                let t = CATextLayer()
                t.string = " 🐾 " + label + " "
                t.fontSize = 12
                t.foregroundColor = NSColor.black.cgColor
                t.backgroundColor = kAmber.cgColor
                t.cornerRadius = 6
                t.contentsScale = 2
                t.frame = CGRect(x: 4, y: v.bounds.height - 4, width: min(260, CGFloat(label.count) * 13 + 40), height: 18)
                v.layer?.masksToBounds = false
                v.layer?.addSublayer(t)
            }
            p.contentView = v
            p.orderFrontRegardless()
            panels.append(p)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.clear() }
    }
}
