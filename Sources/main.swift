// OrdCat — a cozy cat peeking from the right edge of your screen.
// Native AppKit, single file. Event-driven: no polling loops while idle.

import Cocoa
import AVFoundation
import Security
import Speech
import Carbon
import PDFKit
import UniformTypeIdentifiers

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

struct HotKeyOption { let title: String; let code: UInt32; let mods: UInt32 }
let kHotKeys: [HotKeyOption] = [
    HotKeyOption(title: "⌃ Control + ⌥ Option + 空格", code: 49, mods: UInt32(controlKey | optionKey)),
    HotKeyOption(title: "⌥ Option + 空格", code: 49, mods: UInt32(optionKey)),
    HotKeyOption(title: "⌘ Command + ⇧ Shift + 空格", code: 49, mods: UInt32(cmdKey | shiftKey)),
    HotKeyOption(title: "⌃ Control + ⌥ Option + V", code: 9, mods: UInt32(controlKey | optionKey))
]

let kPerceptionHotKeys: [HotKeyOption] = [
    HotKeyOption(title: "⌃ Control + ⌥ Option + D", code: 2, mods: UInt32(controlKey | optionKey)),
    HotKeyOption(title: "⌃ Control + ⌥ Option + P", code: 35, mods: UInt32(controlKey | optionKey)),
    HotKeyOption(title: "⌘ Command + ⇧ Shift + D", code: 2, mods: UInt32(cmdKey | shiftKey))
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
    private static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
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
    static var voice: Bool { get { bool("voice", true) } set { d.set(newValue, forKey: "voice") } }
    static var voiceChat: Bool { get { bool("voiceChat", true) } set { d.set(newValue, forKey: "voiceChat") } }
    static var hotKeyIndex: Int {
        get { min(d.object(forKey: "hotKey") as? Int ?? 0, kHotKeys.count - 1) }
        set { d.set(newValue, forKey: "hotKey") }
    }
    static var clipWatch: Bool { get { bool("clipWatch", true) } set { d.set(newValue, forKey: "clipWatch") } }
    static var selectWatch: Bool { get { bool("selectWatch", true) } set { d.set(newValue, forKey: "selectWatch") } }
    static var selectFallback: Bool { get { bool("selectFallback", true) } set { d.set(newValue, forKey: "selectFallback") } }
    static var care: Bool { get { bool("care", true) } set { d.set(newValue, forKey: "care") } }
    // Desktop perception & memory hub
    static var perception: Bool { get { bool("perception", false) } set { d.set(newValue, forKey: "perception") } }
    static var perceptionHotKeyIndex: Int {
        get { min(d.object(forKey: "perceptionHotKey") as? Int ?? 0, kPerceptionHotKeys.count - 1) }
        set { d.set(newValue, forKey: "perceptionHotKey") }
    }
    static var sendScreenshot: Bool { get { bool("sendScreenshot", false) } set { d.set(newValue, forKey: "sendScreenshot") } }
    static var ocrFallback: Bool { get { bool("ocrFallback", true) } set { d.set(newValue, forKey: "ocrFallback") } }
    static var highlight: Bool { get { bool("highlight", true) } set { d.set(newValue, forKey: "highlight") } }
    static var retentionDays: Int {
        get { d.object(forKey: "retentionDays") as? Int ?? 7 }
        set { d.set(newValue, forKey: "retentionDays") }
    }
    static var contextBudget: Int {
        get { d.object(forKey: "contextBudget") as? Int ?? 3500 }
        set { d.set(newValue, forKey: "contextBudget") }
    }
    static var excludedApps: String {
        get { d.string(forKey: "excludedApps") ?? "" }
        set { d.set(newValue, forKey: "excludedApps") }
    }
    static var autoUpdate: Bool { get { bool("autoUpdate", true) } set { d.set(newValue, forKey: "autoUpdate") } }
    static var catY: Double? {
        get { d.object(forKey: "catY") as? Double }
        set { d.set(newValue, forKey: "catY") }
    }
    static var bondingDays: [String] {
        get { d.stringArray(forKey: "bondingDays") ?? [] }
        set { d.set(newValue, forKey: "bondingDays") }
    }
}

// MARK: - Chat history (persisted locally)

struct ChatMessage: Codable {
    let role: String          // "user" | "assistant"
    var text: String
    var imageNames: [String]
    let date: Date
}

final class ChatStore {
    private(set) var messages: [ChatMessage] = []
    private var observers: [() -> Void] = []
    let dir: URL
    private var imagesDir: URL { dir.appendingPathComponent("images") }
    private var file: URL { dir.appendingPathComponent("history.json") }

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrdCat")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            messages = (try? dec.decode([ChatMessage].self, from: data)) ?? []
        }
    }

    func observe(_ f: @escaping () -> Void) { observers.append(f) }
    func notify() { for o in observers { o() } }

    func append(_ m: ChatMessage) { messages.append(m); save(); notify() }
    func updateLast(_ text: String) {
        guard !messages.isEmpty else { return }
        messages[messages.count - 1].text = text
        notify()
    }
    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(messages) { try? data.write(to: file, options: .atomic) }
    }
    func clear() {
        messages.removeAll()
        try? FileManager.default.removeItem(at: imagesDir)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        save(); notify()
    }
    func saveImage(_ data: Data) -> String? {
        let name = UUID().uuidString + ".jpg"
        do { try data.write(to: imageURL(name)); return name } catch { return nil }
    }
    func imageURL(_ name: String) -> URL { imagesDir.appendingPathComponent(name) }
}

// MARK: - LLM client (streaming, OpenAI-compatible)

let kSystemPrompt = """
你是 OrdCat，一只窝在用户电脑屏幕右侧边、探出半个脑袋的小黑猫陪伴助手。
性格：温柔、共情、轻松幽默，像一个安静的朋友。说话简短口语化，一般不超过 80 个字，可以偶尔用 🐾 🍵 🌙 这类表情。
你不催促用户提高效率，也不制造焦虑；你陪伴、安抚，在需要时给出恰到好处的提示。
遇到代码或报错：先一句安抚，再用最简单的话指出问题和改法。用户发来图片或文件时，认真看完再回答，可以适当说得详细些。
始终使用简体中文回答（除非用户要求翻译成其他语言）。
"""

final class LLM {
    private var task: Task<Void, Never>?
    func cancel() { task?.cancel(); task = nil }

    func stream(_ history: [[String: Any]], context: String? = nil,
                onDelta: @escaping (String) -> Void,
                onDone: @escaping (String?, String?) -> Void) {
        cancel()
        var base = Prefs.base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + "/chat/completions") else {
            onDone(nil, "还没设置模型哦～右键点我 → 设置，就能和我聊天啦。")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = Keychain.get()
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        var system = RemoteConfig.shared.systemPrompt ?? kSystemPrompt
        if let c = context, !c.isEmpty { system += "\n\n" + c }
        let messages: [[String: Any]] = [["role": "system", "content": system]] + history
        var body: [String: Any] = ["model": Prefs.model, "messages": messages, "stream": true, "max_tokens": 1500]
        // Reasoning models (e.g. gpt-oss on Groq) would otherwise spend the budget thinking.
        if base.contains("groq.com") && Prefs.model.contains("gpt-oss") { body["reasoning_effort"] = "low" }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        task = Task {
            var full = ""
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                if let h = resp as? HTTPURLResponse, h.statusCode >= 300 {
                    var errText = ""
                    for try await line in bytes.lines {
                        errText += line
                        if errText.count > 400 { break }
                    }
                    let msg = "模型那边返回了错误（\(h.statusCode)）：\(errText.prefix(220))"
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
                DispatchQueue.main.async { onDone(final, nil) }
            } catch {
                if Task.isCancelled { return }
                let msg = "连不上模型：\(error.localizedDescription)"
                DispatchQueue.main.async { onDone(nil, msg) }
            }
        }
    }
}

// MARK: - Voice out (system TTS)

final class Voice {
    private let synth = AVSpeechSynthesizer()
    func speak(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            let p = s.properties
            if p.isEmojiPresentation || (p.isEmoji && s.value > 0x2000) { continue }
            if s == "*" || s == "#" || s == "`" { continue }
            scalars.append(s)
        }
        let clean = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let u = AVSpeechUtterance(string: clean)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.5
        u.pitchMultiplier = 1.15
        synth.speak(u)
    }
    func stop() { synth.stopSpeaking(at: .immediate) }
}

// MARK: - Voice in (Apple speech recognition, on-device when available)

final class Listener {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var silenceTimer: Timer?
    private var tapInstalled = false
    private var latest = ""
    private(set) var isListening = false
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?

