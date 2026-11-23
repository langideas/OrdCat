// OrdCat — Local Context Hub (端侧个人记忆中枢).
//
//   Tier 1  Working context   : in-memory ring buffer of the last 20 screen cards (≈10 min of activity)
//   Tier 2  Searchable memory : SQLite (WAL) timeline + FTS5 trigram full-text + on-device sentence vectors
//   Tier 3  Entity ledger     : lightweight facts (apps, files, sites, local ports) with frequency & recency
//
// The model never stores anything. Before each question the Dynamic Context Assembler picks a small,
// high-signal slice (≈2–4K tokens) and hands it to whichever model is configured (BYOM).
// Everything lives in ~/Library/Application Support/OrdCat and never leaves the Mac except the slice sent to the model.

import Cocoa
import SQLite3
import NaturalLanguage

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct MemoryHit {
    let id: Int64
    let date: Date
    let kind: String
    let app: String
    let title: String
    let content: String
    var score: Double
}

func estimateTokens(_ s: String) -> Int {
    var cjk = 0, other = 0
    for u in s.unicodeScalars {
        if (0x2E80...0x9FFF).contains(u.value) || (0xAC00...0xD7AF).contains(u.value) || (0xF900...0xFAFF).contains(u.value) { cjk += 1 } else { other += 1 }
    }
    return cjk + other / 4
}

// MARK: - Tier 2 & 3: SQLite store

final class MemoryStore {
    private var db: OpaquePointer?
    private let q = DispatchQueue(label: "app.ordcat.memory")
    private let embedder: NLEmbedding?
    private(set) var ftsOK = false
    let url: URL

