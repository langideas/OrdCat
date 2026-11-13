// OrdCat — a cozy cat peeking from the right edge of your screen.
// Native AppKit, single file. Event-driven: no polling loops while idle.

import Cocoa
import AVFoundation
import Security

// MARK: - Theme

let kAmber = NSColor(calibratedRed: 1.0, green: 0.71, blue: 0.28, alpha: 1)
let kFur = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
let kRim = NSColor(calibratedWhite: 1.0, alpha: 0.22)

// MARK: - Model presets (BYOM, OpenAI-compatible endpoints)

struct Preset { let name: String; let base: String; let model: String }
let kPresets: [Preset] = [
    Preset(name: "Ollama（本地离线）", base: "http://localhost:11434/v1", model: "qwen2.5:7b"),
    Preset(name: "Groq", base: "https://api.groq.com/openai/v1", model: "openai/gpt-oss-120b"),
    Preset(name: "DeepSeek", base: "https://api.deepseek.com/v1", model: "deepseek-chat"),
    Preset(name: "OpenAI", base: "https://api.openai.com/v1", model: "gpt-4o-mini"),
    Preset(name: "Gemini", base: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-2.0-flash"),
    Preset(name: "Claude", base: "https://api.anthropic.com/v1", model: "claude-3-5-haiku-latest"),
    Preset(name: "自定义（OpenAI 兼容）", base: "", model: "")
]

// MARK: - Storage

enum Keychain {
    static let service = "app.ordcat.apikey"
    static func set(_ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get() -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let d = out as? Data, let s = String(data: d, encoding: .utf8) { return s }
        return ""
    }
}

enum Prefs {
    static let d = UserDefaults.standard
    static var base: String {
        get { d.string(forKey: "base") ?? kPresets[0].base }
        set { d.set(newValue, forKey: "base") }
    }
    static var model: String {
        get { d.string(forKey: "model") ?? kPresets[0].model }
        set { d.set(newValue, forKey: "model") }
    }
    static var presetIndex: Int {
        get { d.object(forKey: "preset") as? Int ?? 0 }
        set { d.set(newValue, forKey: "preset") }
    }
    static var voice: Bool {
        get { d.object(forKey: "voice") as? Bool ?? true }
        set { d.set(newValue, forKey: "voice") }
    }
    static var clipWatch: Bool {
        get { d.object(forKey: "clipWatch") as? Bool ?? true }
        set { d.set(newValue, forKey: "clipWatch") }
    }
    static var care: Bool {
        get { d.object(forKey: "care") as? Bool ?? true }
        set { d.set(newValue, forKey: "care") }
    }
    static var catY: Double? {
        get { d.object(forKey: "catY") as? Double }
        set { d.set(newValue, forKey: "catY") }
    }
    static var bondingDays: [String] {
        get { d.stringArray(forKey: "bondingDays") ?? [] }
        set { d.set(newValue, forKey: "bondingDays") }
    }
}

// MARK: - LLM client (streaming, OpenAI-compatible)

final class LLM {
    private(set) var history: [[String: String]] = []
    private var task: Task<Void, Never>?
    let system = """
    你是 OrdCat，一只窝在用户电脑屏幕右侧边、探出半个脑袋的小黑猫陪伴助手。
    性格：温柔、共情、轻松幽默，像一个安静的朋友。说话简短口语化，一般不超过 80 个字，可以偶尔用 🐾 🍵 🌙 这类表情。
    你不催促用户提高效率，也不制造焦虑；你陪伴、安抚，在需要时给出恰到好处的提示。
    遇到代码或报错：先一句安抚，再用最简单的话指出问题和改法。
    始终使用简体中文回答。
    """

    func cancel() { task?.cancel(); task = nil }
    func reset() { cancel(); history.removeAll() }

    func send(_ text: String,
              onDelta: @escaping (String) -> Void,
              onDone: @escaping (String?, String?) -> Void) {
        cancel()
        history.append(["role": "user", "content": text])
        if history.count > 16 { history.removeFirst(history.count - 16) }

        var base = Prefs.base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + "/chat/completions") else {
            onDone(nil, "还没设置模型哦～点菜单栏里的 🐈‍⬛ → 设置模型，就能和我聊天啦。")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = Keychain.get()
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let messages: [[String: String]] = [["role": "system", "content": system]] + history
        var body: [String: Any] = ["model": Prefs.model, "messages": messages, "stream": true, "max_tokens": 1200]
        // Reasoning models (e.g. gpt-oss on Groq) would otherwise spend the budget thinking.
        if base.contains("groq.com") && Prefs.model.contains("gpt-oss") { body["reasoning_effort"] = "low" }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        task = Task { [weak self] in
            var full = ""
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                if let h = resp as? HTTPURLResponse, h.statusCode >= 300 {
                    var errText = ""
                    for try await line in bytes.lines {
                        errText += line
                        if errText.count > 300 { break }
                    }
                    let msg = "模型那边返回了错误（\(h.statusCode)）：\(errText.prefix(160))"
                    DispatchQueue.main.async { onDone(nil, msg) }
                    return
                }
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
                    var piece = ""
                    if let delta = choice["delta"] as? [String: Any], let c = delta["content"] as? String {
                        piece = c
                    } else if let m = choice["message"] as? [String: Any], let c = m["content"] as? String {
                        piece = c
                    }
                    if !piece.isEmpty {
                        full += piece
                        let snapshot = full
                        DispatchQueue.main.async { onDelta(snapshot) }
                    }
                }
                let final = full
                DispatchQueue.main.async {
                    self?.history.append(["role": "assistant", "content": final])
                    onDone(final, nil)
                }
            } catch {
                if Task.isCancelled { return }
                let msg = "连不上模型：\(error.localizedDescription)"
                DispatchQueue.main.async { onDone(nil, msg) }
            }
        }
    }
}

