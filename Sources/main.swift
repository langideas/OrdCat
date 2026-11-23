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
    // 本地（离线，不用 Key）
    Preset(name: "Ollama（本地离线）", base: "http://localhost:11434/v1", model: "qwen2.5:7b"),
    Preset(name: "LM Studio（本地离线）", base: "http://localhost:1234/v1", model: ""),
    // 会员额度，不用 Key（要登录；设置 → 用户 → 会员）
    Preset(name: "OrdCat 托管（会员额度，不用 Key）", base: Account.hostedBase, model: "ordcat"),
    // 国内可直连
    Preset(name: "通义千问 · 阿里云百炼", base: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen3.8-flash"),
    Preset(name: "智谱 GLM", base: "https://open.bigmodel.cn/api/paas/v4", model: "glm-5.3-flash"),
    Preset(name: "DeepSeek", base: "https://api.deepseek.com/v1", model: "deepseek-chat"),
    Preset(name: "硅基流动 SiliconFlow", base: "https://api.siliconflow.cn/v1", model: "deepseek-ai/DeepSeek-V4.1-Flash"),
    Preset(name: "Kimi · 月之暗面", base: "https://api.moonshot.cn/v1", model: "kimi-k3.1-pro"),
    Preset(name: "MiniMax", base: "https://api.minimaxi.com/v1", model: "MiniMax-M3.1-Flash"),
    Preset(name: "豆包 · 火山方舟", base: "https://ark.cn-beijing.volces.com/api/v3", model: "doubao-seed-2-1-turbo-260628"),
    // 海外
    Preset(name: "Groq（极快，听写便宜）", base: "https://api.groq.com/openai/v1", model: "openai/gpt-oss-120b"),
    Preset(name: "OpenAI", base: "https://api.openai.com/v1", model: "gpt-6-luna"),
    Preset(name: "Gemini", base: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-3.1-flash-lite"),
    Preset(name: "Claude", base: "https://api.anthropic.com/v1", model: "claude-haiku-5-5"),
    Preset(name: "Mistral（欧盟）", base: "https://api.mistral.ai/v1", model: "mistral-small-latest"),
    Preset(name: "Grok · xAI", base: "https://api.x.ai/v1", model: "grok-4.3"),
    Preset(name: "OpenRouter（一个 Key 用几百个模型）", base: "https://openrouter.ai/api/v1", model: "openrouter/auto"),
    // 海外节点（同一家的国际站，Key 和国内站不通用）
    Preset(name: "通义千问 · 国际站（新加坡）", base: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", model: "qwen3.8-flash"),
    Preset(name: "智谱 Z.ai · 国际站", base: "https://api.z.ai/api/paas/v4", model: "glm-5.3-flash"),
    Preset(name: "Kimi · 国际站", base: "https://api.moonshot.ai/v1", model: "kimi-k3.1-pro"),
    Preset(name: "MiniMax · 国际站", base: "https://api.minimax.io/v1", model: "MiniMax-M3.1-Flash"),
    Preset(name: "自定义（OpenAI 兼容）", base: "", model: "")
]

/// The preset whose address the user is on (presets are matched by address, so adding presets never
/// changes what someone picked). Unknown address → 自定义.
func presetIndex(forBase b: String) -> Int {
    let t = b.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
    if let i = kPresets.firstIndex(where: { !$0.base.isEmpty && $0.base == t }) { return i }
    return kPresets.count - 1
}

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
    static let ttsService = "app.ordcat.ttskey"
    static func set(_ value: String, service: String = Keychain.service) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        lock.lock(); cache[service] = value; lock.unlock()
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
    /// Read once per launch: every Keychain read can make macOS ask for the login password.
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()
    /// Services being read in the background right now (see prefetch()).
    private static var inFlight = Set<String>()
    static let allServices = ["app.ordcat.apikey", "app.ordcat.ttskey", "app.ordcat.visionkey",
                              "app.ordcat.sttkey", "app.ordcat.session"]
    /// Read every key on a background queue at launch. If macOS asks for the keychain password
    /// (it can after an update), the cat still starts and stays responsive while the prompt waits.
    static func prefetch() {
        lock.lock()
        let todo = allServices.filter { cache[$0] == nil && !inFlight.contains($0) }
        inFlight.formUnion(todo)
        lock.unlock()
        guard !todo.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for svc in todo {
                let v = read(svc)
                lock.lock(); if cache[svc] == nil { cache[svc] = v }; inFlight.remove(svc); lock.unlock()
            }
            DispatchQueue.main.async { NotificationCenter.default.post(name: Keychain.loaded, object: nil) }
        }
    }
    static let loaded = Notification.Name("OrdCatKeychainLoaded")
    static func get(service: String = Keychain.service) -> String {
        lock.lock(); let hit = cache[service]; let waiting = inFlight.contains(service); lock.unlock()
        if let h = hit { return h }
        // Never freeze the UI on a keychain prompt: the background read fills it in shortly.
        if waiting && Thread.isMainThread { return "" }
        if waiting {
            for _ in 0..<600 {   // up to 60 s on a background thread
                Thread.sleep(forTimeInterval: 0.1)
                lock.lock(); let h = cache[service]; lock.unlock()
                if let h = h { return h }
            }
            return ""
        }
        let v = read(service)
        lock.lock(); cache[service] = v; lock.unlock()
        return v
    }
    private static func read(_ service: String) -> String {
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
    static var pageShare: Bool { get { bool("pageShare", true) } set { d.set(newValue, forKey: "pageShare") } }
    // Voice output
    static var ttsEngine: Int { get { d.object(forKey: "ttsEngine") as? Int ?? 0 } set { d.set(newValue, forKey: "ttsEngine") } }
    static var sysVoiceID: String { get { d.string(forKey: "sysVoiceID") ?? "" } set { d.set(newValue, forKey: "sysVoiceID") } }
    static var ttsRate: Double { get { d.object(forKey: "ttsRate") as? Double ?? 0.5 } set { d.set(newValue, forKey: "ttsRate") } }
    static var ttsPitch: Double { get { d.object(forKey: "ttsPitch") as? Double ?? 1.0 } set { d.set(newValue, forKey: "ttsPitch") } }
    static var ttsPreset: Int { get { d.object(forKey: "ttsPreset") as? Int ?? 0 } set { d.set(newValue, forKey: "ttsPreset") } }
    static var ttsBase: String { get { d.string(forKey: "ttsBase") ?? kTTSPresets[0].base } set { d.set(newValue, forKey: "ttsBase") } }
    static var ttsModel: String { get { d.string(forKey: "ttsModel") ?? kTTSPresets[0].model } set { d.set(newValue, forKey: "ttsModel") } }
    static var ttsVoice: String { get { d.string(forKey: "ttsVoice") ?? kTTSPresets[0].voices[0].id } set { d.set(newValue, forKey: "ttsVoice") } }
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

// ChatMessage / ChatStore live in Chats.swift (conversations, categories, projects).

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

    /// Seconds the provider asks us to wait ("try again in 1.53s" / "in 2m3s" / Retry-After header).
    static func retryDelay(_ text: String, header: String?) -> Double {
        if let h = header, let v = Double(h.trimmingCharacters(in: .whitespaces)) { return max(1, v) }
        if let r = text.range(of: #"try again in\s*(?:(\d+)m)?\s*([\d.]+)\s*(ms|s)"#, options: [.regularExpression, .caseInsensitive]) {
            let frag = String(text[r])
            let nums = frag.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
            var sec = 0.0
            if frag.contains("m") && nums.count >= 2 && !frag.hasSuffix("ms") { sec = nums[0] * 60 + nums[1] }
            else if let n = nums.last { sec = frag.hasSuffix("ms") ? n / 1000 : n }
            return max(1, sec + 0.5)
        }
        return 8
    }

    /// The request alone is larger than the per-minute limit, so waiting will not help without trimming.
    static func requestTooBig(_ text: String) -> Bool {
        func num(_ key: String) -> Int? {
            guard let r = text.range(of: key + #"\s*(\d+)"#, options: .regularExpression) else { return nil }
            return Int(text[r].filter(\.isNumber))
        }
        if let lim = num("Limit"), let req = num("Requested") { return req * 10 > lim * 8 }
        return text.localizedCaseInsensitiveContains("too large")
    }

    func stream(_ history: [[String: Any]], context: String? = nil, attempt: Int = 0,
                hosted: (URL, [String: String])? = nil,
                onDelta: @escaping (String) -> Void,
                onDone: @escaping (String?, String?) -> Void) {
        cancel()
        var base = Prefs.base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        // OrdCat 托管: get the proxy address and a fresh login token first.
        if base == Account.hostedBase && hosted == nil {
            Account.shared.hostedEndpoint { [weak self] url, headers, err in
                guard let u = url else { onDone(nil, err ?? "OrdCat 托管模型暂时用不了"); return }
                self?.stream(history, context: context, attempt: attempt, hosted: (u, headers), onDelta: onDelta, onDone: onDone)
            }
            return
        }
        let target = hosted?.0 ?? URL(string: base + "/chat/completions")
        guard !base.isEmpty, let url = target else {
            onDone(nil, "还没设置模型哦～右键点我 → 设置，就能和我聊天啦。")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = Keychain.get()
        if !key.isEmpty && hosted == nil { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        for (k, v) in hosted?.1 ?? [:] { req.setValue(v, forHTTPHeaderField: k) }
        var system = RemoteConfig.shared.systemPrompt ?? kSystemPrompt
        if let c = context, !c.isEmpty { system += "\n\n" + c }
        if L10n.english { system += "\n\nThe user's interface language is English: reply in English unless they write to you in another language or ask otherwise." }
        let messages: [[String: Any]] = [["role": "system", "content": system]] + history
        var body: [String: Any] = ["model": Prefs.model, "messages": messages, "stream": true, "max_tokens": 1500]
        // Reasoning models (e.g. gpt-oss on Groq) would otherwise spend the budget thinking.
        if base.contains("groq.com") && Prefs.model.contains("gpt-oss") { body["reasoning_effort"] = "low" }
        // Chatting with a cat needs no long thinking: switch it off (or low) where the provider allows,
        // which keeps answers fast and cheap.
        if base.contains("dashscope") { body["enable_thinking"] = false }
        if base.contains("bigmodel.cn") || base.contains("z.ai") { body["thinking"] = ["type": "disabled"] }
        if base.contains("generativelanguage.googleapis.com") { body["reasoning_effort"] = "low" }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        task = Task {
            var full = ""
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                if let h = resp as? HTTPURLResponse, h.statusCode >= 300 {
                    var errText = ""
                    for try await line in bytes.lines {
                        errText += line
                        if errText.count > 600 { break }
                    }
                    // OrdCat 托管: the proxy explains itself (额度用完 / 太快 / 没登录).
                    if hosted != nil {
                        let o = (try? JSONSerialization.jsonObject(with: Data(errText.utf8))) as? [String: Any]
                        let m = ((o?["error"] as? [String: Any])?["message"] as? String) ?? "OrdCat 托管模型返回了错误（\(h.statusCode)）"
                        DispatchQueue.main.async { onDone(nil, m) }
                        return
                    }
                    // Per-minute token quota (e.g. Groq free tier: "Limit 8000, Used 4412, Requested 3671").
                    // Wait the time the provider asks for and try again quietly, with a smaller context if needed.
                    if h.statusCode == 429 || h.statusCode == 413, attempt < 2, !Task.isCancelled {
                        let wait = LLM.retryDelay(errText, header: h.value(forHTTPHeaderField: "retry-after"))
                        if wait <= 25 {
                            let tooBig = LLM.requestTooBig(errText) || h.statusCode == 413
                            DispatchQueue.main.async {
                                onDelta("模型这分钟的额度用满了，小猫等 \(Int(wait.rounded(.up))) 秒自动再试…")
                            }
                            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                            if Task.isCancelled { return }
                            let ctx = tooBig || attempt == 1 ? context.map { String($0.prefix($0.count / 2)) } : context
                            let hist = tooBig ? Array(history.suffix(4)) : history
                            DispatchQueue.main.async {
                                self.stream(hist, context: ctx, attempt: attempt + 1, onDelta: onDelta, onDone: onDone)
                            }
                            return
                        }
                    }
                    let msg = h.statusCode == 429
                        ? "模型那边的免费额度暂时用满了（每分钟 token 上限），不是小猫坏了。等一分钟再问，或在 设置 → 模型 换一个额度更高的模型。"
                        : "模型那边返回了错误（\(h.statusCode)）：\(errText.prefix(220))"
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

// MARK: - Voice out (natural system voices, or a cloud voice through an OpenAI-compatible /audio/speech)

struct TTSVoiceOption { let id: String; let label: String }
struct TTSPreset { let name: String; let base: String; let model: String; let voices: [TTSVoiceOption] }

let kTTSPresets: [TTSPreset] = [
    TTSPreset(name: "硅基流动 CosyVoice2（中文最自然）", base: "https://api.siliconflow.cn/v1", model: "FunAudioLLM/CosyVoice2-0.5B",
              voices: [("claire", "温柔女声 Claire"), ("anna", "沉稳女声 Anna"), ("diana", "欢快女声 Diana"), ("bella", "激情女声 Bella"),
                       ("alex", "沉稳男声 Alex"), ("benjamin", "低沉男声 Benjamin"), ("charles", "磁性男声 Charles"), ("david", "欢快男声 David")]
                .map { TTSVoiceOption(id: "FunAudioLLM/CosyVoice2-0.5B:" + $0.0, label: $0.1) }),
    TTSPreset(name: "OpenAI gpt-4o-mini-tts", base: "https://api.openai.com/v1", model: "gpt-4o-mini-tts",
              voices: [("coral", "Coral 温暖女声"), ("nova", "Nova 明亮女声"), ("shimmer", "Shimmer 柔和女声"), ("sage", "Sage 平静女声"),
                       ("alloy", "Alloy 中性"), ("ash", "Ash 男声"), ("echo", "Echo 男声"), ("onyx", "Onyx 低沉男声")]
                .map { TTSVoiceOption(id: $0.0, label: $0.1) }),
    TTSPreset(name: "自定义（OpenAI 兼容 /audio/speech）", base: "", model: "", voices: [])
]

final class Voice: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var cloudTask: URLSessionDataTask?
    private var gen = 0
    /// Reports cloud problems (shown in settings when testing).
    var onStatus: ((String) -> Void)?
    /// 0 idle, 1 speaking (or fetching the cloud voice), 2 paused.
    private(set) var state = 0 { didSet { if state != oldValue { onState?(state) } } }
    var onState: ((Int) -> Void)?
    private var pending = Set<ObjectIdentifier>()

    override init() {
        super.init()
        synth.delegate = self
    }

    var isActive: Bool { state != 0 }

    /// Pause / continue whatever is being read aloud.
    func togglePause() {
        if state == 1 {
            if let p = player, p.isPlaying { p.pause() } else if synth.isSpeaking { synth.pauseSpeaking(at: .word) }
            state = 2
        } else if state == 2 {
            if let p = player { p.play() } else { synth.continueSpeaking() }
            state = 1
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        DispatchQueue.main.async {
            guard self.pending.remove(id) != nil else { return }
            if self.pending.isEmpty && self.player == nil && self.cloudTask == nil { self.state = 0 }
        }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        DispatchQueue.main.async {
            guard self.pending.remove(id) != nil else { return }
            if self.pending.isEmpty && self.player == nil && self.cloudTask == nil { self.state = 0 }
        }
    }
    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            if self.player === p { self.player = nil; if self.pending.isEmpty { self.state = 0 } }
        }
    }

    /// Chinese system voices, best quality first, novelty voices removed.
    static func systemVoices() -> [AVSpeechSynthesisVoice] {
        var vs = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
        if #available(macOS 14.0, *) { vs = vs.filter { !$0.voiceTraits.contains(.isNoveltyVoice) } }
        func langRank(_ v: AVSpeechSynthesisVoice) -> Int { v.language == "zh-CN" ? 0 : (v.language == "zh-TW" ? 1 : 2) }
        return vs.sorted {
            if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
            if langRank($0) != langRank($1) { return langRank($0) < langRank($1) }
            return $0.name < $1.name
        }
    }

    static func describe(_ v: AVSpeechSynthesisVoice) -> String {
        let q: String
        switch v.quality {
        case .premium: q = "高级 ✨"
        case .enhanced: q = "增强"
        default: q = "标准"
        }
        let lang = ["zh-CN": "普通话", "zh-TW": "台湾国语", "zh-HK": "粤语"][v.language] ?? v.language
        return "\(v.name) · \(lang) · \(q)"
    }

    static func chosenSystemVoice() -> AVSpeechSynthesisVoice? {
        if !Prefs.sysVoiceID.isEmpty, let v = AVSpeechSynthesisVoice(identifier: Prefs.sysVoiceID) { return v }
        let vs = systemVoices()
        let best = vs.first
        // Prefer Mandarin unless a much better voice exists in another Chinese variant.
        if let cn = vs.first(where: { $0.language == "zh-CN" }), let b = best, cn.quality.rawValue >= b.quality.rawValue { return cn }
        return best ?? AVSpeechSynthesisVoice(language: "zh-CN")
    }

    /// Turn chat text into something that sounds natural when read aloud.
    static func speakable(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "这个链接", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[\[[^\]]*\]\]"#, with: "", options: .regularExpression)
        var scalars = String.UnicodeScalarView()
        for sc in t.unicodeScalars {
            let p = sc.properties
            if p.isEmojiPresentation || (p.isEmoji && sc.value > 0x2000) { continue }
            if "*#`_>|•~～".unicodeScalars.contains(sc) { continue }
            scalars.append(sc)
        }
        t = String(scalars)
        t = t.replacingOccurrences(of: #"(?m)^\s*[-–—]\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split into sentences so the system voice breathes between them instead of one flat run.
    static func sentences(_ t: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in t {
            if ch == "\n" {
                if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
                cur = ""; continue
            }
            cur.append(ch)
            if "。！？!?；;…".contains(ch) {
                if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
                cur = ""
            }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
        return out
    }

    func speak(_ text: String) {
        stop()
        let clean = Voice.speakable(text)
        guard !clean.isEmpty else { return }
        if Prefs.ttsEngine == 1 { speakCloud(clean) } else { speakSystem(clean) }
    }

    private func speakSystem(_ clean: String) {
        let v = Voice.chosenSystemVoice()
        let parts = Voice.sentences(clean)
        guard !parts.isEmpty else { return }
        state = 1
        for sentence in parts {
            let u = AVSpeechUtterance(string: sentence)
            u.voice = v
            u.rate = Float(Prefs.ttsRate)
            u.pitchMultiplier = Float(Prefs.ttsPitch)
            u.postUtteranceDelay = 0.08
            pending.insert(ObjectIdentifier(u))
            synth.speak(u)
        }
    }

    private func speakCloud(_ clean: String) {
        var base = Prefs.ttsBase.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + "/audio/speech") else {
            onStatus?("⚠️ 云端声音还没填接口地址，先用系统声音读")
            speakSystem(clean); return
        }
        var input = String(clean.prefix(1800))
        if base.contains("siliconflow") {
            // CosyVoice reads spaces as pauses: drop the ones next to Chinese characters.
            input = input.replacingOccurrences(of: #"(?<=[\p{Han}，。！？、：；])\s+|\s+(?=[\p{Han}，。！？、：；])"#,
                                               with: "", options: .regularExpression)
        }
        var body: [String: Any] = ["model": Prefs.ttsModel, "input": input, "voice": Prefs.ttsVoice,
                                   "response_format": "mp3", "speed": max(0.6, min(1.6, Prefs.ttsRate * 2))]
        if Prefs.ttsModel.contains("gpt-4o") {
            body["instructions"] = "用温柔、自然、放松的语气说中文，像坐在旁边陪伴的朋友，语速适中，句子之间自然停顿。"
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = Keychain.get(service: Keychain.ttsService)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        gen += 1
        let g = gen
        state = 1
        cloudTask = URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self, g == self.gen else { return }
                self.cloudTask = nil
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if let d = data, code == 200, d.count > 512, let p = try? AVAudioPlayer(data: d) {
                    self.player = p
                    p.delegate = self
                    p.prepareToPlay()
                    p.play()
                    if self.state == 2 { p.pause() }   // paused while it was still loading
                    self.onStatus?("✅ 云端声音播放中")
                } else {
                    let why = err?.localizedDescription
                        ?? String(data: data ?? Data(), encoding: .utf8).map { "（\(code)）" + String($0.prefix(160)) } ?? "未知错误"
                    NSLog("OrdCat TTS cloud failed: \(why)")
                    self.onStatus?("⚠️ 云端声音失败：\(why)。先用系统声音读")
                    self.speakSystem(clean)
                }
            }
        }
        cloudTask?.resume()
    }

    func stop() {
        gen += 1
        cloudTask?.cancel(); cloudTask = nil
        player?.stop(); player = nil
        pending.removeAll()
        synth.stopSpeaking(at: .immediate)
        state = 0
    }
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
    private var recFile: AVAudioFile?
    private var recURL: URL?
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
        // Cloud speech recognition: keep a copy of what we hear, send it when the user stops talking.
        if Cap.stt != nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ordcat-voice-\(UUID().uuidString).wav")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                           AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false]
            recFile = try? AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            recURL = recFile == nil ? nil : url
        }
        let file = recFile
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.request?.append(buf)
            try? file?.write(from: buf)
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
        let apple = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = recURL, let ep = Cap.stt {
            recFile = nil
            recURL = nil
            onPartial?(apple.isEmpty ? "☁️ 正在识别…" : apple + " ☁️")
            Task {
                let (t, _) = await MediaHub.cloudTranscribe(url, ep: ep)
                try? FileManager.default.removeItem(at: url)
                let best = (t?.isEmpty ?? true) ? apple : t!
                DispatchQueue.main.async { self.onFinal?(best) }
            }
            return
        }
        onFinal?(apple)
    }

    func cancel() {
        isListening = false
        silenceTimer?.invalidate()
        teardown()
        recFile = nil
        if let u = recURL { try? FileManager.default.removeItem(at: u) }
        recURL = nil
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
    var ignoreChangeCount = -1
    /// Where the last selection sits on screen (top-left global points), which app it is in, and when.
    private(set) var lastRect: CGRect?
    private(set) var lastPid: pid_t = 0
    private var dragRect: CGRect?
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
        let shiftClick = e.modifierFlags.contains(.shift)
        guard dragged || e.clickCount >= 2 || shiftClick else { return }
        if isOwnPoint?(p) == true { return }
        // The dragged area, in case the app can't tell us the selection's bounds.
        let h = NSScreen.screens.first?.frame.height ?? 0
        let a = CGPoint(x: downPoint.x, y: h - downPoint.y), b = CGPoint(x: p.x, y: h - p.y)
        dragRect = dragged ? CGRect(x: min(a.x, b.x), y: min(a.y, b.y) - 10,
                                    width: max(abs(a.x - b.x), 24), height: abs(a.y - b.y) + 20) : nil
        guard SelectionWatcher.trusted(prompt: false) else {
            if !asked { asked = true; onNeedsPermission?() }
            return
        }
        generation += 1
        let gen = generation
        // Read almost immediately; retry once in case the app updates its selection a beat later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.grab(gen, retry: true) }
    }

    private var generation = 0

    private func grab(_ gen: Int, retry: Bool) {
        guard gen == generation else { return }   // a newer selection superseded this one
        if let (s, r) = axSelectedText(), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastRect = r ?? dragRect
            lastPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            onSelect?(s)
            return
        }
        if retry {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.grab(gen, retry: false) }
            return
        }
        guard Prefs.selectFallback else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if front == "com.apple.finder" || front == Bundle.main.bundleIdentifier { return }
        if SelectionWatcher.captureToolActive(front: front) { return }
        copyFallback { [weak self] s in
            guard let self = self, gen == self.generation,
                  let s = s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.lastRect = self.dragRect
            self.lastPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            self.onSelect?(s)
        }
    }

    /// True while macOS Screenshot / screen recording (⌘⇧5, ⌘⇧4) or another capture tool is on screen.
    /// We must never press ⌘C or touch the clipboard then — it can break the capture and its save.
    static func captureToolActive(front: String) -> Bool {
        let ids = ["com.apple.screencaptureui", "com.apple.screenshot.launcher", "com.apple.QuickTimePlayerX",
                   "com.apple.Preview", "com.cleanshot", "pl.maketheweb.cleanshotx", "com.obsproject.obs-studio",
                   "com.techsmith.snagit", "com.loom.desktop", "com.apple.FaceTime"]
        if ids.contains(where: { front.hasPrefix($0) }) { return true }
        let owners = ["screencaptureui", "Screenshot", "截屏", "截圖", "screencapture", "CleanShot", "OBS", "Loom"]
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            if owners.contains(where: { owner.localizedCaseInsensitiveContains($0) }) { return true }
        }
        return false
    }

    private var enhanced = Set<pid_t>()

    private func axSelectedText() -> (String, CGRect?)? {
        // Chromium browsers only build the web-page tree for assistive clients: ask once per app.
        if let front = NSWorkspace.shared.frontmostApplication,
           ScreenReader.chromiumBrowsers.contains(front.bundleIdentifier ?? ""), !enhanced.contains(front.processIdentifier) {
            enhanced.insert(front.processIdentifier)
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(front.processIdentifier),
                                         "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let el = f as! AXUIElement
        var sel: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &sel) == .success,
           let s = sel as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (s, SelectionWatcher.rangeBounds(el) ?? SelectionWatcher.markerBounds(el))
        }
        // Web pages (Chrome, Edge, Safari…): plain page text has no AXSelectedText, but the page keeps the
        // selection as a text-marker range. Try the focused node, then walk up to its web area.
        var node: AXUIElement? = el
        for _ in 0..<14 {
            guard let n = node else { break }
            if let s = SelectionWatcher.markerSelection(n) { return (s, SelectionWatcher.markerBounds(n)) }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(n, kAXParentAttribute as CFString, &parent) == .success,
                  let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            node = (p as! AXUIElement)
        }
        return nil
    }

    private static func rectValue(_ v: CFTypeRef?) -> CGRect? {
        guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r), r.width > 1, r.height > 1 else { return nil }
        return r
    }

    /// Bounds of the selected range in a text field / text view (top-left global points).
    private static func rangeBounds(_ el: AXUIElement) -> CGRect? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let r = range else { return nil }
        var b: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, r, &b) == .success
        else { return nil }
        return rectValue(b)
    }

    /// Bounds of a web page's selection (text-marker range).
    private static func markerBounds(_ el: AXUIElement) -> CGRect? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &range) == .success,
              let r = range else { return nil }
        var b: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, "AXBoundsForTextMarkerRange" as CFString, r, &b) == .success
        else { return nil }
        return rectValue(b)
    }

    private static func markerSelection(_ el: AXUIElement) -> String? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &range) == .success,
              let r = range else { return nil }
        var str: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, "AXStringForTextMarkerRange" as CFString, r, &str) == .success,
              let s = str as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
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
        var tries = 0
        func poll() {
            tries += 1
            if pb.changeCount == before {
                if tries < 10 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { poll() } } else { done(nil) }
                return
            }
            finish()
        }
        func finish() {
            let s = pb.string(forType: .string)
            pb.clearContents()
            let items: [NSPasteboardItem] = saved.map { dict in
                let it = NSPasteboardItem()
                for (t, v) in dict { it.setData(v, forType: t) }
                return it
            }
            if !items.isEmpty { pb.writeObjects(items) }
            self.ignoreChangeCount = pb.changeCount
            done(s)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { poll() }
    }
}