    init(dir: URL) {
        url = dir.appendingPathComponent("memory.sqlite")
        embedder = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese) ?? NLEmbedding.sentenceEmbedding(for: .english)
        q.sync { self.open() }
    }

    var vectorEngine: String {
        guard let e = embedder else { return "不可用（仅全文检索）" }
        return "Apple 本地句向量 · \(e.dimension) 维"
    }

    private func open() {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return }
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        exec("CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY, ts REAL, kind TEXT, app TEXT, bundle TEXT, title TEXT, content TEXT, emb BLOB);")
        exec("CREATE INDEX IF NOT EXISTS ev_ts ON events(ts);")
        ftsOK = exec("CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(content, title, app, tokenize='trigram');")
        exec("CREATE TABLE IF NOT EXISTS entities(name TEXT PRIMARY KEY, kind TEXT, count INTEGER, last REAL);")
    }

    @discardableResult private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ s: String) {
        sqlite3_bind_text(st, i, s, -1, SQLITE_TRANSIENT)
    }

    private func col(_ st: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(st, i) else { return "" }
        return String(cString: c)
    }

    private func embed(_ s: String) -> [Float]? {
        guard let e = embedder, let v = e.vector(for: s) else { return nil }
        return v.map { Float($0) }
    }

    // MARK: write
    func add(kind: String, app: String, bundle: String, title: String, content: String, date: Date = Date()) {
        let text = String(content.prefix(8000))
        q.async {
            let vec = self.embed(String((title + "\n" + text).prefix(1200)))
            var st: OpaquePointer?
            sqlite3_prepare_v2(self.db, "INSERT INTO events(ts,kind,app,bundle,title,content,emb) VALUES(?,?,?,?,?,?,?)", -1, &st, nil)
            sqlite3_bind_double(st, 1, date.timeIntervalSince1970)
            self.bind(st, 2, kind); self.bind(st, 3, app); self.bind(st, 4, bundle)
            self.bind(st, 5, title); self.bind(st, 6, text)
            if let v = vec {
                v.withUnsafeBytes { raw in _ = sqlite3_bind_blob(st, 7, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT) }
            } else {
                sqlite3_bind_null(st, 7)
            }
            sqlite3_step(st)
            sqlite3_finalize(st)
            let id = sqlite3_last_insert_rowid(self.db)
            if self.ftsOK {
                var f: OpaquePointer?
                sqlite3_prepare_v2(self.db, "INSERT INTO events_fts(rowid,content,title,app) VALUES(?,?,?,?)", -1, &f, nil)
                sqlite3_bind_int64(f, 1, id)
                self.bind(f, 2, text); self.bind(f, 3, title); self.bind(f, 4, app)
                sqlite3_step(f)
                sqlite3_finalize(f)
            }
            self.extractEntities(title + "\n" + String(text.prefix(3000)), app: kind == "chat" ? nil : app, date: date)
        }
    }

    private static let entityRules: [(NSRegularExpression, String)] = {
        let raw: [(String, String)] = [
            ("(?:localhost|127\\.0\\.0\\.1):(\\d{2,5})", "端口"),
            ("\\b[\\w\\-]{2,40}\\.(?:swift|py|js|ts|tsx|jsx|go|rs|java|kt|md|json|ya?ml|pdf|docx?|xlsx?|pptx?|html|css|cpp|c|h|sql|sh)\\b", "文件"),
            ("https?://(?:www\\.)?([A-Za-z0-9.-]+\\.[A-Za-z]{2,})", "网站")
        ]
        return raw.compactMap { r in (try? NSRegularExpression(pattern: r.0)).map { ($0, r.1) } }
    }()

    private func extractEntities(_ text: String, app: String?, date: Date) {
        var found: [(String, String)] = []
        if let a = app, !a.isEmpty { found.append((a, "应用")) }
        let ns = text as NSString
        for (re, kind) in MemoryStore.entityRules {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).prefix(20) {
                let r = kind == "端口" ? m.range : (m.numberOfRanges > 1 && kind == "网站" ? m.range(at: 1) : m.range)
                found.append((ns.substring(with: r), kind))
            }
        }
        var seen = Set<String>()
        for (name, kind) in found where seen.insert(name).inserted {
            var st: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO entities(name,kind,count,last) VALUES(?,?,1,?) ON CONFLICT(name) DO UPDATE SET count=count+1, last=excluded.last", -1, &st, nil)
            bind(st, 1, name); bind(st, 2, kind)
            sqlite3_bind_double(st, 3, date.timeIntervalSince1970)
            sqlite3_step(st)
            sqlite3_finalize(st)
        }
    }

    // MARK: read
    private static let stop: Set<String> = ["什么", "怎么", "这个", "那个", "一下", "我们", "你们", "他们", "刚才", "之前", "现在",
                                            "是不是", "可以", "帮我", "看看", "一个", "就是", "还是", "如何", "为什么", "哪里",
                                            "the", "and", "for", "what", "how", "this", "that", "with", "you", "are"]

    func keywords(_ q: String) -> [String] {
        let tok = NLTokenizer(unit: .word)
        tok.string = q
        var out: [String] = []
        tok.enumerateTokens(in: q.startIndex..<q.endIndex) { r, _ in
            let w = String(q[r]).lowercased()
            if w.count >= 2 && !MemoryStore.stop.contains(w) && !out.contains(w) { out.append(w) }
            return out.count < 12
        }
        return out
    }

    private func rows(_ sql: String, binder: (OpaquePointer?) -> Void, withEmb: Bool = false,
                      each: (MemoryHit, [Float]?, Double) -> Void) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        binder(st)
        while sqlite3_step(st) == SQLITE_ROW {
            let hit = MemoryHit(id: sqlite3_column_int64(st, 0),
                                date: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                                kind: col(st, 2), app: col(st, 3), title: col(st, 4), content: col(st, 5), score: 0)
            var vec: [Float]?
            if withEmb, let p = sqlite3_column_blob(st, 6) {
                let n = Int(sqlite3_column_bytes(st, 6)) / MemoryLayout<Float>.size
                vec = Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: Float.self), count: n))
            }
            let extra = withEmb ? 0 : sqlite3_column_double(st, 6)
            each(hit, vec, extra)
        }
        sqlite3_finalize(st)
    }

    /// Hybrid recall: FTS5 trigram (≥3 chars) + LIKE (2-char CJK words) + vector cosine, then recency-weighted.
    func search(_ query: String, limit: Int = 3, excludeAfter: Date? = nil) -> [MemoryHit] {
        q.sync {
            var cands: [Int64: MemoryHit] = [:]
            func add(_ h: MemoryHit, _ s: Double) {
                if let ex = excludeAfter, h.date > ex, h.kind == "screen" { return }
                if var c = cands[h.id] { c.score += s; cands[h.id] = c } else { var n = h; n.score = s; cands[h.id] = n }
            }
            let terms = keywords(query)
            let long = terms.filter { $0.count >= 3 }
            if ftsOK && !long.isEmpty {
                let match = long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"" }.joined(separator: " OR ")
                rows("SELECT e.id,e.ts,e.kind,e.app,e.title,e.content,bm25(events_fts) FROM events_fts JOIN events e ON e.id=events_fts.rowid WHERE events_fts MATCH ? ORDER BY bm25(events_fts) LIMIT 40",
                     binder: { self.bind($0, 1, match) }) { h, _, bm in add(h, 1.0 + min(1.0, -bm / 8.0)) }
            }
            for t in terms.filter({ $0.count == 2 }).prefix(4) {
                rows("SELECT id,ts,kind,app,title,content,0 FROM events WHERE content LIKE ? OR title LIKE ? ORDER BY ts DESC LIMIT 25",
                     binder: { self.bind($0, 1, "%\(t)%"); self.bind($0, 2, "%\(t)%") }) { h, _, _ in add(h, 0.6) }
            }
            if let qv = embed(query) {
                var scored: [(MemoryHit, Double)] = []
                rows("SELECT id,ts,kind,app,title,content,emb FROM events WHERE emb IS NOT NULL ORDER BY ts DESC LIMIT 4000",
                     binder: { _ in }, withEmb: true) { h, v, _ in
                    guard let v = v, v.count == qv.count else { return }
                    var dot: Float = 0, na: Float = 0, nb: Float = 0
                    for i in 0..<v.count { dot += v[i] * qv[i]; na += v[i] * v[i]; nb += qv[i] * qv[i] }
                    let cos = Double(dot / max(1e-6, sqrt(na) * sqrt(nb)))
                    if cos > 0.35 { scored.append((h, cos)) }
                }
                for (h, c) in scored.sorted(by: { $0.1 > $1.1 }).prefix(20) { add(h, c * 1.5) }
            }
            let now = Date()
            var list = Array(cands.values)
            for i in list.indices {
                let ageH = now.timeIntervalSince(list[i].date) / 3600
                list[i].score *= 1 + 0.5 * exp(-ageH / 24)
            }
            list.sort { $0.score > $1.score }
            var out: [MemoryHit] = []
            var seen = Set<String>()
            for h in list where out.count < limit {
                let key = String(h.content.prefix(120))
                if seen.insert(key).inserted { out.append(h) }
            }
            return out
        }
    }

    func topEntities(_ n: Int = 8) -> [(String, String, Int)] {
        q.sync {
            var out: [(String, String, Int)] = []
            var st: OpaquePointer?
            let now = Date().timeIntervalSince1970
            sqlite3_prepare_v2(db, "SELECT name,kind,count FROM entities ORDER BY count * (1.0/(1.0+(?-last)/86400.0)) DESC LIMIT ?", -1, &st, nil)
            sqlite3_bind_double(st, 1, now)
            sqlite3_bind_int(st, 2, Int32(n))
            while sqlite3_step(st) == SQLITE_ROW { out.append((col(st, 0), col(st, 1), Int(sqlite3_column_int(st, 2)))) }
            sqlite3_finalize(st)
            return out
        }
    }

    func timeline(since: Date) -> [(Date, String, String)] {
        q.sync {
            var out: [(Date, String, String)] = []
            var st: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT ts,app,title FROM events WHERE kind='screen' AND ts>? ORDER BY ts", -1, &st, nil)
            sqlite3_bind_double(st, 1, since.timeIntervalSince1970)
            while sqlite3_step(st) == SQLITE_ROW {
                out.append((Date(timeIntervalSince1970: sqlite3_column_double(st, 0)), col(st, 1), col(st, 2)))
            }
            sqlite3_finalize(st)
            return out
        }
    }

    func stats() -> (count: Int, bytes: Int64) {
        q.sync {
            var n = 0
            var st: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT count(*) FROM events", -1, &st, nil)
            if sqlite3_step(st) == SQLITE_ROW { n = Int(sqlite3_column_int(st, 0)) }
            sqlite3_finalize(st)
            var size: Int64 = 0
            for suffix in ["", "-wal"] {
                let p = url.path + suffix
                if let a = try? FileManager.default.attributesOfItem(atPath: p), let s = a[.size] as? NSNumber { size += s.int64Value }
            }
            return (n, size)
        }
    }

    func prune(days: Int) {
        guard days > 0 else { return }   // 0 = 永久：不自动删除
        q.async {
            let cut = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
            self.exec("DELETE FROM events WHERE ts < \(cut);")
            if self.ftsOK { self.exec("DELETE FROM events_fts WHERE rowid NOT IN (SELECT id FROM events);") }
            self.exec("DELETE FROM entities WHERE last < \(cut);")
        }
    }

    func clear() {
        q.sync {
            self.exec("DELETE FROM events; DELETE FROM entities;")
            if self.ftsOK { self.exec("DELETE FROM events_fts;") }
            self.exec("VACUUM;")
        }
    }
}