// MARK: - Voice (system TTS)

final class Voice {
    private let synth = AVSpeechSynthesizer()
    func speak(_ text: String) {
        guard Prefs.voice else { return }
        synth.stopSpeaking(at: .immediate)
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            let p = s.properties
            if p.isEmojiPresentation || (p.isEmoji && s.value > 0x2000) { continue }
            scalars.append(s)
        }
        let clean = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let u = AVSpeechUtterance(string: clean)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.48
        u.pitchMultiplier = 1.15
        synth.speak(u)
    }
    func stop() { synth.stopSpeaking(at: .immediate) }
}

// MARK: - Cat view (layer-drawn, right-edge peek)

final class CatView: NSView {
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?

    private let rig = CALayer()
    private let cat = CALayer()
    private let head = CAShapeLayer()
    private let earL = CAShapeLayer()
    private let earR = CAShapeLayer()
    private let eyeL = CAShapeLayer()
    private let eyeR = CAShapeLayer()
    private let paw = CAShapeLayer()
    private let excl = CAShapeLayer()

    private let tilt: CGFloat = 18 * .pi / 180
    private var lookOffset = CGPoint.zero
    private var eyeScale: CGFloat = 1
    private var perked = false
    private var dragStart: NSPoint?
    private var dragged = false
    private var lastLook: TimeInterval = 0

