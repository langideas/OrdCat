// OrdCat — media layer of the Local Context Hub.
// • Chat apps (WeChat, QQ, Telegram…) hide who said what from Accessibility: we OCR the window and
//   rebuild the conversation by position (left = others, right = me, small line above = nickname).
// • Pictures / video frames: a vision model looks at the window only when the user asks, and its
//   description is handed to the chat model (so text-only chat models still "see").
// • Video sound: a few seconds of system audio, transcribed on this Mac or by a cloud Whisper.
// Nothing here runs in the background: every capture happens because the user asked a question.

import Cocoa
import AVFoundation
import Speech
import ScreenCaptureKit
import CoreMedia

struct CapPreset { let name: String; let base: String; let model: String }

let kVisionPresets: [CapPreset] = [
    CapPreset(name: "自动（聊天模型会看图就用它，不会就用同服务商的看图模型）", base: "", model: ""),
    CapPreset(name: "Groq Qwen3.8 看图（可用同一个 Groq Key）", base: "https://api.groq.com/openai/v1", model: "qwen/qwen3.8-27b"),
    CapPreset(name: "硅基流动 Qwen2.5-VL", base: "https://api.siliconflow.cn/v1", model: "Qwen/Qwen2.5-VL-72B-Instruct"),
    CapPreset(name: "OpenAI gpt-4o-mini", base: "https://api.openai.com/v1", model: "gpt-4o-mini"),
    CapPreset(name: "Gemini 2.0 Flash", base: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-2.0-flash"),
    CapPreset(name: "Ollama 本地 qwen2.5vl（离线）", base: "http://localhost:11434/v1", model: "qwen2.5vl:7b"),
    CapPreset(name: "自定义（OpenAI 兼容）", base: "", model: "")
]

let kSTTPresets: [CapPreset] = [
    CapPreset(name: "本机苹果语音识别（离线、免费）", base: "", model: ""),
    CapPreset(name: "Groq Whisper Turbo（可用同一个 Groq Key）", base: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo"),
    CapPreset(name: "硅基流动 SenseVoice（中文好）", base: "https://api.siliconflow.cn/v1", model: "FunAudioLLM/SenseVoiceSmall"),
    CapPreset(name: "OpenAI gpt-4o-mini-transcribe", base: "https://api.openai.com/v1", model: "gpt-4o-mini-transcribe"),
    CapPreset(name: "自定义（OpenAI 兼容 /audio/transcriptions）", base: "", model: "")
]

extension Keychain {
    static let visionService = "app.ordcat.visionkey"
    static let sttService = "app.ordcat.sttkey"
}

extension Prefs {
    static var visionOn: Bool { get { d.object(forKey: "visionOn") as? Bool ?? true } set { d.set(newValue, forKey: "visionOn") } }
    static var visionPreset: Int { get { d.object(forKey: "visionPreset") as? Int ?? 0 } set { d.set(newValue, forKey: "visionPreset") } }
    static var visionBase: String { get { d.string(forKey: "visionBase") ?? "" } set { d.set(newValue, forKey: "visionBase") } }
    static var visionModel: String { get { d.string(forKey: "visionModel") ?? "" } set { d.set(newValue, forKey: "visionModel") } }
    static var sttPreset: Int { get { d.object(forKey: "sttPreset") as? Int ?? 0 } set { d.set(newValue, forKey: "sttPreset") } }
    static var sttBase: String { get { d.string(forKey: "sttBase") ?? "" } set { d.set(newValue, forKey: "sttBase") } }
    static var sttModel: String { get { d.string(forKey: "sttModel") ?? "" } set { d.set(newValue, forKey: "sttModel") } }
    static var videoAudio: Bool { get { d.object(forKey: "videoAudio") as? Bool ?? true } set { d.set(newValue, forKey: "videoAudio") } }
    static var chatLayout: Bool { get { d.object(forKey: "chatLayout") as? Bool ?? true } set { d.set(newValue, forKey: "chatLayout") } }
}

struct Endpoint { let base: String; let model: String; let key: String }

enum Cap {
    static func clean(_ b: String) -> String {
        var s = b.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// A capability's own key, or the chat key when it talks to the same provider.
    static func key(_ service: String, base: String) -> String {
        let k = Keychain.get(service: service)
        if !k.isEmpty { return k }
        if let h1 = URL(string: base)?.host, let h2 = URL(string: clean(Prefs.base))?.host, h1 == h2 { return Keychain.get() }
        return ""
    }

    /// Chat models we know cannot read images.
    static var chatModelIsTextOnly: Bool {
        let m = Prefs.model.lowercased()
        let textOnly = ["gpt-oss", "deepseek-chat", "deepseek-reasoner", "qwen2.5:", "qwen3:", "llama3", "llama-3", "kimi", "compound", "minimax"]
        return textOnly.contains { m.contains($0) } && !m.contains("vl") && !m.contains("vision")
    }

    /// True when the chat model itself should get the pictures.
    static var visionUsesChat: Bool { Prefs.visionPreset == 0 && !chatModelIsTextOnly }

    static var vision: Endpoint? {
        guard Prefs.visionOn else { return nil }
        let chatBase = clean(Prefs.base)
        if Prefs.visionPreset == 0 {
            if !chatModelIsTextOnly { return chatBase.isEmpty ? nil : Endpoint(base: chatBase, model: Prefs.model, key: Keychain.get()) }
            // Text-only chat model: borrow the same provider's vision model when we know one.
            if let p = kVisionPresets.dropFirst().first(where: { !$0.base.isEmpty && URL(string: $0.base)?.host == URL(string: chatBase)?.host }) {
                return Endpoint(base: p.base, model: p.model, key: key(Keychain.visionService, base: p.base))
            }
            return nil
        }
        let b = clean(Prefs.visionBase)
        guard !b.isEmpty, !Prefs.visionModel.isEmpty else { return nil }
        return Endpoint(base: b, model: Prefs.visionModel, key: key(Keychain.visionService, base: b))
    }

    static var stt: Endpoint? {
        guard Prefs.sttPreset != 0 else { return nil }
        let b = clean(Prefs.sttBase)
        guard !b.isEmpty, !Prefs.sttModel.isEmpty else { return nil }
        return Endpoint(base: b, model: Prefs.sttModel, key: key(Keychain.sttService, base: b))
    }
}

enum MediaHub {
    static let chatApps: Set<String> = [
        "com.tencent.xinWeChat", "com.tencent.qq", "com.tencent.QQ", "com.tencent.WeWorkMac",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "com.electron.lark", "com.bytedance.lark", "com.alibaba.DingTalkMac", "com.apple.MobileSMS",
        "jp.naver.line.mac", "net.whatsapp.WhatsApp", "desktop.WhatsApp"
    ]
    static let videoApps: Set<String> = [
        "com.colliderli.iina", "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.apple.TV",
        "com.bilibili.bilibiliPC", "com.youku.mac", "com.tencent.tenvideo", "com.apple.FinalCut"
    ]

    static func isChatApp(_ bid: String) -> Bool {
        let b = bid.lowercased()
        return chatApps.contains(bid) || b.contains("wechat") || b.contains("lark") || b.contains("feishu")
    }
    static func wantsMedia(_ q: String) -> Bool {
        ["图", "照片", "相片", "截图", "表情", "画面", "长什么", "长啥", "是什么东西", "这是什么", "海报", "头像", "颜色", "动图", "看看", "看一下", "看下"].contains { q.contains($0) } || wantsVideo(q)
    }
    static func wantsVideo(_ q: String) -> Bool {
        ["视频", "在播", "播放", "影片", "电影", "直播", "片段", "说了什么", "讲了什么", "唱的"].contains { q.contains($0) }
    }

    // MARK: chat layout from OCR

    /// Rebuild a chat by position. Coordinates are relative to the window so the model can reason about columns.
    static func chatTranscript(_ els: [ScreenElement], window: CGRect) -> String {
        guard window.width > 0 else { return els.map { $0.text }.joined(separator: "\n") }
        let sorted = els.sorted { abs($0.rect.minY - $1.rect.minY) > 6 ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
        // Wide windows usually show the conversation list on the left: find the chat column.
        var chatLeft = window.minX
        if window.width > 760 {
            let xs = sorted.map { $0.rect.minX - window.minX }.filter { $0 > 200 && $0 < window.width * 0.5 }
            if let m = xs.min(), m < 420 { chatLeft = window.minX + m - 70 }
        }
        let chatWidth = window.maxX - chatLeft
        var lines: [String] = []
        for e in sorted {
            let t = e.text.replacingOccurrences(of: "\n", with: " ")
            let relY = Int(e.rect.minY - window.minY)
            if e.rect.maxX < chatLeft + 4 { lines.append("[会话列表] \(t)"); continue }
            if relY < 64 { lines.append("[顶部·聊天名称] \(t)"); continue }
            let relX = e.rect.minX - chatLeft
            let side: String
            if abs(e.rect.midX - (chatLeft + chatWidth / 2)) < chatWidth * 0.12 && e.rect.width < chatWidth * 0.3 { side = "居中" }
            else if relX > chatWidth * 0.45 || e.rect.maxX > window.maxX - chatWidth * 0.12 && relX > chatWidth * 0.3 { side = "右·我" }
            else { side = "左·对方" }
            lines.append("[\(side) x\(Int(relX)) 字高\(Int(e.rect.height))] \(t)")
        }
        return lines.joined(separator: "\n")
    }

    static let chatGuide = """
    这是聊天软件，下面按屏幕位置还原了聊天内容：
    • [左·对方] 是别人发的，[右·我] 是用户自己发的，[居中] 一般是时间或系统提示；
    • 左侧消息正上方、字高更小的那一行，通常就是发这条消息的人的昵称（群聊时）；
    • [顶部·聊天名称] 是群名或聊天对象。
    回答「谁说的」「谁发的」时，请按这个规则判断，并直接说出昵称。
    """

    // MARK: images

    static func jpeg(_ img: CGImage, maxSide: CGFloat = 1280) -> Data? {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let s = min(1, maxSide / max(w, h))
        let tw = max(1, Int(w * s)), th = max(1, Int(h * s))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    }

    /// Ask the vision model what is in the pictures. Returns (description, error).
    static func describe(_ images: [Data], question: String, appName: String, video: Bool) async -> (String?, String?) {
        guard let ep = Cap.vision, let url = URL(string: ep.base + "/chat/completions") else {
            return (nil, "还没设置看图模型")
        }
        let what = video ? "这是用户「\(appName)」窗口里按时间顺序连拍的 \(images.count) 帧画面（可能在放视频）。"
                         : "这是用户「\(appName)」窗口的截图。"
        let prompt = """
        \(what)请用简体中文客观描述：
        1）画面里的图片、照片、表情包、视频画面分别是什么内容（人物、动物、物体、文字、场景、动作）；
        2）如果是聊天窗口：每张图片/视频是谁发的（看它旁边的昵称；右侧是用户自己）；
        3）和这个问题有关的细节：\(question.isEmpty ? "（无）" : question)
        只描述看得到的，不要编造。不超过 250 字。
        """
        var parts: [[String: Any]] = [["type": "text", "text": prompt]]
        for d in images.prefix(4) {
            parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + d.base64EncodedString()]])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !ep.key.isEmpty { req.setValue("Bearer \(ep.key)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = ["model": ep.model, "messages": [["role": "user", "content": parts]],
                                   "max_tokens": 700, "stream": false]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else {
                return (nil, "看图模型返回错误（\(code)）：\(String(data: data, encoding: .utf8)?.prefix(160) ?? "")")
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = (obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
                  let text = msg["content"] as? String, !text.isEmpty else { return (nil, "看图模型没有回答") }
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        } catch {
            return (nil, "连不上看图模型：\(error.localizedDescription)")
        }
    }

    // MARK: speech to text

    /// Cloud first when the user picked one, otherwise Apple's on-device recognizer.
    static func transcribe(_ file: URL, cloudOnly: Bool = false) async -> String? {
        if let ep = Cap.stt { return await cloudTranscribe(file, ep: ep).0 }
        return cloudOnly ? nil : await localTranscribe(file)
    }

    static func cloudTranscribe(_ file: URL, ep: Endpoint) async -> (String?, String?) {
        guard let url = URL(string: ep.base + "/audio/transcriptions"), let audio = try? Data(contentsOf: file) else {
            return (nil, "读不到录音")
        }
        let boundary = "OrdCat-\(UUID().uuidString)"
        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        field("model", ep.model)
        if !ep.base.contains("siliconflow") { field("language", "zh") }
        let ext = file.pathExtension.isEmpty ? "wav" : file.pathExtension
        let mime = ext == "m4a" ? "audio/mp4" : "audio/wav"
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"clip.\(ext)\"\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 40
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !ep.key.isEmpty { req.setValue("Bearer \(ep.key)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 300 else { return (nil, "识别服务返回错误（\(code)）：\(String(data: data, encoding: .utf8)?.prefix(160) ?? "")") }
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return ((obj?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", nil)
        } catch {
            return (nil, "连不上识别服务：\(error.localizedDescription)")
        }
    }

    private final class Once { var done = false }

    static func localTranscribe(_ file: URL) async -> String? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let rec = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), rec.isAvailable else { return nil }
        let req = SFSpeechURLRecognitionRequest(url: file)
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            rec.recognitionTask(with: req) { r, e in
                if once.done { return }
                if let r = r, r.isFinal { once.done = true; cont.resume(returning: r.bestTranscription.formattedString) }
                else if e != nil { once.done = true; cont.resume(returning: nil) }
            }
        }
    }

    /// Listen to what the Mac is playing for a few seconds and turn it into text.
    static func listenToScreen(seconds: Double) async -> String? {
        guard #available(macOS 13.0, *) else { return nil }
        guard let clip = await AudioClip().record(seconds: seconds) else { return nil }
        defer { try? FileManager.default.removeItem(at: clip) }
        let t = await transcribe(clip)
        return (t?.isEmpty ?? true) ? nil : t
    }

    /// One second of silence as WAV, for the 测试 button of a speech service.
    static func silentWav() -> URL {
        let rate: UInt32 = 16000, n: UInt32 = rate
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + n * 2); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(n * 2); d.append(Data(count: Int(n * 2)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ordcat-silence.wav")
        try? d.write(to: url)
        return url
    }
}

/// A short recording of the Mac's own sound output (needs Screen Recording permission).
@available(macOS 13.0, *)
final class AudioClip: NSObject, SCStreamOutput {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private let q = DispatchQueue(label: "app.ordcat.audioclip")

    func record(seconds: Double) async -> URL? {
        guard ScreenReader.screenRecordingAllowed() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 16000
            cfg.channelCount = 1
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ordcat-clip-\(UUID().uuidString).m4a")
            let w = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48000]
            let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            inp.expectsMediaDataInRealTime = true
            guard w.canAdd(inp) else { return nil }
            w.add(inp)
            writer = w
            input = inp
            let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
            try await s.startCapture()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            try? await s.stopCapture()
            return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
                q.async {
                    guard self.started, let w = self.writer else { cont.resume(returning: nil); return }
                    self.input?.markAsFinished()
                    w.finishWriting { cont.resume(returning: w.status == .completed ? url : nil) }
                }
            }
        } catch {
            return nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let w = writer, let inp = input else { return }
        if !started {
            guard w.startWriting() else { return }
            w.startSession(atSourceTime: sb.presentationTimeStamp)
            started = true
        }
        if inp.isReadyForMoreMediaData { inp.append(sb) }
    }
}