    func start() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.onError?("需要「语音识别」权限：系统设置 → 隐私与安全性 → 语音识别，打开 OrdCat。")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        guard ok else {
                            self.onError?("需要「麦克风」权限：系统设置 → 隐私与安全性 → 麦克风，打开 OrdCat。")
                            return
                        }
                        self.begin()
                    }
                }
            }
        }
    }

    private func begin() {
        guard let rec = recognizer, rec.isAvailable else { onError?("语音识别暂时不可用，稍后再试试～"); return }
        teardown()
        latest = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.request?.append(buf)
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() } catch {
            teardown()
            onError?("麦克风启动失败：\(error.localizedDescription)")
            return
        }
        isListening = true
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.isListening else { return }
                if let r = result {
                    self.latest = r.bestTranscription.formattedString
                    self.onPartial?(self.latest)
                    self.armSilence(1.6)
                    if r.isFinal { self.finish() }
                } else if error != nil {
                    self.finish()
                }
            }
        }
        armSilence(7)
    }

    private func armSilence(_ s: Double) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in self?.finish() }
    }

    func finish() {
        guard isListening else { return }
        isListening = false
        silenceTimer?.invalidate()
        teardown()
        onFinal?(latest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func cancel() {
        isListening = false
        silenceTimer?.invalidate()
        teardown()
    }

    private func teardown() {
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
    }
}

// MARK: - Global hotkey (Carbon, no accessibility permission needed)

final class HotKey {
    static var actions: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?
    let id: UInt32

    init(id: UInt32) { self.id = id }

    func register(_ opt: HotKeyOption, action: @escaping () -> Void) {
        unregister()
        HotKey.actions[id] = action
        if !HotKey.installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let which = hk.id
                DispatchQueue.main.async { HotKey.actions[which]?() }
                return OSStatus(noErr)
            }, 1, &spec, nil, nil)
            HotKey.installed = true
        }
        let hid = EventHotKeyID(signature: OSType(0x4F524443), id: id)
        RegisterEventHotKey(opt.code, opt.mods, hid, GetApplicationEventTarget(), 0, &ref)
    }
    func unregister() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
    }
}

// MARK: - Selected text (Accessibility, with copy fallback)

final class SelectionWatcher {
    var onSelect: ((String) -> Void)?
    var onNeedsPermission: (() -> Void)?
    var isOwnPoint: ((NSPoint) -> Bool)?
    private(set) var ignoreChangeCount = -1
    private var downPoint = NSPoint.zero
    private var monitor: Any?
    private var asked = false

    static func trusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
            self?.handle(e)
        }
    }

    private func handle(_ e: NSEvent) {
        let p = NSEvent.mouseLocation
        if e.type == .leftMouseDown { downPoint = p; return }
        guard Prefs.selectWatch else { return }
        let dragged = hypot(p.x - downPoint.x, p.y - downPoint.y) > 8
        guard dragged || e.clickCount >= 2 else { return }
        if isOwnPoint?(p) == true { return }
        guard SelectionWatcher.trusted(prompt: false) else {
            if !asked { asked = true; onNeedsPermission?() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.grab() }
    }

    private func grab() {
        if let s = axSelectedText(), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onSelect?(s)
            return
        }
        guard Prefs.selectFallback else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if front == "com.apple.finder" || front == Bundle.main.bundleIdentifier { return }
        copyFallback { [weak self] s in
            guard let s = s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self?.onSelect?(s)
        }
    }

    private func axSelectedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let el = f as! AXUIElement
        var sel: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &sel) == .success else { return nil }
        return sel as? String
    }

    /// Press ⌘C on the user's behalf, read the text, then put their clipboard back exactly as it was.
    private func copyFallback(_ done: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { dict[t] = v } }
            saved.append(dict)
        }
        let before = pb.changeCount
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard pb.changeCount != before else { done(nil); return }
            let s = pb.string(forType: .string)
            pb.clearContents()
            let items: [NSPasteboardItem] = saved.map { dict in
                let it = NSPasteboardItem()
                for (t, v) in dict { it.setData(v, forType: t) }
                return it
            }
            if !items.isEmpty { pb.writeObjects(items) }
            self?.ignoreChangeCount = pb.changeCount
            done(s)
        }
    }
}

// MARK: - Cat view (layer-drawn, right-edge peek)

final class CatView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onMoved: (() -> Void)?

    private let rig = CALayer()
    private let cat = CALayer()
    private let body = CAShapeLayer()
    private let head = CAShapeLayer()
    private let earL = CAShapeLayer()
    private let earR = CAShapeLayer()
    private let eyeL = CAShapeLayer()
    private let eyeR = CAShapeLayer()
    private let paw = CAShapeLayer()
    private let paw2 = CAShapeLayer()
    private let excl = CAShapeLayer()

    private let tilt: CGFloat = 18 * .pi / 180
    private let restOffset: CGFloat = 18      // tucked in a bit
    private let hoverOffset: CGFloat = -78    // leans out, more body
    private(set) var peek: CGFloat = 18
    private(set) var hovering = false
    private var lookOffset = CGPoint.zero
    private var eyeScale: CGFloat = 1
    private var perked = false
    private var dragStart: NSPoint?
    private var dragged = false
    private var lastLook: TimeInterval = 0

    /// Head centre in view coordinates when not shifted.
    var baseHead: CGPoint { CGPoint(x: bounds.maxX - 46, y: bounds.midY + 20) }
    var currentHead: CGPoint { CGPoint(x: baseHead.x + peek, y: baseHead.y) }

    func headScreenPoint() -> NSPoint {
        guard let w = window else { return .zero }
        return w.convertPoint(toScreen: convert(currentHead, to: nil))
    }

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

    private func makePaw(_ layer: CAShapeLayer, _ r: CGRect) {
        layer.path = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        layer.fillColor = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.1, alpha: 1).cgColor
        layer.strokeColor = kRim.cgColor
        layer.lineWidth = 2
    }

    private func build() {
        guard let root = layer else { return }
        rig.frame = bounds
        root.addSublayer(rig)
        let h = baseHead

        // Body: a soft loaf sloping down and off the screen edge, revealed when it leans out.
        let bodyPath = CGMutablePath()
        bodyPath.addEllipse(in: CGRect(x: h.x - 70, y: h.y - 175, width: 250, height: 150))
        body.path = bodyPath
        body.fillColor = kFur.cgColor
        body.strokeColor = kRim.cgColor
        body.lineWidth = 2
        rig.addSublayer(body)

        makePaw(paw2, CGRect(x: h.x - 20, y: h.y - 160, width: 56, height: 30))
        rig.addSublayer(paw2)

        cat.bounds = CGRect(x: -130, y: -130, width: 260, height: 260)
        cat.position = h
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

        makePaw(paw, CGRect(x: h.x - 62, y: h.y - 100, width: 70, height: 36))
        rig.addSublayer(paw)

        excl.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        excl.position = CGPoint(x: h.x - 108, y: h.y + 100)
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

        CATransaction.begin(); CATransaction.setDisableActions(true)
        rig.transform = CATransform3DMakeTranslation(peek, 0, 0)
        CATransaction.commit()
        applyEars(animated: false)
        applyEyes(animated: false)
    }

    // Slide in from the screen edge.
    func peekIn() {
        let a = CASpringAnimation(keyPath: "position.x")
        a.fromValue = bounds.midX + 260
        a.toValue = bounds.midX
        a.damping = 11
        a.duration = a.settlingDuration
        rig.add(a, forKey: "peek")
    }

    /// Hover: lean out to show more body; otherwise tuck back in.
    func setHover(_ on: Bool) {
        guard on != hovering else { return }
        hovering = on
        let target = on ? hoverOffset : restOffset
        let from = (rig.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat) ?? peek
        let a = CASpringAnimation(keyPath: "transform.translation.x")
        a.fromValue = from
        a.toValue = target
        a.damping = 13
        a.stiffness = 170
        a.duration = a.settlingDuration
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rig.transform = CATransform3DMakeTranslation(target, 0, 0)
        CATransaction.commit()
        rig.add(a, forKey: "hover")
        peek = target
        onMoved?()
    }

    // MARK: eyes
    func look(atScreen p: NSPoint) {
        guard let w = window else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLook < 1.0 / 30.0 { return }   // at most 30 fps, and only while the mouse moves
        lastLook = now
        let vp = convert(w.convertPoint(fromScreen: p), from: nil)
        let c0 = currentHead
        let vx = vp.x - c0.x, vy = vp.y - c0.y
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
        let h = currentHead
        if hypot(p.x - h.x, p.y - h.y) < 100 { return self }
        if hovering && p.y < h.y - 40 && p.y > h.y - 190 && p.x > h.x - 80 { return self }   // body
        return nil
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
                f.origin.y = min(max(f.origin.y, vis.minY - 60), vis.maxY - f.height + 20)
            }
            w.setFrameOrigin(f.origin)
            dragStart = now
            onMoved?()
        }
    }
    override func mouseUp(with event: NSEvent) {
        if dragged, let w = window { Prefs.catY = Double(w.frame.origin.y) }
        if !dragged {
            if event.modifierFlags.contains(.control) { onRightClick?() } else { onClick?() }
        }
        dragStart = nil
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }
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