    var headCenter: CGPoint { CGPoint(x: bounds.maxX - 46, y: bounds.midY + 6) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func tri(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.move(to: pts[0]); p.addLine(to: pts[1]); p.addLine(to: pts[2]); p.closeSubpath()
        return p
    }

    private func makeEar(_ layer: CAShapeLayer, outer: [CGPoint], inner: [CGPoint]) {
        let xs = outer.map { $0.x }, ys = outer.map { $0.y }
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let shift = { (p: CGPoint) in CGPoint(x: p.x - box.minX, y: p.y - box.minY) }
        layer.bounds = CGRect(origin: .zero, size: box.size)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        layer.position = CGPoint(x: box.midX, y: box.minY)
        layer.path = tri(outer.map(shift))
        layer.fillColor = kFur.cgColor
        layer.strokeColor = kRim.cgColor
        layer.lineWidth = 2
        layer.lineJoin = .round
        let innerL = CAShapeLayer()
        innerL.frame = layer.bounds
        innerL.path = tri(inner.map(shift))
        innerL.fillColor = NSColor(calibratedRed: 0.23, green: 0.17, blue: 0.19, alpha: 1).cgColor
        layer.addSublayer(innerL)
    }

    private func makeEye(_ layer: CAShapeLayer, center: CGPoint) {
        layer.bounds = CGRect(x: 0, y: 0, width: 15, height: 28)
        layer.position = center
        layer.path = CGPath(roundedRect: layer.bounds, cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)
        layer.fillColor = kAmber.cgColor
        layer.shadowColor = kAmber.cgColor
        layer.shadowOpacity = 0.6
        layer.shadowRadius = 6
        layer.shadowOffset = .zero
    }

    private func build() {
        guard let root = layer else { return }
        rig.frame = bounds
        root.addSublayer(rig)

        cat.bounds = CGRect(x: -130, y: -130, width: 260, height: 260)
        cat.position = headCenter
        cat.transform = CATransform3DMakeRotation(tilt, 0, 0, 1)
        rig.addSublayer(cat)

        makeEar(earL, outer: [CGPoint(x: -74, y: 28), CGPoint(x: -58, y: 106), CGPoint(x: -14, y: 58)],
                inner: [CGPoint(x: -62, y: 40), CGPoint(x: -55, y: 86), CGPoint(x: -30, y: 58)])
        makeEar(earR, outer: [CGPoint(x: 74, y: 28), CGPoint(x: 58, y: 106), CGPoint(x: 14, y: 58)],
                inner: [CGPoint(x: 62, y: 40), CGPoint(x: 55, y: 86), CGPoint(x: 30, y: 58)])
        cat.addSublayer(earL)
        cat.addSublayer(earR)

        head.path = CGPath(ellipseIn: CGRect(x: -80, y: -72, width: 160, height: 144), transform: nil)
        head.fillColor = kFur.cgColor
        head.strokeColor = kRim.cgColor
        head.lineWidth = 2
        head.shadowColor = kAmber.cgColor
        head.shadowOpacity = 0.22
        head.shadowRadius = 14
        head.shadowOffset = .zero
        cat.addSublayer(head)

        makeEye(eyeL, center: CGPoint(x: -27, y: 2))
        makeEye(eyeR, center: CGPoint(x: 25, y: 2))
        cat.addSublayer(eyeL)
        cat.addSublayer(eyeR)

        let pawRect = CGRect(x: bounds.maxX - 58, y: headCenter.y - 98, width: 70, height: 36)
        paw.path = CGPath(roundedRect: pawRect, cornerWidth: 18, cornerHeight: 18, transform: nil)
        paw.fillColor = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.1, alpha: 1).cgColor
        paw.strokeColor = kRim.cgColor
        paw.lineWidth = 2
        rig.addSublayer(paw)

        let ec = CGPoint(x: headCenter.x - 112, y: headCenter.y + 100)
        excl.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        excl.position = ec
        excl.path = CGPath(ellipseIn: excl.bounds, transform: nil)
        excl.fillColor = kAmber.cgColor
        let t = CATextLayer()
        t.string = "!"
        t.font = NSFont.systemFont(ofSize: 22, weight: .heavy)
        t.fontSize = 22
        t.foregroundColor = NSColor.black.cgColor
        t.alignmentMode = .center
        t.contentsScale = 2
        t.frame = CGRect(x: 0, y: 3, width: 34, height: 28)
        excl.addSublayer(t)
        excl.opacity = 0
        rig.addSublayer(excl)

        applyEars(animated: false)
        applyEyes(animated: false)
    }

    // Peek in from the screen edge.
    func peekIn() {
        let a = CASpringAnimation(keyPath: "position.x")
        a.fromValue = bounds.midX + 220
        a.toValue = bounds.midX
        a.damping = 11
        a.initialVelocity = 0
        a.duration = a.settlingDuration
        rig.add(a, forKey: "peek")
    }

    // MARK: eyes
    func look(atScreen p: NSPoint) {
        guard let w = window else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLook < 1.0 / 30.0 { return }   // cap at 30 fps, only while the mouse moves
        lastLook = now
        let vp = convert(w.convertPoint(fromScreen: p), from: nil)
        let vx = vp.x - headCenter.x, vy = vp.y - headCenter.y
        let c = cos(-tilt), s = sin(-tilt)
        let lx = vx * c - vy * s, ly = vx * s + vy * c
        let dist = max(1, hypot(lx, ly))
        let g = min(1, dist / 250)
        lookOffset = CGPoint(x: lx / dist * 9 * g, y: ly / dist * 7 * g)
        applyEyes(animated: true)
    }

