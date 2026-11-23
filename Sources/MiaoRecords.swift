// OrdCat — 喵传记录 📂 (Lang 2026-11-23)
//
//   • 点「停止」时可以选择保存：先把原始字幕存下来（不会丢），再用用户自己的模型整理：
//     改错字、合并断句、分段 → 整理后的原文 + 完整译文 + 要点。
//   • 只存在这台 Mac：~/Library/Application Support/OrdCat/MiaoChuan/<id>.json，不上传。
//   • 在 设置 → 技能 → 喵传「📂 喵传记录」、菜单栏小猫菜单、字幕条 📂 打开；可下载成
//     PDF、Word、Markdown、纯文本、SRT 字幕、网页。

import Cocoa
import UniformTypeIdentifiers

struct MiaoLine: Codable {
    var t: Double      // seconds after the session started, when the sentence ended
    var o: String      // what was recognised
    var tr: String     // live translation (may be empty)
}

struct MiaoRecord: Codable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var app: String
    var source: String          // speech locale, e.g. en-US
    var target: String          // translation language, e.g. zh
    var lines: [MiaoLine]
    var summary: String
    var origText: String        // tidied original
    var trText: String          // tidied translation
    var tidied: Bool
    var tidyError: String?

    var minutes: Int { max(1, Int((end.timeIntervalSince(start) / 60).rounded())) }
    var sameLanguage: Bool { source.prefix(2) == target.prefix(2) }
    var sourceLabel: String { L10n.t(MiaoChuan.sources.first { $0.0 == source }?.1 ?? source) }
    var targetLabel: String { L10n.t(MiaoChuan.targets.first { $0.0 == target }?.1 ?? target) }
    var sourcePrompt: String { MiaoChuan.sources.first { $0.0 == source }?.2 ?? "English" }
    var targetPrompt: String { MiaoChuan.targets.first { $0.0 == target }?.2 ?? "Simplified Chinese" }

    /// Raw text when tidying has not finished (or failed).
    var bestOrig: String { origText.isEmpty ? lines.map { $0.o }.joined(separator: "\n") : origText }
    var bestTr: String {
        if sameLanguage { return "" }
        return trText.isEmpty ? lines.map { $0.tr }.filter { !$0.isEmpty }.joined(separator: "\n") : trText
    }
}

// MARK: - Store

enum MiaoRecords {
    static let changed = Notification.Name("MiaoRecords.changed")

    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrdCat/MiaoChuan", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func file(_ id: String) -> URL { dir.appendingPathComponent(id + ".json") }

    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    static func all() -> [MiaoRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(MiaoRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.start > $1.start }
    }
    static func load(_ id: String) -> MiaoRecord? { try? dec.decode(MiaoRecord.self, from: Data(contentsOf: file(id))) }
    static var count: Int { all().count }

    static func save(_ r: MiaoRecord) {
        if let data = try? enc.encode(r) { try? data.write(to: file(r.id), options: .atomic) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: r.id) }
    }
    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: file(id))
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: id) }
    }
    static func defaultTitle(app: String, start: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = L10n.english ? "MMM d, HH:mm" : "M月d日 HH:mm"
        return "\(app.isEmpty ? L10n.t("喵传") : app) · \(f.string(from: start))"
    }
}

// MARK: - Tidy (the user's own model)

/// Turns the raw subtitles into a clean original, a full translation and key points, chunk by chunk.
final class MiaoTidier {
    private static var running: [String: MiaoTidier] = [:]
    static func isBusy(_ id: String) -> Bool { running[id] != nil }

    static func start(_ r: MiaoRecord, done: @escaping (MiaoRecord) -> Void) {
        guard running[r.id] == nil else { return }
        let t = MiaoTidier(r, done: done)
        running[r.id] = t
        t.next()
    }

    private let llm = LLM()
    private var rec: MiaoRecord
    private var chunks: [[MiaoLine]] = []
    private var idx = 0
    private var origParts: [String] = []
    private var trParts: [String] = []
    private var firstError: String?
    private let done: (MiaoRecord) -> Void

    private init(_ r: MiaoRecord, done: @escaping (MiaoRecord) -> Void) {
        rec = r
        self.done = done
        // About 2500 characters per request keeps every model's context and rate limits happy.
        var cur: [MiaoLine] = [], n = 0
        for l in r.lines {
            cur.append(l); n += l.o.count
            if n > 2500 { chunks.append(cur); cur = []; n = 0 }
        }
        if !cur.isEmpty { chunks.append(cur) }
    }

