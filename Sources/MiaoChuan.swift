// OrdCat — 技能「喵传」🎧：实时翻译 / 解读 Mac 里的语音会议、视频会议、X Spaces。
//
// v1 (Lang 2026-11-23):
//   • 用户点「开始喵传」→ 弹窗选要听的应用和语言（这就是开始前的确认）。
//   • ScreenCaptureKit 只录那个应用的声音（不录画面），苹果语音识别优先在本机转文字，声音不离开 Mac。
//   • 每说完一句，用用户自己设置的模型翻译成目标语言（只发文字）。
//   • 屏幕下方一条字幕条：原话（小字）+ 译文（大字），可以拖动；「刚才在说什么」总结最近几分钟。
//   • 字幕只在内存里，点「停止」就清掉，不自动保存、不上传。
// v2 (later): 会议纪要、术语解释、「我该怎么回」、识别自己的麦克风。

import Cocoa
import AVFoundation
import Speech
import ScreenCaptureKit
import CoreMedia

extension Prefs {
    static var miaoOn: Bool { get { d.object(forKey: "miaoOn") as? Bool ?? false } set { d.set(newValue, forKey: "miaoOn") } }
    /// Language the speakers use (speech recognizer locale).
    static var miaoSource: String { get { d.string(forKey: "miaoSource") ?? "en-US" } set { d.set(newValue, forKey: "miaoSource") } }
    /// Language the subtitles are translated into.
    static var miaoTarget: String { get { d.string(forKey: "miaoTarget") ?? (L10n.english ? "en" : "zh") } set { d.set(newValue, forKey: "miaoTarget") } }
}