    func setSleepy(_ sleepy: Bool) {
        let target: CGFloat = sleepy ? 0.25 : 1
        if target != eyeScale { eyeScale = target; applyEyes(animated: true) }
    }

    private func applyEyes(animated: Bool) {
        CATransaction.begin()
        if animated { CATransaction.setAnimationDuration(0.09) } else { CATransaction.setDisableActions(true) }
        let sy = eyeScale * (perked ? 1.15 : 1)
        let t = CATransform3DScale(CATransform3DMakeTranslation(lookOffset.x, lookOffset.y, 0), 1, sy, 1)
        eyeL.transform = t
        eyeR.transform = t
        CATransaction.commit()
    }

    func blink() {
        guard eyeScale > 0.5 else { return }
        for e in [eyeL, eyeR] {
            let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
            a.values = [1, 0.1, 1]
            a.keyTimes = [0, 0.5, 1]
            a.duration = 0.18
            e.add(a, forKey: "blink")
        }
    }

    // MARK: ears
    func perk(_ on: Bool) {
        guard on != perked else { return }
        perked = on
        applyEars(animated: true)
        applyEyes(animated: true)
        if on { popExclamation() }
    }

    private func earTransform(left: Bool) -> CATransform3D {
        let angle: CGFloat = perked ? 0 : (left ? 0.36 : -0.36)
        let sy: CGFloat = perked ? 1.15 : 0.8
        return CATransform3DScale(CATransform3DMakeRotation(angle, 0, 0, 1), 1, sy, 1)
    }

    private func applyEars(animated: Bool) {
        for (layer, left) in [(earL, true), (earR, false)] {
            let to = earTransform(left: left)
            if animated {
                let a = CASpringAnimation(keyPath: "transform")
                a.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? layer.transform)
                a.toValue = NSValue(caTransform3D: to)
                a.damping = 9
                a.duration = a.settlingDuration
                layer.add(a, forKey: "ear")
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.transform = to
            CATransaction.commit()
        }
    }

    private func popExclamation() {
        let s = CASpringAnimation(keyPath: "transform.scale")
        s.fromValue = 0.3; s.toValue = 1; s.damping = 8; s.duration = s.settlingDuration
        let o = CAKeyframeAnimation(keyPath: "opacity")
        o.values = [0, 1, 1, 0]
        o.keyTimes = [0, 0.1, 0.75, 1]
        o.duration = 1.6
        excl.add(s, forKey: "s")
        excl.add(o, forKey: "o")
    }