func iconButton(_ title: String, _ target: AnyObject, _ action: Selector, tip: String) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded
    b.toolTip = tip
    return b
}

// MARK: - Bubble (non-activating, sits to the left of the cat)

final class Bubble: NSObject {
    let panel: KeyPanel
    private let card = NSVisualEffectView()
    private let title = NSTextField(labelWithString: "OrdCat")
    private var expandButton: NSButton!
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private var actionButtons: [NSButton] = []
    private var actions: [() -> Void] = []
    private let input = NSTextField()
    private var micButton: NSButton!
    private var sendButton: NSButton!
    private var hideTimer: Timer?
    private(set) var chatMode = false
    var onSend: ((String) -> Void)?
    var onExpand: (() -> Void)?
    var onMic: (() -> Void)?
    var anchor: () -> NSPoint = { .zero }   // cat head centre, screen coords
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

        expandButton = NSButton(title: "↗ 完整对话", target: self, action: #selector(doExpand))
        expandButton.isBordered = false
        expandButton.font = .systemFont(ofSize: 11)
        expandButton.contentTintColor = .secondaryLabelColor
        expandButton.toolTip = "打开独立聊天窗口（聊天记录、发送图片和文件）"
        card.addSubview(expandButton)

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

        input.placeholderString = "和小猫说点什么…（回车发送）"
        input.font = .systemFont(ofSize: 13)
        input.focusRingType = .none
        input.bezelStyle = .roundedBezel
        input.target = self
        input.action = #selector(doSend)
        card.addSubview(input)

        micButton = iconButton("🎤", self, #selector(doMic), tip: "语音对话")
        card.addSubview(micButton)
        sendButton = iconButton("发送", self, #selector(doSend), tip: "发送")
        card.addSubview(sendButton)
    }

    @objc private func doExpand() { onExpand?() }
    @objc private func doMic() { onMic?() }
    @objc private func doAction(_ sender: NSButton) {
        let i = sender.tag
        guard i < actions.count else { return }
        let a = actions[i]
        a()
    }
    @objc private func doSend() {
        let t = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        input.stringValue = ""
        onSend?(t)
    }

    private func setActions(_ list: [(String, () -> Void)]) {
        for b in actionButtons { b.removeFromSuperview() }
        actionButtons = []
        actions = list.map { $0.1 }
        for (i, item) in list.enumerated() {
            let b = NSButton(title: item.0, target: self, action: #selector(doAction(_:)))
            b.bezelStyle = .rounded
            b.tag = i
            card.addSubview(b)
            actionButtons.append(b)
        }
    }

    /// A short note that retracts by itself.
    func notify(_ text: String, actions list: [(String, () -> Void)] = [], hold: Double? = nil) {
        chatMode = false
        setActions(list)
        textView.string = text
        present(makeKey: false)
        scheduleHide(after: hold ?? min(15, 4 + Double(text.count) * 0.08 + (list.isEmpty ? 0 : 4)))
    }

    /// Open the quick-chat box.
    func openChat(greeting: String?) {
        chatMode = true
        setActions([])
        hideTimer?.invalidate()
        if let g = greeting { textView.string = g }
        present(makeKey: true)
        panel.makeFirstResponder(input)
    }

    func setText(_ text: String) {
        textView.string = text
        if isShown { layout() }
    }

    func setListening(_ on: Bool) { micButton?.title = on ? "⏹" : "🎤" }

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
        var used: CGFloat = 18
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            used = lm.usedRect(for: tc).height
        }
        let textH = min(max(used, 18), 300)
        let actionH: CGFloat = actionButtons.isEmpty ? 0 : 36
        let chatH: CGFloat = chatMode ? 40 : 0
        let h = pad + 18 + 6 + textH + actionH + chatH + pad

        var y = h - pad - 16
        title.frame = NSRect(x: pad, y: y, width: 120, height: 16)
        expandButton.frame = NSRect(x: width - pad - 90, y: y - 2, width: 92, height: 20)
        expandButton.isHidden = !chatMode
        y -= 6 + textH
        scroll.frame = NSRect(x: pad, y: y, width: inner, height: textH)
        textView.frame = NSRect(x: 0, y: 0, width: inner, height: max(used, textH))
        if !actionButtons.isEmpty {
            y -= actionH
            var x = pad - 4
            for b in actionButtons {
                b.sizeToFit()
                let w = max(84, b.frame.width + 16)
                b.frame = NSRect(x: x, y: y + 3, width: w, height: 30)
                x += w + 6
            }
        }
        input.isHidden = !chatMode
        sendButton.isHidden = !chatMode
        micButton.isHidden = !chatMode
        if chatMode {
            y -= chatH
            input.frame = NSRect(x: pad, y: y + 6, width: inner - 104, height: 26)
            micButton.frame = NSRect(x: pad + inner - 100, y: y + 4, width: 40, height: 30)
            sendButton.frame = NSRect(x: pad + inner - 58, y: y + 4, width: 60, height: 30)
        }

        let head = anchor()
        var x = head.x - width - 70
        var yy = head.y - h / 2 + 40
        let scr = NSScreen.screens.first(where: { $0.frame.contains(head) }) ?? NSScreen.main
        if let vis = scr?.visibleFrame {
            x = max(vis.minX + 8, x)
            yy = min(max(vis.minY + 8, yy), vis.maxY - h - 8)
        }
        panel.setFrame(NSRect(x: x, y: yy, width: width, height: h), display: true)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: h)
        card.frame = NSRect(x: 0, y: 0, width: width, height: h)
        textView.scrollToEndOfDocument(nil)
    }
}

// MARK: - Chat window (full history, images and files)

struct PendingFile { let name: String; let text: String }

