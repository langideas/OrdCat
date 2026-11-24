// SoundListen.swift — 小猫弹窗的「🔊 正在听」(v0.2.59)
//   • 电脑里有应用在出声时，「正在分享」下面多一行「🔊 正在听「微信」」，没声音就不显示。
//   • 默认不带上。用户点亮后，小猫在本机把那个应用的声音转成文字，只在内存里留最近 10 分钟，不保存。
//   • 弹窗关掉就停止并清空。

import Cocoa
import AVFoundation
import Speech
import ScreenCaptureKit
import CoreAudio
import CoreMedia

/// Which apps are making sound right now (Core Audio process list, macOS 14.2+).
enum AudioPlayers {
    struct Player: Equatable { let pid: pid_t; let bundleID: String; let name: String }

    /// The regular apps currently playing sound, OrdCat itself left out. Older macOS: none.
    static func playing() -> [Player] {
        guard #available(macOS 14.2, *) else { return [] }
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let me = Bundle.main.bundleIdentifier ?? ""
        var out: [Player] = []
        for id in ids {
            guard uint32(id, kAudioProcessPropertyIsRunningOutput) == 1 else { continue }
            var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var ps = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(id, &pidAddr, 0, nil, &ps, &pid) == noErr, pid > 0 else { continue }
            guard let app = owningApp(pid: pid, bundleID: bundleID(id)),
                  let bid = app.bundleIdentifier, bid != me else { continue }
            let p = Player(pid: app.processIdentifier, bundleID: bid, name: app.localizedName ?? bid)
            if !out.contains(where: { $0.bundleID == p.bundleID }) { out.append(p) }
        }
        return out
    }

    private static func uint32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var s = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr ? v : 0
    }

    private static func bundleID(_ id: AudioObjectID) -> String {
        guard #available(macOS 14.2, *) else { return "" }
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var s = UInt32(MemoryLayout<CFString?>.size)
        var v: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr, let str = v?.takeRetainedValue() else { return "" }
        return str as String
    }

    /// Browser and app helpers (Chrome Helper, WebKit GPU…) are traced back to the app the user sees.
    private static func owningApp(pid: pid_t, bundleID: String) -> NSRunningApplication? {
        if let a = NSRunningApplication(processIdentifier: pid), a.activationPolicy == .regular { return a }
        let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var parts = bundleID.split(separator: ".").map(String.init)
        while parts.count > 2 {
            parts.removeLast()
            let prefix = parts.joined(separator: ".")
            if let a = regular.first(where: { $0.bundleIdentifier == prefix }) { return a }
        }
        if bundleID.hasPrefix("com.apple.WebKit") {
            // WebKit's audio process belongs to Safari (or another WebKit app); prefer the one in front.
            let front = NSWorkspace.shared.frontmostApplication
            if let f = front, f.bundleIdentifier == "com.apple.Safari" { return f }
            return regular.first { $0.bundleIdentifier == "com.apple.Safari" }
        }
        return nil
    }
}