    // MARK: mouse
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return hypot(p.x - headCenter.x, p.y - headCenter.y) < 110 ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let w = window, let start = dragStart else { return }
        let now = NSEvent.mouseLocation
        let dy = now.y - start.y
        if abs(dy) > 3 { dragged = true }
        if dragged {
            var f = w.frame
            f.origin.y += dy
            if let vis = w.screen?.visibleFrame {
                f.origin.y = min(max(f.origin.y, vis.minY - 40), vis.maxY - f.height + 20)
            }
            w.setFrameOrigin(f.origin)
            dragStart = now
            onMoved?()
        }
    }
    override func mouseUp(with event: NSEvent) {
        if dragged, let w = window { Prefs.catY = Double(w.frame.origin.y) }
        if !dragged { onClick?() }
        dragStart = nil
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Panels

final class CatPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class KeyPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - Bubble (non-activating, sits to the left of the cat)

final class Bubble: NSObject, NSTextFieldDelegate {
    let panel: KeyPanel
    private let card = NSVisualEffectView()
    private let title = NSTextField(labelWithString: "OrdCat")
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let input = NSTextField()
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private var hideTimer: Timer?
    private(set) var chatMode = false
    private var action: (() -> Void)?
    var onSend: ((String) -> Void)?
    var anchor: () -> NSRect = { .zero }   // cat window frame
    let width: CGFloat = 340

    var isShown: Bool { panel.isVisible && panel.alphaValue > 0.01 }

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.onEscape = { [weak self] in self?.hide() }

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = content
        card.material = .hudWindow
        card.state = .active
        card.blendingMode = .behindWindow
        card.appearance = NSAppearance(named: .vibrantDark)
        card.wantsLayer = true
        card.layer?.cornerRadius = 20
        card.layer?.masksToBounds = true
        content.addSubview(card)

        title.font = .systemFont(ofSize: 12, weight: .bold)
        title.textColor = kAmber
        card.addSubview(title)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .white
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        card.addSubview(scroll)

        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(doAction)
        card.addSubview(actionButton)

        input.placeholderString = "和小猫说点什么…（回车发送，Esc 收起）"
        input.font = .systemFont(ofSize: 13)
        input.focusRingType = .none
        input.bezelStyle = .roundedBezel
        input.delegate = self
        input.target = self
        input.action = #selector(doSend)
        card.addSubview(input)

        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(doSend)
        card.addSubview(sendButton)
    }

    @objc private func doAction() { let a = action; a?() }
    @objc private func doSend() {
        let t = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        input.stringValue = ""
        onSend?(t)
    }

    /// A short note that retracts by itself.
    func notify(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        chatMode = false
        self.action = action
        setText(text, actionTitle: actionTitle)
        present(makeKey: false)
        scheduleHide(after: min(15, 4 + Double(text.count) * 0.08))
    }

    /// Open the chat box.
    func openChat(greeting: String?) {
        chatMode = true
        action = nil
        hideTimer?.invalidate()
        setText(greeting ?? textView.string, actionTitle: nil)
        present(makeKey: true)
        panel.makeFirstResponder(input)
    }

    func setText(_ text: String, actionTitle: String? = nil) {
        textView.string = text
        if let at = actionTitle { actionButton.title = at; actionButton.isHidden = false }
        else if !chatMode || action == nil { actionButton.isHidden = true }
        layout()
    }

    func hide() {
        hideTimer?.invalidate()
        chatMode = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.panel.alphaValue < 0.01 else { return }
            self.panel.orderOut(nil)
        })
    }

    private func scheduleHide(after s: Double) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
            guard let self = self, !self.chatMode else { return }
            if self.panel.frame.contains(NSEvent.mouseLocation) { self.scheduleHide(after: 2); return }
            self.hide()
        }
        hideTimer?.tolerance = 0.3
    }

    private func present(makeKey: Bool) {
        layout()
        if !panel.isVisible { panel.alphaValue = 0 }
        if makeKey { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    func layout() {
        let pad: CGFloat = 16
        let inner = width - pad * 2
        textView.frame = NSRect(x: 0, y: 0, width: inner, height: 10)
        textView.textContainer?.containerSize = NSSize(width: inner, height: .greatestFiniteMagnitude)
        if let lm = textView.layoutManager, let tc = textView.textContainer { lm.ensureLayout(for: tc) }
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 18
        let textH = min(max(used, 18), 300)
        let showAction = !actionButton.isHidden
        let actionH: CGFloat = showAction ? 34 : 0
        let chatH: CGFloat = chatMode ? 40 : 0
        let h = pad + 18 + 6 + textH + actionH + chatH + pad

        var y = h - pad - 16
        title.frame = NSRect(x: pad, y: y, width: inner, height: 16)
        y -= 6 + textH
        scroll.frame = NSRect(x: pad, y: y, width: inner, height: textH)
        textView.frame = NSRect(x: 0, y: 0, width: inner, height: max(used, textH))
        if showAction {
            y -= actionH
            actionButton.frame = NSRect(x: pad - 4, y: y + 2, width: 130, height: 28)
        }
        input.isHidden = !chatMode
        sendButton.isHidden = !chatMode
        if chatMode {
            y -= chatH
            input.frame = NSRect(x: pad, y: y + 6, width: inner - 64, height: 26)
            sendButton.frame = NSRect(x: pad + inner - 58, y: y + 4, width: 60, height: 30)
        }

        let a = anchor()
        let headY = a.midY + 6
        var x = a.minX - width + 70
        var yy = headY - h / 2 + 30
        if let vis = (NSScreen.screens.first(where: { $0.frame.intersects(a) }) ?? NSScreen.main)?.visibleFrame {
            x = max(vis.minX + 8, x)
            yy = min(max(vis.minY + 8, yy), vis.maxY - h - 8)
        }
        panel.setFrame(NSRect(x: x, y: yy, width: width, height: h), display: true)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: h)
        card.frame = NSRect(x: 0, y: 0, width: width, height: h)
        textView.scrollToEndOfDocument(nil)
    }
}