// MARK: - Cat view (layer-drawn, right-edge peek)

final class CatView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
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

    /// 订阅会员: a soft amber rim glow around the whole cat (follows its shape and peeks). Off for everyone else.
    func setMember(_ on: Bool) {
        rig.shadowColor = kAmber.cgColor
        rig.shadowRadius = 7
        rig.shadowOffset = .zero
        rig.shadowOpacity = on ? 0.55 : 0
    }

    private let tilt: CGFloat = 18 * .pi / 180
    private let restOffset: CGFloat = 0       // classic v0.1.3 peek
    private let hoverOffset: CGFloat = -22    // a small, curious lean on hover
    private(set) var peek: CGFloat = 0
    private(set) var hovering = false
    private var lookOffset = CGPoint.zero
    private var eyeScale: CGFloat = 1
    private var perked = false
    private var dragStart: NSPoint?
    private var dragged = false
    private var lastLook: TimeInterval = 0

    /// Head centre in view coordinates when not shifted.
    var baseHead: CGPoint { CGPoint(x: bounds.maxX - 46, y: bounds.midY + 6) }
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

        makePaw(paw, CGRect(x: h.x - 12, y: h.y - 98, width: 70, height: 36))
        rig.addSublayer(paw)

        excl.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        excl.position = CGPoint(x: h.x - 112, y: h.y + 100)
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
        return hypot(p.x - h.x, p.y - h.y) < 110 ? self : nil
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

/// The voice button: a sound-wave symbol (a stop symbol while listening).
func voiceIcon(listening: Bool) -> NSImage? {
    let name = listening ? "stop.circle.fill" : "waveform"
    let img = NSImage(systemSymbolName: name, accessibilityDescription: listening ? "停止" : "语音对话")
    return img?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
}
func styleVoiceButton(_ b: NSButton, listening: Bool) {
    if let img = voiceIcon(listening: listening) {
        b.title = ""
        b.image = img
        b.imagePosition = .imageOnly
        b.contentTintColor = listening ? .systemRed : nil
    } else {
        b.title = listening ? "⏹" : "🎙"
    }
    b.toolTip = voiceTip(listening: listening)
}
/// Hover text for the voice button: what it does and its shortcut.
func voiceTip(listening: Bool = false) -> String {
    if listening { return "结束语音（再按一次快捷键也可以）" }
    guard Prefs.voiceChat else { return "语音对话 · 快捷键没开（右键小猫 → 设置 → 小猫 里打开）" }
    return "语音对话 · 快捷键 \(kHotKeys[Prefs.hotKeyIndex].title)"
}