    private func next() {
        guard idx < chunks.count else { summarize(); return }
        let chunk = chunks[idx]
        let raw = chunk.map { $0.o }.joined(separator: "\n")
        let ctx: String
        if rec.sameLanguage {
            ctx = """
            [喵传 · 整理记录] 下面是一段会议/语音的语音识别原文（\(rec.sourcePrompt)），每行一句，可能有错字、断句不对、重复。
            把它整理通顺：改正明显的识别错字，把被切断的句子合起来，按意思分段。不要删减内容，不要编造，不要总结。
            严格按下面的格式输出，不要其他内容：
            ===原文===
            （整理后的原文）
            """
        } else {
            ctx = """
            [喵传 · 整理记录] 下面是一段会议/语音的语音识别原文（\(rec.sourcePrompt)），每行一句，可能有错字、断句不对、重复。
            1) 把原文整理通顺：改正明显的识别错字，把被切断的句子合起来，按意思分段。不要删减内容，不要编造，不要总结。
            2) 把整理后的原文完整翻译成 \(rec.targetPrompt)，段落和原文一一对应。
            严格按下面的格式输出，不要其他内容：
            ===原文===
            （整理后的原文）
            ===译文===
            （译文）
            """
        }
        llm.stream([["role": "user", "content": raw]], context: ctx, onDelta: { _ in }, onDone: { [weak self] t, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if err == nil, let t = t, let parsed = MiaoTidier.parse(t, needTr: !self.rec.sameLanguage) {
                    self.origParts.append(parsed.0)
                    self.trParts.append(parsed.1)
                } else {
                    // Keep the raw lines for this part so nothing is lost.
                    if self.firstError == nil { self.firstError = err ?? L10n.t("模型没按格式回答") }
                    self.origParts.append(chunk.map { $0.o }.joined(separator: " "))
                    self.trParts.append(chunk.map { $0.tr }.filter { !$0.isEmpty }.joined(separator: " "))
                }
                self.idx += 1
                self.next()
            }
        })
    }

    static func parse(_ text: String, needTr: Bool) -> (String, String)? {
        guard let o = text.range(of: "===原文===") else { return nil }
        let after = text[o.upperBound...]
        if !needTr {
            let s = after.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : (s, "")
        }
        guard let t = after.range(of: "===译文===") else { return nil }
        let orig = after[..<t.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let tr = after[t.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return orig.isEmpty || tr.isEmpty ? nil : (orig, tr)
    }

    private func summarize() {
        rec.origText = origParts.joined(separator: "\n\n")
        rec.trText = rec.sameLanguage ? "" : trParts.joined(separator: "\n\n")
        let base = rec.sameLanguage ? rec.origText : rec.trText
        let text = String(base.prefix(14000))
        let lang = rec.sameLanguage ? rec.sourcePrompt : rec.targetPrompt
        let ctx = """
        [喵传 · 会议要点] 下面是一段会议/语音（\(rec.app)）整理后的文字。用 \(lang) 写要点。
        第一行写「标题：」加一个不超过 20 个字的标题。然后用 Markdown 小标题（###）和列表写：主要内容；关键观点和数字（说明是谁说的，如果能看出来）；待办或需要回应的事（没有就写「无」）。
        只根据文字写，不要编造。不超过 400 字。
        """
        llm.stream([["role": "user", "content": text]], context: ctx, onDelta: { _ in }, onDone: { [weak self] t, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if err == nil, var s = t?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    if let first = s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
                       let r = first.range(of: #"^\s*(\*\*)?(标题|Title)(\*\*)?\s*[:：]\s*"#, options: [.regularExpression, .caseInsensitive]) {
                        let title = first[r.upperBound...].replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
                        if !title.isEmpty { self.rec.title = String(title.prefix(40)) }
                        s = String(s.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    self.rec.summary = s
                } else if self.firstError == nil {
                    self.firstError = err ?? L10n.t("模型没按格式回答")
                }
                self.rec.tidied = true
                self.rec.tidyError = self.firstError
                MiaoRecords.save(self.rec)
                MiaoTidier.running[self.rec.id] = nil
                self.done(self.rec)
            }
        })
    }
}

// MARK: - Export

enum MiaoExport {
    static let formats: [(name: String, ext: String)] = [
        ("PDF", "pdf"), ("Word（.docx）", "docx"), ("Markdown（.md）", "md"),
        ("纯文本（.txt）", "txt"), ("字幕（.srt）", "srt"), ("网页（.html）", "html")
    ]
    static let contents = ["原文 + 译文", "只要译文", "只要原文"]

    /// Save panel with a format and a content picker.
    static func run(_ r: MiaoRecord) {
        let panel = NSSavePanel()
        panel.title = L10n.t("下载喵传记录")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let helper = Helper(panel: panel, title: safeName(r.title))
        let fmt = NSPopUpButton(frame: NSRect(x: 72, y: 34, width: 220, height: 26), pullsDown: false)
        for f in formats { fmt.addItem(withTitle: L10n.t(f.name)) }
        fmt.selectItem(at: max(0, min(formats.count - 1, UserDefaults.standard.integer(forKey: "miao.exportFormat"))))
        fmt.target = helper
        fmt.action = #selector(Helper.formatChanged(_:))
        let cnt = NSPopUpButton(frame: NSRect(x: 72, y: 4, width: 220, height: 26), pullsDown: false)
        for c in contents { cnt.addItem(withTitle: L10n.t(c)) }
        if r.sameLanguage { cnt.selectItem(at: 2); cnt.isEnabled = false }
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 66))
        for (y, t) in [(38, "格式"), (8, "内容")] {
            let l = NSTextField(labelWithString: L10n.t(t))
            l.alignment = .right
            l.frame = NSRect(x: 0, y: CGFloat(y), width: 64, height: 18)
            box.addSubview(l)
        }
        box.addSubview(fmt); box.addSubview(cnt)
        panel.accessoryView = box
        helper.formatChanged(fmt)
        NSApp.activate(ignoringOtherApps: true)
        let answer = withExtendedLifetime(helper) { panel.runModal() }
        guard answer == .OK, let url = panel.url else { return }
        let f = fmt.indexOfSelectedItem
        UserDefaults.standard.set(f, forKey: "miao.exportFormat")
        let c = r.sameLanguage ? 2 : cnt.indexOfSelectedItem
        if !write(r, format: formats[f].ext, content: c, to: url) {
            OCConfirm.ask(L10n.t("没能保存这个文件"), url.path, ok: L10n.t("好"))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private final class Helper: NSObject {
        let panel: NSSavePanel
        let title: String
        init(panel: NSSavePanel, title: String) { self.panel = panel; self.title = title }
        @objc func formatChanged(_ p: NSPopUpButton) {
            let ext = MiaoExport.formats[max(0, p.indexOfSelectedItem)].ext
            if let t = UTType(filenameExtension: ext) { panel.allowedContentTypes = [t] }
            panel.nameFieldStringValue = title + "." + ext
        }
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    }

    static func write(_ r: MiaoRecord, format: String, content: Int, to url: URL) -> Bool {
        switch format {
        case "md": return (try? markdown(r, content: content).write(to: url, atomically: true, encoding: .utf8)) != nil
        case "txt": return (try? plain(r, content: content).write(to: url, atomically: true, encoding: .utf8)) != nil
        case "srt": return (try? srt(r, content: content).write(to: url, atomically: true, encoding: .utf8)) != nil
        case "html": return (try? html(r, content: content).write(to: url, atomically: true, encoding: .utf8)) != nil
        case "docx":
            let a = attributed(r, content: content, print: true)
            guard let d = try? a.data(from: NSRange(location: 0, length: a.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]) else { return false }
            return (try? d.write(to: url, options: .atomic)) != nil
        default: return pdf(attributed(r, content: content, print: true), to: url)
        }
    }

    // MARK: pieces

    static func metaLines(_ r: MiaoRecord) -> [String] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let g = DateFormatter()
        g.dateFormat = "HH:mm"
        let when = "\(f.string(from: r.start))–\(g.string(from: r.end))"
        let dur = L10n.english ? "\(r.minutes) min" : "\(r.minutes) 分钟"
        let langs = r.sameLanguage ? r.sourceLabel : "\(r.sourceLabel) → \(r.targetLabel)"
        return [
            "\(L10n.t("时间"))：\(when)（\(dur)）",
            "\(L10n.t("应用"))：\(r.app)",
            "\(L10n.t("语言"))：\(langs)"
        ].map { L10n.english ? $0.replacingOccurrences(of: "：", with: ": ").replacingOccurrences(of: "（", with: " (").replacingOccurrences(of: "）", with: ")") : $0 }
    }

    /// (heading, body) sections in reading order.
    static func sections(_ r: MiaoRecord, content: Int) -> [(String, String)] {
        var out: [(String, String)] = []
        if !r.summary.isEmpty { out.append((L10n.t("要点"), r.summary)) }
        let tr = r.bestTr
        if content != 1 || tr.isEmpty { out.append((r.sameLanguage ? L10n.t("整理后的文字") : L10n.t("原文") + "（\(r.sourceLabel)）", r.bestOrig)) }
        if content != 2 && !tr.isEmpty { out.append((L10n.t("译文") + "（\(r.targetLabel)）", tr)) }
        if L10n.english { out = out.map { ($0.0.replacingOccurrences(of: "（", with: " (").replacingOccurrences(of: "）", with: ")"), $0.1) } }
        return out
    }

    static func markdown(_ r: MiaoRecord, content: Int) -> String {
        var s = "# \(r.title)\n\n" + metaLines(r).map { "- \($0)" }.joined(separator: "\n") + "\n"
        for (h, b) in sections(r, content: content) { s += "\n## \(h)\n\n\(b)\n" }
        return s
    }

    static func plain(_ r: MiaoRecord, content: Int) -> String {
        var s = r.title + "\n" + metaLines(r).joined(separator: "\n") + "\n"
        for (h, b) in sections(r, content: content) {
            s += "\n【\(h)】\n\n" + stripMarkdown(b) + "\n"
        }
        return s
    }

    static func stripMarkdown(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = String(line).replacingOccurrences(of: "**", with: "")
            while l.hasPrefix("#") { l.removeFirst() }
            if l.hasPrefix("- ") || l.hasPrefix("* ") { l = "• " + l.dropFirst(2) }
            return l.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    static func srt(_ r: MiaoRecord, content: Int) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        var out = "", n = 0, prevEnd = 0.0
        for (i, l) in r.lines.enumerated() {
            let lenSec = min(8, max(1.5, Double(l.o.count) * 0.07))
            let start = max(prevEnd, l.t - lenSec)
            var end = l.t + 1.5
            if i + 1 < r.lines.count { end = min(end, max(start + 0.8, r.lines[i + 1].t - 0.3)) }
            prevEnd = end
            var text: [String] = []
            if content != 1 || l.tr.isEmpty { text.append(l.o) }
            if content != 2 && !l.tr.isEmpty && !r.sameLanguage { text.append(l.tr) }
            n += 1
            out += "\(n)\n\(ts(start)) --> \(ts(end))\n\(text.joined(separator: "\n"))\n\n"
        }
        return out
    }

    static func html(_ r: MiaoRecord, content: Int) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var b = "<h1>\(esc(r.title))</h1>\n<p class=\"meta\">" + metaLines(r).map(esc).joined(separator: "<br>") + "</p>\n"
        for (h, body) in sections(r, content: content) {
            b += "<h2>\(esc(h))</h2>\n"
            var inList = false
            for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw).trimmingCharacters(in: .whitespaces)
                let isItem = line.hasPrefix("- ") || line.hasPrefix("* ")
                if isItem && !inList { b += "<ul>\n"; inList = true }
                if !isItem && inList { b += "</ul>\n"; inList = false }
                if line.isEmpty { continue }
                let clean = esc(line.replacingOccurrences(of: "**", with: ""))
                if isItem { b += "<li>\(String(clean.dropFirst(2)))</li>\n" }
                else if line.hasPrefix("#") { b += "<h3>\(clean.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))</h3>\n" }
                else { b += "<p>\(clean)</p>\n" }
            }
            if inList { b += "</ul>\n" }
        }
        return """
        <!doctype html>
        <html lang="\(L10n.english ? "en" : "zh")"><head><meta charset="utf-8"><title>\(esc(r.title))</title>
        <style>body{font:16px/1.7 -apple-system,"PingFang SC",sans-serif;max-width:760px;margin:40px auto;padding:0 20px;color:#222}
        h1{font-size:26px}h2{font-size:19px;margin-top:32px;border-bottom:1px solid #eee;padding-bottom:4px}h3{font-size:16px}.meta{color:#777;font-size:14px}</style>
        </head><body>
        \(b)</body></html>
        """
    }

    /// Rich text for PDF, Word and the records window.
    static func attributed(_ r: MiaoRecord, content: Int, print: Bool) -> NSAttributedString {
        let text: NSColor = print ? .black : .labelColor
        let dim: NSColor = print ? NSColor(white: 0.45, alpha: 1) : .secondaryLabelColor
        let out = NSMutableAttributedString()
        func para(_ before: CGFloat, _ after: CGFloat, indent: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = after
            p.lineSpacing = 3
            p.headIndent = indent
            return p
        }
        func add(_ s: String, _ font: NSFont, _ color: NSColor, _ p: NSParagraphStyle) {
            out.append(NSAttributedString(string: s + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p]))
        }
        add(r.title, .systemFont(ofSize: 20, weight: .bold), text, para(0, 6))
        for m in metaLines(r) { add(m, .systemFont(ofSize: 11), dim, para(0, 1)) }
        for (h, body) in sections(r, content: content) {
            add(h, .systemFont(ofSize: 15, weight: .semibold), print ? .black : kAmber, para(16, 6))
            for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
                var line = String(raw).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
                if line.isEmpty { continue }
                if line.hasPrefix("#") {
                    line = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                    add(line, .systemFont(ofSize: 13, weight: .semibold), text, para(8, 3))
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    add("•  " + line.dropFirst(2), .systemFont(ofSize: 12.5), text, para(0, 3, indent: 14))
                } else {
                    add(line, .systemFont(ofSize: 12.5), text, para(0, 6))
                }
            }
        }
        return out
    }

    static func pdf(_ s: NSAttributedString, to url: URL) -> Bool {
        let info = NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary().setObject(url, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString)
        info.paperSize = NSSize(width: 595, height: 842)   // A4
        info.topMargin = 48; info.bottomMargin = 48; info.leftMargin = 56; info.rightMargin = 56
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let w: CGFloat = 595 - 112
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: w, height: 100))
        tv.appearance = NSAppearance(named: .aqua)
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = true
        tv.backgroundColor = .white
        tv.textStorage?.setAttributedString(s)
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            tv.setFrameSize(NSSize(width: w, height: ceil(lm.usedRect(for: tc).height) + 24))
        }
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        return op.run() && FileManager.default.fileExists(atPath: url.path)
    }
}