// MARK: - Settings window

final class SettingsController: NSObject {
    private var window: NSWindow?
    private let preset = NSPopUpButton()
    private let base = NSTextField()
    private let key = NSSecureTextField()
    private let model = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let llm = LLM()

    func show() {
        if window == nil { build() }
        base.stringValue = Prefs.base
        model.stringValue = Prefs.model
        key.stringValue = Keychain.get()
        preset.selectItem(at: min(Prefs.presetIndex, kPresets.count - 1))
        status.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func row(_ label: String, _ field: NSView, y: CGFloat, in v: NSView) {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.frame = NSRect(x: 16, y: y + 3, width: 96, height: 20)
        v.addSubview(l)
        field.frame = NSRect(x: 120, y: y, width: 320, height: 26)
        v.addSubview(field)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 290),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "OrdCat · 模型设置（BYOM）"
        w.isReleasedWhenClosed = false
        let v = NSView(frame: w.contentRect(forFrameRect: w.frame))
        w.contentView = v

        for p in kPresets { preset.addItem(withTitle: p.name) }
        preset.target = self
        preset.action = #selector(presetChanged)
        base.placeholderString = "https://…/v1"
        key.placeholderString = "本地 Ollama 可留空"
        model.placeholderString = "模型名称"

        row("服务商", preset, y: 236, in: v)
        row("接口地址", base, y: 198, in: v)
        row("API Key", key, y: 160, in: v)
        row("模型", model, y: 122, in: v)

        let hint = NSTextField(wrappingLabelWithString: "任何 OpenAI 兼容接口都能用。API Key 只保存在你 Mac 的钥匙串里。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.frame = NSRect(x: 120, y: 84, width: 320, height: 30)
        v.addSubview(hint)

        status.frame = NSRect(x: 20, y: 52, width: 430, height: 22)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        v.addSubview(status)

        let test = NSButton(title: "测试连接", target: self, action: #selector(testIt))
        test.frame = NSRect(x: 250, y: 14, width: 96, height: 30)
        v.addSubview(test)
        let save = NSButton(title: "保存", target: self, action: #selector(saveIt))
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: 350, y: 14, width: 96, height: 30)
        v.addSubview(save)
        window = w
    }

    @objc private func presetChanged() {
        let p = kPresets[preset.indexOfSelectedItem]
        if !p.base.isEmpty { base.stringValue = p.base; model.stringValue = p.model }
    }

    private func store() {
        Prefs.presetIndex = preset.indexOfSelectedItem
        Prefs.base = base.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Prefs.model = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func saveIt() {
        store()
        window?.close()
    }

    @objc private func testIt() {
        store()
        status.stringValue = "正在连接…"
        llm.reset()
        llm.send("用一句话跟我打个招呼", onDelta: { [weak self] t in
            self?.status.stringValue = "🐾 " + t
        }, onDone: { [weak self] t, err in
            if let err = err { self?.status.stringValue = "⚠️ " + err }
            else { self?.status.stringValue = "✅ 连接成功：" + (t ?? "") }
        })
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var catPanel: CatPanel!
    private var catView: CatView!
    private let bubble = Bubble()
    private let llm = LLM()
    private let voice = Voice()
    private let settings = SettingsController()
    private var statusItem: NSStatusItem!
    private var monitors: [Any] = []
    private var clipTimer: Timer?
    private var careTimer: Timer?
    private var blinkTimer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var sessionStart = Date()
    private var nudgedLong = false
    private var nudgedNight: String?
    private var lastClip: String = ""

    let catSize = NSSize(width: 230, height: 260)

    func applicationDidFinishLaunching(_ note: Notification) {
        buildCat()
        buildMenu()
        bubble.anchor = { [weak self] in self?.catPanel.frame ?? .zero }
        bubble.onSend = { [weak self] text in self?.ask(text) }
        startMonitors()
        recordBondingDay()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self = self else { return }
            let days = Prefs.bondingDays.count
            let hello = days <= 1 ? "你好呀，我是 OrdCat 🐾 我会安静窝在这里。点我可以聊天，复制一段文字我会竖起耳朵～"
                                  : "我回来啦～这是我们一起的第 \(days) 天 🐾"
            self.bubble.notify(hello)
        }
    }

    // MARK: cat window
    private func catFrame(on screen: NSScreen) -> NSRect {
        let f = screen.frame          // full frame: sit on the real edge
        let vis = screen.visibleFrame
        var y = CGFloat(Prefs.catY ?? Double(vis.minY + vis.height * 0.42))
        y = min(max(y, vis.minY - 40), vis.maxY - catSize.height + 20)
        return NSRect(x: f.maxX - catSize.width, y: y, width: catSize.width, height: catSize.height)
    }

    private func buildCat() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        catPanel = CatPanel(contentRect: catFrame(on: screen),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        catPanel.isOpaque = false
        catPanel.backgroundColor = .clear
        catPanel.hasShadow = false
        catPanel.level = .floating
        catPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        catPanel.hidesOnDeactivate = false
        catPanel.isMovable = false
        catView = CatView(frame: NSRect(origin: .zero, size: catSize))
        catPanel.contentView = catView
        catView.onClick = { [weak self] in self?.toggleChat() }
        catView.onMoved = { [weak self] in
            guard let self = self, self.bubble.isShown else { return }
            self.bubble.layout()
        }
        catPanel.orderFrontRegardless()
        catView.peekIn()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self = self, let s = self.catPanel.screen ?? NSScreen.main else { return }
            self.catPanel.setFrame(self.catFrame(on: s), display: true)
        }
    }

    // MARK: menu bar
    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐈‍⬛"
        let m = NSMenu()
        m.addItem(withTitle: "和小猫聊天", action: #selector(menuChat), keyEquivalent: "").target = self
        m.addItem(withTitle: "显示 / 隐藏小猫", action: #selector(toggleCat), keyEquivalent: "").target = self
        m.addItem(.separator())
        let clip = m.addItem(withTitle: "复制文字时竖起耳朵", action: #selector(toggleClip(_:)), keyEquivalent: "")
        clip.target = self; clip.state = Prefs.clipWatch ? .on : .off
        let voiceItem = m.addItem(withTitle: "语音播报", action: #selector(toggleVoice(_:)), keyEquivalent: "")
        voiceItem.target = self; voiceItem.state = Prefs.voice ? .on : .off
        let careItem = m.addItem(withTitle: "久坐 / 熬夜关怀", action: #selector(toggleCare(_:)), keyEquivalent: "")
        careItem.target = self; careItem.state = Prefs.care ? .on : .off
        m.addItem(withTitle: "清空对话记忆", action: #selector(clearChat), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "设置模型…", action: #selector(openSettings), keyEquivalent: ",").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "退出 OrdCat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    @objc private func menuChat() { if !catPanel.isVisible { toggleCat() }; openChat() }
    @objc private func toggleCat() {
        if catPanel.isVisible { bubble.hide(); catPanel.orderOut(nil) }
        else { catPanel.orderFrontRegardless(); catView.peekIn() }
    }
    @objc private func toggleClip(_ s: NSMenuItem) { Prefs.clipWatch.toggle(); s.state = Prefs.clipWatch ? .on : .off }
    @objc private func toggleVoice(_ s: NSMenuItem) {
        Prefs.voice.toggle(); s.state = Prefs.voice ? .on : .off
        if !Prefs.voice { voice.stop() }
    }
    @objc private func toggleCare(_ s: NSMenuItem) { Prefs.care.toggle(); s.state = Prefs.care ? .on : .off }
    @objc private func clearChat() { llm.reset(); bubble.notify("好哒，刚才聊的我都忘掉啦 🐾") }
    @objc private func openSettings() { settings.show() }

    // MARK: chat
    private func toggleChat() {
        if bubble.isShown && bubble.chatMode { bubble.hide(); voice.stop(); catView.perk(false) }
        else { openChat() }
    }
    private func openChat() {
        catView.perk(false)
        bubble.openChat(greeting: llm.history.last?["content"] ?? "喵～想聊点什么？")
    }
    private func ask(_ text: String) {
        voice.stop()
        if !bubble.chatMode { bubble.openChat(greeting: nil) }
        bubble.setText("……")
        llm.send(text, onDelta: { [weak self] t in
            self?.bubble.setText(t)
        }, onDone: { [weak self] t, err in
            guard let self = self else { return }
            self.catView.perk(false)
            if let err = err { self.bubble.setText(err); return }
            let reply = t ?? ""
            self.bubble.setText(reply)
            self.voice.speak(reply)
        })
    }

    // MARK: monitors (event-driven)
    private func startMonitors() {
        // Eyes follow the mouse. Fires only when the mouse moves; no polling.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            self?.catView.look(atScreen: NSEvent.mouseLocation)
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] e in
            self?.catView.look(atScreen: NSEvent.mouseLocation)
            return e
        }) { monitors.append(l) }

        // Pasteboard has no change notification on macOS; a 1 s timer with wide tolerance is the cheapest option.
        clipTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.checkClipboard() }
        clipTimer?.tolerance = 0.5

        careTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.checkCare() }
        careTimer?.tolerance = 20

        scheduleBlink()

        // Pause timers during sleep.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionStart = Date()
            self?.nudgedLong = false
        }
    }

    private func scheduleBlink() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 3.5...8), repeats: false) { [weak self] _ in
            self?.catView.blink()
            self?.scheduleBlink()
        }
        blinkTimer?.tolerance = 0.5
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard Prefs.clipWatch, catPanel.isVisible, !bubble.chatMode else { return }
        // Privacy: never look at passwords or transient data from password managers.
        let banned: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                   "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]
        let types = Set((pb.types ?? []).map { $0.rawValue })
        if !types.isDisjoint(with: banned) { return }
        guard let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.count >= 2, s.count <= 6000, s != lastClip else { return }
        lastClip = s
        catView.perk(true)
        let preview = s.count > 40 ? String(s.prefix(40)) + "…" : s
        bubble.notify("我看到你复制了「\(preview)」～要我帮你看看吗？", actionTitle: "帮我看看 🐾") { [weak self] in
            guard let self = self else { return }
            self.bubble.openChat(greeting: "……")
            self.ask("我刚复制了下面这段内容，请帮我看看：如果是报错或代码，告诉我问题和改法；如果是普通文字，用一两句话解释或接个话。\n\n\(s)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self, !self.bubble.chatMode else { return }
            self.catView.perk(false)
        }
    }