/// Turns one app's sound into text on this Mac and keeps the last 10 minutes in memory.
final class SoundListen: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = SoundListen()
    static let keepSeconds: TimeInterval = 600

    private(set) var appName = ""
    private(set) var bundleID = ""
    private(set) var running = false
    /// Finished pieces of text, oldest first, trimmed to the last 10 minutes.
    private var pieces: [(at: Date, text: String)] = []
    private var latest = ""
    private var stream: SCStream?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recTask: SFSpeechRecognitionTask?
    private var recGen = 0
    private var taskStarted = Date()
    private var restartTimer: Timer?
    private let audioQ = DispatchQueue(label: "ordcat.soundlisten")
    private var starting = false

    /// The language the cat listens for. Default: Chinese when the Mac is in Chinese, else English.
    static var language: String {
        get {
            if let s = UserDefaults.standard.string(forKey: "soundListenLang") { return s }
            return (Locale.preferredLanguages.first ?? "").hasPrefix("zh") ? "zh-CN" : "en-US"
        }
        set { UserDefaults.standard.set(newValue, forKey: "soundListenLang") }
    }

    var hasText: Bool { !transcript().isEmpty }

    /// Start listening to this app (switches app when another one is playing; text heard so far is kept).
    func start(_ p: AudioPlayers.Player) {
        if (running || starting) && p.bundleID == bundleID { return }
        stopCapture()
        starting = true
        bundleID = p.bundleID
        appName = p.name
        SFSpeechRecognizer.requestAuthorization { st in
            DispatchQueue.main.async {
                guard st == .authorized else { self.starting = false; return }
                Task { @MainActor in await self.capture(p) }
            }
        }
    }

    @MainActor private func capture(_ p: AudioPlayers.Player) async {
        defer { starting = false }
        guard bundleID == p.bundleID,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let display = content.displays.first,
              let app = content.applications.first(where: { $0.bundleIdentifier == p.bundleID }),
              let rec = SFSpeechRecognizer(locale: Locale(identifier: SoundListen.language)), rec.isAvailable else { return }
        recognizer = rec
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 16000
        cfg.channelCount = 1
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: SCContentFilter(display: display, including: [app], exceptingWindows: []),
                         configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQ)
            try await s.startCapture()
        } catch { return }
        stream = s
        running = true
        startRecognition()
        // A fresh recognition task every ~50 s keeps long listening under the recognizer's limits.
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in self?.restartRecognition() }
    }

    /// Language changed: listen again with the new one (text heard so far is kept).
    func relisten() {
        guard running else { return }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: SoundListen.language))
        restartRecognition()
    }

    /// Stop capturing. clear = also forget everything heard.
    func stop(clear: Bool) {
        stopCapture()
        if clear { pieces = []; latest = ""; appName = ""; bundleID = "" }
    }

    private func stopCapture() {
        restartTimer?.invalidate(); restartTimer = nil
        commit()
        recGen += 1
        audioQ.sync { self.request?.endAudio(); self.request = nil }
        recTask?.cancel(); recTask = nil
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
        running = false
    }

    private func startRecognition() {
        guard running, let rec = recognizer, rec.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        req.taskHint = .dictation
        audioQ.sync { self.request = req }
        taskStarted = Date()
        recGen += 1
        let myGen = recGen
        recTask = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.running, myGen == self.recGen else { return }
                if let r = result {
                    self.latest = r.bestTranscription.formattedString
                    if r.isFinal { self.restartRecognition() }
                } else if error != nil {
                    // No speech yet right after a start: wait a moment so it never spins.
                    let wait = Date().timeIntervalSince(self.taskStarted) < 3 ? 1.5 : 0
                    self.recGen += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.restartRecognition() }
                }
            }
        }
    }

    private func restartRecognition() {
        guard running else { return }
        commit()
        let old = recTask
        recGen += 1
        audioQ.sync { self.request?.endAudio() }
        old?.finish()
        startRecognition()
    }

    private func commit() {
        let t = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        latest = ""
        if !t.isEmpty { pieces.append((Date(), t)) }
        trim()
    }

    private func trim() {
        let cut = Date().addingTimeInterval(-SoundListen.keepSeconds)
        pieces.removeAll { $0.at < cut }
    }

    /// Everything heard in the last 10 minutes, oldest first.
    func transcript() -> String {
        trim()
        var all = pieces.map { $0.text }
        let now = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !now.isEmpty { all.append(now) }
        return all.joined(separator: "\n")
    }

    /// The text the model gets with the user's message.
    func context() -> String? {
        let body = transcript()
        if body.isEmpty {
            guard !appName.isEmpty else { return nil }
            return "## 用户让小猫一起听「\(appName)」的声音\n（还没听到说话。请如实告诉用户，不要编造。）"
        }
        return """
        ## 用户让小猫一起听「\(appName)」的声音（最近 10 分钟，在本机转成的文字）
        用户说「刚才」「他说的」「这段」「这条语音」时，指的就是下面这些内容。请根据这些文字回答，不要编造没听到的内容；语音识别可能有错字，按上下文理解。
        \(String(body.suffix(16000)))
        """
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let req = request, let buf = MiaoChuan.pcm(sb) else { return }
        req.append(buf)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.stopCapture() }
    }
}