// MARK: - Records window

/// 喵传记录: list on the left, the record on the right, 下载 / 重命名 / 删除 on top.
final class MiaoRecordsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let shared = MiaoRecordsWindow()

    private var window: NSWindow?
    private let table = NSTableView()
    private let textView = NSTextView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var downloadButton: OCButton!
    private var renameButton: OCButton!
    private var deleteButton: OCButton!
    private var retryButton: OCButton!
    private var records: [MiaoRecord] = []

    func show(select id: String? = nil) {
        if window == nil { build() }
        reload(keep: id)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = L10n.t("📂 喵传记录")
        w.minSize = NSSize(width: 680, height: 400)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        let root = w.contentView!

        // List
        let col = NSTableColumn(identifier: .init("r"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 52
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        // Detail
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let detailScroll = NSScrollView()
        detailScroll.documentView = textView
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false

        downloadButton = OCButton(title: "⬇︎ 下载…", target: self, action: #selector(doDownload))
        downloadButton.style = .primary
        renameButton = OCButton(title: "重命名", target: self, action: #selector(doRename))
        retryButton = OCButton(title: "重新整理", target: self, action: #selector(doRetry))
        deleteButton = OCButton(title: "删除", target: self, action: #selector(doDelete))
        deleteButton.style = .danger
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [status, spacer, retryButton, renameButton, deleteButton, downloadButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        empty.stringValue = L10n.t("还没有喵传记录。\n结束喵传时选「保存记录并结束」，记录就会出现在这里。只存在这台 Mac 上。")
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 13)
        empty.translatesAutoresizingMaskIntoConstraints = false

        for v in [listScroll, sep, bar, detailScroll, empty] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            listScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listScroll.topAnchor.constraint(equalTo: root.topAnchor),
            listScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            listScroll.widthAnchor.constraint(equalToConstant: 260),
            sep.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor),
            sep.topAnchor.constraint(equalTo: root.topAnchor),
            sep.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sep.widthAnchor.constraint(equalToConstant: 1),
            bar.leadingAnchor.constraint(equalTo: sep.trailingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            detailScroll.leadingAnchor.constraint(equalTo: sep.trailingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detailScroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            detailScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: MiaoRecords.changed, object: nil)
        window = w
    }

    @objc private func changed(_ n: Notification) {
        guard window?.isVisible == true else { return }
        reload(keep: selected?.id)
    }

    private var selected: MiaoRecord? {
        let r = table.selectedRow
        return r >= 0 && r < records.count ? records[r] : nil
    }

    private func reload(keep id: String?) {
        records = MiaoRecords.all()
        table.reloadData()
        let row = id.flatMap { i in records.firstIndex { $0.id == i } } ?? (records.isEmpty ? -1 : 0)
        if row >= 0 { table.selectRowIndexes([row], byExtendingSelection: false) }
        let has = !records.isEmpty
        empty.isHidden = has
        for v in [table.enclosingScrollView, textView.enclosingScrollView, status, downloadButton, renameButton, deleteButton, retryButton] as [NSView?] {
            v?.isHidden = !has
        }
        showSelected()
    }

    private func showSelected() {
        guard let r = selected else { textView.string = ""; return }
        textView.textStorage?.setAttributedString(MiaoExport.attributed(r, content: 0, print: false))
        textView.scrollToBeginningOfDocument(nil)
        let busy = MiaoTidier.isBusy(r.id)
        if busy { status.stringValue = L10n.t("小猫正在整理原文和译文…") }
        else if let e = r.tidyError { status.stringValue = L10n.t("有一部分没整理好，先保留了原始字幕：") + e }
        else if !r.tidied { status.stringValue = L10n.t("还没整理，显示的是原始字幕") }
        else { status.stringValue = "" }
        retryButton.isHidden = busy || (r.tidied && r.tidyError == nil)
        downloadButton.isEnabled = !busy
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = records[row]
        let v = NSTableCellView()
        let t = NSTextField(labelWithString: "")
        t.attributedStringValue = NSAttributedString(string: r.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        t.lineBreakMode = .byTruncatingTail
        let f = DateFormatter()
        f.dateFormat = L10n.english ? "MMM d HH:mm" : "M月d日 HH:mm"
        let dur = L10n.english ? "\(r.minutes) min" : "\(r.minutes) 分钟"
        let busy = MiaoTidier.isBusy(r.id) ? (L10n.english ? " · tidying…" : " · 整理中…") : ""
        let s = NSTextField(labelWithString: "")
        s.attributedStringValue = NSAttributedString(string: "\(f.string(from: r.start)) · \(dur) · \(r.app)\(busy)",
                                                     attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        s.lineBreakMode = .byTruncatingTail
        for x in [t, s] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            t.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            t.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            s.leadingAnchor.constraint(equalTo: t.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: t.trailingAnchor),
            s.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 3)
        ])
        return v
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showSelected() }

    // MARK: actions

    @objc private func doDownload() { if let r = selected { MiaoExport.run(r) } }

    @objc private func doRename() {
        guard var r = selected else { return }
        let a = NSAlert()
        a.messageText = L10n.t("重命名这条记录")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = r.title
        a.accessoryView = field
        a.addButton(withTitle: L10n.t("保存"))
        let c = a.addButton(withTitle: L10n.t("取消")); c.keyEquivalent = "\u{1b}"
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != r.title else { return }
        r.title = String(t.prefix(60))
        MiaoRecords.save(r)
    }

    @objc private func doDelete() {
        guard let r = selected else { return }
        guard OCConfirm.ask(L10n.t("删除这条喵传记录？"), r.title + "\n" + L10n.t("删除后找不回来。"), ok: L10n.t("删除"), danger: true) else { return }
        MiaoRecords.delete(r.id)
    }

    @objc private func doRetry() {
        guard var r = selected else { return }
        guard OCConfirm.ask(L10n.t("用你的模型重新整理这条记录？"), L10n.t("会把字幕文字发给你设置的模型，整理好后替换现在的原文、译文和要点。"), ok: L10n.t("重新整理")) else { return }
        r.tidyError = nil
        MiaoTidier.start(r) { _ in }
        showSelected()
        table.reloadData()
    }
}