    private func idleSeconds() -> Double {
        guard let any = CGEventType(rawValue: UInt32.max) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    private func checkCare() {
        let idle = idleSeconds()
        catView.setSleepy(idle > 600)
        if idle > 300 { sessionStart = Date(); nudgedLong = false; return }
        guard Prefs.care, catPanel.isVisible, !bubble.chatMode else { return }

        let minutes = Date().timeIntervalSince(sessionStart) / 60
        if minutes >= 120 && !nudgedLong {
            nudgedLong = true
            say("已经连续看屏幕 2 小时啦，喝口水、伸个懒腰歇一歇吧 🍵")
            return
        }
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let dayKey = DateFormatter.localizedString(from: now, dateStyle: .short, timeStyle: .none)
        if hour >= 1 && hour < 5 && nudgedNight != dayKey {
            nudgedNight = dayKey
            let f = DateFormatter(); f.dateFormat = "H:mm"
            say("已经 \(f.string(from: now)) 啦，手头这件事收个尾就去睡吧，我陪你到这里 🌙")
        }
    }

    private func say(_ text: String) {
        catView.perk(true)
        bubble.notify(text)
        voice.speak(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.catView.perk(false) }
    }

    private func recordBondingDay() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        var days = Prefs.bondingDays
        if !days.contains(today) { days.append(today); Prefs.bondingDays = days }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