final class ChatWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: ChatStore
    private let transcript = NSTextView()
    private let input = NSTextField()
    private let attachLabel = NSTextField(labelWithString: "")
    private var clearAttach: NSButton!
    private var micButton: NSButton!
    private var pendingImages: [Data] = []
    private var pendingFiles: [PendingFile] = []
    private var thumbs: [String: NSImage] = [:]
    private var renderQueued = false
    var onSend: ((String, [Data]) -> Void)?
    var onMic: (() -> Void)?
    var onClear: (() -> Void)?

    var isVisible: Bool { window?.isVisible ?? false }

    init(store: ChatStore) {
        self.store = store
        super.init()
        store.observe { [weak self] in self?.queueRender() }
    }

    func show() {
        if window == nil { build() }
        render()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(input)
    }

    func setListening(_ on: Bool, partial: String? = nil) {
        micButton?.title = on ? "⏹" : "🎤"
        if let p = partial, isVisible { input.stringValue = p }
        if !on && isVisible { input.stringValue = "" }
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "和 OrdCat 聊天 🐈‍⬛"
        w.minSize = NSSize(width: 380, height: 360)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("OrdCatChat")
        let v = DropView(frame: w.contentRect(forFrameRect: w.frame))
        v.onFiles = { [weak self] urls in self?.add(urls) }
        w.contentView = v
        let W = v.bounds.width, H = v.bounds.height

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 100, width: W, height: H - 100))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        transcript.frame = scroll.bounds
        transcript.autoresizingMask = [.width]
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.textContainerInset = NSSize(width: 16, height: 14)
        transcript.isVerticallyResizable = true
        transcript.textContainer?.widthTracksTextView = true
        scroll.documentView = transcript
        v.addSubview(scroll)

        let sep = NSBox(frame: NSRect(x: 0, y: 99, width: W, height: 1))
        sep.boxType = .separator
        sep.autoresizingMask = [.width, .maxYMargin]
        v.addSubview(sep)

        let clear = NSButton(title: "清空记录", target: self, action: #selector(clearHistory))
        clear.bezelStyle = .rounded
        clear.controlSize = .small
        clear.frame = NSRect(x: 10, y: 64, width: 84, height: 26)
        clear.autoresizingMask = [.maxXMargin, .maxYMargin]
        v.addSubview(clear)

        attachLabel.frame = NSRect(x: 102, y: 68, width: W - 200, height: 18)
        attachLabel.textColor = .secondaryLabelColor
        attachLabel.font = .systemFont(ofSize: 12)
        attachLabel.lineBreakMode = .byTruncatingMiddle
        attachLabel.autoresizingMask = [.width, .maxYMargin]
        v.addSubview(attachLabel)

        clearAttach = NSButton(title: "移除附件", target: self, action: #selector(removeAttachments))
        clearAttach.bezelStyle = .rounded
        clearAttach.controlSize = .small
        clearAttach.frame = NSRect(x: W - 94, y: 64, width: 84, height: 26)
        clearAttach.autoresizingMask = [.minXMargin, .maxYMargin]
        clearAttach.isHidden = true
        v.addSubview(clearAttach)

        input.frame = NSRect(x: 12, y: 14, width: W - 12 - 170, height: 42)
        input.autoresizingMask = [.width, .maxYMargin]
        input.placeholderString = "说点什么…（回车发送，⌥+回车换行）"
        input.font = .systemFont(ofSize: 14)
        input.usesSingleLineMode = false
        input.cell?.wraps = true
        input.cell?.isScrollable = false
        input.target = self
        input.action = #selector(send)
        v.addSubview(input)

        let attach = iconButton("📎", self, #selector(pickFiles), tip: "添加图片或文件（也可以直接拖进窗口）")
        attach.frame = NSRect(x: W - 152, y: 18, width: 42, height: 34)
        attach.autoresizingMask = [.minXMargin, .maxYMargin]
        v.addSubview(attach)

        micButton = iconButton("🎤", self, #selector(mic), tip: "语音对话")
        micButton.frame = NSRect(x: W - 108, y: 18, width: 42, height: 34)
        micButton.autoresizingMask = [.minXMargin, .maxYMargin]
        v.addSubview(micButton)

        let sendB = iconButton("发送", self, #selector(send), tip: "发送")
        sendB.frame = NSRect(x: W - 64, y: 18, width: 56, height: 34)
        sendB.autoresizingMask = [.minXMargin, .maxYMargin]
        v.addSubview(sendB)

        window = w
    }

    @objc private func mic() { onMic?() }
    @objc private func clearHistory() {
        let a = NSAlert()
        a.messageText = "清空所有聊天记录？"
        a.informativeText = "清空后无法恢复，小猫也会忘掉之前聊过的内容。"
        a.addButton(withTitle: "清空")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { onClear?() }
    }
    @objc private func removeAttachments() { pendingImages = []; pendingFiles = []; updateAttachLabel() }

    @objc private func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.image, .pdf, .plainText, .text, .sourceCode, .json, .commaSeparatedText, .xml, .html]
        p.message = "选择要发给小猫的图片或文件"
        guard let w = window else { return }
        p.beginSheetModal(for: w) { [weak self] r in
            if r == .OK { self?.add(p.urls) }
        }
    }

    func add(_ urls: [URL]) {
        for u in urls {
            let type = UTType(filenameExtension: u.pathExtension) ?? .data
            if type.conforms(to: .image) {
                if let d = jpegData(from: u) { pendingImages.append(d) }
            } else if type.conforms(to: .pdf) {
                let t = PDFDocument(url: u)?.string ?? ""
                pendingFiles.append(PendingFile(name: u.lastPathComponent, text: String(t.prefix(20000))))
            } else if let t = try? String(contentsOf: u, encoding: .utf8) {
                pendingFiles.append(PendingFile(name: u.lastPathComponent, text: String(t.prefix(20000))))
            } else {
                NSSound.beep()
            }
        }
        updateAttachLabel()
    }

    private func updateAttachLabel() {
        var parts: [String] = []
        if !pendingImages.isEmpty { parts.append("🖼 \(pendingImages.count) 张图片") }
        for f in pendingFiles { parts.append("📄 " + f.name) }
        attachLabel.stringValue = parts.isEmpty ? "" : "待发送：" + parts.joined(separator: "、")
        clearAttach.isHidden = parts.isEmpty
    }

    @objc private func send() {
        var text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && pendingImages.isEmpty && pendingFiles.isEmpty { return }
        if text.isEmpty { text = pendingImages.isEmpty ? "帮我看看这个文件" : "帮我看看这张图" }
        for f in pendingFiles { text += "\n\n【附件：\(f.name)】\n\(f.text)" }
        let imgs = pendingImages
        input.stringValue = ""
        pendingImages = []; pendingFiles = []
        updateAttachLabel()
        onSend?(text, imgs)
    }

    private func queueRender() {
        guard isVisible, !renderQueued else { return }
        renderQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.renderQueued = false
            self?.render()
        }
    }

    private func thumb(_ name: String) -> NSImage? {
        if let t = thumbs[name] { return t }
        guard let img = NSImage(contentsOf: store.imageURL(name)) else { return nil }
        let maxW: CGFloat = 220
        let s = img.size.width > maxW ? maxW / img.size.width : 1
        let size = NSSize(width: img.size.width * s, height: img.size.height * s)
        let t = NSImage(size: size)
        t.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: size))
        t.unlockFocus()
        thumbs[name] = t
        return t
    }

    private func render() {
        guard window != nil else { return }
        let out = NSMutableAttributedString()
        let df = DateFormatter()
        df.dateFormat = "M月d日 HH:mm"
        if store.messages.isEmpty {
            out.append(NSAttributedString(string: "还没有聊天记录～在下面和小猫打个招呼吧 🐾\n",
                                          attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        for m in store.messages {
            let isUser = m.role == "user"
            let para = NSMutableParagraphStyle()
            para.alignment = isUser ? .right : .left
            para.paragraphSpacingBefore = 12
            let bodyPara = NSMutableParagraphStyle()
            bodyPara.alignment = isUser ? .right : .left
            bodyPara.lineSpacing = 3
            out.append(NSAttributedString(string: (isUser ? "你" : "🐈‍⬛ OrdCat") + " · " + df.string(from: m.date) + "\n",
                                          attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                       .foregroundColor: isUser ? NSColor.secondaryLabelColor : kAmber,
                                                       .paragraphStyle: para]))
            for name in m.imageNames {
                if let t = thumb(name) {
                    let att = NSTextAttachment()
                    att.image = t
                    att.bounds = CGRect(origin: .zero, size: t.size)
                    let s = NSMutableAttributedString(attachment: att)
                    s.append(NSAttributedString(string: "\n"))
                    s.addAttribute(.paragraphStyle, value: bodyPara, range: NSRange(location: 0, length: s.length))
                    out.append(s)
                }
            }
            var shown = m.text
            if isUser, let r = shown.range(of: "\n\n【附件：") {   // collapse long attachments in the transcript
                let names = shown.components(separatedBy: "【附件：").dropFirst().compactMap { $0.components(separatedBy: "】").first }
                shown = String(shown[..<r.lowerBound]) + "\n📄 " + names.joined(separator: "、")
            }
            if shown.isEmpty && !isUser { shown = "……" }
            out.append(NSAttributedString(string: shown + "\n",
                                          attributes: [.font: NSFont.systemFont(ofSize: 14),
                                                       .foregroundColor: NSColor.labelColor,
                                                       .paragraphStyle: bodyPara]))
        }
        transcript.textStorage?.setAttributedString(out)
        transcript.scrollToEndOfDocument(nil)
    }
}

final class DropView: NSView {
    var onFiles: (([URL]) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        onFiles?(urls)
        return !urls.isEmpty
    }
}

func jpegData(from url: URL) -> Data? {
    guard let img = NSImage(contentsOf: url) else { return nil }
    var rect = CGRect(origin: .zero, size: img.size)
    guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
    return jpegData(cgImage: cg)
}

func jpegData(cgImage cg: CGImage) -> Data? {
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    let scale = min(1, 1568 / max(w, h))
    let nw = max(1, Int(w * scale)), nh = max(1, Int(h * scale))
    guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: nw, height: nh))
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
    guard let out = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
}

// MARK: - Settings window