final class MiaoChuan: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = MiaoChuan()

    /// (locale id, name shown, name used in the prompt)
    static let sources: [(String, String, String)] = [
        ("en-US", "英语", "English"), ("zh-CN", "中文（普通话）", "Chinese"), ("zh-TW", "中文（台湾）", "Chinese"),
        ("ja-JP", "日语", "Japanese"), ("ko-KR", "韩语", "Korean"), ("de-DE", "德语", "German"),
        ("fr-FR", "法语", "French"), ("es-ES", "西班牙语", "Spanish"), ("ru-RU", "俄语", "Russian")
    ]
    static let targets: [(String, String, String)] = [
        ("zh", "简体中文", "Simplified Chinese"), ("en", "英语", "English"), ("ja", "日语", "Japanese"),
        ("de", "德语", "German"), ("ko", "韩语", "Korean")
    ]

    /// Shows a longer message next to the cat (set by the app delegate).
    var present: ((String) -> Void)?

    private(set) var running = false
    private var stream: SCStream?
    private let audioQ = DispatchQueue(label: "app.ordcat.miao.audio")
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recTask: SFSpeechRecognitionTask?
    private var taskStarted = Date()
    private var recGen = 0
    private var appName = ""

    // Sentence handling (main thread).
    private var latestText = ""          // the current recognition task's full text
    private var committed = 0            // characters of latestText already sent for translation
    private var lastChange = Date()
    private var tick: Timer?
    private var lines: [(at: Date, orig: String, tr: String)] = []
    private var queue: [Int] = []        // indexes into lines waiting for translation
    private var translating = false
    private let llm = LLM()
    private let sumLLM = LLM()
    private var bar: MiaoBar?

    private var sourceName: String { MiaoChuan.sources.first { $0.0 == Prefs.miaoSource }?.2 ?? "English" }
    private var targetName: String { MiaoChuan.targets.first { $0.0 == Prefs.miaoTarget }?.2 ?? "Simplified Chinese" }
    private var sameLanguage: Bool {
        let s = Prefs.miaoSource.prefix(2), t = Prefs.miaoTarget.prefix(2)
        return s == t
    }

    // MARK: start / stop

    func toggle() { running ? stop() : begin() }

    /// Pick the app and languages, check permissions, then listen.
    func begin() {
        guard !running else { bar?.show(); return }
        guard Prefs.miaoOn, Billing.isUnlocked("miao") || !Billing.enabled else {
            present?(L10n.t("先在 设置 → 技能 打开「喵传」再用哦。"))
            return
        }
        guard ScreenReader.screenRecordingAllowed() else {
            ScreenReader.requestScreenRecording()
            present?(L10n.t("喵传要听电脑里的声音，需要「屏幕录制」权限。去 系统设置 → 隐私与安全性 → 屏幕录制 打开 OrdCat，再点一次开始。"))
            return
        }
        SFSpeechRecognizer.requestAuthorization { st in
            DispatchQueue.main.async {
                guard st == .authorized else {
                    self.present?(L10n.t("喵传需要「语音识别」权限。去 系统设置 → 隐私与安全性 → 语音识别 打开 OrdCat。"))
                    return
                }
                Task { @MainActor in await self.pickAndStart() }
            }
        }
    }

    @MainActor private func pickAndStart() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else {
            present?(L10n.t("没拿到屏幕内容，确认一下「屏幕录制」权限。"))
            return
        }
        let me = Bundle.main.bundleIdentifier ?? ""
        let withWindows = Set(content.windows.compactMap { $0.owningApplication?.bundleIdentifier })
        var apps = content.applications.filter {
            $0.bundleIdentifier != me && withWindows.contains($0.bundleIdentifier) && !$0.applicationName.isEmpty
        }
        apps.sort { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
        guard !apps.isEmpty else { present?(L10n.t("没找到能听的应用，先把会议或 X Spaces 打开。")); return }

        // The start dialog: which app, which languages. Pressing 开始 is the user's go-ahead.
        let appPop = NSPopUpButton(frame: .zero, pullsDown: false)
        for a in apps { appPop.addItem(withTitle: a.applicationName) }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let guess = apps.firstIndex { $0.bundleIdentifier == front }
            ?? apps.firstIndex { app in
                let id = app.bundleIdentifier.lowercased()
                return ["zoom", "teams", "chrome", "safari", "meet", "wemeet", "tencent", "lark", "feishu", "discord", "slack"]
                    .contains { id.contains($0) }
            } ?? 0
        appPop.selectItem(at: guess)
        let srcPop = NSPopUpButton(frame: .zero, pullsDown: false)
        for s in MiaoChuan.sources { srcPop.addItem(withTitle: L10n.t(s.1)) }
        srcPop.selectItem(at: MiaoChuan.sources.firstIndex { $0.0 == Prefs.miaoSource } ?? 0)
        let dstPop = NSPopUpButton(frame: .zero, pullsDown: false)
        for t in MiaoChuan.targets { dstPop.addItem(withTitle: L10n.t(t.1)) }
        dstPop.selectItem(at: MiaoChuan.targets.firstIndex { $0.0 == Prefs.miaoTarget } ?? 0)

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let rows: [(String, NSPopUpButton)] = [("听哪个应用", appPop), ("他们说的语言", srcPop), ("翻译成", dstPop)]
        for (i, r) in rows.enumerated() {
            let y = CGFloat(68 - i * 34)
            let l = NSTextField(labelWithString: r.0)
            l.frame = NSRect(x: 0, y: y + 4, width: 100, height: 18)
            r.1.frame = NSRect(x: 104, y: y, width: 196, height: 26)
            box.addSubview(l); box.addSubview(r.1)
        }
        let a = NSAlert()
        a.messageText = L10n.t("🎧 开始喵传")
        a.informativeText = L10n.t("小猫只听你选的应用的声音，在本机转成文字，再用你设置的模型翻译（只发文字）。字幕不会保存，点「停止」就清掉。")
        a.accessoryView = box
        a.addButton(withTitle: L10n.t("开始"))
        let c = a.addButton(withTitle: L10n.t("取消")); c.keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Prefs.miaoSource = MiaoChuan.sources[srcPop.indexOfSelectedItem].0
        Prefs.miaoTarget = MiaoChuan.targets[dstPop.indexOfSelectedItem].0
        let app = apps[appPop.indexOfSelectedItem]
        appName = app.applicationName

        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: Prefs.miaoSource)), rec.isAvailable else {
            present?(L10n.t("这台 Mac 现在用不了这个语言的语音识别，换一个语言试试。"))
            return
        }
        recognizer = rec
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 16000
        cfg.channelCount = 1
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQ)
            try await s.startCapture()
        } catch {
            present?(L10n.t("没能开始听：") + error.localizedDescription)
            return
        }
        stream = s
        running = true
        lines = []; queue = []; latestText = ""; committed = 0
        startRecognition()
        let b = bar ?? MiaoBar()
        b.onStop = { [weak self] in self?.stop() }
        b.onSummary = { [weak self] in self?.summarize() }
        b.onLanguages = { [weak self] src, dst in self?.changeLanguages(source: src, target: dst) }
        bar = b
        b.syncLanguages()
        b.setStatus(L10n.english ? "● Listening to \(appName)" : "● 正在听 \(appName)")
        b.setLines(prev: nil, orig: L10n.t("等有人说话…"), tr: "")
        b.show()
        tick = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.onTick() }
    }

    /// Languages changed from the subtitle bar while listening: a new source restarts recognition.
    func changeLanguages(source: String, target: String) {
        let srcChanged = source != Prefs.miaoSource
        Prefs.miaoSource = source
        Prefs.miaoTarget = target
        guard running, srcChanged else { return }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: source)), rec.isAvailable else {
            bar?.setStatus(L10n.t("这台 Mac 现在用不了这个语言的语音识别，换一个语言试试。"))
            return
        }
        commitTail()
        recognizer = rec
        restartRecognition()
        bar?.setStatus(L10n.english ? "● Listening to \(appName)" : "● 正在听 \(appName)")
    }

    func stop() {
        guard running else { return }
        running = false
        tick?.invalidate(); tick = nil
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
        audioQ.async {
            self.request?.endAudio()
            self.recTask?.cancel()
            self.request = nil; self.recTask = nil
        }
        llm.cancel(); sumLLM.cancel()
        lines = []; queue = []; translating = false
        bar?.hide()
        present?(L10n.t("喵传停啦，这次的字幕已经清掉了 🎧"))
    }

    // MARK: recognition

    /// A new recognition task (also every ~50 s, so long meetings never hit the recognizer's limits).
    private func startRecognition() {
        guard let rec = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        req.taskHint = .dictation
        audioQ.sync {
            self.request = req
        }
        taskStarted = Date()
        recGen += 1
        let myGen = recGen
        recTask = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                // Results from a task we already replaced are ignored.
                guard let self = self, self.running, myGen == self.recGen else { return }
                if let r = result {
                    let t = r.bestTranscription.formattedString
                    if t != self.latestText { self.latestText = t; self.lastChange = Date(); self.onText() }
                    if r.isFinal { self.commitTail(); self.restartRecognition() }
                } else if error != nil {
                    // Errors right after a start (e.g. no speech yet) wait a moment so we never spin.
                    self.commitTail()
                    let wait = Date().timeIntervalSince(self.taskStarted) < 3 ? 1.5 : 0
                    self.recGen += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.restartRecognition() }
                }
            }
        }
    }

    private func restartRecognition() {
        guard running else { return }
        let old = recTask
        recGen += 1
        audioQ.sync { self.request?.endAudio() }
        old?.finish()
        latestText = ""; committed = 0
        startRecognition()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let req = request, let buf = MiaoChuan.pcm(sb) else { return }
        req.append(buf)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard self.running else { return }
            self.stop()
            self.present?(L10n.t("喵传停了：那个应用可能关掉了。"))
        }
    }

    static func pcm(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd),
              let fmt = AVAudioFormat(streamDescription: asbd) else { return nil }
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
        buf.frameLength = n
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList)
        return st == noErr ? buf : nil
    }

    // MARK: sentences

    private func tail() -> String {
        guard latestText.count > committed else { return "" }
        return String(latestText.dropFirst(committed))
    }

    /// Finished sentences go to translation; the unfinished rest shows live.
    private func onText() {
        var t = tail()
        let enders: Set<Character> = [".", "?", "!", "。", "？", "！", "…"]
        while let i = t.firstIndex(where: { enders.contains($0) }) {
            let sentence = String(t[...i]).trimmingCharacters(in: .whitespaces)
            committed += t.distance(from: t.startIndex, to: t.index(after: i))
            if sentence.count > 1 { add(sentence) }
            t = tail()
        }
        let live = t.trimmingCharacters(in: .whitespaces)
        if !live.isEmpty { bar?.setLive(live) }
    }

    private func onTick() {
        guard running else { return }
        // A pause of 1.2 s ends a sentence even without punctuation; long talk gets cut at ~120 characters.
        let t = tail().trimmingCharacters(in: .whitespaces)
        if !t.isEmpty && (Date().timeIntervalSince(lastChange) > 1.2 || t.count > 120) { commitTail() }
        let age = Date().timeIntervalSince(taskStarted)
        if (age > 50 && tail().trimmingCharacters(in: .whitespaces).isEmpty) || age > 58 { commitTail(); restartRecognition() }
    }

    private func commitTail() {
        let t = tail().trimmingCharacters(in: .whitespaces)
        committed = latestText.count
        if t.count > 1 { add(t) }
    }

    private func add(_ sentence: String) {
        lines.append((Date(), sentence, ""))
        // Keep about 15 minutes in memory, nothing more.
        let cutoff = Date().addingTimeInterval(-15 * 60)
        let drop = lines.prefix { $0.at < cutoff }.count
        if drop > 0 { lines.removeFirst(drop); queue = queue.map { $0 - drop }.filter { $0 >= 0 } }
        if sameLanguage {
            show()
        } else {
            queue.append(lines.count - 1)
            show()
            translateNext()
        }
    }

    private func show() {
        guard let last = lines.last else { return }
        let prev = lines.count >= 2 ? lines[lines.count - 2] : nil
        bar?.setLines(prev: prev.map { $0.tr.isEmpty ? $0.orig : $0.tr }, orig: sameLanguage ? "" : last.orig, tr: sameLanguage ? last.orig : last.tr)
    }

    private func translateNext() {
        guard running, !translating, !queue.isEmpty else { return }
        // Behind by more than 3 lines: skip the oldest so subtitles stay live.
        if queue.count > 3 { queue.removeFirst(queue.count - 3) }
        let i = queue.removeFirst()
        guard i < lines.count else { translateNext(); return }
        translating = true
        let ctx = """
        [喵传 · 同声传译] 你现在只做翻译。把用户发来的这句 \(sourceName) 翻译成 \(targetName)。
        只输出译文本身：不要解释、不要引号、不要表情、不要加前缀。语音识别可能有错字，按上下文猜最合理的意思。
        """
        let before = lines[max(0, i - 2)..<i].map { $0.orig }.joined(separator: " ")
        let msg = before.isEmpty ? lines[i].orig : "（上文：\(before)）\n要翻译的句子：\(lines[i].orig)"
        llm.stream([["role": "user", "content": msg]], context: ctx, onDelta: { [weak self] t in
            guard let self = self, self.running, i < self.lines.count else { return }
            self.lines[i].tr = t
            if i == self.lines.count - 1 { self.show() }
        }, onDone: { [weak self] t, err in
            guard let self = self else { return }
            self.translating = false
            guard self.running else { return }
            if i < self.lines.count {
                self.lines[i].tr = err == nil ? (t ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : "⚠️ " + (err ?? "")
                if i == self.lines.count - 1 { self.show() }
            }
            self.translateNext()
        })
    }

    // MARK: 刚才在说什么

    func summarize() {
        let recent = lines.filter { $0.at > Date().addingTimeInterval(-5 * 60) }
        guard !recent.isEmpty else { present?(L10n.t("最近几分钟还没听到人说话。")); return }
        let text = recent.map { $0.tr.isEmpty ? $0.orig : "\($0.orig)\n→ \($0.tr)" }.joined(separator: "\n")
        let ctx = """
        [喵传 · 解读] 下面是用户正在听的会议/语音（\(appName)）最近几分钟的语音识别原文和译文，识别可能有错字。
        用 \(targetName) 简洁回答：1) 在聊什么 2) 谁提出了什么观点或数字 3) 有没有需要用户注意或回应的地方。不超过 150 字。
        """
        bar?.setSummaryBusy(true)
        sumLLM.stream([["role": "user", "content": text]], context: ctx, onDelta: { _ in }, onDone: { [weak self] t, err in
            guard let self = self else { return }
            self.bar?.setSummaryBusy(false)
            self.present?("🎧 " + (err.map { "⚠️ " + $0 } ?? (t ?? "")))
        })
    }
}