// MARK: - Brand mark (2026-11-20): the cat's amber capsule eyes, no background.
/// Proportions from brand/ordcat-logo.svg: eye 130×286, gap 170.
func ordEyesImage(height h: CGFloat, color: NSColor = kAmber, glow: Bool = true, dot: NSColor? = nil, openness: CGFloat = 1) -> NSImage {
    let ew = h * 130 / 286, gap = h * 170 / 286
    let pad: CGFloat = glow ? max(1, h * 0.12) : 0
    let dotW: CGFloat = dot == nil ? 0 : h * 0.45
    let w = ew * 2 + gap + pad * 2 + dotW
    let img = NSImage(size: NSSize(width: ceil(w), height: ceil(h + pad * 2)), flipped: false) { _ in
        NSGraphicsContext.current?.saveGraphicsState()
        if glow {
            let sh = NSShadow(); sh.shadowColor = color.withAlphaComponent(0.6); sh.shadowBlurRadius = h * 0.18; sh.shadowOffset = .zero; sh.set()
        }
        color.setFill()
        // openness < 1 = mid-blink: squash each eye toward its centre (canvas size unchanged, so nothing jumps).
        let eh = max(h * openness, min(ew, h) * 0.35)
        for x in [pad, pad + ew + gap] {
            let r = min(ew, eh) / 2
            NSBezierPath(roundedRect: NSRect(x: x, y: pad + (h - eh) / 2, width: ew, height: eh), xRadius: r, yRadius: r).fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()
        if let d = dot {
            let r = h * 0.28
            d.setFill()
            NSBezierPath(ovalIn: NSRect(x: pad + ew * 2 + gap + dotW - r, y: pad + h - r * 1.1, width: r, height: r)).fill()
        }
        return true
    }
    return img
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
    /// Tappable full-width rows (reply ideas): click one to use it.
    private var choiceButtons: [NSButton] = []
    private var choiceActions: [() -> Void] = []
    /// What the bubble shows right now, set by the caller ("xcard"); any new notify/openChat clears it.
    var tag: String?
    /// Read-aloud controls in the header, shown while the cat is speaking.
    private var speakPause: NSButton!
    private var speakStop: NSButton!
    private(set) var speakState = 0   // 0 idle, 1 speaking, 2 paused
    var onSpeakPause: (() -> Void)?
    var onSpeakStop: (() -> Void)?
    private let input = NSTextField()
    private var micButton: NSButton!
    private var sendButton: NSButton!
    private let shareChip = NSButton(title: "", target: nil, action: nil)
    private let shareClose = NSButton(title: "✕", target: nil, action: nil)
    /// Title of the page the user can share (nil = nothing shareable, chip hidden).
    private(set) var shareTitle: String?
    private(set) var sharing = false
    var onShareChanged: ((Bool) -> Void)?
    private var hideTimer: Timer?
    private(set) var chatMode = false
    var onSend: ((String) -> Void)?
    var onExpand: (() -> Void)?
    var onTopics: ((NSView) -> Void)?
    private var topicsButton: NSButton!
    private var squareButton: NSButton!
    private var signalButton: NSButton!
    /// 小猫等级 icons right after the "OrdCat" title (hidden at Lv0). Click → 设置 → 用户.
    private var levelButton: NSButton!
    var onLevel: (() -> Void)?
    var onMic: (() -> Void)?
    var anchor: () -> NSPoint = { .zero }   // cat head centre, screen coords
    /// Roomier in chat (header buttons + input row), a little narrower for one-off hints.
    var width: CGFloat { chatMode ? 420 : 360 }

    var isShown: Bool { panel.isVisible && panel.alphaValue > 0.01 }
    var hasDraft: Bool { !input.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }

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
        card.appearance = Theme.bubbleAppearance
        NotificationCenter.default.addObserver(forName: Theme.changed, object: nil, queue: .main) { [weak self] _ in
            self?.applyTheme()
        }
        card.wantsLayer = true
        card.layer?.cornerRadius = 20
        card.layer?.masksToBounds = true
        content.addSubview(card)

        title.font = .systemFont(ofSize: 12, weight: .bold)
        title.textColor = kAmber
        card.addSubview(title)

        expandButton = OCButton(title: "↗ 完整对话", target: self, action: #selector(doExpand))
        (expandButton as? OCButton)?.chip = true
        (expandButton as? OCButton)?.style = .secondary
        expandButton.toolTip = "打开独立聊天窗口（聊天记录、发送图片和文件）"
        card.addSubview(expandButton)

        topicsButton = OCButton(title: "🗂 对话记录", target: self, action: #selector(doTopics))
        (topicsButton as? OCButton)?.chip = true
        (topicsButton as? OCButton)?.style = .secondary
        topicsButton.toolTip = "默认只参考当前页面；想接着聊以前的内容，在这里选"
        card.addSubview(topicsButton)

        squareButton = OCButton(title: "🐟 猫帮圈", target: self, action: #selector(doSquare))
        (squareButton as? OCButton)?.chip = true
        (squareButton as? OCButton)?.style = .secondary
        squareButton.toolTip = "打开猫帮圈"
        card.addSubview(squareButton)

        signalButton = OCButton(title: L10n.english ? "📶 Signals" : "📶 信号站", target: self, action: #selector(doSignal))
        (signalButton as? OCButton)?.chip = true
        (signalButton as? OCButton)?.style = .secondary
        signalButton.toolTip = "打开信号站"
        card.addSubview(signalButton)

        levelButton = NSButton(title: "", target: self, action: #selector(doLevel))
        levelButton.isBordered = false
        levelButton.imagePosition = .imageOnly
        levelButton.isHidden = true
        card.addSubview(levelButton)
        NotificationCenter.default.addObserver(forName: CatLevel.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.isShown else { return }
            self.layout()
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = Theme.fg
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

        micButton = iconButton("", self, #selector(doMic), tip: voiceTip())
        styleVoiceButton(micButton, listening: false)
        card.addSubview(micButton)

        speakPause = NSButton(title: "", target: self, action: #selector(doSpeakPause))
        speakStop = NSButton(title: "", target: self, action: #selector(doSpeakStop))
        for (b, sym, tip) in [(speakPause!, "pause.fill", "暂停朗读"), (speakStop!, "stop.fill", "停止朗读（Esc 也可以）")] {
            b.isBordered = false
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            if b.image == nil { b.title = sym == "stop.fill" ? "⏹" : "⏸" }
            b.imagePosition = .imageOnly
            b.contentTintColor = kAmber
            b.toolTip = tip
            b.isHidden = true
            card.addSubview(b)
        }
        sendButton = iconButton("发送", self, #selector(doSend), tip: "发送")
        card.addSubview(sendButton)

        shareChip.isBordered = false
        shareChip.wantsLayer = true
        shareChip.layer?.cornerRadius = 11
        shareChip.layer?.backgroundColor = Theme.fg.withAlphaComponent(0.10).cgColor
        shareChip.font = .systemFont(ofSize: 11)
        shareChip.contentTintColor = Theme.fg
        shareChip.alignment = .left
        shareChip.lineBreakMode = .byTruncatingTail
        shareChip.target = self
        shareChip.action = #selector(chipClicked)
        shareChip.toolTip = "小猫会读这个页面上的文字来回答你（密码框不会读，隐私信息会先打码）"
        card.addSubview(shareChip)
        shareClose.isBordered = false
        shareClose.font = .systemFont(ofSize: 11)
        shareClose.contentTintColor = .secondaryLabelColor
        shareClose.target = self
        shareClose.action = #selector(closeShare)
        shareClose.toolTip = "这次对话不分享这个页面"
        card.addSubview(shareClose)
    }

    @objc private func chipClicked() { if !sharing { setShare(title: shareTitle, on: true); onShareChanged?(true) } }
    @objc private func closeShare() { setShare(title: shareTitle, on: false); onShareChanged?(false) }

    /// Show or update the "正在分享「…」" chip above the input box.
    /// Set when the user picked an earlier topic from 🗂: the chip then says what we are continuing.
    var topicLabel: String? { didSet { setShare(title: shareTitle, on: sharing, force: true) } }

    func setShare(title: String?, on: Bool, force: Bool = false) {
        let changed = force || title != shareTitle || on != sharing
        shareTitle = title
        sharing = on && title != nil
        if let t = title {
            let short = t.count > 28 ? String(t.prefix(28)) + "…" : t
            if sharing {
                shareChip.title = "  🟢 正在分享「\(short)」"
            } else if let tl = topicLabel {
                let ts = tl.count > 18 ? String(tl.prefix(18)) + "…" : tl
                shareChip.title = "  💬 在聊之前的「\(ts)」· 点这里改回当前页面"
            } else {
                shareChip.title = "  ⚪️ 未分享当前页面 · 点这里分享"
            }
        }
        if changed && isShown { layout() }
    }

    @objc private func doExpand() { onExpand?() }
    @objc private func doTopics() { onTopics?(topicsButton) }
    @objc private func doSquare() { TaskSquare.shared.showWindow() }
    @objc private func doSignal() { SignalStation.shared.showWindow() }
    @objc private func doLevel() { onLevel?() }
    @objc private func doMic() { onMic?() }
    @objc private func doSpeakPause() { onSpeakPause?() }
    @objc private func doSpeakStop() { onSpeakStop?() }

    /// 0 idle, 1 speaking, 2 paused: show / hide the pause and stop buttons next to the title.
    func setSpeaking(_ st: Int) {
        speakState = st
        let sym = st == 2 ? "play.fill" : "pause.fill"
        speakPause.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        speakPause.toolTip = st == 2 ? "继续朗读" : "暂停朗读"
        if speakPause.image == nil { speakPause.title = st == 2 ? "▶︎" : "⏸" }
        if isShown { layout() }
    }
    @objc private func doChoice(_ sender: NSButton) {
        let i = sender.tag
        guard i < choiceActions.count else { return }
        choiceActions[i]()
    }

    /// Full-width tappable rows under the text (reply ideas). Pass [] to remove them.
    /// Light / dark switched: recolour what is already on screen.
    private func applyTheme() {
        card.appearance = Theme.bubbleAppearance
        textView.textColor = Theme.fg
        if let ts = textView.textStorage, ts.length > 0 {
            ts.addAttribute(.foregroundColor, value: Theme.fg, range: NSRange(location: 0, length: ts.length))
        }
        shareChip.layer?.backgroundColor = Theme.fg.withAlphaComponent(0.10).cgColor
        shareChip.contentTintColor = Theme.fg
        for b in choiceButtons {
            b.layer?.backgroundColor = Theme.fg.withAlphaComponent(0.09).cgColor
            let at = NSMutableAttributedString(attributedString: b.attributedTitle)
            at.addAttribute(.foregroundColor, value: Theme.fg, range: NSRange(location: 0, length: at.length))
            b.attributedTitle = at
        }
    }

    func setChoices(_ list: [(String, () -> Void)], tip: String = "") {
        for b in choiceButtons { b.removeFromSuperview() }
        choiceButtons = []
        choiceActions = list.map { $0.1 }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.alignment = .left
        for (i, item) in list.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(doChoice(_:)))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 9
            b.layer?.backgroundColor = Theme.fg.withAlphaComponent(0.09).cgColor
            b.layer?.borderWidth = 1
            b.layer?.borderColor = kAmber.withAlphaComponent(0.35).cgColor
            b.attributedTitle = NSAttributedString(string: item.0, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.fg, .paragraphStyle: para])
            b.cell?.wraps = true
            b.cell?.lineBreakMode = .byWordWrapping
            (b.cell as? NSButtonCell)?.imageScaling = .scaleNone
            b.toolTip = tip
            b.tag = i
            card.addSubview(b)
            choiceButtons.append(b)
        }
        if isShown { layout() }
    }
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

    func setActions(_ list: [(String, () -> Void)]) {
        for b in actionButtons { b.removeFromSuperview() }
        actionButtons = []
        actions = list.map { $0.1 }
        for (i, item) in list.enumerated() {
            let b = OCButton(title: item.0, target: self, action: #selector(doAction(_:)))
            b.bezelStyle = .rounded
            b.font = .systemFont(ofSize: list.count > 3 ? 12 : 13, weight: .medium)
            b.lineBreakMode = .byTruncatingTail
            if i == 0 { b.style = .primary }
            b.tag = i
            card.addSubview(b)
            actionButtons.append(b)
        }
    }

    /// A short note that retracts by itself.
    func notify(_ text: String, actions list: [(String, () -> Void)] = [], hold: Double? = nil) {
        chatMode = false
        tag = nil
        setChoices([])
        setActions(list)
        textView.textStorage?.setAttributedString(bubbleAttributed(L10n.t(text)))   // UI hints follow the app language
        if isShown {
            // Already on screen: swap content instantly, no fade.
            panel.animator().alphaValue = 1
            layout()
            panel.orderFrontRegardless()
        } else {
            present(makeKey: false)
        }
        scheduleHide(after: hold ?? min(15, 4 + Double(text.count) * 0.08 + (list.isEmpty ? 0 : 4)))
    }

    /// Inside an open chat: show a short hint with buttons, keeping the chat box and its input.
    func offerInChat(_ text: String, actions list: [(String, () -> Void)]) {
        setChoices([])
        setActions(list)
        textView.textStorage?.setAttributedString(bubbleAttributed(L10n.t(text)))
        layout()
        panel.orderFrontRegardless()
    }

    /// Put text in the chat input and focus it (the user finishes the question).
    func prefill(_ text: String) {
        if !chatMode { openChat(greeting: nil) }
        setActions([])
        input.stringValue = text
        panel.makeKey()
        panel.makeFirstResponder(input)
        input.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        layout()
    }

    /// Open the quick-chat box.
    func openChat(greeting: String?) {
        chatMode = true
        tag = nil
        setChoices([])
        setActions([])
        hideTimer?.invalidate()
        if let g = greeting { textView.textStorage?.setAttributedString(bubbleAttributed(g)) }
        present(makeKey: true)
        panel.makeFirstResponder(input)
    }

    func setText(_ text: String) {
        textView.textStorage?.setAttributedString(bubbleAttributed(text))
        if isShown { layout() }
    }

    func setListening(_ on: Bool) { if let b = micButton { styleVoiceButton(b, listening: on) } }

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

    /// Level icons right after the title: ~11pt, amber glow, no "Lv" text; hidden at Lv0 and while reading aloud.
    private func layoutLevel(titleY y: CGFloat, speaking: Bool) {
        let lc = CatLevel.shared
        let lv = lc.level
        let x = title.frame.minX + ceil(title.attributedStringValue.size().width) + 5
        let limit = chatMode ? signalButton.frame.minX - 2 : width - 14
        var img = RankIcon.strip(level: lv, height: 11)
        if img.size.width > limit - x { img = RankIcon.strip(level: lv, height: 11, maxRepeat: 1) }
        guard lv > 0, !speaking, img.size.width <= limit - x else { levelButton.isHidden = true; return }
        levelButton.image = img
        levelButton.frame = NSRect(x: x, y: y - 1, width: img.size.width, height: 16)
        levelButton.toolTip = L10n.english ? "Lv\(lv) · \(lc.days) days together" : "Lv\(lv) · 已陪伴 \(lc.days) 天"
        levelButton.isHidden = false
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
        // Action buttons: equal widths filling the row (up to 4 per row; 2 per row when a title is long).
        let actGap: CGFloat = 6
        let longest = actionButtons.map { ceil($0.intrinsicContentSize.width) }.max() ?? 0
        var perRow = min(4, max(1, actionButtons.count))
        while perRow > 1 && (inner - actGap * CGFloat(perRow - 1)) / CGFloat(perRow) < longest { perRow -= 1 }
        let actRows = actionButtons.isEmpty ? 0 : (actionButtons.count + perRow - 1) / perRow
        let actionH: CGFloat = actRows == 0 ? 0 : CGFloat(actRows) * 30 + CGFloat(actRows - 1) * actGap + 10
        let choiceW = inner
        var choiceHs: [CGFloat] = []
        for b in choiceButtons {
            let r = b.attributedTitle.boundingRect(with: NSSize(width: choiceW - 20, height: 1000),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
            choiceHs.append(ceil(r.height) + 14)
        }
        let choicesH: CGFloat = choiceHs.reduce(0) { $0 + $1 + 6 } + (choiceHs.isEmpty ? 0 : 4)
        let chatH: CGFloat = chatMode ? 44 : 0
        let showChip = chatMode && shareTitle != nil
        let chipH: CGFloat = showChip ? 32 : 0
        let h = pad + 18 + 10 + textH + choicesH + actionH + chipH + chatH + pad

        var y = h - pad - 16
        title.frame = NSRect(x: pad, y: y, width: 120, height: 16)
        // Header buttons hug their text (right to left) so 📶 and the level icons fit next to them.
        // Amber chips (OCButton.chip) with a small gap between them.
        let fitW: (NSButton, CGFloat) -> CGFloat = { b, maxW in min(maxW, ceil(b.intrinsicContentSize.width)) }
        let gap: CGFloat = 6
        let ew = fitW(expandButton, 110), tw = fitW(topicsButton, 120), qw = fitW(squareButton, 90), sw = fitW(signalButton, 96)
        expandButton.frame = NSRect(x: width - pad - ew, y: y - 2, width: ew, height: 20)
        expandButton.isHidden = !chatMode
        topicsButton.frame = NSRect(x: expandButton.frame.minX - gap - tw, y: y - 2, width: tw, height: 20)
        topicsButton.isHidden = !chatMode
        // Read-aloud controls sit right after the "OrdCat" title.
        let speaking = speakState != 0
        squareButton.frame = NSRect(x: topicsButton.frame.minX - gap - qw, y: y - 2, width: qw, height: 20)
        squareButton.isHidden = !chatMode || speaking
        signalButton.frame = NSRect(x: squareButton.frame.minX - gap - sw, y: y - 2, width: sw, height: 20)
        signalButton.isHidden = !chatMode || speaking
        layoutLevel(titleY: y, speaking: speaking)
        speakPause.isHidden = !speaking
        speakStop.isHidden = !speaking
        if speaking {
            speakPause.frame = NSRect(x: pad + 58, y: y - 2, width: 22, height: 20)
            speakStop.frame = NSRect(x: pad + 82, y: y - 2, width: 22, height: 20)
        }
        y -= 10 + textH
        scroll.frame = NSRect(x: pad, y: y, width: inner, height: textH)
        textView.frame = NSRect(x: 0, y: 0, width: inner, height: max(used, textH))
        if !choiceButtons.isEmpty {
            y -= 4
            for (i, b) in choiceButtons.enumerated() {
                y -= choiceHs[i] + 6
                b.frame = NSRect(x: pad, y: y + 3, width: choiceW, height: choiceHs[i])
            }
        }
        if !actionButtons.isEmpty {
            y -= actionH
            let bw = floor((inner - actGap * CGFloat(perRow - 1)) / CGFloat(perRow))
            for (i, b) in actionButtons.enumerated() {
                let row = i / perRow, col = i % perRow
                let by = y + actionH - 4 - CGFloat(row + 1) * 30 - CGFloat(row) * actGap
                b.frame = NSRect(x: pad + CGFloat(col) * (bw + actGap), y: by, width: bw, height: 30)
            }
        }
        shareChip.isHidden = !showChip
        shareClose.isHidden = !showChip || !sharing
        if showChip {
            y -= chipH
            shareChip.sizeToFit()
            let cw = min(inner - 28, shareChip.frame.width + 14)
            shareChip.frame = NSRect(x: pad, y: y + 6, width: cw, height: 22)
            shareClose.frame = NSRect(x: pad + cw + 4, y: y + 6, width: 22, height: 22)
        }
        input.isHidden = !chatMode
        sendButton.isHidden = !chatMode
        micButton.isHidden = !chatMode
        if micButton.image != nil && micButton.contentTintColor == nil { micButton.toolTip = voiceTip() }
        if chatMode {
            y -= chatH
            // Input, voice and send share one 30pt row with even 6pt gaps.
            input.frame = NSRect(x: pad, y: y + 8, width: inner - 6 - 40 - 6 - 64, height: 30)
            micButton.frame = NSRect(x: pad + inner - 64 - 6 - 40, y: y + 8, width: 40, height: 30)
            sendButton.frame = NSRect(x: pad + inner - 64, y: y + 8, width: 64, height: 30)
        }

        let head = anchor()
        var x = head.x - width - 130
        var yy = head.y - h / 2 + 30
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

final class ChatWindowController: NSObject, NSWindowDelegate, NSSplitViewDelegate {
    private var window: NSWindow?
    private let store: ChatStore
    private var sidebar: ChatSidebar!
    private var split: NSSplitView!
    private var deleteButton: NSButton!
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
    var onOpenAccount: (() -> Void)?

    var isVisible: Bool { window?.isVisible ?? false }

    init(store: ChatStore) {
        self.store = store
        super.init()
        store.observe { [weak self] structural in
            guard let self = self, self.isVisible else { return }
            if structural { self.sidebar?.reload(); self.updateTitle() }
            self.queueRender()
        }
    }

    private func updateTitle() {
        guard let w = window else { return }
        let c = store.currentConversation
        var t = c?.title ?? store.pendingTitleShown ?? "新对话"
        if let p = store.currentProject { t = "\(p.emoji) \(p.name) · " + t }
        w.title = t + " — OrdCat 🐈‍⬛"
        deleteButton?.isEnabled = c != nil
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 180 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 380 }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { subview === sidebar?.view }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        // Keep the sidebar's width when the window is resized; the chat takes the rest.
        guard splitView.subviews.count == 2 else { splitView.adjustSubviews(); return }
        let side = splitView.subviews[0], main = splitView.subviews[1]
        let H = splitView.bounds.height, W = splitView.bounds.width
        let sw = side.isHidden ? 0 : min(side.frame.width, max(0, W - 300))
        let d = side.isHidden ? 0 : splitView.dividerThickness
        side.frame = NSRect(x: 0, y: 0, width: sw, height: H)
        main.frame = NSRect(x: sw + d, y: 0, width: W - sw - d, height: H)
    }
    @objc private func toggleSidebar() {
        guard let side = sidebar?.view, let split = split else { return }
        side.isHidden.toggle()
        if !side.isHidden && side.frame.width < 180 { side.frame.size.width = 240 }
        split.adjustSubviews()
        split.needsLayout = true
        UserDefaults.standard.set(side.isHidden, forKey: "chatSidebarHidden")
    }
    @objc private func deleteCurrent() {
        guard let c = store.currentConversation else { return }
        let a = NSAlert()
        a.messageText = "删除对话「\(c.title)」？"
        a.informativeText = "删除后无法恢复。"
        a.addButton(withTitle: "删除")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { store.deleteConversation(c.id) }
    }

    func show() {
        if window == nil { build() }
        sidebar.reload()
        updateTitle()
        render()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(input)
    }

    func setListening(_ on: Bool, partial: String? = nil) {
        if let b = micButton { styleVoiceButton(b, listening: on) }
        if let p = partial, isVisible { input.stringValue = p }
        if !on && isVisible { input.stringValue = "" }
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "和 OrdCat 聊天 🐈‍⬛"
        w.minSize = NSSize(width: 420, height: 360)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("OrdCatChat2")
        let root = DropView(frame: w.contentRect(forFrameRect: w.frame))
        root.onFiles = { [weak self] urls in self?.add(urls) }
        w.contentView = root

        // Left: chats, categories and projects. Right: the open chat.
        split = NSSplitView(frame: root.bounds)
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        split.delegate = self
        sidebar = ChatSidebar(store: store)
        sidebar.window = w
        sidebar.onClearAll = { [weak self] in self?.clearHistory() }
        sidebar.onAccount = { [weak self] in self?.onOpenAccount?() }
        let side = sidebar.view
        side.frame = NSRect(x: 0, y: 0, width: 240, height: root.bounds.height)
        let v = NSView(frame: NSRect(x: 241, y: 0, width: root.bounds.width - 241, height: root.bounds.height))
        split.addSubview(side)
        split.addSubview(v)
        root.addSubview(split)
        side.isHidden = UserDefaults.standard.bool(forKey: "chatSidebarHidden")
        split.adjustSubviews()
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

        let sideB = NSButton(title: "◧", target: self, action: #selector(toggleSidebar))
        sideB.bezelStyle = .rounded
        sideB.controlSize = .small
        sideB.toolTip = "显示/隐藏左侧的对话和项目栏"
        sideB.frame = NSRect(x: 10, y: 64, width: 34, height: 26)
        sideB.autoresizingMask = [.maxXMargin, .maxYMargin]
        v.addSubview(sideB)

        deleteButton = OCButton(title: "删除对话", target: self, action: #selector(deleteCurrent))
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small
        deleteButton.toolTip = "删除正在看的这个对话（全部清空在左栏右键或设置里）"
        deleteButton.frame = NSRect(x: 48, y: 64, width: 76, height: 26)
        deleteButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        v.addSubview(deleteButton)

        attachLabel.frame = NSRect(x: 132, y: 68, width: W - 230, height: 18)
        attachLabel.textColor = .secondaryLabelColor
        attachLabel.font = .systemFont(ofSize: 12)
        attachLabel.lineBreakMode = .byTruncatingMiddle
        attachLabel.autoresizingMask = [.width, .maxYMargin]
        v.addSubview(attachLabel)

        clearAttach = OCButton(title: "移除附件", target: self, action: #selector(removeAttachments))
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

        micButton = iconButton("", self, #selector(mic), tip: voiceTip())
        styleVoiceButton(micButton, listening: false)
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
    @objc func clearHistory() {
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
        let msgs = store.currentMessages
        if msgs.isEmpty {
            let hello = store.currentProject.map { "新对话 · \($0.emoji) \($0.name)\n" + ($0.note.isEmpty ? "" : "小猫会记着这个项目的说明。\n") } ?? ""
            out.append(NSAttributedString(string: hello + "在下面和小猫打个招呼吧 🐾\n",
                                          attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        for m in msgs {
            let isUser = m.role == "user"
            let para = NSMutableParagraphStyle()
            para.alignment = isUser ? .right : .left
            para.paragraphSpacingBefore = 12
            let bodyPara = NSMutableParagraphStyle()
            bodyPara.alignment = isUser ? .right : .left
            bodyPara.lineSpacing = 3
            if !isUser {
                let eyes = NSTextAttachment()
                eyes.image = ordEyesImage(height: 10, glow: false)
                eyes.bounds = CGRect(x: 0, y: -1, width: eyes.image!.size.width, height: eyes.image!.size.height)
                let e = NSMutableAttributedString(attachment: eyes)
                e.append(NSAttributedString(string: " "))
                e.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: e.length))
                out.append(e)
            }
            out.append(NSAttributedString(string: (isUser ? "你" : "OrdCat") + " · " + df.string(from: m.date) + "\n",
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

/// Settings pages in sidebar order. Open pages by name, never by number (the order can change).
enum SettingsPage: Int, CaseIterable {
    case user, cat, model, voice, memory, skills, square, signal, about
}

final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let preset = NSPopUpButton()
    private let base = NSTextField()
    private let key = NSSecureTextField()
    private let model = NSTextField()
    private let status = SK.WrapLabel()
    // 看图 / 听写 panes of the model tab
    private var modelPanes: [NSView] = []
    private let modelPaneHost = NSStackView()
    /// Only the chosen sub-page (聊天/看图/听写/朗读) is in the layout, stretched to the page width.
    private func showModelPane(_ i: Int) {
        for v in modelPaneHost.arrangedSubviews { modelPaneHost.removeArrangedSubview(v); v.removeFromSuperview() }
        guard i >= 0, i < modelPanes.count else { return }
        let v = modelPanes[i]
        v.translatesAutoresizingMaskIntoConstraints = false
        modelPaneHost.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: modelPaneHost.widthAnchor).isActive = true
    }
    private let visionPreset = NSPopUpButton()
    private let visionBase = NSTextField()
    private let visionKey = NSSecureTextField()
    private let visionModel = NSTextField()
    private let visionStatus = SK.WrapLabel()
    private let sttPreset = NSPopUpButton()
    private let sttBase = NSTextField()
    private let sttKey = NSSecureTextField()
    private let sttModel = NSTextField()
    private let sttStatus = SK.WrapLabel()
    private let hotkeyPopup = NSPopUpButton()
    private let appearancePopup = NSPopUpButton()
    private let languagePopup = NSPopUpButton()
    private var checks: [String: NSSwitch] = [:]
    private let axStatus = SK.WrapLabel()
    private let llm = LLM()
    private let perceptionPopup = NSPopUpButton()
    private let retentionPopup = NSPopUpButton()
    private let excluded = NSTextField()
    private let memStats = SK.WrapLabel()
    private let versionLabel = NSTextField(labelWithString: "")
    private let updateStatus = SK.WrapLabel()
    private let notesLabel = SK.WrapLabel()
    private let signLabel = SK.WrapLabel()
    private var updateButton: NSButton!
    private let retentionOptions = [1, 3, 7, 30, 0]   // 0 = 永久
    var hub: ContextHub?
    var voice: Voice?
    var xbuddy: XCompanion?
    let skillsPane = SkillsPane()
    let squarePane = SquarePane()
    let accountPane = AccountPane()
    let signalPane = SignalPane()
    private let enginePopup = NSPopUpButton()
    private let sysVoicePopup = NSPopUpButton()
    private let rateSlider = NSSlider(value: 0.5, minValue: 0.35, maxValue: 0.65, target: nil, action: nil)
    private let pitchSlider = NSSlider(value: 1.0, minValue: 0.8, maxValue: 1.25, target: nil, action: nil)
    private let ttsPresetPopup = NSPopUpButton()
    private let ttsBase = NSTextField()
    private let ttsKey = NSSecureTextField()
    private let ttsModel = NSTextField()
    private let ttsVoiceBox = NSComboBox()
    private let ttsStatus = SK.WrapLabel()
    private var sysVoiceIDs: [String] = []
    var onHotKeyChanged: (() -> Void)?
    var onClearHistory: (() -> Void)?
    var onPerceptionChanged: (() -> Void)?
    var onPreviewContext: (() -> Void)?

    func show(page: SettingsPage = .model) {
        if window == nil { build() }
        skillsPane.refresh()
        squarePane.refresh()
        accountPane.refresh()
        signalPane.refresh()
        base.stringValue = Prefs.base
        model.stringValue = Prefs.model
        key.stringValue = Keychain.get()
        preset.selectItem(at: presetIndex(forBase: Prefs.base))
        visionPreset.selectItem(at: capPresetIndex(kVisionPresets, stored: Prefs.visionPreset, base: Prefs.visionBase))
        visionBase.stringValue = Prefs.visionBase
        visionModel.stringValue = Prefs.visionModel
        visionKey.stringValue = Keychain.get(service: Keychain.visionService)
        sttPreset.selectItem(at: capPresetIndex(kSTTPresets, stored: Prefs.sttPreset, base: Prefs.sttBase))
        sttBase.stringValue = Prefs.sttBase
        sttModel.stringValue = Prefs.sttModel
        sttKey.stringValue = Keychain.get(service: Keychain.sttService)
        checks["visionOn"]?.state = Prefs.visionOn ? .on : .off
        checks["videoAudio"]?.state = Prefs.videoAudio ? .on : .off
        checks["chatLayout"]?.state = Prefs.chatLayout ? .on : .off
        refreshVisionHint()
        sttStatus.stringValue = ""
        hotkeyPopup.selectItem(at: Prefs.hotKeyIndex)
        checks["voice"]?.state = Prefs.voice ? .on : .off
        checks["pageShare"]?.state = Prefs.pageShare ? .on : .off
        refreshVoiceTab()
        checks["voiceChat"]?.state = Prefs.voiceChat ? .on : .off
        checks["selectWatch"]?.state = Prefs.selectWatch ? .on : .off
        checks["selectFallback"]?.state = Prefs.selectFallback ? .on : .off
        checks["clipWatch"]?.state = Prefs.clipWatch ? .on : .off
        checks["care"]?.state = Prefs.care ? .on : .off
        checks["perception"]?.state = Prefs.perception ? .on : .off
        checks["ocrFallback"]?.state = Prefs.ocrFallback ? .on : .off
        checks["sendScreenshot"]?.state = Prefs.sendScreenshot ? .on : .off
        checks["highlight"]?.state = Prefs.highlight ? .on : .off
        checks["xMode"]?.state = Prefs.xMode ? .on : .off
        checks["autoUpdate"]?.state = Prefs.autoUpdate ? .on : .off
        perceptionPopup.selectItem(at: Prefs.perceptionHotKeyIndex)
        retentionPopup.selectItem(at: retentionOptions.firstIndex(of: Prefs.retentionDays) ?? 2)
        excluded.stringValue = Prefs.excludedApps
        refreshMemStats()
        refreshUpdate()
        refreshSign()
        refreshAX()
        status.stringValue = ""
        select(page: page)
        NSApp.activate(ignoringOtherApps: true)
        if !restoredFrame { window?.center(); restoredFrame = true }
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshMemStats() {
        guard let hub = hub else { return }
        let st = hub.memory.stats()
        let mb = String(format: "%.1f", Double(st.bytes) / 1_048_576)
        let rec = ScreenReader.screenRecordingAllowed() ? "已授权" : "未授权"
        memStats.stringValue = "记忆 \(st.count) 条 · \(mb) MB · 本次保留 \(hub.keptFrames) 帧 / 丢弃重复 \(hub.droppedFrames) 帧\n向量引擎：\(hub.memory.vectorEngine) · 全文检索：\(hub.memory.ftsOK ? "FTS5" : "LIKE") · 屏幕录制：\(rec)"

    }

    func refreshX() {
        skillsPane.refresh()
    }

    func refreshUpdate() {
        let u = Updater.shared
        versionLabel.stringValue = "OrdCat  v\(u.current)"
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

    // MARK: layout (sidebar + pages, native Auto Layout, nothing scaled)

    private var pages: [NSScrollView] = []
    private var sidebar: SettingsSidebar?
    private var pageHost = NSView()
    private var current = 0
    private var restoredFrame = false

    private func select(page: SettingsPage) {
        let i = page.rawValue
        guard i >= 0, i < pages.count else { return }
        current = i
        for (k, p) in pages.enumerated() { p.isHidden = k != i }
        sidebar?.select(i)
        pages[i].contentView.scroll(to: .zero)
        pages[i].reflectScrolledClipView(pages[i].contentView)
    }

    /// Switch row bound to a Prefs key through `toggled(_:)`.
    private func sw(_ id: String, _ title: String, sub: String? = nil) -> NSView {
        let s = NSSwitch()
        s.identifier = NSUserInterfaceItemIdentifier(id)
        s.target = self
        s.action = #selector(toggled(_:))
        checks[id] = s
        return SK.toggle(title, s, sub: sub)
    }

    private func field(_ f: NSTextField) -> NSTextField {
        f.translatesAutoresizingMaskIntoConstraints = false
        f.font = .systemFont(ofSize: 13)
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.usesSingleLineMode = true
        return f
    }

    private func build() {
        let saved = UserDefaults.standard.string(forKey: "settingsFrame3").map(NSRectFromString)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "OrdCat 设置 · v\(Updater.shared.current)"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 640, height: 440)
        if let f = saved, f.width >= 640, f.height >= 440 { w.setFrame(f, display: false); restoredFrame = true }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 580))
        w.contentView = root
        // Never let Auto Layout shrink the window to nothing (pages have no fixed height of their own).
        w.contentMinSize = NSSize(width: 640, height: 440)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 640),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 440)])
        let side = SettingsSidebar(items: [
            ("person.crop.circle", "用户"), ("pawprint", "小猫"), ("cpu", "模型"), ("speaker.wave.2", "声音"),
            ("eye", "感知与记忆"), ("sparkles", "技能"), ("fish", "猫帮圈"),
            ("antenna.radiowaves.left.and.right", "信号站"), ("info.circle", "关于")])
        side.onSelect = { [weak self] i in if let pg = SettingsPage(rawValue: i) { self?.select(page: pg) } }
        sidebar = side
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        pageHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(side); root.addSubview(divider); root.addSubview(pageHost)
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            side.widthAnchor.constraint(equalToConstant: 190),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            pageHost.topAnchor.constraint(equalTo: root.topAnchor),
            pageHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pageHost.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            pageHost.trailingAnchor.constraint(equalTo: root.trailingAnchor)])

        // Pages are built in their original order (some share controls), then shown in sidebar order.
        let built: [(SettingsPage, SK.Page)] = [(.model, modelPage()), (.cat, catPage()), (.memory, memoryPage()),
                                                (.voice, voicePage()), (.skills, skillsPage()), (.square, squarePage()),
                                                (.about, aboutPage()), (.user, accountPage()), (.signal, signalPage())]
        for pg in SettingsPage.allCases {
            guard let page = built.first(where: { $0.0 == pg })?.1 else { continue }
            let sv = page.scroller()
            pageHost.addSubview(sv)
            NSLayoutConstraint.activate([
                sv.topAnchor.constraint(equalTo: pageHost.topAnchor),
                sv.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor),
                sv.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
                sv.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor)])
            pages.append(sv)
        }
        if !restoredFrame { w.setContentSize(NSSize(width: 780, height: 580)) }
        w.delegate = self
        window = w
        select(page: .model)
    }

    // 模型
    private func modelPage() -> SK.Page {
        let p = SK.Page(title: "模型")
        for x in kPresets { preset.addItem(withTitle: x.name) }
        preset.target = self
        preset.action = #selector(presetChanged)
        base.placeholderString = "https://…/v1"
        key.placeholderString = "本地 Ollama 可留空"
        model.placeholderString = "模型名称"
        let seg = NSSegmentedControl(labels: ["💬 聊天", "🖼️ 看图 / 视频", "🎙️ 听写", "🔊 朗读"],
                                     trackingMode: .selectOne, target: self, action: #selector(modelPaneChanged(_:)))
        seg.selectedSegment = 0
        seg.segmentDistribution = .fillEqually
        p.add(seg, gap: 16)

        // 聊天
        let chat = NSStackView()
        chat.orientation = .vertical; chat.alignment = .leading; chat.spacing = 10
        func put(_ v: NSView, in s: NSStackView) {
            v.translatesAutoresizingMaskIntoConstraints = false
            s.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        }
        let g1 = SK.Group()
        g1.add(SK.row("服务商", preset))
        g1.add(SK.row("接口地址", field(base)))
        g1.add(SK.row("API Key", field(key)))
        g1.add(SK.row("模型", field(model)))
        put(g1, in: chat)
        put(SK.WrapLabel("任何 OpenAI 兼容接口都能用。API Key 只保存在你 Mac 的钥匙串里。聊天模型只懂文字也没关系：图片会交给「看图」模型，声音交给「听写」。"), in: chat)
        put(status, in: chat)
        let save = SK.button("保存", self, #selector(saveIt))
        save.keyEquivalent = "\r"
        put(SK.buttons([SK.button("测试连接", self, #selector(testIt)), save], trailing: true), in: chat)

        // 看图 / 视频
        let vis = NSStackView()
        vis.orientation = .vertical; vis.alignment = .leading; vis.spacing = 10
        for x in kVisionPresets { visionPreset.addItem(withTitle: x.name) }
        visionPreset.target = self
        visionPreset.action = #selector(visionPresetChanged)
        visionBase.placeholderString = "https://…/v1"
        visionKey.placeholderString = "和聊天同一家可留空"
        visionModel.placeholderString = "看图模型名称"
        let gv0 = SK.Group()
        gv0.add(sw("visionOn", "需要时看图片和视频画面", sub: "只在你提问时截这个窗口"))
        put(gv0, in: vis)
        let gv = SK.Group()
        gv.add(SK.row("服务商", visionPreset))
        gv.add(SK.row("接口地址", field(visionBase)))
        gv.add(SK.row("API Key", field(visionKey)))
        gv.add(SK.row("模型", field(visionModel)))
        put(gv, in: vis)
        let gv2 = SK.Group()
        gv2.add(sw("videoAudio", "看视频时顺便听 6 秒声音", sub: "用「听写」转成文字"))
        gv2.add(sw("chatLayout", "聊天软件（微信、QQ…）按位置识别谁说了什么"))
        put(gv2, in: vis)
        put(visionStatus, in: vis)
        put(SK.buttons([SK.button("测试看图", self, #selector(testVision)), SK.button("保存", self, #selector(saveIt))], trailing: true), in: vis)

        // 听写
        let stt = NSStackView()
        stt.orientation = .vertical; stt.alignment = .leading; stt.spacing = 10
        for x in kSTTPresets { sttPreset.addItem(withTitle: x.name) }
        sttPreset.target = self
        sttPreset.action = #selector(sttPresetChanged)
        sttBase.placeholderString = "https://…/v1"
        sttKey.placeholderString = "和聊天同一家可留空"
        sttModel.placeholderString = "语音识别模型名称"
        let gs = SK.Group()
        gs.add(SK.row("服务商", sttPreset))
        gs.add(SK.row("接口地址", field(sttBase)))
        gs.add(SK.row("API Key", field(sttKey)))
        gs.add(SK.row("模型", field(sttModel)))
        put(gs, in: stt)
        put(SK.WrapLabel("用在两个地方：你对小猫说话（⌃⌥空格 / 🎤），和看视频时听声音。本机识别完全离线；云端 Whisper 更准，会把录音发给你选的服务商。"), in: stt)
        put(sttStatus, in: stt)
        put(SK.buttons([SK.button("测试听写", self, #selector(testSTT)), SK.button("保存", self, #selector(saveIt))], trailing: true), in: stt)

        // 朗读
        let tts = NSStackView()
        tts.orientation = .vertical; tts.alignment = .leading; tts.spacing = 12
        put(SK.WrapLabel("小猫说话的声音（系统声音或云端自然声音、语速、音调）在「声音」标签里设置。", size: 13, secondary: false), in: tts)
        put(SK.buttons([SK.button("去「声音」设置", self, #selector(goVoiceTab))]), in: tts)

        modelPanes = [chat, vis, stt, tts]
        modelPaneHost.orientation = .vertical
        modelPaneHost.alignment = .leading
        p.add(modelPaneHost)
        showModelPane(0)
        return p
    }

    // 小猫
    private func catPage() -> SK.Page {
        let p = SK.Page(title: "小猫")
        p.header("外观与语言")
        appearancePopup.addItems(withTitles: ["跟随系统", "浅色", "深色"])
        appearancePopup.selectItem(at: max(0, min(2, Theme.mode)))
        appearancePopup.target = self
        appearancePopup.action = #selector(appearanceChanged)
        languagePopup.addItems(withTitles: ["中文", "English"])
        languagePopup.selectItem(at: L10n.english ? 1 : 0)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        let g0 = SK.Group()
        g0.add(SK.row("外观", appearancePopup, fill: false, maxW: 200))
        g0.add(SK.row("语言", languagePopup, fill: false, maxW: 200))
        p.add(g0)
        p.hint("切换语言后重启 OrdCat 生效。")

        p.header("说话")
        for h in kHotKeys { hotkeyPopup.addItem(withTitle: h.title) }
        hotkeyPopup.target = self
        hotkeyPopup.action = #selector(hotkeyChanged)
        let g1 = SK.Group()
        g1.add(sw("voiceChat", "开启语音对话", sub: "按快捷键或 🎤 和小猫说话"))
        g1.add(SK.row("快捷键", hotkeyPopup, fill: false, maxW: 300))
        g1.add(sw("pageShare", "打开对话时分享当前页面", sub: "气泡里点 ✕ 就不分享"))
        p.add(g1)

        p.header("陪伴")
        let g2 = SK.Group()
        g2.add(sw("selectWatch", "选中文字时竖起耳朵提示"))
        g2.add(sw("selectFallback", "兼容模式", sub: "读不到选中内容时，自动复制再还原剪贴板"))
        g2.add(sw("clipWatch", "复制文字时提示"))
        g2.add(sw("care", "久坐 / 熬夜温柔提醒"))
        p.add(g2)

        p.header("权限")
        axStatus.font = .systemFont(ofSize: 13)
        let g3 = SK.Group()
        g3.add(SK.info(axStatus, SK.button("授权辅助功能", self, #selector(askAX))))
        p.add(g3)
        p.hint("选中文字提示需要「辅助功能」权限：系统设置 → 隐私与安全性 → 辅助功能，打开 OrdCat。从 v0.2.8 起小猫用这台 Mac 自己的签名，授权一次以后更新不会再丢。如果开关是开着却没用，先用「−」删掉旧的 OrdCat 再重新添加。")

        p.space(20)
        p.add(SK.buttons([SK.button("清空聊天记录", self, #selector(clearHistory))]))
        return p
    }

    // 感知与记忆
    private func memoryPage() -> SK.Page {
        let p = SK.Page(title: "感知与记忆")
        for h in kPerceptionHotKeys { perceptionPopup.addItem(withTitle: h.title) }
        perceptionPopup.target = self
        perceptionPopup.action = #selector(perceptionHotkeyChanged)
        let g1 = SK.Group()
        g1.add(sw("perception", "开启桌面感知", sub: "回答时参考你屏幕上的内容"))
        g1.add(SK.row("快捷键", perceptionPopup, fill: false, maxW: 300))
        g1.add(sw("ocrFallback", "读不到文字时用 OCR 识别", sub: "需要「屏幕录制」权限"))
        g1.add(sw("sendScreenshot", "提问时附带当前窗口截图", sub: "需要识图模型"))
        g1.add(sw("highlight", "回答里指到的位置，在屏幕上高亮出来"))
        p.add(g1)

        p.header("记忆")
        for d in retentionOptions { retentionPopup.addItem(withTitle: d == 0 ? "永久" : "\(d) 天") }
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChanged)
        excluded.placeholderString = "Bundle ID，用逗号分隔，例如 com.tencent.xinWeChat"
        excluded.target = self
        excluded.action = #selector(excludedChanged)
        let g2 = SK.Group()
        g2.add(SK.row("记忆保留", retentionPopup, fill: false, maxW: 140))
        g2.add(SK.row("排除应用", field(excluded)))
        p.add(g2)
        p.add(memStats)
        p.hint("「陪你刷推」等技能在 设置 → 技能 里开关。")
        p.space(20)
        p.add(SK.buttons([SK.button("授权屏幕录制", self, #selector(askScreen)),
                          SK.button("查看当前上下文", self, #selector(previewContext)),
                          SK.button("清空记忆", self, #selector(clearMemory)),
                          SK.button("数据文件夹", self, #selector(openData))]))
        return p
    }

    // 声音
    private func voicePage() -> SK.Page {
        let p = SK.Page(title: "声音")
        enginePopup.addItems(withTitles: ["系统声音（离线、免费）", "云端自然声音（更像真人）"])
        enginePopup.target = self; enginePopup.action = #selector(voiceChanged)
        sysVoicePopup.target = self; sysVoicePopup.action = #selector(voiceChanged)
        rateSlider.target = self; rateSlider.action = #selector(voiceChanged)
        pitchSlider.target = self; pitchSlider.action = #selector(voiceChanged)
        let g1 = SK.Group()
        g1.add(sw("voice", "用语音读出小猫的回复"))
        g1.add(SK.row("声音来源", enginePopup))
        g1.add(SK.row("系统声音", sysVoicePopup))
        g1.add(SK.row("语速", rateSlider))
        g1.add(SK.row("音调", pitchSlider))
        p.add(g1)
        p.hint("想更自然：系统设置 → 辅助功能 → 朗读内容 → 系统声音 → 管理声音，下载带「高级」或「增强」的中文声音（如 Lilian、Tingting 增强版），装好后在上面选。")

        p.header("云端声音")
        for x in kTTSPresets { ttsPresetPopup.addItem(withTitle: x.name) }
        ttsPresetPopup.target = self; ttsPresetPopup.action = #selector(ttsPresetChanged)
        ttsBase.placeholderString = "https://…/v1"
        ttsKey.placeholderString = "云端声音的 API Key（只存在本机钥匙串）"
        ttsModel.placeholderString = "模型"
        ttsVoiceBox.completes = false
        ttsVoiceBox.translatesAutoresizingMaskIntoConstraints = false
        let g2 = SK.Group()
        g2.add(SK.row("云端服务", ttsPresetPopup))
        g2.add(SK.row("接口地址", field(ttsBase)))
        g2.add(SK.row("API Key", field(ttsKey)))
        g2.add(SK.row("模型", field(ttsModel)))
        g2.add(SK.row("声音", ttsVoiceBox))
        p.add(g2)
        p.add(ttsStatus)
        let saveV = SK.button("保存", self, #selector(saveVoice))
        p.add(SK.buttons([SK.button("▶︎ 试听", self, #selector(testVoice)), saveV], trailing: true))
        return p
    }

    // 技能
    private func skillsPage() -> SK.Page {
        let p = SK.Page(title: "技能")
        skillsPane.build(xbuddy: xbuddy, into: p)
        return p
    }

    // 猫帮圈（功能，不是技能）
    private func squarePage() -> SK.Page {
        let p = SK.Page(title: "猫帮圈")
        squarePane.build(into: p)
        return p
    }

    // 信号站（功能，不是技能）
    private func signalPage() -> SK.Page {
        let p = SK.Page(title: "信号站")
        signalPane.build(into: p)
        return p
    }

    // 关于
    private func aboutPage() -> SK.Page {
        let p = SK.Page(title: "关于")
        versionLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        p.add(versionLabel, full: false, gap: 4)
        p.hint("A cozy cat in your island & desktop. Less burden, low power, always with you.")

        p.header("更新")
        updateStatus.font = .systemFont(ofSize: 13)
        updateStatus.textColor = .labelColor
        let g = SK.Group()
        g.add(SK.info(updateStatus))
        g.add(sw("autoUpdate", "自动检查更新（每 6 小时）"))
        p.add(g)
        updateButton = SK.button("立即更新", self, #selector(installUpdate))
        p.add(SK.buttons([SK.button("检查更新", self, #selector(checkUpdate)), updateButton,
                          SK.button("发布页", self, #selector(openReleases))]))

        p.header("客服与反馈")
        p.hint("有问题或建议，直接在 app 里找客服聊，或者发邮件到 support@ordcat.de。")
        p.add(SK.buttons([SK.button("💬 在线客服", self, #selector(supportChat)),
                          SK.button("✉️ 发邮件", self, #selector(supportMail))]))

        p.header("签名与授权")
        signLabel.font = .systemFont(ofSize: 12)
        signLabel.textColor = .labelColor
        let g2 = SK.Group()
        g2.add(SK.info(signLabel, SK.button("修复授权", self, #selector(repairSigning))))
        p.add(g2)

        p.header("更新内容")
        p.add(notesLabel)
        return p
    }

    // 账号
    private func accountPage() -> SK.Page {
        let p = SK.Page(title: "用户")
        accountPane.onOpenSkills = { [weak self] in self?.select(page: .skills) }
        accountPane.build(into: p)
        return p
    }

    @objc private func appearanceChanged() {
        Theme.mode = appearancePopup.indexOfSelectedItem
    }

    @objc private func languageChanged() {
        let en = languagePopup.indexOfSelectedItem == 1
        guard en != L10n.english else { return }
        L10n.english = en
        let a = NSAlert()
        a.messageText = en ? "Restart OrdCat to switch to English?" : "重启 OrdCat 切换到中文？"
        a.informativeText = en ? "The whole app, including the cat's replies, will use English." : "整个应用（包括小猫的回答）都会用中文。"
        a.addButton(withTitle: en ? "Restart now" : "立即重启")
        a.addButton(withTitle: en ? "Later" : "以后")
        if a.runModal() == .alertFirstButtonReturn {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "ordcat-relaunch", Bundle.main.bundlePath]
            try? p.run()
            NSApp.terminate(nil)
        }
    }

    func windowDidResize(_ notification: Notification) {
        if let w = window, w.frame.height >= 440 { UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: "settingsFrame3") }
    }
    func windowDidMove(_ notification: Notification) {
        if let w = window, w.frame.height >= 440 { UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: "settingsFrame3") }
    }

    @objc private func toggled(_ b: NSSwitch) {
        let on = b.state == .on
        switch b.identifier?.rawValue ?? "" {
        case "voice": Prefs.voice = on
        case "pageShare": Prefs.pageShare = on; if on { _ = SelectionWatcher.trusted(prompt: true) }
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
        case "xMode":
            Prefs.xMode = on
            if on { Prefs.xOffered = true; _ = SelectionWatcher.trusted(prompt: true) }
            refreshMemStats()
        case "autoUpdate": Prefs.autoUpdate = on
        case "visionOn":
            Prefs.visionOn = on
            if on && !ScreenReader.screenRecordingAllowed() { ScreenReader.requestScreenRecording() }
            refreshVisionHint()
        case "videoAudio":
            Prefs.videoAudio = on
            if on && !ScreenReader.screenRecordingAllowed() { ScreenReader.requestScreenRecording() }
        case "chatLayout":
            Prefs.chatLayout = on
            if on && !ScreenReader.screenRecordingAllowed() { ScreenReader.requestScreenRecording() }
        default: break
        }
    }

    // MARK: voice tab
    private func refreshVoiceTab() {
        enginePopup.selectItem(at: Prefs.ttsEngine)
        sysVoicePopup.removeAllItems()
        sysVoiceIDs = [""]
        sysVoicePopup.addItem(withTitle: "自动（选最自然的中文声音）")
        for v in Voice.systemVoices() {
            sysVoicePopup.addItem(withTitle: Voice.describe(v))
            sysVoiceIDs.append(v.identifier)
        }
        sysVoicePopup.selectItem(at: sysVoiceIDs.firstIndex(of: Prefs.sysVoiceID) ?? 0)
        rateSlider.doubleValue = Prefs.ttsRate
        pitchSlider.doubleValue = Prefs.ttsPitch
        ttsPresetPopup.selectItem(at: min(Prefs.ttsPreset, kTTSPresets.count - 1))
        ttsBase.stringValue = Prefs.ttsBase
        ttsModel.stringValue = Prefs.ttsModel
        ttsKey.stringValue = Keychain.get(service: Keychain.ttsService)
        fillVoiceBox(kTTSPresets[min(Prefs.ttsPreset, kTTSPresets.count - 1)])
        ttsVoiceBox.stringValue = Prefs.ttsVoice
        ttsStatus.stringValue = Prefs.ttsEngine == 1 ? "云端声音需要对应服务的 API Key；失败时会自动改用系统声音。" : ""
    }
    private func fillVoiceBox(_ p: TTSPreset) {
        ttsVoiceBox.removeAllItems()
        ttsVoiceBox.addItems(withObjectValues: p.voices.map { $0.id })
        ttsVoiceBox.toolTip = p.voices.map { "\($0.id)  \($0.label)" }.joined(separator: "\n")
    }
    @objc private func voiceChanged() {
        Prefs.ttsEngine = enginePopup.indexOfSelectedItem
        let i = sysVoicePopup.indexOfSelectedItem
        if i >= 0 && i < sysVoiceIDs.count { Prefs.sysVoiceID = sysVoiceIDs[i] }
        Prefs.ttsRate = rateSlider.doubleValue
        Prefs.ttsPitch = pitchSlider.doubleValue
    }
    @objc private func ttsPresetChanged() {
        let p = kTTSPresets[ttsPresetPopup.indexOfSelectedItem]
        Prefs.ttsPreset = ttsPresetPopup.indexOfSelectedItem
        if !p.base.isEmpty { ttsBase.stringValue = p.base; ttsModel.stringValue = p.model }
        fillVoiceBox(p)
        if let first = p.voices.first { ttsVoiceBox.stringValue = first.id }
    }
    @objc private func saveVoice() {
        guard OCConfirm.ask("保存声音设置？", "朗读引擎、声音和云端声音的地址、模型、Key 会换成现在填的内容。", ok: "保存") else { return }
        storeVoice()
    }
    private func storeVoice() {
        voiceChanged()
        Prefs.ttsBase = ttsBase.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Prefs.ttsModel = ttsModel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Prefs.ttsVoice = ttsVoiceBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(ttsKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), service: Keychain.ttsService)
        ttsStatus.stringValue = "✅ 已保存"
    }
    @objc private func testVoice() {
        storeVoice()
        ttsStatus.stringValue = Prefs.ttsEngine == 1 ? "正在请求云端声音…" : "▶︎ 系统声音试听中"
        voice?.onStatus = { [weak self] m in self?.ttsStatus.stringValue = m }
        voice?.speak("喵～我是 OrdCat。今天辛苦啦，要不要先喝口水，休息一下眼睛？我一直在这儿陪着你。")
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
    @objc private func supportChat() { Social.openSupport() }
    @objc private func supportMail() { Social.mailSupport() }
    @objc private func installUpdate() {
        guard OCConfirm.ask("现在安装更新？", "下载完成后 OrdCat 会自动重启，聊天记录和设置都会保留。", ok: "安装并重启") else { return }
        updateButton.isEnabled = false
        Updater.shared.install { [weak self] msg in self?.updateStatus.stringValue = msg }
    }
    @objc private func repairSigning() {
        guard OCConfirm.ask("修复授权？", "会用这台 Mac 的签名重新签 OrdCat，完成后自动退出，需要你再打开一次。", ok: "修复") else { return }
        signLabel.stringValue = "正在用这台 Mac 的签名重新签…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Updater.shared.repairSigning()
            DispatchQueue.main.async {
                self.signLabel.stringValue = r.message
                if r.ok { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) } }
            }
        }
    }
    private func refreshSign() {
        signLabel.stringValue = "正在检查签名…"
        DispatchQueue.global(qos: .utility).async {
            let st = LocalSigner.state()
            DispatchQueue.main.async { self.signLabel.stringValue = st.text }
        }
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
        let trim: (NSTextField) -> String = { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        Prefs.presetIndex = preset.indexOfSelectedItem
        Prefs.base = trim(base)
        Prefs.model = trim(model)
        Keychain.set(trim(key))
        Prefs.visionPreset = max(0, visionPreset.indexOfSelectedItem)
        Prefs.visionBase = trim(visionBase)
        Prefs.visionModel = trim(visionModel)
        Keychain.set(trim(visionKey), service: Keychain.visionService)
        Prefs.sttPreset = max(0, sttPreset.indexOfSelectedItem)
        Prefs.sttBase = trim(sttBase)
        Prefs.sttModel = trim(sttModel)
        Keychain.set(trim(sttKey), service: Keychain.sttService)
        refreshVisionHint()
    }

    @objc private func modelPaneChanged(_ seg: NSSegmentedControl) {
        showModelPane(seg.selectedSegment)
    }
    @objc private func goVoiceTab() { select(page: .voice) }

    @objc private func visionPresetChanged() {
        let p = kVisionPresets[visionPreset.indexOfSelectedItem]
        visionBase.stringValue = p.base
        visionModel.stringValue = p.model
        let auto = visionPreset.indexOfSelectedItem == 0
        visionBase.isEnabled = !auto; visionModel.isEnabled = !auto; visionKey.isEnabled = !auto
    }
    @objc private func sttPresetChanged() {
        let p = kSTTPresets[sttPreset.indexOfSelectedItem]
        sttBase.stringValue = p.base
        sttModel.stringValue = p.model
        let local = sttPreset.indexOfSelectedItem == 0
        sttBase.isEnabled = !local; sttModel.isEnabled = !local; sttKey.isEnabled = !local
    }

    private func refreshVisionHint() {
        let auto = Prefs.visionPreset == 0
        visionBase.isEnabled = !auto; visionModel.isEnabled = !auto; visionKey.isEnabled = !auto
        let local = Prefs.sttPreset == 0
        sttBase.isEnabled = !local; sttModel.isEnabled = !local; sttKey.isEnabled = !local
        var s: String
        if !Prefs.visionOn { s = "看图已关闭。" }
        else if let ep = Cap.vision {
            s = Cap.visionUsesChat ? "现在用聊天模型「\(ep.model)」直接看图。" : "现在用「\(ep.model)」看图，再把描述交给聊天模型。"
        } else { s = "⚠️ 聊天模型「\(Prefs.model)」只懂文字，请在上面选一个看图模型。" }
        if Prefs.visionOn && !ScreenReader.screenRecordingAllowed() { s += " 还需要「屏幕录制」权限。" }
        visionStatus.stringValue = s
    }

    /// Draw a tiny picture (an orange circle on blue) and ask the vision model what it sees.
    @objc private func testVision() {
        store()
        visionStatus.stringValue = "正在测试…"
        let img = NSImage(size: NSSize(width: 160, height: 120))
        img.lockFocus()
        NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 160, height: 120).fill()
        NSColor.orange.setFill(); NSBezierPath(ovalIn: NSRect(x: 50, y: 30, width: 60, height: 60)).fill()
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        Task {
            let (d, e) = await MediaHub.describe([jpg], question: "图里是什么形状、什么颜色？一句话。", appName: "测试图片", video: false)
            await MainActor.run {
                self.visionStatus.stringValue = d.map { "✅ 看得到：" + $0 } ?? "⚠️ " + (e ?? "失败")
            }
        }
    }

    @objc private func testSTT() {
        store()
        guard let ep = Cap.stt else {
            sttStatus.stringValue = SFSpeechRecognizer.authorizationStatus() == .authorized
                ? "✅ 本机语音识别可用（离线）" : "本机识别需要「语音识别」权限，第一次和小猫说话时会弹出来。"
            return
        }
        sttStatus.stringValue = "正在测试…"
        let url = MediaHub.silentWav()
        Task {
            let (t, e) = await MediaHub.cloudTranscribe(url, ep: ep)
            await MainActor.run {
                self.sttStatus.stringValue = t != nil ? "✅ 连接成功，「\(ep.model)」可以用" : "⚠️ " + (e ?? "失败")
            }
        }
    }

    @objc private func saveIt() {
        guard OCConfirm.ask("保存模型设置？", "对话、看图和听写模型的地址、模型名和 Key 会换成现在填的内容。", ok: "保存") else { return }
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
    /// Signed-in account the level was last loaded for.
    private var levelUser = ""
    private let bubble = Bubble()
    private let store = ChatStore()
    private let llm = LLM()
    private let voice = Voice()
    private let listener = Listener()
    private let hotKey = HotKey(id: 1)
    private let perceptionKey = HotKey(id: 2)
    private lazy var hub = ContextHub(dir: store.dir)
    private lazy var xbuddy = XCompanion(dir: store.dir, hub: hub)
    private let agent = DesktopAgent()

    /// A message next to the cat: inside the open chat bubble when it is up, as a light popup otherwise.
    private func catPopup(_ text: String, _ acts: [(String, () -> Void)], hold: Double) {
        if bubble.chatMode && bubble.isShown {
            bubble.setText(text)
            bubble.setActions(acts)
            bubble.layout()
        } else {
            bubble.notify(text, actions: acts, hold: hold)
        }
    }
    private var lastXReact = Date.distantPast
    private let xllm = LLM()
    /// The X greeting card is still what the bubble shows (no question asked yet): follow page changes live.
    private var xGreetingLive = false
    private var pendingXAlerts: [XAlert] = []
    private var xAlertTimer: Timer?
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
    /// The text the user last selected, where it is on screen and when (for ringing what the answer is about).
    private var selectionMark: (rect: CGRect, pid: pid_t, text: String, at: Date)?
    private var voiceFromWindow = false
    private var bubbleGen = 0

    let catSize = NSSize(width: 300, height: 330)

    func applicationDidFinishLaunching(_ note: Notification) {
        L10n.install()
        Theme.start()
        Keychain.prefetch()
        // Only one cat at a time: quit any other (older) OrdCat that is still running.
        let me = ProcessInfo.processInfo.processIdentifier
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.ordcat.OrdCat")
        where other.processIdentifier != me { other.terminate() }
        // First run of this version: move into /Applications if needed and switch to this Mac's
        // stable signature, so permissions survive future updates.
        DispatchQueue.global(qos: .userInitiated).async {
            if Updater.shared.selfInstallIfNeeded() {
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
        buildMainMenu()
        buildCat()
        buildStatusMenu()
        chatWindow = ChatWindowController(store: store)
        chatWindow.onSend = { [weak self] text, imgs in self?.ask(text, images: imgs, inBubble: false) }
        chatWindow.onMic = { [weak self] in self?.toggleVoice(fromWindow: true) }
        chatWindow.onClear = { [weak self] in self?.store.clear() }
        chatWindow.onOpenAccount = { [weak self] in self?.settings.show(page: .user) }
        bubble.anchor = { [weak self] in self?.catView.headScreenPoint() ?? .zero }
        bubble.onSend = { [weak self] text in self?.ask(text) }
        bubble.onExpand = { [weak self] in self?.bubble.hide(); self?.chatWindow.show() }
        bubble.onMic = { [weak self] in self?.toggleVoice(fromWindow: false) }
        bubble.onTopics = { [weak self] v in self?.showTopicsMenu(v) }
        bubble.onShareChanged = { [weak self] on in
            guard let self = self else { return }
            if on { self.chosenTopic = nil; self.bubble.topicLabel = nil }
        }
        startTrustWatch()
        checkSigningOnce()
        settings.onHotKeyChanged = { [weak self] in self?.registerHotKey() }
        settings.onClearHistory = { [weak self] in self?.store.clear() }
        settings.hub = hub
        settings.voice = voice
        settings.onPerceptionChanged = { [weak self] in self?.applyPerception(announce: true) }
        settings.onPreviewContext = { [weak self] in self?.previewContext() }
        hub.idleSeconds = { [weak self] in self?.idleSeconds() ?? 0 }
        applyPerception(announce: false)
        settings.xbuddy = xbuddy
        xbuddy.onKnownPerson = { [weak self] _ in
            // Someone you know: ears up for a few seconds, no popup. Click the cat to see the card.
            guard let self = self, self.catPanel.isVisible, !self.bubble.chatMode else { return }
            self.catView.perk(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self = self, !self.bubble.chatMode else { return }
                self.catView.perk(false)
            }
        }
        xbuddy.onFirstVisit = { [weak self] in self?.offerXMode() }
        xbuddy.onInteraction = { [weak self] handle, kind in
            guard let self = self, self.catPanel.isVisible, !self.bubble.chatMode,
                  Date().timeIntervalSince(self.lastXReact) > 20 else { return }
            // The post card is up: just perk the ears, don't cover it.
            if self.bubble.tag == "xcard" && self.bubble.isShown {
                self.catView.perk(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.catView.perk(false) }
                return
            }
            self.lastXReact = Date()
            let icon = kind == "bookmark" ? "🔖" : (kind == "repost" ? "🔁" : "❤️")
            self.catView.perk(true)
            self.bubble.notify("\(icon) 记住啦：你\(XCompanion.verb(kind)) @\(handle)", hold: 2.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.catView.perk(false) }
        }
        xbuddy.onRead = { [weak self] n in
            guard let self = self, n > 0, self.catPanel.isVisible, !self.bubble.chatMode,
                  !(self.bubble.tag == "xcard" && self.bubble.isShown) else { return }
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let today = df.string(from: Date())
            guard UserDefaults.standard.string(forKey: "xHelloDay") != today else { return }
            UserDefaults.standard.set(today, forKey: "xHelloDay")
            self.catView.perk(true)
            self.bubble.notify("陪你刷推中 🐾 这页我看到 \(n) 条帖子。点我：TA 是谁 · 重点+核实 · 筛评论 · 想回复", hold: 6)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.catView.perk(false) }
        }
        xbuddy.onAlerts = { [weak self] a in self?.queueXAlerts(a) }
        xbuddy.onReplyComposer = { [weak self] post in self?.xReplyAssist(post) }
        xbuddy.onPageChanged = { [weak self] in self?.xPageChanged() }
        xbuddy.onPostOpening = { [weak self] h in self?.xPostOpening(h) }
        xbuddy.onLeftX = { [weak self] in
            guard let self = self, self.bubble.isShown else { return }
            if self.bubble.chatMode && self.xGreetingLive {
                self.xGreetingLive = false
                let page = Prefs.pageShare ? self.hub.shareableWindow() : nil
                self.bubble.setShare(title: page?.title, on: page != nil)
                self.bubble.setChoices([])
                self.bubble.setText(page != nil ? "喵～我能看到你正在看的页面，想问点什么？" : "喵～想聊点什么？")
                self.bubble.setActions(page != nil ? self.pageQuickActions() : [])
                self.bubble.layout()
            } else if self.bubble.tag == "xcard" && !self.bubble.chatMode {
                self.bubble.hide()
            }
        }
        xbuddy.onPostUpdated = { [weak self] in
            guard let self = self, self.bubble.isShown, !self.xReplyShowing else { return }
            if self.bubble.chatMode && self.xGreetingLive { self.xShow(self.xGreeting(scan: false)) }
            else if self.bubble.tag == "xcard" && !self.bubble.chatMode { self.showXCard(self.xGreeting(scan: false)) }
        }
        // Read-aloud: pause / continue / stop from the bubble header; Esc also stops.
        voice.onState = { [weak self] st in self?.bubble.setSpeaking(st) }
        bubble.onSpeakPause = { [weak self] in self?.voice.togglePause() }
        bubble.onSpeakStop = { [weak self] in self?.voice.stop() }
        bubble.panel.onEscape = { [weak self] in
            guard let self = self else { return }
            if self.voice.isActive { self.voice.stop() } else { self.bubble.hide() }
        }
        agent.present = { [weak self] text, acts in self?.catPopup(text, acts, hold: acts.isEmpty ? 8 : 120) }
        agent.onFinish = { [weak self] log in
            guard let self = self else { return }
            self.store.updateLast(log)
            self.store.save()
        }
        settings.skillsPane.onChanged = { [weak self] id, on in
            guard let self = self else { return }
            if id == "agent" {
                self.bubble.notify(on ? "「帮我操作电脑」开啦 🤖 跟我说「帮我……」试试，每一步我都会先问你。" : "「帮我操作电脑」关掉啦。", hold: 5)
                return
            }
            if id == "square" {
                self.bubble.notify(on ? "「猫帮圈」开啦 🐟 说「发任务：……」把问题发到猫帮圈；我也会去猫帮圈找适合我的任务，接之前先问你。" : "「猫帮圈」关掉啦。", hold: 6)
                return
            }
            guard id == "x" else { return }
            self.bubble.notify(on ? "「陪你刷推」开啦 🐾 去 x.com 刷一刷，我在旁边看着。" : "「陪你刷推」关掉啦，我不看 X 了。", hold: 4)
        }
        xbuddy.start()
        TaskSquare.shared.present = { [weak self] text, acts, hold in self?.catPopup(text, acts, hold: hold) }
        TaskSquare.shared.openAccount = { [weak self] in self?.settings.show(page: .user) }
        TaskSquare.shared.start()
        // 信号站 + 小猫等级 + 会员光环
        SignalStation.shared.present = { [weak self] text, acts, hold in self?.catPopup(text, acts, hold: hold) }
        SignalStation.shared.openAccount = { [weak self] in self?.settings.show(page: .user) }
        SignalStation.shared.captureDesktop = { [weak self] in
            guard let hub = self?.hub, let app = hub.lastExternalApp, !app.isTerminated,
                  let card = await hub.reader.capture(app: app, deep: true, wantScreenshot: false, maxNodes: 4000, axBudget: 0.6)
            else { return nil }
            return (app: card.app, title: Redactor.clean(card.windowTitle), text: Redactor.clean(card.plainText))
        }
        SignalStation.shared.start()
        bubble.onLevel = { [weak self] in self?.settings.show(page: .user) }
        catView.setMember(CatLevel.isMember)
        CatLevel.shared.startClock()
        Social.onUnread = { [weak self] n in
            guard let self = self, !self.bubble.chatMode else { return }
            self.bubble.notify(L10n.english ? "💬 You have \(n) new private message\(n > 1 ? "s" : "")" : "💬 你有 \(n) 条新私信",
                               actions: [(L10n.t("打开私信"), { DMWindow.shared.show() })], hold: 8)
        }
        Social.startUnreadWatch()
        CatLevel.shared.refresh()
        Account.shared.observe { [weak self] in
            guard let self = self else { return }
            self.catView.setMember(CatLevel.isMember)
            let uid = Account.shared.signedIn ? (Account.shared.profile.userID ?? "") : ""
            if uid != self.levelUser { self.levelUser = uid; CatLevel.shared.refresh() }
        }
        levelUser = Account.shared.signedIn ? (Account.shared.profile.userID ?? "") : ""
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
        catView.onRightClick = { [weak self] in self?.settings.show(page: .cat) }
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
        statusItem.button?.title = ""
        setStatusEyes()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "OrdCat"
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
        m.addItem(withTitle: "🐟 猫帮圈", action: #selector(menuSquare), keyEquivalent: "").target = self
        m.addItem(withTitle: "📶 信号站", action: #selector(menuSignal), keyEquivalent: "").target = self
        m.addItem(withTitle: "💬 私信", action: #selector(menuDM), keyEquivalent: "").target = self
        m.addItem(withTitle: "🎁 邀请好友", action: #selector(menuInvite), keyEquivalent: "").target = self
        m.addItem(withTitle: "🛟 联系客服", action: #selector(menuSupport), keyEquivalent: "").target = self
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
    @objc private func menuSquare() { TaskSquare.shared.showWindow() }
    @objc private func menuSignal() { SignalStation.shared.showWindow() }
    @objc private func menuDM() { DMWindow.shared.show() }
    @objc private func menuInvite() { InviteWindow.shared.show() }
    @objc private func menuSupport() { Social.openSupport() }
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
        setStatusEyes()
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
        CatLevel.shared.touch()
        if bubble.isShown && bubble.chatMode {
            bubble.hide(); voice.stop(); catView.perk(false)
        } else {
            openChat()
        }
    }
    private func openChat() {
        catView.perk(false)
        let last = store.messages.last(where: { $0.role == "assistant" && !$0.text.isEmpty })?.text
        let page = Prefs.pageShare ? hub.shareableWindow() : nil
        chosenTopic = nil
        bubble.topicLabel = nil
        bubble.setShare(title: page?.title, on: page != nil)
        var greeting = page != nil ? "喵～我能看到你正在看的页面，想问点什么？" : (last ?? "喵～想聊点什么？")
        let onX = xbuddy.readablePage() != nil
        if onX { greeting = xGreeting(scan: xbuddy.lastPosts.isEmpty) }   // the page is read in the background already
        bubble.openChat(greeting: greeting)
        xGreetingLive = onX
        if onX { bubble.setActions(xQuickActions()); bubble.layout() }
        else if page != nil { bubble.setActions(pageQuickActions()); bubble.layout() }
        startShareWatch()
    }

    // MARK: Accessibility grant → take effect without the user restarting
    private var trustTimer: Timer?
    private func startTrustWatch() {
        guard !AXIsProcessTrusted() else { return }
        let flip: () -> Void = { [weak self] in
            guard let self = self, self.trustTimer != nil, AXIsProcessTrusted() else { return }
            self.trustTimer?.invalidate(); self.trustTimer = nil
            self.bubble.notify("授权成功啦～小猫重启一下马上生效 🐾", hold: 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.relaunch() }
        }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in flip() }
        trustTimer?.tolerance = 0.5
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"),
                                                            object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { flip() }
        }
    }
    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "ordcat-relaunch", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
    /// If this copy still has a temporary signature, say why once per version (grants won't survive updates).
    private func checkSigningOnce() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) { [weak self] in
            let st = LocalSigner.state()
            let key = "signWarned-\(Updater.shared.current)"
            guard !st.stable, !UserDefaults.standard.bool(forKey: key) else { return }
            UserDefaults.standard.set(true, forKey: key)
            DispatchQueue.main.async {
                self?.bubble.notify("这一版没能用本机固定签名，所以每次更新都要重新授权。可以在 设置 → 关于 点「修复授权」再试一次。", 
                                    actions: [("去修复", { [weak self] in self?.settings.show(page: .about) })], hold: 12)
            }
        }
    }

    // MARK: topics (one per shared page; the user can go back to an earlier one)
    struct Topic: Codable { var title: String; var start: Date; var last: Date }
    private lazy var topics: [Topic] = {
        guard let d = UserDefaults.standard.data(forKey: "topics"),
              let t = try? JSONDecoder().decode([Topic].self, from: d) else { return [] }
        return t
    }()
    private var chosenTopic: Topic?
    private func saveTopics() {
        if topics.count > 30 { topics.removeFirst(topics.count - 30) }
        if let d = try? JSONEncoder().encode(topics) { UserDefaults.standard.set(d, forKey: "topics") }
    }
    /// Same page within 30 minutes continues its topic; anything else starts a fresh one.
    private func beginTopic(title: String) -> Topic {
        let now = Date()
        if let last = topics.last, last.title == title, now.timeIntervalSince(last.last) < 1800 {
            topics[topics.count - 1].last = now
            saveTopics()
            return topics[topics.count - 1]
        }
        let t = Topic(title: title, start: now.addingTimeInterval(-0.01), last: now)
        topics.append(t)
        saveTopics()
        return t
    }
    private func showTopicsMenu(_ from: NSView) {
        let menu = NSMenu()
        let cur = NSMenuItem(title: "📄 当前页面（默认）", action: #selector(topicCurrent), keyEquivalent: "")
        cur.target = self
        menu.addItem(cur)
        menu.addItem(.separator())
        let df = DateFormatter(); df.dateFormat = "M月d日 HH:mm"
        let list = Array(topics.reversed().prefix(12))
        if list.isEmpty {
            let none = NSMenuItem(title: "还没有对话记录", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for (i, t) in list.enumerated() {
            let short = t.title.count > 32 ? String(t.title.prefix(32)) + "…" : t.title
            let it = NSMenuItem(title: "💬 \(short)  ·  \(df.string(from: t.last))", action: #selector(topicPicked(_:)), keyEquivalent: "")
            it.target = self
            it.tag = topics.count - 1 - i
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let fresh = NSMenuItem(title: "🆕 新话题（不带之前的聊天）", action: #selector(topicFresh), keyEquivalent: "")
        fresh.target = self
        menu.addItem(fresh)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: from.bounds.height + 2), in: from)
    }
    @objc private func topicCurrent() {
        chosenTopic = nil
        bubble.topicLabel = nil
        let page = hub.shareableWindow()
        bubble.setShare(title: page?.title, on: page != nil)
        bubble.setText(page != nil ? "好～我们聊你现在看的这个页面。" : "现在没有可以分享的页面，直接聊也可以～")
    }
    @objc private func topicPicked(_ item: NSMenuItem) {
        guard item.tag >= 0 && item.tag < topics.count else { return }
        let t = topics[item.tag]
        chosenTopic = t
        bubble.setShare(title: bubble.shareTitle ?? t.title, on: false)
        bubble.topicLabel = t.title
        bubble.setActions([])
        bubble.setText("好的，我们接着聊「\(t.title)」～这次不读当前页面。")
    }
    @objc private func topicFresh() {
        chosenTopic = nil
        bubble.topicLabel = nil
        if let title = bubble.shareTitle {
            topics.append(Topic(title: title, start: Date(), last: Date()))
            saveTopics()
        }
        bubble.setText("新话题开始啦，之前的聊天这次不带上。")
    }

    private func pageQuickActions() -> [(String, () -> Void)] {
        if xbuddy.readablePage() != nil { return xQuickActions() }
        return [("总结这页", { [weak self] in self?.ask("帮我用几句话总结一下这个页面。") }),
         ("重点是什么", { [weak self] in self?.ask("这个页面里最值得注意的重点是什么？") }),
         ("帮我解释", { [weak self] in self?.ask("用简单的话帮我解释一下这个页面在讲什么。") })]
    }

    // MARK: 陪你刷推 (X)
    private func offerXMode() {
        guard catPanel.isVisible, !bubble.chatMode, !listener.isListening else { Prefs.xOffered = false; return }
        catView.perk(true)
        bubble.notify("你在刷 X 呀～要我陪你刷吗？我会记住你关注和互动过的人，帮你讲重点、筛评论、想回复（不替你发）。全部只存在这台 Mac 上，私信不看。", actions: [
            ("好呀 🐾", { [weak self] in
                Prefs.xMode = true
                _ = SelectionWatcher.trusted(prompt: true)
                self?.settings.refreshX()
                self?.bubble.notify("好～从现在起我陪你刷。命中信号、营销号、水评我会提醒你，点回复时给你回复建议。想改提醒：右键我 → 设置 → 技能。", hold: 8)
            }),
            ("先不用", { [weak self] in self?.bubble.hide(); self?.catView.perk(false) })
        ], hold: 20)
    }

    private func xQuickActions() -> [(String, () -> Void)] {
        [("TA 是谁", { [weak self] in self?.xWho() }),
         ("重点+核实", { [weak self] in self?.xPoint() }),
         ("筛评论", { [weak self] in self?.xFilter() }),
         ("想回复", { [weak self] in self?.xDraft() })]
    }

    private func xShow(_ text: String) {
        bubble.setChoices([])
        bubble.setText(text)
        bubble.setActions(xQuickActions())
        bubble.layout()
    }

    /// After the first answer, let the model name the conversation from what was said (shown in full in the sidebar).
    private let titleLLM = LLM()
    private func autoTitle(user: String, reply: String) {
        guard let id = store.current, store.wantsAITitle(id) else { return }
        let u = user.components(separatedBy: "\n\n---\n").last ?? user
        let prompt = "给下面这段对话起一个标题：不超过 12 个字，具体说出在聊什么（比如「X 帖子：Zaps 条款解读」「修 Swift 编译报错」），不要标点和引号，只输出标题本身。\n\n用户：\(u.prefix(500))\n小猫：\(reply.prefix(400))"
        titleLLM.stream([["role": "user", "content": prompt]], onDelta: { _ in }, onDone: { [weak self] t, err in
            guard err == nil, let t = t else { return }
            self?.store.setAITitle(id, t)
        })
    }

    private let gistLLM = LLM()
    private var gists: [String: String] = [:]
    private var gistPending = ""

    private func xGreeting(scan: Bool = true) -> String {
        if scan { xbuddy.scanNow() }
        // A single post page: talk about the post, not just the person.
        if let p = xbuddy.mainPost {
            let key = "\(p.handle)|\(p.text.prefix(80))"
            var g = "📝 @\(p.handle)\(p.name.isEmpty ? "" : "（\(p.name)）") 的帖子\n"
            if let gist = gists[key] {
                g += "一句话：\(gist)\n"
            } else {
                g += "「\(p.text.count > 90 ? String(p.text.prefix(90)) + "…" : p.text)」\n"
                if p.text.count > 60 { requestGist(p, key: key) }
            }
            let r = xbuddy.replyStats
            if r.total > 0 {
                g += "💬 这屏读到 \(r.total) 条回复" + (r.water + r.spam > 0 ? "，其中 \(r.water) 条水评、\(r.spam) 条营销号" : "") + "\n"
            }
            if let who = xbuddy.person(p.handle), who.known {
                let n = who.interactions.count
                g += "👤 " + (who.following == true ? "你关注了 TA" : "你认识 TA") + (n > 0 ? "，互动过 \(n) 次" : "") + "\n"
            }
            return g + "\n想看重点、筛评论，还是帮你想回复？"
        }
        if let p = xbuddy.person(xbuddy.focus), p.known { return xbuddy.card(p) + "\n\n想让我帮你做点什么？" }
        if let f = xbuddy.focus { return "这页是 @\(f) 🐾 我还不太认识 TA。想让我帮你做点什么？" }
        return "喵～陪你刷推中 🐾 想让我帮你做点什么？"
    }

    /// One-sentence gist of a long post, fetched quietly and dropped into the card when it arrives.
    private func requestGist(_ p: XPost, key: String) {
        guard gistPending != key, !Prefs.base.isEmpty else { return }
        gistPending = key
        let prompt = "用一句中文概括这条帖子在说什么（不超过 40 字，只输出这一句）：\n@\(p.handle)：\(p.text.prefix(1500))"
        gistLLM.stream([["role": "user", "content": prompt]], onDelta: { _ in }, onDone: { [weak self] t, err in
            guard let self = self else { return }
            self.gistPending = ""
            guard err == nil, let t = t?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return }
            self.gists[key] = String(t.prefix(80))
            if self.gists.count > 200 { self.gists.removeAll() }
            guard let m = self.xbuddy.mainPost, "\(m.handle)|\(m.text.prefix(80))" == key, self.bubble.isShown else { return }
            if self.xGreetingLive && self.bubble.chatMode {
                self.xShow(self.xGreeting(scan: false))
            } else if self.bubble.tag == "xcard" && !self.bubble.chatMode {
                self.showXCard(self.xGreeting(scan: false))
            }
        })
    }

    /// Show an X popup: inside the open chat bubble when it is up, as a light popup otherwise.
    private func xPopup(_ text: String, _ acts: [(String, () -> Void)], hold: Double) {
        if bubble.chatMode && bubble.isShown {
            var a = acts
            a.append(("返回", { [weak self] in
                guard let self = self else { return }
                self.xGreetingLive = true
                self.xShow(self.xGreeting(scan: false))
            }))
            bubble.setChoices([])
            bubble.setText(text)
            bubble.setActions(a)
            bubble.layout()
        } else {
            bubble.notify(text, actions: acts, hold: hold)
        }
    }

    // MARK: post card that follows you around X

    /// When the post card last appeared (other popups wait a moment so they don't cover it).
    private var xCardAt = Date.distantPast
    /// A chat answer is being written into the bubble right now.
    private var bubbleAnswering = false

    /// May the post card take over the bubble now?
    private func xCardMayShow() -> Bool {
        guard catPanel.isVisible, !listener.isListening, !agent.running else { return false }
        if bubble.isShown && bubble.chatMode {
            if xGreetingLive { return true }
            // You are in a conversation: switch only when nothing is being written or typed.
            return Prefs.xAlert("autopost") && !bubbleAnswering && !bubble.hasDraft
        }
        return Prefs.xAlert("autopost")
    }

    /// Show the post card: in the open chat bubble, otherwise as a popup that stays while you read.
    private func showXCard(_ text: String) {
        xCardAt = Date()
        xReplyShowing = false
        if bubble.isShown && bubble.chatMode {
            xGreetingLive = true
            if let pg = xbuddy.readablePage() { bubble.setShare(title: pg.title, on: bubble.sharing) }
            xShow(text)
        } else {
            bubble.notify(text, actions: xQuickActions(), hold: 25)
            bubble.tag = "xcard"
        }
    }

    /// The address just changed to a post: show the card at once, filled in when the page is read.
    private func xPostOpening(_ handle: String) {
        pendingXAlerts.removeAll()
        guard xCardMayShow() else { return }
        let who = xbuddy.person(handle)
        var t = "📝 @\(handle) 的帖子\n正在读…"
        if let w = who, w.known { t += "\n👤 " + (w.following == true ? "你关注了 TA" : "你认识 TA") }
        showXCard(t)
    }

    /// The X page in front is read: switch the card right away.
    private func xPageChanged() {
        pendingXAlerts.removeAll()
        let cardUp = bubble.isShown && ((bubble.chatMode && xGreetingLive) || bubble.tag == "xcard")
        if xbuddy.mainPost != nil {
            guard xCardMayShow() else { return }
            showXCard(xGreeting(scan: false))
        } else if cardUp && xbuddy.onStatusPage, let h = XCompanion.statusAuthor(xbuddy.currentURL) {
            // A post page we couldn't read: say so instead of falling back to the generic greeting.
            let t = "📝 @\(h) 的帖子\n这页我没读全 😿 点「重点+核实」我直接读整页给你看"
            if bubble.chatMode { xShow(t) } else { showXCard(t) }
        } else if cardUp {
            // Left the post (back to the timeline or a profile).
            if bubble.chatMode { xShow(xGreeting(scan: false)) } else { bubble.hide() }
        }
    }

    // MARK: 刷推 popups

    private func queueXAlerts(_ a: [XAlert]) {
        pendingXAlerts.append(contentsOf: a)
        if pendingXAlerts.count > 40 { pendingXAlerts.removeFirst(pendingXAlerts.count - 40) }
        let since = Date().timeIntervalSince(lastXReact)
        let hasSignal = pendingXAlerts.contains { $0.kind == .signal }
        let wait = max(0, (hasSignal ? min(3, Prefs.xAlertGap) : Prefs.xAlertGap) - since)
        if wait <= 0.05 { flushXAlerts(); return }
        if xAlertTimer == nil {
            xAlertTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
                self?.xAlertTimer = nil; self?.flushXAlerts()
            }
        }
    }

    private func flushXAlerts() {
        guard !pendingXAlerts.isEmpty else { return }
        // The post card just appeared: give it a few seconds before any other popup.
        let sinceCard = Date().timeIntervalSince(xCardAt)
        if sinceCard < 5 {
            xAlertTimer?.invalidate()
            xAlertTimer = Timer.scheduledTimer(withTimeInterval: 5 - sinceCard, repeats: false) { [weak self] _ in
                self?.xAlertTimer = nil; self?.flushXAlerts()
            }
            return
        }
        // Never interrupt a chat, voice, or reply ideas you are reading.
        // Never interrupt a conversation, voice, or reply ideas you are reading; the open X card is fine.
        let chatBusy = bubble.chatMode && bubble.isShown && !xGreetingLive
        guard catPanel.isVisible, !chatBusy, !listener.isListening, !xReplyShowing,
              xbuddy.readablePage() != nil else {
            if !(xbuddy.readablePage() != nil) { pendingXAlerts.removeAll() }
            return
        }
        let all = pendingXAlerts
        pendingXAlerts.removeAll()
        guard let top = all.map({ $0.kind.rawValue }).min(), let kind = XAlert.Kind(rawValue: top) else { return }
        let group = all.filter { $0.kind == kind }
        let rest = all.count - group.count
        lastXReact = Date()
        let names = group.prefix(4).map { "@" + $0.post.handle }.joined(separator: "、") + (group.count > 4 ? " 等" : "")
        let snippet: (XPost) -> String = { p in p.text.count > 70 ? String(p.text.prefix(70)) + "…" : p.text }
        var text = ""
        var acts: [(String, () -> Void)] = []
        let posts = group.map { $0.post }
        // Mark where they are right now (found again at click time, so scrolling never puts the box in the wrong place).
        let mark: (String, Int, Double) -> () -> Void = { [weak self] label, limit, secs in
            { guard let self = self else { return }
              let found = self.xbuddy.locate(posts)
              if found.isEmpty { self.xPopup("它已经滚出屏幕啦 🐾 点「打开」我直接带你去看", self.openActs(posts), hold: 6); return }
              self.highlighter.show(found.map { $0.rect }, label: label, seconds: secs, limit: limit) }
        }
        switch kind {
        case .signal:
            let a = group[0]
            text = "📡 信号：\(a.reason)\n@\(a.post.handle)：\(snippet(a.post))"
            if group.count > 1 { text += "\n（这屏还有 \(group.count - 1) 条命中）" }
            acts = openActs([a.post]) + [("在哪", mark("信号", 6, 8)), ("想回复", { [weak self] in self?.xReplyAssist(a.post) })]
        case .spam:
            text = group.count == 1 ? "🚫 营销号 / 广告：@\(group[0].post.handle)（\(group[0].reason)）"
                                    : "🚫 这屏有 \(group.count) 个营销号 / 广告：\(names)"
            acts = [("标出来", mark("营销号", 6, 8))]
        case .known:
            let a = group[0]
            text = "👋 @\(a.post.handle) 出现了，\(a.reason)" + (group.count > 1 ? "\n还有 \(names)" : "")
            acts = openActs([a.post]) + [("在哪", mark("熟人", 4, 6)),
                    ("TA 是谁", { [weak self] in
                        guard let self = self, let p = self.xbuddy.person(a.post.handle) else { return }
                        self.bubble.notify(self.xbuddy.card(p), hold: 12) })]
        case .follow:
            let a = group[0]
            text = "🆕 你关注的 @\(a.post.handle) 发帖了：\(snippet(a.post))" + (group.count > 1 ? "\n还有 \(group.count - 1) 条" : "")
            acts = openActs([a.post]) + [("在哪", mark("关注", 4, 6))]
        case .water:
            text = "🗑 评论里有 \(group.count) 条水评：\(names)"
            acts = [("标出来", mark("水评", 8, 8)),
                    ("筛评论", { [weak self] in self?.openChat(); self?.xFilter() })]
        }
        if rest > 0 { text += "\n另外还有 \(rest) 条别的提醒" }
        catView.perk(true)
        xPopup(text, acts, hold: kind == .signal ? 12 : 8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.catView.perk(false) }
    }

    /// 「打开」: open the post itself (a click on its time link, like you would); the post card then explains it.
    private func openActs(_ posts: [XPost]) -> [(String, () -> Void)] {
        guard let first = posts.first else { return [] }
        return [("打开", { [weak self] in
            guard let self = self, let app = self.hub.lastExternalApp else { return }
            guard let p = self.xbuddy.locate([first]).first, p.link != .zero else {
                self.xPopup("这条已经不在屏幕上了，往回滚一下就能看到 @\(first.handle) 🐾", [], hold: 5)
                return
            }
            app.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let pt = CGPoint(x: p.link.midX, y: p.link.midY)
                let src = CGEventSource(stateID: .hidSystemState)
                CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
                CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        })]
    }

    // MARK: reply ideas when you click reply

    private var xReplyShowing = false

    private func parseDrafts(_ raw: String) -> [String] {
        var drafts: [String] = []
        for l in raw.components(separatedBy: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard let f = t.first, ("1"..."9").contains(String(f)), t.count > 2 else { continue }
            var body = String(t.dropFirst())
            while let c = body.first, ".、)）:： ".contains(c) { body.removeFirst() }
            body = body.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " \"“”"))
            if !body.isEmpty { drafts.append(body) }
        }
        return drafts
    }

    /// The reply-ideas prompt, built from 设置 → 技能 → 陪你刷推 → 回复建议设置.
    private func replyPrompt(_ p: XPost) -> String {
        let n = Prefs.xReplyCount
        let len = Prefs.xReplyLengths[Prefs.xReplyLength].1
        let tone = Prefs.xReplyTones[Prefs.xReplyTone]
        let lang = Prefs.xReplyLangs[Prefs.xReplyLang]
        var rules = "帮我想 \(n) 条回复草稿：自然、像真人说话、别营销腔，每条不超过 \(len) 字，语言：\(lang)。"
        if Prefs.xReplyTone == 0 {
            rules += "每条换一个角度（比如接住观点、提个好问题、轻松幽默、补充信息、表达不同看法），别重复。"
        } else {
            rules += "语气：\(tone)。每条说法不一样。"
        }
        let me = Prefs.xReplyPersona.trimmingCharacters(in: .whitespacesAndNewlines)
        if !me.isEmpty { rules += "\n关于我 / 我的要求（一定照做）：\(me)" }
        let nums = (1...n).map { "\($0)." }.joined(separator: " ")
        return """
        ## 我想回复的帖子
        @\(p.handle)\(p.name.isEmpty ? "" : "（\(p.name)）")：\(p.text.prefix(1200))

        \(rules)
        只按「\(nums)」一行一条列出来，不要别的话。
        """
    }

    private func xReplyAssist(_ post: XPost?) {
        guard catPanel.isVisible, !listener.isListening else { return }
        guard let p = post, !p.text.isEmpty else {
            xPopup("✍️ 想回复呀～这条我没读到文字，等页面加载完再点「想回复」试试。", [], hold: 4)
            return
        }
        xReplyShowing = true
        catView.perk(true)
        xPopup("✍️ 在帮你想怎么回 @\(p.handle)…", [], hold: 30)
        var ctx = [xbuddy.interestLine()]
        if let who = xbuddy.person(p.handle) {
            ctx.append("[作者 @\(who.handle)：\(who.following == true ? "我已关注" : "我没关注")，我们互动过 \(who.interactions.count) 次]")
        }
        let want = Prefs.xReplyCount
        xllm.stream([["role": "user", "content": replyPrompt(p)]], context: ctx.filter { !$0.isEmpty }.joined(separator: "\n"),
                    onDelta: { _ in }, onDone: { [weak self] full, err in
            guard let self = self else { return }
            self.catView.perk(false)
            if let e = err { self.xReplyShowing = false; self.xPopup("✍️ " + e, [], hold: 6); return }
            let drafts = Array(self.parseDrafts(full ?? "").prefix(want))
            guard !drafts.isEmpty else {
                self.xReplyShowing = false
                self.xPopup("✍️ 这次没想出来，点「换一批」再试试～", [("换一批", { [weak self] in self?.xReplyAssist(p) })], hold: 8)
                return
            }
            self.showDrafts(drafts, for: p)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.xReplyShowing = false }
        })
    }

    /// Reply ideas as tappable rows: one click puts it into X's reply box (or copies it). Never sends.
    private func showDrafts(_ drafts: [String], for p: XPost) {
        let how = Prefs.xReplyFill ? "点一条，我帮你填进回复框" : "点一条就复制"
        let text = "✍️ 回复 @\(p.handle)：\(how)（不会替你发）"
        let choices: [(String, () -> Void)] = drafts.enumerated().map { (i, d) in
            ("\(i + 1). \(d)", { [weak self] in self?.useDraft(d, index: i + 1, post: p) })
        }
        let acts: [(String, () -> Void)] = [
            ("换一批", { [weak self] in self?.xReplyAssist(p) }),
            ("回复设置", { [weak self] in self?.settings.show(page: .skills) })
        ]
        if bubble.chatMode && bubble.isShown {
            var a = acts
            a.append(("返回", { [weak self] in
                guard let self = self else { return }
                self.xGreetingLive = true
                self.xShow(self.xGreeting(scan: false))
            }))
            bubble.setText(text)
            bubble.setActions(a)
        } else {
            bubble.notify(text, actions: acts, hold: 60)
        }
        bubble.setChoices(choices, tip: Prefs.xReplyFill ? "点击填进 X 的回复框（只填不发）" : "点击复制")
        bubble.layout()
    }

    /// Copy a reply idea; when X's reply box is open, paste it in (⌘V) — the user still presses 回复 themselves.
    private func useDraft(_ d: String, index: Int, post: XPost) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(d, forType: .string)
        selection.ignoreChangeCount = pb.changeCount
        lastChange = pb.changeCount
        xReplyShowing = false
        let done: (String) -> Void = { [weak self] msg in
            guard let self = self else { return }
            let back: [(String, () -> Void)] = [("换一批", { [weak self] in self?.xReplyAssist(post) })]
            if self.bubble.chatMode && self.bubble.isShown { self.bubble.setChoices([]); self.bubble.setText(msg); self.bubble.setActions(back); self.bubble.layout() }
            else { self.bubble.notify(msg, actions: back, hold: 5) }
        }
        guard Prefs.xReplyFill, AXIsProcessTrusted(), let app = hub.lastExternalApp, !app.isTerminated,
              XCompanion.browsers.contains(app.bundleIdentifier ?? "") else {
            done("已复制第 \(index) 条 ✂️ 在回复框里按 ⌘V，改一改再自己发～")
            return
        }
        let pid = app.processIdentifier
        let reader = hub.reader
        let probe = String(d.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
        // 1. Find X's reply box: the focused one, or the page's「发布你的回复」box.
        DispatchQueue.global(qos: .userInitiated).async {
            let box = reader.replyEditor(pid: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard let box = box else {
                    done("已复制第 \(index) 条 ✂️ 没找到回复框：点一下 X 的「发布你的回复」再按 ⌘V～")
                    return
                }
                // 2. Bring the browser forward and put the cursor in the box.
                app.activate(options: [.activateIgnoringOtherApps])
                self.waitFront(app, tries: 0) {
                    if !box.focused && !reader.focus(box.el) {
                        // The page ignored the focus request: click inside the box (a click only focuses it).
                        let p = CGPoint(x: box.rect.midX, y: box.rect.midY)
                        let src = CGEventSource(stateID: .hidSystemState)
                        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        // 3. Paste: ⌘V only, nothing is ever sent.
                        self.pressPaste()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            DispatchQueue.global(qos: .userInitiated).async {
                                let target = reader.replyEditor(pid: pid)?.el ?? box.el
                                var ok = reader.editorText(target).contains(probe)
                                // 4. Paste didn't land: insert through accessibility instead.
                                if !ok, reader.insert(d, into: target) {
                                    Thread.sleep(forTimeInterval: 0.2)
                                    ok = reader.editorText(target).contains(probe)
                                }
                                DispatchQueue.main.async {
                                    done(ok ? "✅ 第 \(index) 条已填进回复框，改一改再自己点「回复」～"
                                            : "已复制第 \(index) 条 ✂️ 回复框没接住，点一下框再按 ⌘V 就好")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Wait (up to ~1 s) until the app is really in front, then continue.
    private func waitFront(_ app: NSRunningApplication, tries: Int, _ then: @escaping () -> Void) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier || tries >= 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: then)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.waitFront(app, tries: tries + 1, then) }
    }

    /// ⌘V with a real Command key press around it (some pages ignore a bare flagged V).
    private func pressPaste() {
        let src = CGEventSource(stateID: .hidSystemState)
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)
        cmdDown?.flags = .maskCommand
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        for e in [cmdDown, vDown, vUp, cmdUp] { e?.post(tap: .cghidEventTap) }
    }

    private func xExtra() -> String? {
        let s = [xbuddy.interestLine(), xbuddy.personContext() ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        return s.isEmpty ? nil : s
    }

    private func xWho() {
        xbuddy.scanNow()
        if let p = xbuddy.person(xbuddy.focus) {
            xShow(xbuddy.card(p))
        } else {
            xShow("这页上没认出具体是谁～打开 TA 的主页或者点进某一条帖子，再点「TA 是谁」。")
        }
    }

    private func xPoint() {
        xbuddy.scanNow()
        if bubble.shareTitle != nil && !bubble.sharing { bubble.setShare(title: bubble.shareTitle, on: true) }
        ask("用一句话讲清这条帖子的重点。然后结合我平时关注的领域，指出 1–3 个值得核实的说法：为什么值得怀疑、怎么去核实。没有可疑的就直说。",
            extra: xExtra(), after: { [weak self] _ in
                self?.bubble.setActions(self?.xQuickActions() ?? []); self?.bubble.layout(); return nil
            })
    }

    private func xFilter() {
        guard let r = xbuddy.repliesForFilter() else {
            xShow("这页上没看到评论～点进一条帖子、往下滑到评论区，再点「筛评论」。")
            return
        }
        let replies = r.posts
        let page = r.text + """

        请严格按这个格式回答：
        第一行：值得看：编号,编号（最多 6 个，没有就写「无」）
        第二行：水评：编号,编号（营销号、广告、引流、复读、纯表情、跑题都算；没有就写「无」）
        然后用两三句话说说值得看的讨论在聊什么、有哪些不同观点。
        """
        ask("帮我筛一下这条帖子下面的评论。", pageOverride: page, extra: xbuddy.interestLine(), after: { [weak self] raw in
            guard let self = self else { return nil }
            let n = replies.count
            let good = XCompanion.numbers(after: "值得看", in: raw).filter { $0 >= 1 && $0 <= n }
            let bad = XCompanion.numbers(after: "水评", in: raw).filter { $0 >= 1 && $0 <= n }
            if Prefs.highlight && !good.isEmpty {
                self.highlighter.show(good.map { replies[$0 - 1].rect }, label: "值得看", seconds: 12, limit: 6)
            }
            var lines = raw.components(separatedBy: "\n")
            if let i = lines.firstIndex(where: { $0.contains("值得看") }) { lines.remove(at: i) }
            if let i = lines.firstIndex(where: { $0.contains("水评") }) { lines.remove(at: i) }
            let names: ([Int]) -> String = { $0.map { "@" + replies[$0 - 1].handle }.joined(separator: "、") }
            let head = "🟡 值得看：" + (good.isEmpty ? "没有特别值得看的" : names(good))
                + "\n🗑 水评：" + (bad.isEmpty ? "没发现" : names(bad))
            let rest = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            self.bubble.setActions(self.xQuickActions())
            return head + (rest.isEmpty ? "" : "\n\n" + rest)
        })
    }

    private func xDraft() {
        let posts = xbuddy.scanNow()
        xReplyAssist(xbuddy.mainPost ?? posts.first)
    }

    /// While the chat bubble is open, keep the share chip pointed at whatever page is in front.
    private var shareWatch: Timer?
    private func startShareWatch() {
        shareWatch?.invalidate()
        shareWatch = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            guard self.bubble.isShown && self.bubble.chatMode else { t.invalidate(); return }
            guard Prefs.pageShare else { return }
            let page = self.hub.shareableWindow()
            if page?.title != self.bubble.shareTitle {
                // A new page: share it again unless the user switched sharing off for this chat.
                let on = self.bubble.shareTitle == nil ? true : self.bubble.sharing
                self.bubble.setShare(title: page?.title, on: on)
            }
        }
        shareWatch?.tolerance = 0.5
    }

    /// Build the request history: recent turns as text; images only for the newest message.
    private func apiHistory(newImages: [Data], since: Date? = nil, until: Date? = nil) -> [[String: Any]] {
        var pool = store.currentMessages   // only the open conversation
        if let s = since {
            // Topic window: earlier topic turns, plus the message just added (always the last one).
            let last = pool.last
            pool = pool.dropLast().filter { $0.date >= s && (until == nil || $0.date < until!) }
            if let l = last { pool.append(l) }
        }
        let recent = pool.suffix(16).filter { !($0.role == "assistant" && ($0.text.isEmpty || $0.text.hasPrefix("⚠️"))) }
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

    private func ask(_ text: String, images: [Data] = [], spoken: Bool = false, inBubble: Bool = true,
                     pageOverride: String? = nil, extra: String? = nil, after: ((String) -> String?)? = nil,
                     aboutSelection: Bool = false) {
        xGreetingLive = false
        CatLevel.shared.touch()
        // 信号站: "发信号：……" / "/信号" opens the review window (never shares by itself).
        if images.isEmpty && pageOverride == nil, let pre = SignalStation.postIntent(text) {
            SignalStation.shared.compose(prefill: pre)
            return
        }
        // 猫帮圈: "发任务：……" opens the post form instead of a chat answer.
        if images.isEmpty && pageOverride == nil, let pre = TaskSquare.postIntent(text) {
            TaskSquare.shared.postDialog(prefill: pre)
            return
        }
        // 技能「帮我操作电脑」: "帮我……" runs the desktop agent instead of a plain chat answer.
        if images.isEmpty && pageOverride == nil && !Prefs.agentOn && DesktopAgent.isTask(text) {
            catPopup("🤖 这件事要「帮我操作电脑」技能来做，它现在是关着的。去 设置 → 技能 打开开关，我就能替你动手。",
                     [("打开技能", { [weak self] in self?.settings.show(page: .skills) })], hold: 8)
            return
        }
        if images.isEmpty && pageOverride == nil && Prefs.agentOn && DesktopAgent.isTask(text) {
            if Billing.isUnlocked("agent") {
                store.append(ChatMessage(role: "user", text: text, imageNames: [], date: Date()))
                store.append(ChatMessage(role: "assistant", text: "🤖 正在帮你操作…", imageNames: [], date: Date()))
                agent.start(goal: text)
                return
            } else {
                catPopup("🤖 「帮我操作电脑」是订阅技能，去 设置 → 技能 可以试用或订阅。",
                         [("打开技能", { [weak self] in self?.settings.show(page: .skills) })], hold: 8)
                return
            }
        }
        voice.stop()
        highlighter.clear()
        bubble.setChoices([])
        bubble.tag = nil
        if inBubble { bubbleAnswering = true }
        // Decide which earlier turns this question may see (default: only the current page's topic).
        let chipOffPre = inBubble && bubble.chatMode && bubble.shareTitle != nil && !bubble.sharing
        let pageTopic = inBubble && bubble.chatMode && bubble.sharing && Prefs.pageShare ? bubble.shareTitle : nil
        var since: Date? = nil, until: Date? = nil
        if let pickedTopic = chosenTopic, chipOffPre {
            since = pickedTopic.start
            until = topics.first(where: { $0.start > pickedTopic.start })?.start
            if until != nil { since = pickedTopic.start }
        } else if let t = pageTopic {
            let topic = beginTopic(title: t)
            since = topic.start
            // A page the cat hasn't talked about yet starts its own conversation (category 网页).
            if Date().timeIntervalSince(topic.start) < 2 && !store.currentMessages.isEmpty {
                store.startNew(title: t, category: "网页")
            }
        }
        // Coming back from the bubble after a long break: start a fresh conversation in the list.
        if inBubble && chosenTopic == nil && store.current != nil && store.idleTime > 2 * 3600 {
            store.startNew()
        }
        let project = store.currentProject
        let names = images.compactMap { store.saveImage($0) }
        store.append(ChatMessage(role: "user", text: text, imageNames: names, date: Date()))
        var history = apiHistory(newImages: images, since: since, until: until)
        store.append(ChatMessage(role: "assistant", text: "", imageNames: [], date: Date()))
        // The user can switch off the page chip for this chat: then nothing on screen is read.
        let chipOff = inBubble && bubble.chatMode && bubble.shareTitle != nil && !bubble.sharing
        let usePerception = Prefs.perception && !chipOff
        let sharePage = !usePerception && inBubble && bubble.chatMode && bubble.sharing && Prefs.pageShare && pageOverride == nil
        if inBubble {
            bubble.setActions([])
            let wait = usePerception ? "👀 我先看一眼你的屏幕…"
                : (sharePage ? (MediaHub.wantsVideo(text) ? "🎬 我看几眼画面、听几秒声音…" : "👀 正在读「\(bubble.shareTitle ?? "当前页面")」…") : "……")
            if bubble.chatMode { bubble.setText(wait) } else {
                let page = Prefs.pageShare ? hub.shareableWindow() : nil
                bubble.setShare(title: page?.title, on: page != nil)
                bubble.openChat(greeting: wait)
                startShareWatch()
            }
        }
        let gen = bubbleGen
        let pointish = ["重点", "关键", "在哪", "哪里", "哪儿", "标出", "圈", "指出", "找到", "highlight", "circle", "point"]
            .contains { text.lowercased().contains($0) }
        // The user's recent selection counts when they act on it, or ask to ring/point within 3 minutes of making it.
        let selMark: (rect: CGRect, pid: pid_t, text: String, at: Date)? = {
            guard let m = selectionMark, Date().timeIntervalSince(m.at) < 180 else { return nil }
            return (aboutSelection || pointish || text.contains(String(m.text.prefix(12)))) ? m : nil
        }()
        Task { @MainActor in
            var context: String?
            // Pictures the user attached: a text-only chat model gets the vision model's description instead.
            if !images.isEmpty && !Cap.visionUsesChat, let i = history.indices.last {
                if inBubble && gen == self.bubbleGen { self.bubble.setText("🖼️ 看图模型正在看图…") }
                let (desc, err) = await MediaHub.describe(images, question: text, appName: "用户发来的图片", video: false)
                let note = desc.map { "\n\n[用户发来的图片内容（看图模型的描述）]\n" + $0 }
                    ?? "\n\n[用户发来了 \(images.count) 张图片，但这次没看成：\(err ?? "未知原因")。请如实告诉用户，并提醒到 设置 → 模型 → 看图 检查。]"
                history[i] = ["role": "user", "content": text + note]
            }
            if sharePage, let page = await self.hub.pageContext(question: text, progress: { [weak self] msg in
                DispatchQueue.main.async {
                    guard let self = self, inBubble, gen == self.bubbleGen, self.bubble.isShown else { return }
                    self.bubble.setText(msg)
                }
            }) {
                // Put the page right next to the question, so it outweighs older chat turns.
                if let i = history.indices.last, history[i]["content"] is String {
                    let merged = page.text + "\n\n---\n我的问题（请以上面这个页面为准来回答）：" + text
                    if page.images.isEmpty {
                        history[i]["content"] = merged
                    } else {
                        var parts: [[String: Any]] = [["type": "text", "text": merged]]
                        for d in page.images {
                            parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + d.base64EncodedString()]])
                        }
                        history[i] = ["role": "user", "content": parts]
                    }
                } else {
                    context = page.text
                }
            }
            if let po = pageOverride, let i = history.indices.last, history[i]["content"] is String {
                history[i]["content"] = po + "\n\n---\n我的问题：" + text
            }
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
            if let x = extra, !x.isEmpty {
                context = context.map { x + "\n\n" + $0 } ?? x
            }
            // A project's standing note is kept in mind for every chat inside it.
            if let p = project, !p.note.isEmpty {
                let note = "[这个对话属于用户的项目「\(p.name)」，项目说明如下，回答时请参考]\n" + p.note
                context = context.map { note + "\n\n" + $0 } ?? note
            }
            var liveRinged = 0
            let ringLive = (usePerception || sharePage) && Prefs.highlight
            if ringLive { self.highlighter.clear() }
            // The text the user just selected: ring it right away, so they see what the cat is looking at.
            if let m = selMark, Prefs.highlight { self.highlighter.add(m.rect, number: 0, seconds: 20) }
            self.llm.stream(history, context: context, onDelta: { [weak self] t in
                guard let self = self else { return }
                // Ring each place the moment the answer points at it (positions from the capture just taken);
                // the final pass after the answer re-checks them and narrows to the exact line.
                if ringLive {
                    let live = self.hub.taggedTargets(in: t)
                    if live.count > liveRinged {
                        for g in live[liveRinged...] { self.highlighter.add(g.el.rect, number: g.n, seconds: 12) }
                        liveRinged = live.count
                    }
                }
                let shown = ContextHub.stripTags(t)
                self.store.updateLast(shown)
                if inBubble && self.bubble.isShown && gen == self.bubbleGen { self.bubble.setText(shown) }
            }, onDone: { [weak self] t, err in
                guard let self = self else { return }
                if inBubble { self.bubbleAnswering = false }
                let raw = t ?? ""
                let final = err.map { "⚠️ " + $0 } ?? ContextHub.stripTags(raw)
                self.store.updateLast(final)
                self.store.save()
                self.catView.perk(false)
                if inBubble && self.bubble.isShown && gen == self.bubbleGen { self.bubble.setText(final) }
                guard err == nil else { return }
                self.hub.recordChat(user: text, reply: final)
                self.autoTitle(user: text, reply: final)
                if (usePerception || sharePage || selMark != nil) && Prefs.highlight {
                    // Rings go exactly on the lines the answer talks about: tagged lines first, otherwise the
                    // on-screen line each point matches, otherwise the lines inside the user's selection.
                    // Positions are re-read right before drawing.
                    let pageRead = usePerception || sharePage
                    var targets = pageRead ? self.hub.taggedTargets(in: raw) : []
                    if targets.isEmpty && pointish && pageRead { targets = self.hub.fallbackTargets(for: final) }
                    let points = pageRead ? self.hub.pointTargets(in: raw) : []
                    Task { @MainActor in
                        var marks = await self.hub.relocate(targets) + points
                        if marks.isEmpty, let m = selMark {
                            marks = await self.hub.selectionMarks(rect: m.rect, pid: m.pid, reply: final, wantLines: pointish)
                        }
                        if !marks.isEmpty { self.highlighter.show(marks: marks.sorted { $0.1 < $1.1 }, seconds: 15) }
                        else if liveRinged > 0 { self.highlighter.clear() }   // everything scrolled away
                        if marks.isEmpty && pointish && inBubble && self.bubble.isShown && gen == self.bubbleGen {
                            self.bubble.setText(final + "\n\n" + L10n.t("（这次没在屏幕上找到能圈出来的位置。先选中那段文字，或打开「分享页面」再问我。）"))
                        }
                    }
                }
                var said = final
                if let a = after, let shown = a(raw) {
                    said = shown
                    self.store.updateLast(shown)
                    self.store.save()
                    if inBubble && self.bubble.isShown && gen == self.bubbleGen { self.bubble.setText(shown) }
                }
                if Prefs.voice || spoken { self.voice.speak(said.replacingOccurrences(of: "👉", with: "")) }
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
        CatLevel.shared.touch()
        if listener.isListening { listener.finish(); return }
        guard Prefs.voiceChat else {
            bubble.notify("语音对话还没开哦～右键点我 → 小猫 → 开启语音对话。",
                          actions: [("打开设置", { [weak self] in self?.settings.show(page: .cat) })])
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
            if let r = self.selection.lastRect {
                self.selectionMark = (r, self.selection.lastPid, s, Date())
            } else { self.selectionMark = nil }
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
        guard s.count >= 2, s.count <= 8000 else { return }
        if s == lastPrompted && bubble.isShown && !bubble.chatMode { return }
        guard catPanel.isVisible, !listener.isListening else { return }
        if bubble.chatMode && bubble.hasDraft { return }   // don't interrupt typing
        // Clicking into a post can look like a selection: never let it replace the fresh post card.
        if Date().timeIntervalSince(xCardAt) < 4 && bubble.isShown { return }
        lastPrompted = s
        catView.perk(true)
        let preview = s.count > 36 ? String(s.prefix(36)) + "…" : s
        let acts: [(String, () -> Void)] = [
            ("帮我看看 🐾", { [weak self] in
                self?.ask("请帮我看看下面这段内容：如果是报错或代码，告诉我问题和改法；如果是普通文字，用一两句话解释或接个话。\n\n\(s)", aboutSelection: true)
            }),
            (L10n.english ? "Translate" : "翻译", { [weak self] in
                self?.ask("把下面的内容翻译成中文（如果原文已经是中文，就翻译成英文），只给译文：\n\n\(s)", aboutSelection: true)
            }),
            ("问这段", { [weak self] in self?.bubble.prefill("关于「\(preview)」：") })
        ]
        // Chat box already open: offer the help inside it instead of closing the chat.
        if bubble.chatMode && bubble.isShown {
            bubble.offerInChat("✂️ 你\(verb)了「\(preview)」～要我帮忙吗？", actions: acts)
            return
        }
        bubbleGen += 1   // older streaming answers stop writing into the bubble
        bubble.notify("你\(verb)了「\(preview)」～要我帮忙吗？", actions: acts)
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

    /// Menu-bar eyes: sized like other menu-bar glyphs (≈11 pt tall, no glow); green dot while 桌面感知 is on.
    private func setStatusEyes(openness: CGFloat = 1) {
        statusItem?.button?.image = ordEyesImage(height: 11, glow: false,
                                                 dot: Prefs.perception ? .systemGreen : nil, openness: openness)
    }

    /// Blink the menu-bar eyes together with the cat (same 0.18 s timing as CatView.blink).
    private func blinkStatusEyes() {
        let steps: [(Double, CGFloat)] = [(0, 0.5), (0.045, 0.1), (0.09, 0.1), (0.135, 0.5), (0.18, 1)]
        for (t, o) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.setStatusEyes(openness: o) }
        }
    }

    private func scheduleBlink() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 3.5...8), repeats: false) { [weak self] _ in
            self?.catView.blink()
            self?.blinkStatusEyes()
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


/// Light Markdown for the bubble: **bold**, headings and list markers become plain, readable text.
/// Tolerates half-streamed text (an unclosed ** just makes the rest bold until it closes).
func bubbleAttributed(_ rawIn: String, size: CGFloat = 14) -> NSAttributedString {
    let raw = L10n.t(rawIn)
    var lines: [String] = []
    for l in raw.replacingOccurrences(of: "`", with: "").components(separatedBy: "\n") {
        let t = l.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") {
            lines.append(String(t.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces))
        } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("– ") || t.hasPrefix("— ") {
            lines.append("• " + String(t.dropFirst(2)))
        } else if t == "---" || t == "***" {
            lines.append("")
        } else {
            lines.append(l)
        }
    }
    let text = lines.joined(separator: "\n")
    let para = NSMutableParagraphStyle()
    para.lineSpacing = 2
    let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size),
                                               .foregroundColor: Theme.fg,
                                               .paragraphStyle: para]
    let out = NSMutableAttributedString()
    for (i, part) in text.components(separatedBy: "**").enumerated() {
        var a = base
        if i % 2 == 1 { a[.font] = NSFont.boldSystemFont(ofSize: size) }
        out.append(NSAttributedString(string: part, attributes: a))
    }
    return out
}