final class SettingsController: NSObject {
    private var window: NSWindow?
    private let preset = NSPopUpButton()
    private let base = NSTextField()
    private let key = NSSecureTextField()
    private let model = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let hotkeyPopup = NSPopUpButton()
    private var checks: [String: NSButton] = [:]
    private let axStatus = NSTextField(labelWithString: "")
    private let llm = LLM()
    private let perceptionPopup = NSPopUpButton()
    private let retentionPopup = NSPopUpButton()
    private let excluded = NSTextField()
    private let memStats = NSTextField(wrappingLabelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let notesLabel = NSTextField(wrappingLabelWithString: "")
    private var updateButton: NSButton!
    private let retentionOptions = [1, 3, 7, 30]
    var hub: ContextHub?
    var onHotKeyChanged: (() -> Void)?
    var onClearHistory: (() -> Void)?
    var onPerceptionChanged: (() -> Void)?
    var onPreviewContext: (() -> Void)?

    func show(tab: Int = 0) {
        if window == nil { build() }
        base.stringValue = Prefs.base
        model.stringValue = Prefs.model
        key.stringValue = Keychain.get()
        preset.selectItem(at: min(Prefs.presetIndex, kPresets.count - 1))
        hotkeyPopup.selectItem(at: Prefs.hotKeyIndex)
        checks["voice"]?.state = Prefs.voice ? .on : .off
        checks["voiceChat"]?.state = Prefs.voiceChat ? .on : .off
        checks["selectWatch"]?.state = Prefs.selectWatch ? .on : .off
        checks["selectFallback"]?.state = Prefs.selectFallback ? .on : .off
        checks["clipWatch"]?.state = Prefs.clipWatch ? .on : .off
        checks["care"]?.state = Prefs.care ? .on : .off
        checks["perception"]?.state = Prefs.perception ? .on : .off
        checks["ocrFallback"]?.state = Prefs.ocrFallback ? .on : .off
        checks["sendScreenshot"]?.state = Prefs.sendScreenshot ? .on : .off
        checks["highlight"]?.state = Prefs.highlight ? .on : .off
        checks["autoUpdate"]?.state = Prefs.autoUpdate ? .on : .off
        perceptionPopup.selectItem(at: Prefs.perceptionHotKeyIndex)
        retentionPopup.selectItem(at: retentionOptions.firstIndex(of: Prefs.retentionDays) ?? 2)
        excluded.stringValue = Prefs.excludedApps
        refreshMemStats()
        refreshUpdate()
        refreshAX()
        status.stringValue = ""
        if let tv = window?.contentView?.subviews.first as? NSTabView { tv.selectTabViewItem(at: tab) }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshMemStats() {
        guard let hub = hub else { return }
        let st = hub.memory.stats()
        let mb = String(format: "%.1f", Double(st.bytes) / 1_048_576)
        let rec = ScreenReader.screenRecordingAllowed() ? "已授权" : "未授权"
        memStats.stringValue = "记忆 \(st.count) 条 · \(mb) MB · 本次保留 \(hub.keptFrames) 帧 / 丢弃重复 \(hub.droppedFrames) 帧\n向量引擎：\(hub.memory.vectorEngine) · 全文检索：\(hub.memory.ftsOK ? "FTS5" : "LIKE") · 屏幕录制：\(rec)"
    }

    func refreshUpdate() {
        let u = Updater.shared
        versionLabel.stringValue = "OrdCat 🐈‍⬛  v\(u.current)"
        if u.hasUpdate, let v = u.latestVersion {
            updateStatus.stringValue = "🎉 有新版本 v\(v)，点「立即更新」，小猫会自己换新并重启。"
        } else if let v = u.latestVersion {
            updateStatus.stringValue = "✅ 已经是最新版本（线上最新 v\(v)）"
        } else {
            updateStatus.stringValue = "还没检查过更新"
        }
        updateButton?.isEnabled = u.hasUpdate
        notesLabel.stringValue = u.hasUpdate ? String(u.latestNotes.prefix(500)) : ""
    }

    private func refreshAX() {
        let ok = SelectionWatcher.trusted(prompt: false)
        axStatus.stringValue = ok ? "✅ 已获得辅助功能权限" : "⚠️ 还没授权「辅助功能」，选中文字提示暂时用不了"
    }

    private func label(_ s: String, _ frame: NSRect, in v: NSView) {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        l.frame = frame
        v.addSubview(l)
    }

    private func row(_ title: String, _ field: NSView, y: CGFloat, in v: NSView) {
        label(title, NSRect(x: 10, y: y + 3, width: 96, height: 20), in: v)
        field.frame = NSRect(x: 114, y: y, width: 330, height: 26)
        v.addSubview(field)
    }

    private func check(_ id: String, _ title: String, y: CGFloat, in v: NSView) {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggled(_:)))
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.frame = NSRect(x: 24, y: y, width: 440, height: 22)
        v.addSubview(b)
        checks[id] = b
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "OrdCat 设置 · v\(Updater.shared.current)"
        w.isReleasedWhenClosed = false
        let root = NSView(frame: w.contentRect(forFrameRect: w.frame))
        w.contentView = root
        let tabs = NSTabView(frame: root.bounds.insetBy(dx: 10, dy: 10))
        tabs.autoresizingMask = [.width, .height]
        root.addSubview(tabs)

        // Tab 1: model
        let t1 = NSTabViewItem(identifier: "model")
        t1.label = "模型（BYOM）"
        let v1 = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 360))
        for p in kPresets { preset.addItem(withTitle: p.name) }
        preset.target = self
        preset.action = #selector(presetChanged)
        base.placeholderString = "https://…/v1"
        key.placeholderString = "本地 Ollama 可留空"
        model.placeholderString = "模型名称"
        row("服务商", preset, y: 300, in: v1)
        row("接口地址", base, y: 262, in: v1)
        row("API Key", key, y: 224, in: v1)
        row("模型", model, y: 186, in: v1)
        let hint = NSTextField(wrappingLabelWithString: "任何 OpenAI 兼容接口都能用。API Key 只保存在你 Mac 的钥匙串里。发送图片需要模型支持识图。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.frame = NSRect(x: 114, y: 140, width: 330, height: 40)
        v1.addSubview(hint)
        status.frame = NSRect(x: 20, y: 100, width: 430, height: 34)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        v1.addSubview(status)
        let test = NSButton(title: "测试连接", target: self, action: #selector(testIt))
        test.frame = NSRect(x: 250, y: 20, width: 96, height: 30)
        v1.addSubview(test)
        let save = NSButton(title: "保存", target: self, action: #selector(saveIt))
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: 350, y: 20, width: 96, height: 30)
        v1.addSubview(save)
        t1.view = v1
        tabs.addTabViewItem(t1)

        // Tab 2: cat
        let t2 = NSTabViewItem(identifier: "cat")
        t2.label = "小猫"
        let v2 = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 360))
        check("voiceChat", "开启语音对话（按快捷键或 🎤 和小猫说话）", y: 318, in: v2)
        label("快捷键", NSRect(x: 30, y: 287, width: 60, height: 20), in: v2)
        for h in kHotKeys { hotkeyPopup.addItem(withTitle: h.title) }
        hotkeyPopup.target = self
        hotkeyPopup.action = #selector(hotkeyChanged)
        hotkeyPopup.frame = NSRect(x: 96, y: 282, width: 300, height: 26)
        v2.addSubview(hotkeyPopup)
        check("voice", "用语音读出小猫的回复", y: 250, in: v2)
        check("selectWatch", "选中文字时竖起耳朵提示", y: 214, in: v2)
        check("selectFallback", "兼容模式：读不到选中内容时，自动复制再还原剪贴板", y: 190, in: v2)
        check("clipWatch", "复制文字时提示", y: 166, in: v2)
        check("care", "久坐 / 熬夜温柔提醒", y: 142, in: v2)
        axStatus.frame = NSRect(x: 24, y: 104, width: 300, height: 20)
        axStatus.font = .systemFont(ofSize: 12)
        v2.addSubview(axStatus)
        let ax = NSButton(title: "授权辅助功能", target: self, action: #selector(askAX))
        ax.frame = NSRect(x: 330, y: 98, width: 120, height: 30)
        v2.addSubview(ax)
        let axHint = NSTextField(wrappingLabelWithString: "选中文字提示需要「辅助功能」权限：系统设置 → 隐私与安全性 → 辅助功能，打开 OrdCat。更新新版本后如果失效，先把旧的 OrdCat 删掉再重新添加。")
        axHint.textColor = .secondaryLabelColor
        axHint.font = .systemFont(ofSize: 11)
        axHint.frame = NSRect(x: 24, y: 56, width: 430, height: 42)
        v2.addSubview(axHint)
        let clear = NSButton(title: "清空聊天记录", target: self, action: #selector(clearHistory))
        clear.frame = NSRect(x: 20, y: 14, width: 130, height: 30)
        v2.addSubview(clear)
        t2.view = v2
        tabs.addTabViewItem(t2)

        // Tab 3: perception & memory
        let t3 = NSTabViewItem(identifier: "memory")
        t3.label = "感知与记忆"
        let v3 = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 360))
        check("perception", "开启桌面感知（回答时参考你屏幕上的内容）", y: 318, in: v3)
        label("快捷键", NSRect(x: 30, y: 289, width: 60, height: 20), in: v3)
        for h in kPerceptionHotKeys { perceptionPopup.addItem(withTitle: h.title) }
        perceptionPopup.target = self
        perceptionPopup.action = #selector(perceptionHotkeyChanged)
        perceptionPopup.frame = NSRect(x: 96, y: 284, width: 300, height: 26)
        v3.addSubview(perceptionPopup)
        check("ocrFallback", "读不到文字时用 OCR 识别（需要「屏幕录制」权限）", y: 256, in: v3)
        check("sendScreenshot", "提问时附带当前窗口截图（需要识图模型）", y: 232, in: v3)
        check("highlight", "回答里指到的位置，在屏幕上高亮出来", y: 208, in: v3)
        label("记忆保留", NSRect(x: 10, y: 177, width: 80, height: 20), in: v3)
        for d in retentionOptions { retentionPopup.addItem(withTitle: "\(d) 天") }
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChanged)
        retentionPopup.frame = NSRect(x: 96, y: 172, width: 110, height: 26)
        v3.addSubview(retentionPopup)
        label("排除应用", NSRect(x: 10, y: 143, width: 80, height: 20), in: v3)
        excluded.placeholderString = "Bundle ID，用逗号分隔，例如 com.tencent.xinWeChat"
        excluded.frame = NSRect(x: 96, y: 140, width: 350, height: 24)
        excluded.target = self
        excluded.action = #selector(excludedChanged)
        v3.addSubview(excluded)
        memStats.font = .systemFont(ofSize: 11)
        memStats.textColor = .secondaryLabelColor
        memStats.frame = NSRect(x: 20, y: 56, width: 430, height: 70)
        v3.addSubview(memStats)
        let b1 = NSButton(title: "授权屏幕录制", target: self, action: #selector(askScreen))
        b1.frame = NSRect(x: 6, y: 14, width: 116, height: 30); v3.addSubview(b1)
        let b2 = NSButton(title: "查看当前上下文", target: self, action: #selector(previewContext))
        b2.frame = NSRect(x: 120, y: 14, width: 124, height: 30); v3.addSubview(b2)
        let b3 = NSButton(title: "清空记忆", target: self, action: #selector(clearMemory))
        b3.frame = NSRect(x: 242, y: 14, width: 96, height: 30); v3.addSubview(b3)
        let b4 = NSButton(title: "数据文件夹", target: self, action: #selector(openData))
        b4.frame = NSRect(x: 336, y: 14, width: 110, height: 30); v3.addSubview(b4)
        t3.view = v3
        tabs.addTabViewItem(t3)

        // Tab 4: about & updates
        let t4 = NSTabViewItem(identifier: "about")
        t4.label = "关于"
        let v4 = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 360))
        versionLabel.font = .systemFont(ofSize: 20, weight: .bold)
        versionLabel.frame = NSRect(x: 20, y: 300, width: 430, height: 28)
        v4.addSubview(versionLabel)
        let slogan = NSTextField(labelWithString: "A cozy cat in your island & desktop. Less burden, low power, always with you.")
        slogan.font = .systemFont(ofSize: 11)
        slogan.textColor = .secondaryLabelColor
        slogan.frame = NSRect(x: 20, y: 278, width: 440, height: 18)
        v4.addSubview(slogan)
        updateStatus.frame = NSRect(x: 20, y: 228, width: 430, height: 40)
        v4.addSubview(updateStatus)
        check("autoUpdate", "自动检查更新（每 6 小时）", y: 198, in: v4)
        let c = NSButton(title: "检查更新", target: self, action: #selector(checkUpdate))
        c.frame = NSRect(x: 16, y: 156, width: 110, height: 30); v4.addSubview(c)
        updateButton = NSButton(title: "立即更新", target: self, action: #selector(installUpdate))
        updateButton.frame = NSRect(x: 126, y: 156, width: 110, height: 30); v4.addSubview(updateButton)
        let rel = NSButton(title: "发布页", target: self, action: #selector(openReleases))
        rel.frame = NSRect(x: 236, y: 156, width: 90, height: 30); v4.addSubview(rel)
        notesLabel.font = .systemFont(ofSize: 11)
        notesLabel.textColor = .secondaryLabelColor
        notesLabel.frame = NSRect(x: 20, y: 10, width: 430, height: 140)
        v4.addSubview(notesLabel)
        t4.view = v4
        tabs.addTabViewItem(t4)

        window = w
    }

    @objc private func toggled(_ b: NSButton) {
        let on = b.state == .on
        switch b.identifier?.rawValue ?? "" {
        case "voice": Prefs.voice = on
        case "voiceChat": Prefs.voiceChat = on; onHotKeyChanged?()
        case "selectWatch": Prefs.selectWatch = on; if on { _ = SelectionWatcher.trusted(prompt: true) }
        case "selectFallback": Prefs.selectFallback = on
        case "clipWatch": Prefs.clipWatch = on
        case "care": Prefs.care = on
        case "perception":
            Prefs.perception = on
            if on { _ = SelectionWatcher.trusted(prompt: true) }
            onPerceptionChanged?()
        case "ocrFallback":
            Prefs.ocrFallback = on
            if on && !ScreenReader.screenRecordingAllowed() { ScreenReader.requestScreenRecording() }
        case "sendScreenshot":
            Prefs.sendScreenshot = on
            if on && !ScreenReader.screenRecordingAllowed() { ScreenReader.requestScreenRecording() }
        case "highlight": Prefs.highlight = on
        case "autoUpdate": Prefs.autoUpdate = on
        default: break
        }
    }

    @objc private func perceptionHotkeyChanged() {
        Prefs.perceptionHotKeyIndex = perceptionPopup.indexOfSelectedItem
        onHotKeyChanged?()
    }
    @objc private func retentionChanged() {
        Prefs.retentionDays = retentionOptions[retentionPopup.indexOfSelectedItem]
        hub?.memory.prune(days: Prefs.retentionDays)
    }
    @objc private func excludedChanged() { Prefs.excludedApps = excluded.stringValue }
    @objc private func askScreen() {
        ScreenReader.requestScreenRecording()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func previewContext() { onPreviewContext?() }
    @objc private func clearMemory() {
        let a = NSAlert()
        a.messageText = "清空所有桌面记忆？"
        a.informativeText = "本机保存的屏幕卡片、划选记录和实体都会删除，无法恢复。"
        a.addButton(withTitle: "清空")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { hub?.memory.clear(); refreshMemStats() }
    }
    @objc private func openData() {
        if let dir = hub?.memory.url.deletingLastPathComponent() { NSWorkspace.shared.open(dir) }
    }
    @objc private func checkUpdate() {
        updateStatus.stringValue = "正在检查…"
        Updater.shared.check { [weak self] err in
            if let e = err { self?.updateStatus.stringValue = "⚠️ 检查失败：\(e)" } else { self?.refreshUpdate() }
        }
    }
    @objc private func installUpdate() {
        updateButton.isEnabled = false
        Updater.shared.install { [weak self] msg in self?.updateStatus.stringValue = msg }
    }
    @objc private func openReleases() {
        if let u = URL(string: "https://github.com/\(Updater.repo)/releases") { NSWorkspace.shared.open(u) }
    }

    @objc private func hotkeyChanged() {
        Prefs.hotKeyIndex = hotkeyPopup.indexOfSelectedItem
        onHotKeyChanged?()
    }

    @objc private func askAX() {
        _ = SelectionWatcher.trusted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refreshAX() }
    }

    @objc private func clearHistory() {
        let a = NSAlert()
        a.messageText = "清空所有聊天记录？"
        a.addButton(withTitle: "清空")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { onClearHistory?() }
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
        status.stringValue = "✅ 已保存"
    }

    @objc private func testIt() {
        store()
        status.stringValue = "正在连接…"
        llm.stream([["role": "user", "content": "用一句话跟我打个招呼"]], onDelta: { [weak self] t in
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
    private let store = ChatStore()
    private let llm = LLM()
    private let voice = Voice()
    private let listener = Listener()
    private let hotKey = HotKey(id: 1)
    private let perceptionKey = HotKey(id: 2)
    private lazy var hub = ContextHub(dir: store.dir)
    private let highlighter = Highlighter()
    private var versionItem: NSMenuItem!
    private var perceptionItem: NSMenuItem!
    private var contextWindow: NSWindow?
    private let selection = SelectionWatcher()
    private let settings = SettingsController()
    private var chatWindow: ChatWindowController!
    private var statusItem: NSStatusItem!
    private var monitors: [Any] = []
    private var clipTimer: Timer?
    private var careTimer: Timer?
    private var blinkTimer: Timer?
    private var unhoverWork: DispatchWorkItem?
    private var lastChange = NSPasteboard.general.changeCount
    private var sessionStart = Date()
    private var nudgedLong = false
    private var nudgedNight: String?
    private var lastPrompted = ""
    private var voiceFromWindow = false

    let catSize = NSSize(width: 300, height: 330)

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMainMenu()
        buildCat()
        buildStatusMenu()
        chatWindow = ChatWindowController(store: store)
        chatWindow.onSend = { [weak self] text, imgs in self?.ask(text, images: imgs, inBubble: false) }
        chatWindow.onMic = { [weak self] in self?.toggleVoice(fromWindow: true) }
        chatWindow.onClear = { [weak self] in self?.store.clear() }
        bubble.anchor = { [weak self] in self?.catView.headScreenPoint() ?? .zero }
        bubble.onSend = { [weak self] text in self?.ask(text) }
        bubble.onExpand = { [weak self] in self?.bubble.hide(); self?.chatWindow.show() }
        bubble.onMic = { [weak self] in self?.toggleVoice(fromWindow: false) }
        settings.onHotKeyChanged = { [weak self] in self?.registerHotKey() }
        settings.onClearHistory = { [weak self] in self?.store.clear() }
        settings.hub = hub
        settings.onPerceptionChanged = { [weak self] in self?.applyPerception(announce: true) }
        settings.onPreviewContext = { [weak self] in self?.previewContext() }
        hub.idleSeconds = { [weak self] in self?.idleSeconds() ?? 0 }
        applyPerception(announce: false)
        Updater.shared.onUpdateAvailable = { [weak self] v in self?.announceUpdate(v) }
        if Prefs.autoUpdate { Updater.shared.startAutoCheck() }
        RemoteConfig.shared.fetch { [weak self] text in
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self?.bubble.notify(text, hold: 12) }
        }
        setupListener()
        setupSelection()
        registerHotKey()
        startMonitors()
        recordBondingDay()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self = self else { return }
            let days = Prefs.bondingDays.count
            let hello = days <= 1 ? "你好呀，我是 OrdCat 🐾 点我聊天，右键点我打开设置；选中一段文字我会竖起耳朵～"
                                  : "我回来啦～这是我们一起的第 \(days) 天 🐾"
            self.bubble.notify(hello)
        }
    }

    // Without a main menu, ⌘C / ⌘V / ⌘A don't work in text fields of a menu-bar app.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出 OrdCat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // MARK: cat window
    private func catFrame(on screen: NSScreen) -> NSRect {
        let f = screen.frame          // full frame: sit on the real edge
        let vis = screen.visibleFrame
        var y = CGFloat(Prefs.catY ?? Double(vis.minY + vis.height * 0.38))
        y = min(max(y, vis.minY - 60), vis.maxY - catSize.height + 20)
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
        catView.onRightClick = { [weak self] in self?.settings.show(tab: 1) }
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
    private func buildStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐈‍⬛"
        let m = NSMenu()
        versionItem = NSMenuItem(title: "OrdCat v\(Updater.shared.current)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        m.addItem(versionItem)
        m.addItem(.separator())
        m.addItem(withTitle: "和小猫聊天", action: #selector(menuChat), keyEquivalent: "").target = self
        m.addItem(withTitle: "打开聊天窗口", action: #selector(menuWindow), keyEquivalent: "").target = self
        m.addItem(withTitle: "语音对话", action: #selector(menuVoice), keyEquivalent: "").target = self
        m.addItem(withTitle: "显示 / 隐藏小猫", action: #selector(toggleCat), keyEquivalent: "").target = self
        perceptionItem = NSMenuItem(title: "桌面感知", action: #selector(togglePerception), keyEquivalent: "")
        perceptionItem.target = self
        m.addItem(perceptionItem)
        m.addItem(withTitle: "查看当前上下文", action: #selector(previewContextMenu), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "退出 OrdCat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
    }

    @objc private func menuChat() { if !catPanel.isVisible { toggleCat() }; openChat() }
    @objc private func menuWindow() { chatWindow.show() }
    @objc private func menuVoice() { toggleVoice(fromWindow: false) }
    @objc private func toggleCat() {
        if catPanel.isVisible { bubble.hide(); catPanel.orderOut(nil) }
        else { catPanel.orderFrontRegardless(); catView.peekIn() }
    }
    @objc private func openSettings() { settings.show() }
    @objc private func previewContextMenu() { previewContext() }

    // MARK: perception
    @objc private func togglePerception() {
        Prefs.perception.toggle()
        if Prefs.perception { _ = SelectionWatcher.trusted(prompt: true) }
        applyPerception(announce: true)
    }

    private func applyPerception(announce: Bool) {
        let on = Prefs.perception
        hub.setEnabled(on)
        statusItem.button?.title = on ? "🐈‍⬛👀" : "🐈‍⬛"
        perceptionItem?.state = on ? .on : .off
        let k = kPerceptionHotKeys[Prefs.perceptionHotKeyIndex]
        perceptionItem?.title = "桌面感知（\(k.title)）"
        if announce {
            say(on ? "👀 桌面感知打开啦，问我问题时我会先看看你的屏幕。" : "🙈 桌面感知已关闭，我不会再看你的屏幕。")
        }
    }

    private func previewContext() {
        Task { @MainActor in
            let ctx = await hub.assemble(query: "（预览）", wantScreenshot: false)
            showContextWindow("约 \(ctx.tokens) tokens · 预算 \(Prefs.contextBudget)\n\n" + ctx.text)
            self.settings.refreshMemStats()
        }
    }

    private func showContextWindow(_ text: String) {
        if contextWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "当前会发给模型的上下文"
            w.isReleasedWhenClosed = false
            let sv = NSScrollView(frame: w.contentView!.bounds)
            sv.autoresizingMask = [.width, .height]
            sv.hasVerticalScroller = true
            let tv = NSTextView(frame: sv.bounds)
            tv.autoresizingMask = [.width]
            tv.isEditable = false
            tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.textContainerInset = NSSize(width: 12, height: 12)
            sv.documentView = tv
            w.contentView = sv
            w.center()
            contextWindow = w
        }
        ((contextWindow?.contentView as? NSScrollView)?.documentView as? NSTextView)?.string = text
        NSApp.activate(ignoringOtherApps: true)
        contextWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: updates
    private func announceUpdate(_ v: String) {
        versionItem?.title = "OrdCat v\(Updater.shared.current) · ⬆️ 可更新到 v\(v)"
        versionItem?.isEnabled = true
        versionItem?.target = self
        versionItem?.action = #selector(installFromMenu)
        settings.refreshUpdate()
        bubble.notify("有新版本 v\(v) 啦～要我现在换新吗？", actions: [
            ("立即更新", { [weak self] in self?.installFromMenu() }),
            ("稍后", { [weak self] in self?.bubble.hide() })
        ], hold: 15)
    }

    @objc private func installFromMenu() {
        Updater.shared.install { [weak self] msg in self?.bubble.notify(msg, hold: 8) }
    }

    // MARK: chat
    private func toggleChat() {
        if bubble.isShown && bubble.chatMode {
            bubble.hide(); voice.stop(); catView.perk(false)
        } else {
            openChat()
        }
    }
    private func openChat() {
        catView.perk(false)
        let last = store.messages.last(where: { $0.role == "assistant" && !$0.text.isEmpty })?.text
        bubble.openChat(greeting: last ?? "喵～想聊点什么？")
    }

    /// Build the request history: recent turns as text; images only for the newest message.
    private func apiHistory(newImages: [Data]) -> [[String: Any]] {
        let recent = store.messages.suffix(16).filter { !($0.role == "assistant" && ($0.text.isEmpty || $0.text.hasPrefix("⚠️"))) }
        var out: [[String: Any]] = []
        for (i, m) in recent.enumerated() {
            let isLast = i == recent.count - 1
            if isLast && m.role == "user" && !newImages.isEmpty {
                var parts: [[String: Any]] = [["type": "text", "text": m.text]]
                for d in newImages {
                    parts.append(["type": "image_url",
                                  "image_url": ["url": "data:image/jpeg;base64," + d.base64EncodedString()]])
                }
                out.append(["role": "user", "content": parts])
            } else {
                let suffix = m.imageNames.isEmpty ? "" : "\n[之前发过 \(m.imageNames.count) 张图片]"
                out.append(["role": m.role, "content": m.text + suffix])
            }
        }
        return out
    }

    private func ask(_ text: String, images: [Data] = [], spoken: Bool = false, inBubble: Bool = true) {
        voice.stop()
        highlighter.clear()
        let names = images.compactMap { store.saveImage($0) }
        store.append(ChatMessage(role: "user", text: text, imageNames: names, date: Date()))
        var history = apiHistory(newImages: images)
        store.append(ChatMessage(role: "assistant", text: "", imageNames: [], date: Date()))
        let usePerception = Prefs.perception
        if inBubble {
            let wait = usePerception ? "👀 我先看一眼你的屏幕…" : "……"
            if bubble.chatMode { bubble.setText(wait) } else { bubble.openChat(greeting: wait) }
        }
        Task { @MainActor in
            var context: String?
            if usePerception {
                let ctx = await self.hub.assemble(query: text, wantScreenshot: Prefs.sendScreenshot && images.isEmpty)
                context = ctx.text
                if let img = ctx.image, let lastIndex = history.indices.last {
                    let parts: [[String: Any]] = [
                        ["type": "text", "text": text],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + img.base64EncodedString()]]
                    ]
                    history[lastIndex] = ["role": "user", "content": parts]
                }
            }
            self.llm.stream(history, context: context, onDelta: { [weak self] t in
                guard let self = self else { return }
                let shown = ContextHub.stripTags(t)
                self.store.updateLast(shown)
                if inBubble && self.bubble.isShown { self.bubble.setText(shown) }
            }, onDone: { [weak self] t, err in
                guard let self = self else { return }
                let raw = t ?? ""
                let final = err.map { "⚠️ " + $0 } ?? ContextHub.stripTags(raw)
                self.store.updateLast(final)
                self.store.save()
                self.catView.perk(false)
                if inBubble && self.bubble.isShown { self.bubble.setText(final) }
                guard err == nil else { return }
                self.hub.recordChat(user: text, reply: final)
                if usePerception && Prefs.highlight {
                    let rects = self.hub.resolveTargets(in: raw)
                    if !rects.isEmpty { self.highlighter.show(rects, label: "在这里") }
                }
                if Prefs.voice || spoken { self.voice.speak(final.replacingOccurrences(of: "👉", with: "")) }
            })
        }
    }

    // MARK: voice chat
    private func registerHotKey() {
        if Prefs.voiceChat {
            hotKey.register(kHotKeys[Prefs.hotKeyIndex]) { [weak self] in self?.toggleVoice(fromWindow: false) }
        } else {
            hotKey.unregister()
        }
        perceptionKey.register(kPerceptionHotKeys[Prefs.perceptionHotKeyIndex]) { [weak self] in self?.togglePerception() }
        if perceptionItem != nil { applyPerception(announce: false) }
    }

    private func setupListener() {
        listener.onPartial = { [weak self] t in
            guard let self = self else { return }
            if self.voiceFromWindow { self.chatWindow.setListening(true, partial: t) }
            else { self.bubble.setText("🎙️ " + t) }
        }
        listener.onFinal = { [weak self] t in
            guard let self = self else { return }
            self.bubble.setListening(false)
            self.chatWindow.setListening(false)
            self.catView.perk(false)
            if t.isEmpty {
                if !self.voiceFromWindow { self.bubble.setText("没听清呢，再说一次？🐾") }
                return
            }
            self.ask(t, spoken: true, inBubble: !self.voiceFromWindow)
        }
        listener.onError = { [weak self] msg in
            guard let self = self else { return }
            self.bubble.setListening(false)
            self.chatWindow.setListening(false)
            self.catView.perk(false)
            self.bubble.notify(msg, hold: 10)
        }
    }

    private func toggleVoice(fromWindow: Bool) {
        if listener.isListening { listener.finish(); return }
        guard Prefs.voiceChat else {
            bubble.notify("语音对话还没开哦～右键点我 → 小猫 → 开启语音对话。",
                          actions: [("打开设置", { [weak self] in self?.settings.show(tab: 1) })])
            return
        }
        voice.stop()
        llm.cancel()
        voiceFromWindow = fromWindow && chatWindow.isVisible
        if !catPanel.isVisible { toggleCat() }
        catView.perk(true)
        if voiceFromWindow {
            chatWindow.setListening(true, partial: "")
        } else {
            bubble.openChat(greeting: "🎙️ 我在听…（说完停一下就好，再按一次快捷键结束）")
            bubble.setListening(true)
        }
        listener.start()
    }

    // MARK: selection & clipboard
    private func setupSelection() {
        selection.isOwnPoint = { [weak self] p in
            guard let self = self else { return false }
            if self.catPanel.frame.contains(p) || self.bubble.panel.frame.contains(p) { return true }
            for w in NSApp.windows where w.isVisible && w.frame.contains(p) { return true }
            return false
        }
        selection.onSelect = { [weak self] s in
            guard let self = self else { return }
            if Prefs.perception { self.hub.recordSelection(s) }
            self.offerHelp(with: s, verb: "选中")
        }
        selection.onNeedsPermission = { [weak self] in
            self?.bubble.notify("想在你选中文字时竖起耳朵，需要先授权「辅助功能」哦～",
                                actions: [("去授权", { _ = SelectionWatcher.trusted(prompt: true) })], hold: 10)
        }
        selection.start()
    }

    private func offerHelp(with raw: String, verb: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 2, s.count <= 8000, s != lastPrompted else { return }
        guard catPanel.isVisible, !bubble.chatMode, !listener.isListening else { return }
        lastPrompted = s
        catView.perk(true)
        let preview = s.count > 36 ? String(s.prefix(36)) + "…" : s
        bubble.notify("你\(verb)了「\(preview)」～要我帮忙吗？", actions: [
            ("帮我看看 🐾", { [weak self] in
                self?.ask("请帮我看看下面这段内容：如果是报错或代码，告诉我问题和改法；如果是普通文字，用一两句话解释或接个话。\n\n\(s)")
            }),
            ("翻译", { [weak self] in
                self?.ask("把下面的内容翻译成中文（如果原文已经是中文，就翻译成英文），只给译文：\n\n\(s)")
            })
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self, !self.bubble.chatMode else { return }
            self.catView.perk(false)
        }
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        if pb.changeCount == selection.ignoreChangeCount { return }
        guard Prefs.clipWatch else { return }
        // Privacy: never look at passwords or transient data from password managers.
        let banned: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                   "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]
        let types = Set((pb.types ?? []).map { $0.rawValue })
        if !types.isDisjoint(with: banned) { return }
        guard let s = pb.string(forType: .string) else { return }
        offerHelp(with: s, verb: "复制")
    }

    // MARK: monitors (event-driven)
    private func startMonitors() {
        // Eyes and hover follow the mouse. Fires only when the mouse moves; no polling.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            self?.mouseMoved(NSEvent.mouseLocation)
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] e in
            self?.mouseMoved(NSEvent.mouseLocation)
            return e
        }) { monitors.append(l) }

        // The pasteboard has no change notification on macOS; a 1 s timer with wide tolerance is the cheapest option.
        clipTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.checkClipboard() }
        clipTimer?.tolerance = 0.5

        careTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.checkCare() }
        careTimer?.tolerance = 20

        scheduleBlink()

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sessionStart = Date()
            self?.nudgedLong = false
        }
    }

    private func mouseMoved(_ p: NSPoint) {
        guard catPanel.isVisible else { return }
        catView.look(atScreen: p)
        let c = catView.headScreenPoint()
        let d = hypot(p.x - c.x, p.y - c.y)
        if catView.hovering {
            if d > 170 {
                if unhoverWork == nil {
                    let w = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }
                        self.unhoverWork = nil
                        if self.bubble.chatMode { return }
                        self.catView.setHover(false)
                    }
                    unhoverWork = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
                }
            } else {
                unhoverWork?.cancel(); unhoverWork = nil
            }
        } else if d < 100 {
            unhoverWork?.cancel(); unhoverWork = nil
            catView.setHover(true)
        }
    }

    private func scheduleBlink() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 3.5...8), repeats: false) { [weak self] _ in
            self?.catView.blink()
            self?.scheduleBlink()
        }
        blinkTimer?.tolerance = 0.5
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
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
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
        if Prefs.voice { voice.speak(text) }
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