// MARK: - 字幕条

/// Subtitle look, kept between sessions: size, weight and colour of the translated line.
enum MiaoStyle {
    private static let d = UserDefaults.standard
    static let colors: [(String, NSColor)] = [
        ("白色", NSColor(white: 1, alpha: 0.96)),
        ("琥珀", kAmber),
        ("浅黄", NSColor(srgbRed: 1, green: 0.93, blue: 0.62, alpha: 1)),
        ("浅蓝", NSColor(srgbRed: 0.62, green: 0.83, blue: 1, alpha: 1)),
        ("浅绿", NSColor(srgbRed: 0.62, green: 0.94, blue: 0.72, alpha: 1))
    ]
    static let weights: [(String, NSFont.Weight)] = [("常规", .regular), ("中等", .medium), ("粗", .bold)]
    static var size: CGFloat {
        get { let v = d.double(forKey: "miao.fontSize"); return v > 0 ? CGFloat(v) : 18 }
        set { d.set(Double(min(40, max(12, newValue))), forKey: "miao.fontSize") }
    }
    static var weight: Int {
        get { d.object(forKey: "miao.fontWeight") == nil ? 1 : min(2, max(0, d.integer(forKey: "miao.fontWeight"))) }
        set { d.set(newValue, forKey: "miao.fontWeight") }
    }
    static var color: Int {
        get { min(colors.count - 1, max(0, d.integer(forKey: "miao.fontColor"))) }
        set { d.set(newValue, forKey: "miao.fontColor") }
    }
}