// MARK: - Hub: perception loop + Tier 1 + Dynamic Context Assembler

struct AssembledContext {
    let text: String
    let image: Data?
    let tokens: Int
}

/// One place on screen the answer points at.
struct GroundTarget {
    let el: ScreenElement
    let hint: String
    let n: Int
}

final class ContextHub {
    let reader = ScreenReader()
    let memory: MemoryStore
    private(set) var ring: [ContextCard] = []
    private(set) var keptFrames = 0
    private(set) var droppedFrames = 0
    private(set) var lastExternalApp: NSRunningApplication?
    private(set) var lastAssembled = ""
    /// Elements and screenshot geometry of the last assembled context, for [[el:N]] / [[img:x,y]] grounding.
    private(set) var groundingElements: [ScreenElement] = []
    private(set) var groundingShot: (frame: CGRect, size: CGSize)?
    private var lastCaptureAt = Date.distantPast
    private var lastTitleKey = ""
    private var capturing = false
    private var periodic: Timer?
    private var titleWatch: Timer?
    var idleSeconds: () -> Double = { 0 }

    init(dir: URL) {
        memory = MemoryStore(dir: dir)
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            guard let self = self,
                  let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self.lastExternalApp = app
            if Prefs.perception {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.captureNow() }
            }
        }
        memory.prune(days: Prefs.retentionDays)
    }

    func setEnabled(_ on: Bool) {
        periodic?.invalidate(); titleWatch?.invalidate()
        periodic = nil; titleWatch = nil
        guard on else { return }
        // Window-title watch: one cheap AX read every 3 s, captures only when the title changes.
        titleWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkTitle() }
        titleWatch?.tolerance = 1
        // Continuous companion frame: every 30 s, only while the user is active. Identical frames are dropped.
        periodic = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self, self.idleSeconds() < 60 else { return }
            self.captureNow()
        }
        periodic?.tolerance = 8
        captureNow()
    }

    private func checkTitle() {
        guard let app = lastExternalApp, AXIsProcessTrusted() else { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.2)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &w) == .success,
              let win = w, CFGetTypeID(win) == AXUIElementGetTypeID() else { return }
        var t: CFTypeRef?
        AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &t)
        let key = "\(app.processIdentifier)|\((t as? String) ?? "")"
        if key != lastTitleKey { lastTitleKey = key; captureNow() }
    }

    func captureNow() {
        guard Prefs.perception, !capturing, Date().timeIntervalSince(lastCaptureAt) > 4,
              let app = lastExternalApp, !app.isTerminated else { return }
        capturing = true
        Task {
            let card = await reader.capture(app: app, deep: false, wantScreenshot: false)
            await MainActor.run {
                self.capturing = false
                if let c = card { self.ingest(c) }
            }
        }
    }

    /// Frame-drop tolerance: a frame that is ≥85% identical to the previous one of the same window is not stored.
    private func ingest(_ card0: ContextCard) {
        lastCaptureAt = Date()
        var card = card0
        card.screenshot = nil   // pixels are never kept; only the structured text card is
        if card.elements.isEmpty { return }
        if let prev = ring.last, prev.bundleID == card.bundleID, prev.windowTitle == card.windowTitle {
            let a = prev.lineSet, b = card.lineSet
            let sim = Double(a.intersection(b).count) / Double(max(1, a.union(b).count))
            if sim > 0.85 {
                droppedFrames += 1
                ring[ring.count - 1] = card
                return
            }
        }
        ring.append(card)
        if ring.count > 20 { ring.removeFirst(ring.count - 20) }
        keptFrames += 1
        memory.add(kind: "screen", app: card.app, bundle: card.bundleID, title: card.windowTitle, content: card.plainText)
    }

    // MARK: Page sharing (the "正在分享「…」" chip in the bubble)

    /// Cheap read of the front app's focused window title, for the share chip. nil when nothing can be shared.
    func shareableWindow() -> (app: NSRunningApplication, title: String)? {
        guard AXIsProcessTrusted(), let app = lastExternalApp, !app.isTerminated else { return nil }
        let bid = app.bundleIdentifier ?? ""
        if reader.isExcluded(bid) || bid == Bundle.main.bundleIdentifier { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.15)
        var title = ""
        var w: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &w) == .success,
           let win = w, CFGetTypeID(win) == AXUIElementGetTypeID() {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &t)
            title = (t as? String) ?? ""
        }
        title = Redactor.clean(title.trimmingCharacters(in: .whitespacesAndNewlines))
        if title.isEmpty { title = app.localizedName ?? "当前窗口" }
        return (app, title)
    }

    /// One-shot read of the page the user chose to share. Nothing is read until they actually ask.
    struct PageContext { var text: String; var images: [Data] }

    /// Read the window the user shared, once, because they asked. Chat apps are rebuilt by position
    /// (so names are known); pictures and video frames go to a vision model only when useful.
    func pageContext(question: String = "", budgetChars: Int = 6500,
                     progress: ((String) -> Void)? = nil) async -> PageContext? {
        guard let app = lastExternalApp, !app.isTerminated else { return nil }
        let bid = app.bundleIdentifier ?? ""
        let pid = app.processIdentifier
        var card = await reader.capture(app: app, deep: true, wantScreenshot: false, maxNodes: 4000, axBudget: 0.6)
        if let c = card, c.plainText.count < 200, ScreenReader.chromiumBrowsers.contains(c.bundleID) {
            // Chromium builds its accessibility tree lazily the first time we ask: give it a moment.
            try? await Task.sleep(nanoseconds: 450_000_000)
            card = await reader.capture(app: app, deep: true, wantScreenshot: false, maxNodes: 4000, axBudget: 0.6)
        }
        guard let c = card else { return nil }
        await MainActor.run { self.ingestIfEnabled(c) }

        let isChat = Prefs.chatLayout && MediaHub.isChatApp(bid)
        let wantsVideo = MediaHub.wantsVideo(question) || MediaHub.videoApps.contains(bid)
        let wantsMedia = MediaHub.wantsMedia(question) || MediaHub.videoApps.contains(bid)
        let vision = Cap.vision
        let thin = c.plainText.count < 200
        // Start listening right away so sound and frames are captured together.
        let audioTask: Task<String?, Never>? = (MediaHub.wantsVideo(question) && Prefs.videoAudio)
            ? Task { await MediaHub.listenToScreen(seconds: 6) } : nil

        var shot: (CGImage, CGRect)?
        if isChat || (vision != nil && (wantsMedia || thin)) {
            shot = await reader.captureWindowImage(pid: pid, maxWidth: 1800)
        }
        // Numbered lines: what is on screen right now first (that is what "重点" is about), so the model can
        // point at a line with [[el:N]] and OrdCat rings the exact spot.
        let (numbered, els) = ContextHub.numberedLines(c, budgetChars: budgetChars)
        var body = numbered.isEmpty ? c.plainText : numbered
        await MainActor.run {
            self.groundingElements = els
            self.groundingShot = nil
            self.groundingApp = app
        }
        var layout = ""
        if isChat, let (img, frame) = shot {
            let o = reader.ocr(img, frame: frame, accurate: true)
            if !o.isEmpty { layout = MediaHub.chatTranscript(o, window: frame) }
        }
        if !layout.isEmpty { body = layout }
        if body.count > budgetChars { body = String(body.prefix(budgetChars)) + "\n…（页面后面的内容省略）" }
        if body.isEmpty { body = "（这个窗口读不到文字，可能是图片或画布类内容）" }

        var media = ""
        var images: [Data] = []
        if let (img, _) = shot, vision != nil, isChat || wantsMedia || thin {
            var frames = [img]
            if wantsVideo {
                progress?("🎬 我多看几眼画面…")
                for _ in 0..<2 {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if let (f, _) = await reader.captureWindowImage(pid: pid, maxWidth: 1280) { frames.append(f) }
                }
            }
            let datas = frames.compactMap { MediaHub.jpeg($0, maxSide: 1280) }
            if Cap.visionUsesChat {
                images = datas
            } else {
                progress?("🖼️ 看图模型正在看图…")
                let (desc, err) = await MediaHub.describe(datas, question: question, appName: c.app, video: wantsVideo)
                if let d = desc { media = "## 画面里的图片 / 视频（看图模型的描述）\n\(d)" }
                else if let e = err { media = "## 画面里的图片\n（这次没看成：\(e)。请如实告诉用户。）" }
            }
        } else if wantsMedia && vision == nil {
            media = "## 画面里的图片\n（还没有设置看图模型，所以看不到图片和视频画面。请告诉用户：右键小猫 → 设置 → 模型 → 看图，选一个看图模型。）"
        } else if wantsMedia && shot == nil && !ScreenReader.screenRecordingAllowed() {
            media = "## 画面里的图片\n（没有「屏幕录制」权限，看不到图片。请告诉用户到 系统设置 → 隐私与安全性 → 屏幕录制 打开 OrdCat。）"
        }
        var sound = ""
        if let t = audioTask {
            progress?("👂 我听几秒声音…")
            if let heard = await t.value { sound = "## 刚才几秒的声音（语音转文字）\n\(Redactor.clean(heard))" }
        }

        var text = """
        ## 用户正在分享的页面
        用户主动把当前页面分享给你。用户说「这个」「这页」「这里」时，指的就是它；请结合页面内容回答，不要编造页面上没有的信息。
        应用：\(c.app)
        窗口标题：\(c.windowTitle)
        """
        if !layout.isEmpty { text += "\n" + MediaHub.chatGuide + "\n聊天内容（从上到下）：\n" + body }
        else {
            text += "\n页面文字（[编号] 内容；⭐ 表示此刻在屏幕上能看到的部分，用户问「这页/重点」时以 ⭐ 部分为主）：\n" + body
            text += "\n\n提到页面上的某一处（比如每条重点）时，在那句话末尾写上它的编号，格式 [[el:编号]]，例如「价格涨了 [[el:12]]」。OrdCat 会在屏幕上把那里圈出来。只写真实存在的编号。"
        }
        if !media.isEmpty { text += "\n\n" + media }
        if !sound.isEmpty { text += "\n\n" + sound }
        if !images.isEmpty { text += "\n\n（附上了这个窗口的截图\(images.count > 1 ? "，共 \(images.count) 帧" : "")，可以直接看图回答。）" }
        return PageContext(text: text, images: images)
    }

    private func ingestIfEnabled(_ c: ContextCard) { if Prefs.perception { ingest(c) } }

    func recordSelection(_ text: String) {
        let app = lastExternalApp
        memory.add(kind: "select", app: app?.localizedName ?? "", bundle: app?.bundleIdentifier ?? "",
                   title: "划选文字", content: Redactor.clean(text))
    }

    func recordChat(user: String, reply: String) {
        memory.add(kind: "chat", app: "OrdCat", bundle: Bundle.main.bundleIdentifier ?? "",
                   title: "和小猫的对话", content: Redactor.clean("用户：\(user.prefix(1500))\nOrdCat：\(reply.prefix(1500))"))
    }

    // MARK: Dynamic Context Assembler
    func assemble(query: String, wantScreenshot: Bool, budget: Int = Prefs.contextBudget) async -> AssembledContext {
        let df = DateFormatter(); df.dateFormat = "HH:mm"
        let dfl = DateFormatter(); dfl.dateFormat = "M月d日 HH:mm"
        var sections: [String] = []
        var image: Data?
        var elements: [ScreenElement] = []
        var shotGeo: (CGRect, CGSize)?

        // 1. Current screen (fresh, deep capture)
        if let app = lastExternalApp, !app.isTerminated,
           let card = await reader.capture(app: app, deep: true, wantScreenshot: wantScreenshot) {
            await MainActor.run { self.ingest(card) }
            let wr = card.windowRect
            var s = "## 当前屏幕\n应用：\(card.app)\n窗口：\(card.windowTitle)\n窗口区域：(\(Int(wr.minX)),\(Int(wr.minY)),\(Int(wr.width)),\(Int(wr.height)))\n读取方式：\(card.source)\n可见元素（#编号 [类型] 内容 @x,y,宽,高）：\n"
            let screenBudget = budget * 55 / 100
            var used = estimateTokens(s)
            for e in card.elements where !e.chrome {
                let t = e.text.count > 240 ? String(e.text.prefix(240)) + "…" : e.text
                let line = "#\(elements.count + 1) [\(e.role)] \(t.replacingOccurrences(of: "\n", with: " ")) @\(Int(e.rect.minX)),\(Int(e.rect.minY)),\(Int(e.rect.width)),\(Int(e.rect.height))\n"
                let cost = estimateTokens(line)
                if used + cost > screenBudget { s += "…（其余元素省略）\n"; break }
                s += line; used += cost
                elements.append(e)
            }
            sections.append(s)
            if let img = card.screenshot, let d = jpegData(cgImage: img) {
                image = d
                shotGeo = (wr == .zero ? CGRect(x: 0, y: 0, width: img.width, height: img.height) : wr,
                           CGSize(width: img.width, height: img.height))
            }
        } else {
            sections.append("## 当前屏幕\n（没有读取到：可能未授权「辅助功能」，或当前是被排除的应用）")
        }

        // 2. Working context: last 10 minutes
        let since = Date().addingTimeInterval(-600)
        var tl: [String] = []
        var lastKey = ""
        for c in ring where c.date > since {
            let key = c.app + c.windowTitle
            if key == lastKey { continue }
            lastKey = key
            tl.append("\(df.string(from: c.date))  \(c.app) — \(c.windowTitle)")
        }
        if !tl.isEmpty { sections.append("## 最近 10 分钟\n" + tl.suffix(12).joined(separator: "\n")) }

        // 3. Semantic recall
        let hits = memory.search(query, limit: 3, excludeAfter: Date().addingTimeInterval(-90))
        if !hits.isEmpty {
            var s = "## 相关记忆（本地检索）\n"
            for h in hits {
                let snippet = h.content.count > 420 ? String(h.content.prefix(420)) + "…" : h.content
                s += "- [\(dfl.string(from: h.date)) · \(h.app) · \(h.title)]\n  \(snippet.replacingOccurrences(of: "\n", with: " / "))\n"
            }
            sections.append(s)
        }

        // 4. Entity ledger
        let ents = memory.topEntities(8)
        if !ents.isEmpty {
            sections.append("## 用户常用\n" + ents.map { "\($0.1)：\($0.0)" }.joined(separator: "；"))
        }

        var guide = """
        ## 指示位置的方法
        需要告诉用户点哪里时，在句子里写 [[el:编号]] 指向上面的元素（例如 [[el:12]]），OrdCat 会在屏幕上高亮它。
        也可以写 [[pt:x,y]]，单位是屏幕点，原点在主屏左上角。
        """
        if let g = shotGeo { guide += "\n附带了当前窗口截图（\(Int(g.1.width))×\(Int(g.1.height)) 像素），指截图里的位置可写 [[img:x,y]]（截图像素坐标）。" }
        sections.append(guide)

        var text = "以下是 OrdCat 在用户本机整理的桌面上下文（已脱敏，仅供参考；不要逐条复述，直接用它回答问题）：\n\n" + sections.joined(separator: "\n\n")
        while estimateTokens(text) > budget && text.count > 400 {
            text = String(text.prefix(text.count * 9 / 10))
        }
        let final = text
        await MainActor.run {
            self.lastAssembled = final
            self.groundingElements = elements
            self.groundingShot = shotGeo.map { (frame: $0.0, size: $0.1) }
            self.groundingApp = self.lastExternalApp
        }
        return AssembledContext(text: final, image: image, tokens: estimateTokens(final))
    }

    /// The app the grounding elements came from (to re-find them after a scroll).
    var groundingApp: NSRunningApplication?

    /// Page text as "[n] line", visible-on-screen lines first and starred, within a character budget.
    static func numberedLines(_ c: ContextCard, budgetChars: Int) -> (String, [ScreenElement]) {
        let screens = NSScreen.screens.map { r -> CGRect in
            let h = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: r.frame.minX, y: h - r.frame.maxY, width: r.frame.width, height: r.frame.height)
        }
        let win = c.windowRect
        func visible(_ e: ScreenElement) -> Bool {
            let r = e.rect
            guard r.width > 2, r.height > 2 else { return false }
            if win != .zero && !win.intersects(r) { return false }
            return screens.contains { $0.intersects(r) }
        }
        var seen = Set<String>()
        var vis: [ScreenElement] = [], rest: [ScreenElement] = []
        for e in c.elements where !e.chrome {   // toolbars / tabs / bookmarks are never numbered (never ringed)
            let t = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, seen.insert(t).inserted else { continue }
            if visible(e) { vis.append(e) } else { rest.append(e) }
        }
        var out: [ScreenElement] = []
        var lines: [String] = []
        var used = 0
        for (group, star) in [(vis, true), (rest, false)] {
            for e in group {
                var t = e.text.replacingOccurrences(of: "\n", with: " ")
                if t.count > 300 { t = String(t.prefix(300)) + "…" }
                let line = "[\(out.count + 1)]\(star ? "⭐" : "") \(t)"
                if used + line.count > budgetChars { lines.append("…（其余内容省略）"); return (lines.joined(separator: "\n"), out) }
                used += line.count + 1
                lines.append(line)
                out.append(e)
            }
        }
        return (lines.joined(separator: "\n"), out)
    }

    /// Character-bigram overlap between two strings (0…1), for matching an answer line to page text.
    static func similarity(_ a: String, _ b: String) -> Double {
        func grams(_ s: String) -> Set<String> {
            let c = Array(s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol })
            guard c.count >= 2 else { return Set(c.map { String($0) }) }
            return Set((0..<(c.count - 1)).map { String(c[$0]) + String(c[$0 + 1]) })
        }
        let ga = grams(a), gb = grams(b)
        guard !ga.isEmpty, !gb.isEmpty else { return 0 }
        return Double(ga.intersection(gb).count) / Double(min(ga.count, gb.count))
    }

    /// When the model gave no tags: match each point of the answer to the on-screen line it talks about.
    /// Strict on purpose: a wrong ring is worse than no ring. Short labels (buttons, bookmarks) never match on a
    /// couple of shared letters, and lines visible on screen win ties.
    func fallbackTargets(for reply: String, limit: Int = 4) -> [GroundTarget] {
        let parts = reply.components(separatedBy: CharacterSet(charactersIn: "\n。；;！？!?"))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " •-*·0123456789.、：:①②③④⑤⑥⑦⑧⑨👉")) }
            .filter { $0.count >= 6 }
        var picked: [GroundTarget] = []
        for p in parts {
            var best: (Double, ScreenElement)?
            for e in groundingElements where !e.chrome && e.text.count >= 6 && !picked.contains(where: { $0.el.rect == e.rect }) {
                let (sc, shared) = ContextHub.overlap(p, e.text)
                guard shared >= 4 else { continue }
                if sc > (best?.0 ?? 0.5) { best = (sc, e) }
            }
            if let b = best { picked.append(GroundTarget(el: b.1, hint: p, n: picked.count + 1)) }
            if picked.count >= limit { break }
        }
        return picked
    }

    /// Bigram overlap score (0…1, relative to the shorter text) and the number of shared bigrams.
    static func overlap(_ a: String, _ b: String) -> (Double, Int) {
        func grams(_ s: String) -> Set<String> {
            let c = Array(s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol })
            guard c.count >= 2 else { return Set(c.map { String($0) }) }
            return Set((0..<(c.count - 1)).map { String(c[$0]) + String(c[$0 + 1]) })
        }
        let ga = grams(a), gb = grams(b)
        guard !ga.isEmpty, !gb.isEmpty else { return (0, 0) }
        let n = ga.intersection(gb).count
        return (Double(n) / Double(min(ga.count, gb.count)), n)
    }

    /// Elements named by [[el:N]] tags, in the order the answer mentions them. Each carries the sentence that
    /// pointed at it (to find the exact line inside a long block) and its ring number (① ② …, same as the text).
    func taggedTargets(in reply: String) -> [GroundTarget] {
        guard let re = try? NSRegularExpression(pattern: "\\[\\[el:\\s*([0-9]+)\\s*\\]\\]") else { return [] }
        let ns = reply as NSString
        var out: [GroundTarget] = []
        var seen: [Int] = []
        var prevEnd = 0
        for m in re.matches(in: reply, range: NSRange(location: 0, length: ns.length)) {
            let i = (Int(ns.substring(with: m.range(at: 1))) ?? 0) - 1
            // The sentence right before the tag.
            var hint = ns.substring(with: NSRange(location: prevEnd, length: max(0, m.range.location - prevEnd)))
            prevEnd = m.range.location + m.range.length
            if let cut = hint.rangeOfCharacter(from: CharacterSet(charactersIn: "\n。！？!?"), options: .backwards),
               hint.distance(from: cut.upperBound, to: hint.endIndex) >= 4 { hint = String(hint[cut.upperBound...]) }
            hint = hint.replacingOccurrences(of: "\\[\\[[^\\]]*\\]\\]", with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " •-*·、：:，,"))
            guard !seen.contains(i) else { continue }
            seen.append(i)
            guard i >= 0 && i < groundingElements.count, !groundingElements[i].chrome else { continue }
            out.append(GroundTarget(el: groundingElements[i], hint: hint, n: seen.count))
        }
        return out
    }

    /// Kept for older callers.
    func taggedElements(in reply: String) -> [ScreenElement] { taggedTargets(in: reply).map { $0.el } }

    /// Re-read the page right before drawing, so rings land where the text is now (the user may have scrolled
    /// while the answer was streaming), then narrow each ring from a whole block to the exact line(s) the
    /// answer is about (on-device OCR of the window, nothing leaves the Mac). Off-screen targets are left out.
    func relocate(_ targets: [GroundTarget]) async -> [(CGRect, Int)] {
        guard !targets.isEmpty else { return [] }
        let screens = NSScreen.screens.map { r -> CGRect in
            let h = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: r.frame.minX, y: h - r.frame.maxY, width: r.frame.width, height: r.frame.height)
        }
        func onScreen(_ r: CGRect, _ win: CGRect) -> Bool {
            r.width > 2 && r.height > 2 && (win == .zero || win.intersects(r)) && screens.contains { $0.intersects(r) }
        }
        guard let app = groundingApp ?? lastExternalApp, !app.isTerminated,
              let c = await reader.capture(app: app, deep: true, wantScreenshot: false, maxNodes: 4000, axBudget: 0.6) else {
            return targets.map { ($0.el.rect, $0.n) }
        }
        var found: [(CGRect, GroundTarget)] = []
        for t in targets {
            let same = c.elements.filter { $0.text == t.el.text && !$0.chrome && onScreen($0.rect, c.windowRect) }
            func dist(_ e: ScreenElement) -> CGFloat { hypot(e.rect.midY - t.el.rect.midY, e.rect.midX - t.el.rect.midX) }
            // Exact text first; then text that changed a little (a counter, "5m" → "6m"); then where it was.
            var hit = same.min(by: { dist($0) < dist($1) })?.rect
            if hit == nil {
                let close = c.elements.filter { !$0.chrome && onScreen($0.rect, c.windowRect) && $0.text.count >= 4 }
                    .map { ($0, ContextHub.overlap(t.el.text, $0.text)) }
                    .filter { $0.1.0 >= 0.8 && Double($0.0.text.count) < Double(t.el.text.count) * 1.6 + 10 }
                hit = close.min(by: { dist($0.0) < dist($1.0) })?.0.rect
            }
            // Fall back to where it was only when the re-read itself came back nearly empty. If the page was
            // read fine and the text is gone, it scrolled away or the user moved on: no ring at all.
            if hit == nil && c.elements.count < 10 && onScreen(t.el.rect, c.windowRect) { hit = t.el.rect }
            if let h = hit {
                let r = h.intersection(c.windowRect == .zero ? h : c.windowRect)
                if !r.isNull && r.height > 2 { found.append((r, t)) }
            }
        }
        guard !found.isEmpty else { return [] }
        // What is really on screen right now (on-device OCR of the window, nothing leaves the Mac).
        // Used twice: to check the text is actually where the ring would go, and to narrow tall blocks to a line.
        var lines: [ScreenElement] = []
        if let (img, frame) = await reader.captureWindowImage(pid: app.processIdentifier, maxWidth: 2400) {
            lines = reader.ocr(img, frame: frame, accurate: true)
        }
        var out: [(CGRect, Int)] = []
        for (r, t) in found {
            var rect = r
            if !lines.isEmpty {
                // Some apps (X, long feeds) report stale positions for recycled rows. Only ring a place whose
                // pixels show the text we mean; otherwise leave it out rather than ring the wrong lines.
                guard ContextHub.textVisible(t.el.text, hint: t.hint, in: r, lines: lines) else { continue }
            }
            if r.height > 44 && t.hint.count >= 4, let narrow = ContextHub.bestLines(in: r, hint: t.hint, lines: lines) {
                rect = narrow
            } else if r.height > 44, let tight = ContextHub.textBounds(of: t.el.text, in: r, lines: lines) {
                // Hug the text: a block's frame can run far past it (sidebars, empty margins).
                rect = tight
            }
            out.append((rect, t.n))
        }
        return out
    }

    /// Rings inside the text the user selected: each point of the answer goes on the selected line it talks
    /// about (on-device OCR of that window). When nothing matches, or the user didn't ask for points, the whole
    /// selection is ringed so they still see what the answer is about.
    func selectionMarks(rect: CGRect, pid: pid_t, reply: String, wantLines: Bool) async -> [(CGRect, Int)] {
        guard rect.width > 2, rect.height > 2 else { return [] }
        if wantLines, rect.height > 30, let (img, frame) = await reader.captureWindowImage(pid: pid, maxWidth: 2400) {
            let lines = reader.ocr(img, frame: frame, accurate: true)
            let parts = reply.components(separatedBy: CharacterSet(charactersIn: "\n。；;！？!?"))
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " •-*·0123456789.、：:①②③④⑤⑥⑦⑧⑨👉")) }
                .filter { $0.count >= 4 }
            var out: [(CGRect, Int)] = []
            for p in parts {
                guard let r = ContextHub.bestLines(in: rect, hint: p, lines: lines),
                      !out.contains(where: { $0.0.intersects(r) }) else { continue }
                out.append((r, out.count + 1))
                if out.count >= 4 { break }
            }
            if !out.isEmpty { return out }
        }
        return [(rect, 0)]
    }

    /// Older callers: plain rects.
    func relocate(_ targets: [ScreenElement]) async -> [CGRect] {
        await relocate(targets.enumerated().map { GroundTarget(el: $0.element, hint: "", n: $0.offset + 1) }).map { $0.0 }
    }

    /// OCR lines that sit inside `block`.
    static func linesInside(_ block: CGRect, _ lines: [ScreenElement]) -> [ScreenElement] {
        lines.filter { l in
            let i = l.rect.intersection(block.insetBy(dx: -4, dy: -4))
            return !i.isNull && i.width * i.height >= 0.6 * l.rect.width * l.rect.height
        }
    }

    /// True when the pixels inside `block` show (part of) the element's text or the answer's quote.
    static func textVisible(_ text: String, hint: String, in block: CGRect, lines: [ScreenElement]) -> Bool {
        let inside = linesInside(block, lines)
        guard !inside.isEmpty else { return false }
        let seen = inside.map { $0.text }.joined(separator: " ")
        let probe = String(text.prefix(400))
        let (a, na) = overlap(probe, seen)
        if na >= 3 && a >= 0.35 { return true }
        if hint.count >= 4 {
            let (b, nb) = overlap(hint, seen)
            if nb >= 3 && b >= 0.35 { return true }
        }
        // Very short labels (a button, "5m"): exact containment is enough.
        let compact = { (s: String) in s.lowercased().filter { !$0.isWhitespace } }
        let pt = compact(probe)
        return pt.count >= 2 && pt.count <= 6 && compact(seen).contains(pt)
    }

    /// The box around the OCR lines inside `block` that belong to `text` (nil when none do).
    static func textBounds(of text: String, in block: CGRect, lines: [ScreenElement]) -> CGRect? {
        let probe = String(text.prefix(2000))
        let inside = linesInside(block, lines).filter { l in
            let (sc, n) = overlap(l.text, probe)
            return n >= 2 && sc >= 0.5
        }
        guard var r = inside.first?.rect else { return nil }
        for l in inside.dropFirst() { r = r.union(l.rect) }
        return r.insetBy(dx: -2, dy: -1)
    }

    /// The OCR line(s) inside `block` that best match `hint`: the best line, plus the next line when the point
    /// runs onto it. Nil when nothing matches well enough (then the whole block is ringed).
    static func bestLines(in block: CGRect, hint: String, lines: [ScreenElement]) -> CGRect? {
        let inside = lines.filter { l in
            let i = l.rect.intersection(block.insetBy(dx: -4, dy: -4))
            return !i.isNull && i.width * i.height >= 0.6 * l.rect.width * l.rect.height
        }.sorted { abs($0.rect.minY - $1.rect.minY) > 4 ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
        guard !inside.isEmpty else { return nil }
        var best: (Double, Int)?
        for (k, l) in inside.enumerated() {
            let (sc, n) = overlap(hint, l.text)
            guard n >= 2 else { continue }
            if sc > (best?.0 ?? 0.3) { best = (sc, k) }
        }
        guard let (_, k) = best else { return nil }
        var r = inside[k].rect
        // Same visual row (wrapped spans) and the following row if it continues the quoted point.
        for l in inside where l.rect != inside[k].rect && abs(l.rect.midY - r.midY) < r.height * 0.5 { r = r.union(l.rect) }
        if k + 1 < inside.count {
            let nx = inside[k + 1]
            let (sc, n) = overlap(hint, nx.text)
            if nx.rect.minY > r.midY && nx.rect.minY - r.maxY < r.height && n >= 2 && sc >= 0.3 { r = r.union(nx.rect) }
        }
        return r.insetBy(dx: -2, dy: -1)
    }

    /// Resolve [[el:N]] / [[pt:x,y]] / [[img:x,y]] tags into global top-left rects.
    /// [[pt:…]] / [[img:…]] tags with their ring numbers (counted over every tag, the same way stripTags numbers them).
    func pointTargets(in reply: String) -> [(CGRect, Int)] {
        guard let re = try? NSRegularExpression(pattern: "\\[\\[((?:el|pt|img):[^\\]]*)\\]\\]") else { return [] }
        let ns = reply as NSString
        var order: [String] = []
        var out: [(CGRect, Int)] = []
        for m in re.matches(in: reply, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: " ", with: "")
            if order.contains(key) { continue }
            order.append(key)
            if key.hasPrefix("el:") { continue }
            if let r = resolveTargets(in: "[[" + key + "]]").first { out.append((r, order.count)) }
        }
        return out
    }

    func resolveTargets(in reply: String) -> [CGRect] {
        guard let re = try? NSRegularExpression(pattern: "\\[\\[(el|pt|img):\\s*([0-9.]+)\\s*(?:,\\s*([0-9.]+))?\\s*\\]\\]") else { return [] }
        let ns = reply as NSString
        var out: [CGRect] = []
        for m in re.matches(in: reply, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: m.range(at: 1))
            let a = Double(ns.substring(with: m.range(at: 2))) ?? 0
            let b = m.range(at: 3).location != NSNotFound ? (Double(ns.substring(with: m.range(at: 3))) ?? 0) : 0
            switch kind {
            case "el":
                let i = Int(a) - 1
                if i >= 0 && i < groundingElements.count { out.append(groundingElements[i].rect) }
            case "pt":
                out.append(CGRect(x: a - 14, y: b - 14, width: 28, height: 28))
            case "img":
                if let g = groundingShot, g.size.width > 0 {
                    let x = g.frame.minX + a * g.frame.width / g.size.width
                    let y = g.frame.minY + b * g.frame.height / g.size.height
                    out.append(CGRect(x: x - 16, y: y - 16, width: 32, height: 32))
                }
            default: break
            }
        }
        return out
    }

    /// Tags become ring numbers ① ② … in the order the answer first mentions each place, so the text and the
    /// rings on screen match. Unfinished tags at the end of a streaming chunk are hidden.
    static func stripTags(_ s: String) -> String {
        let marks = ["①","②","③","④","⑤","⑥","⑦","⑧","⑨","⑩"]
        guard let re = try? NSRegularExpression(pattern: "\\[\\[((?:el|pt|img):[^\\]]*)\\]\\]") else { return s }
        let ns = s as NSString
        var order: [String] = []
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let key = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: " ", with: "")
            if !order.contains(key) { order.append(key) }
            let i = order.firstIndex(of: key)!
            out += i < marks.count ? marks[i] : "👉"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        if let r = out.range(of: "\\[\\[[^\\]]*$", options: .regularExpression) { out.removeSubrange(r) }
        return out
    }
}