/// A floating subtitle bar at the bottom of the screen: original line small, translation large. Draggable.
/// The header holds the language pickers and Aa (font size, weight, colour); the bar grows and shrinks with the font.
final class MiaoBar: NSObject {
    var onStop: (() -> Void)?
    var onSummary: (() -> Void)?
    var onLanguages: ((String, String) -> Void)?
    private let panel: NSPanel
    private let card = NSView()
    private let grad = CAGradientLayer()
    private let title = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let prevLabel = NSTextField(wrappingLabelWithString: "")
    private let origLabel = NSTextField(wrappingLabelWithString: "")
    private let trLabel = NSTextField(wrappingLabelWithString: "")
    private let srcPop = NSPopUpButton()
    private let arrow = NSTextField(labelWithString: "→")
    private let dstPop = NSPopUpButton()
    private var styleButton: OCButton!
    private var sumButton: OCButton!
    private var stopButton: OCButton!
    private let stylePop = NSPopover()
    private var sizeLabel: NSTextField?
    private var texts: (prev: String, orig: String, tr: String, status: String) = ("", "", "", "")

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 150),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .vibrantDark)

        card.wantsLayer = true
        // Graphite, never pure black.
        grad.colors = [NSColor(srgbRed: 0.17, green: 0.18, blue: 0.19, alpha: 0.94).cgColor,
                       NSColor(srgbRed: 0.11, green: 0.12, blue: 0.13, alpha: 0.94).cgColor]
        grad.cornerRadius = 16
        card.layer?.addSublayer(grad)
        card.layer?.cornerRadius = 16
        card.layer?.borderWidth = 1
        card.layer?.borderColor = kAmber.withAlphaComponent(0.25).cgColor

        title.attributedStringValue = NSAttributedString(string: "🎧 喵传", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: kAmber])
        status.font = .systemFont(ofSize: 11)
        status.textColor = NSColor(white: 0.62, alpha: 1)
        status.lineBreakMode = .byTruncatingTail

        for (pop, list, tip) in [(srcPop, MiaoChuan.sources.map { $0.1 }, "他们说的语言"), (dstPop, MiaoChuan.targets.map { $0.1 }, "翻译成")] {
            pop.controlSize = .small
            pop.font = .systemFont(ofSize: 11)
            pop.isBordered = false
            for t in list { pop.addItem(withTitle: L10n.t(t)) }
            pop.target = self
            pop.action = #selector(languageChanged)
            pop.toolTip = L10n.t(tip)
            (pop.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        }
        arrow.font = .systemFont(ofSize: 11)
        arrow.textColor = NSColor(white: 0.55, alpha: 1)

        styleButton = OCButton(title: "Aa", target: self, action: #selector(doStyle))
        styleButton.chip = true
        styleButton.style = .neutral
        styleButton.toolTip = L10n.t("字幕字体：大小、粗细、颜色")
        sumButton = OCButton(title: "刚才在说什么", target: self, action: #selector(doSummary))
        sumButton.chip = true
        sumButton.style = .secondary
        stopButton = OCButton(title: "停止", target: self, action: #selector(doStop))
        stopButton.chip = true
        stopButton.style = .neutral

        for l in [prevLabel, origLabel, trLabel] {
            l.maximumNumberOfLines = l === trLabel ? 2 : 1
            l.lineBreakMode = .byTruncatingHead
            l.isSelectable = false
        }
        for v in [card, title, status, srcPop, arrow, dstPop, styleButton!, sumButton!, stopButton!, prevLabel, origLabel, trLabel] as [NSView] {
            panel.contentView?.addSubview(v)
        }
        stylePop.behavior = .transient
        stylePop.appearance = NSAppearance(named: .vibrantDark)
        applyStyle()
    }

    func syncLanguages() {
        srcPop.selectItem(at: MiaoChuan.sources.firstIndex { $0.0 == Prefs.miaoSource } ?? 0)
        dstPop.selectItem(at: MiaoChuan.targets.firstIndex { $0.0 == Prefs.miaoTarget } ?? 0)
        layout()
    }

    @objc private func languageChanged() {
        let s = MiaoChuan.sources[max(0, srcPop.indexOfSelectedItem)].0
        let t = MiaoChuan.targets[max(0, dstPop.indexOfSelectedItem)].0
        onLanguages?(s, t)
        layout()
    }

    // MARK: font

    private var trFont: NSFont { .systemFont(ofSize: MiaoStyle.size, weight: MiaoStyle.weights[MiaoStyle.weight].1) }
    private var origSize: CGFloat { max(11, round(MiaoStyle.size * 0.72)) }
    private var prevSize: CGFloat { max(10, round(MiaoStyle.size * 0.66)) }

    private func applyStyle() {
        trLabel.font = trFont
        trLabel.textColor = MiaoStyle.colors[MiaoStyle.color].1
        origLabel.font = .systemFont(ofSize: origSize)
        origLabel.textColor = NSColor(white: 1, alpha: 0.62)
        prevLabel.font = .systemFont(ofSize: prevSize)
        prevLabel.textColor = NSColor(white: 1, alpha: 0.38)
        put(prevLabel, texts.prev); put(origLabel, texts.orig); put(trLabel, texts.tr)
        layout()
    }

    @objc private func doStyle() {
        if stylePop.isShown { stylePop.close(); return }
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 10
        col.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        func head(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: L10n.t(t))
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = kAmber
            return l
        }
        // 大小
        let sizeRow = NSStackView()
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 8
        let slider = NSSlider(value: Double(MiaoStyle.size), minValue: 12, maxValue: 40, target: self, action: #selector(sizeChanged(_:)))
        slider.controlSize = .small
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let sl = NSTextField(labelWithString: "\(Int(MiaoStyle.size))")
        sl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sl.textColor = .secondaryLabelColor
        sizeLabel = sl
        sizeRow.addArrangedSubview(slider); sizeRow.addArrangedSubview(sl)
        // 粗细
        let seg = NSSegmentedControl(labels: MiaoStyle.weights.map { L10n.t($0.0) }, trackingMode: .selectOne,
                                     target: self, action: #selector(weightChanged(_:)))
        seg.controlSize = .small
        seg.selectedSegment = MiaoStyle.weight
        // 颜色
        let colors = NSStackView()
        colors.orientation = .horizontal
        colors.spacing = 8
        for (i, c) in MiaoStyle.colors.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(colorChanged(_:)))
            b.tag = i
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 10
            b.layer?.backgroundColor = c.1.cgColor
            b.layer?.borderWidth = i == MiaoStyle.color ? 2 : 0
            b.layer?.borderColor = NSColor.white.cgColor
            b.toolTip = L10n.t(c.0)
            b.widthAnchor.constraint(equalToConstant: 20).isActive = true
            b.heightAnchor.constraint(equalToConstant: 20).isActive = true
            colors.addArrangedSubview(b)
        }
        for v in [head("大小"), sizeRow, head("粗细"), seg, head("颜色"), colors] as [NSView] { col.addArrangedSubview(v) }
        let vc = NSViewController()
        vc.view = col
        stylePop.contentViewController = vc
        stylePop.show(relativeTo: styleButton.bounds, of: styleButton, preferredEdge: .maxY)
    }

    @objc private func sizeChanged(_ s: NSSlider) {
        MiaoStyle.size = CGFloat(s.doubleValue.rounded())
        sizeLabel?.stringValue = "\(Int(MiaoStyle.size))"
        applyStyle()
    }
    @objc private func weightChanged(_ s: NSSegmentedControl) { MiaoStyle.weight = s.selectedSegment; applyStyle() }
    @objc private func colorChanged(_ b: NSButton) {
        MiaoStyle.color = b.tag
        for v in b.superview?.subviews ?? [] { v.layer?.borderWidth = v === b ? 2 : 0 }
        applyStyle()
    }

    // MARK: layout

    /// Size follows the font: wider and taller for big text, never wider than the screen.
    private func layout() {
        let fs = MiaoStyle.size
        let scr = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(scr.width - 40, max(760, round(fs * 42)))
        let trLine = ceil(trFont.ascender - trFont.descender + trFont.leading) + 2
        let origH = ceil(origSize * 1.35), prevH = ceil(prevSize * 1.35)
        let headH: CGFloat = 40
        let h = headH + prevH + 4 + origH + 8 + trLine * 2 + 12

        // Keep the bottom edge and the centre where they are while resizing.
        let old = panel.frame
        var f = NSRect(x: old.midX - w / 2, y: old.minY, width: w, height: h)
        if panel.isVisible { f.origin.x = min(max(scr.minX + 8, f.origin.x), scr.maxX - w - 8) }
        panel.setFrame(f, display: true)
        card.frame = NSRect(x: 0, y: 0, width: w, height: h)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        grad.frame = card.bounds
        CATransaction.commit()

        let y0 = h - 28
        title.frame = NSRect(x: 16, y: y0, width: 70, height: 16)
        let fit: (NSControl, CGFloat) -> CGFloat = { c, minW in max(minW, ceil(c.intrinsicContentSize.width)) }
        let tw = fit(stopButton, 48), sw = fit(sumButton, 96), aw = fit(styleButton, 32)
        stopButton.frame = NSRect(x: w - 16 - tw, y: y0 - 4, width: tw, height: 20)
        sumButton.frame = NSRect(x: stopButton.frame.minX - 6 - sw, y: y0 - 4, width: sw, height: 20)
        styleButton.frame = NSRect(x: sumButton.frame.minX - 6 - aw, y: y0 - 4, width: aw, height: 20)
        let dw = fit(dstPop, 70), pw = fit(srcPop, 70)
        dstPop.frame = NSRect(x: styleButton.frame.minX - 10 - dw, y: y0 - 4, width: dw, height: 22)
        arrow.frame = NSRect(x: dstPop.frame.minX - 16, y: y0, width: 14, height: 16)
        srcPop.frame = NSRect(x: arrow.frame.minX - 2 - pw, y: y0 - 4, width: pw, height: 22)
        status.frame = NSRect(x: 86, y: y0, width: max(40, srcPop.frame.minX - 8 - 86), height: 16)

        var y = h - headH - prevH
        prevLabel.frame = NSRect(x: 16, y: y, width: w - 32, height: prevH)
        y -= 4 + origH
        origLabel.frame = NSRect(x: 16, y: y, width: w - 32, height: origH)
        trLabel.frame = NSRect(x: 16, y: 12, width: w - 32, height: trLine * 2)
    }

    /// Set text without the English-mode auto-translation (these are the meeting's own words).
    private func put(_ l: NSTextField, _ s: String) {
        l.attributedStringValue = NSAttributedString(string: s, attributes: [.font: l.font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: l.textColor ?? NSColor.white])
    }

    func setStatus(_ s: String) { texts.status = s; put(status, s) }
    func setLines(prev: String?, orig: String, tr: String) {
        texts.prev = prev ?? ""
        texts.orig = orig
        texts.tr = tr.isEmpty ? (orig.isEmpty ? "" : "…") : tr
        put(prevLabel, texts.prev)
        put(origLabel, texts.orig)
        put(trLabel, texts.tr)
    }
    /// The sentence still being spoken.
    func setLive(_ s: String) { texts.orig = s; put(origLabel, s) }
    func setSummaryBusy(_ busy: Bool) {
        sumButton.isEnabled = !busy
        sumButton.title = busy ? "正在想…" : "刚才在说什么"
    }

    func show() {
        layout()
        if !panel.isVisible, let scr = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: scr.midX - panel.frame.width / 2, y: scr.minY + 40))
        }
        panel.orderFrontRegardless()
    }
    func hide() { stylePop.close(); panel.orderOut(nil) }

    @objc private func doStop() { onStop?() }
    @objc private func doSummary() { onSummary?() }
}
