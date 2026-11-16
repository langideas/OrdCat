// OrdCat — 陪你刷推 (X companion mode).
//
// While you browse x.com in a Mac browser, the cat quietly remembers the people you meet there:
// who you follow, whose posts you liked / bookmarked / reposted, and what topics you care about.
// When you open someone you know, the cat only perks its ears; click it to see the person card.
// It can also give the one-line point of a long post, filter replies, and draft (never send) a reply.
//
// Privacy: off until you say yes; only x.com / twitter.com windows; DMs, chat and settings pages are never read;
// everything is stored in x_people.json on this Mac and can be wiped in Settings.

import Cocoa

extension Prefs {
    static var xMode: Bool { get { d.object(forKey: "xMode") as? Bool ?? false } set { d.set(newValue, forKey: "xMode") } }
    static var xOffered: Bool { get { d.object(forKey: "xOffered") as? Bool ?? false } set { d.set(newValue, forKey: "xOffered") } }
    /// Signal keywords, comma separated ("AI, 融资, 空投").
    static var xSignalWords: String { get { d.string(forKey: "xSignalWords") ?? "" } set { d.set(newValue, forKey: "xSignalWords") } }
    /// Accounts to watch, comma separated ("@elonmusk, @sama").
    static var xSignalAccounts: String { get { d.string(forKey: "xSignalAccounts") ?? "" } set { d.set(newValue, forKey: "xSignalAccounts") } }
    /// Seconds between two popups (signals may cut in after 3 s).
    static var xAlertGap: Double { get { d.object(forKey: "xAlertGap") as? Double ?? 8 } set { d.set(newValue, forKey: "xAlertGap") } }
    static let xAlertDefaults: [String: Bool] = ["signal": true, "spam": true, "water": true, "known": true, "follow": false, "reply": true]
    static func xAlert(_ k: String) -> Bool { d.object(forKey: "xAlert." + k) as? Bool ?? (xAlertDefaults[k] ?? false) }
    static func setXAlert(_ k: String, _ on: Bool) { d.set(on, forKey: "xAlert." + k) }

    static func list(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Something worth a popup while you scroll X.
struct XAlert {
    enum Kind: Int { case signal = 0, spam, known, follow, water }
    let kind: Kind
    let post: XPost
    let reason: String
}

struct XInteraction: Codable {
    var kind: String       // like | bookmark | repost
    var date: Date
    var snippet: String
}

struct XPerson: Codable {
    var handle: String
    var name: String
    var firstSeen: Date
    var lastSeen: Date
    var seenDays: [String]
    var following: Bool?
    var interactions: [XInteraction]
    var visits: Int

    func count(_ kind: String) -> Int { interactions.filter { $0.kind == kind }.count }
    var known: Bool { following == true || !interactions.isEmpty || visits >= 2 || seenDays.count >= 3 }
}

struct XPost {
    var handle: String
    var name: String
    var text: String
    var rect: CGRect
    var marks: Set<String>
    var isAd: Bool
}

private struct XData: Codable {
    var people: [String: XPerson]
    var interests: [String: Int]
    var marks: [String]
}

final class XCompanion {
    private(set) var people: [String: XPerson] = [:]
    private(set) var interests: [String: Int] = [:]
    private var marks: [String] = []
    private var markSet = Set<String>()
    private let url: URL
    private let hub: ContextHub
    private var timer: Timer?
    private var lastTitle = ""
    private var lastScan = Date.distantPast
    private var announcedTitle = ""
    private var dirty = false
    /// Posts read on the last scan, in reading order (first = the main post on a post page).
    private(set) var lastPosts: [XPost] = []
    /// The person this page is about (profile page or a post page), if any.
    private(set) var focus: String?
    /// True while an X page is in front.
    private(set) var onX = false

    var onKnownPerson: ((XPerson) -> Void)?
    var onFirstVisit: (() -> Void)?
    /// You just liked / bookmarked / reposted someone (seen live, not on page load).
    var onInteraction: ((String, String) -> Void)?
    /// A page was read: how many posts the cat can see now.
    var onRead: ((Int) -> Void)?
    /// New posts on screen that match a signal, look like spam, come from people you know…
    var onAlerts: (([XAlert]) -> Void)?
    /// You focused the reply box: the post you are replying to (nil when unclear).
    var onReplyComposer: ((XPost?) -> Void)?
    /// The X page in front changed (new profile, new post, back to the timeline).
    var onPageChanged: (() -> Void)?
    private var seenKeys = Set<String>()
    private var seenOrder: [String] = []
    private var replyKey = ""
    private var replyAt = Date.distantPast
    private var lastFocusKey = ""
    private var initialScanOfPage = false

    init(dir: URL, hub: ContextHub) {
        url = dir.appendingPathComponent("x_people.json")
        self.hub = hub
        if let d = try? Data(contentsOf: url), let x = try? JSONDecoder().decode(XData.self, from: d) {
            people = x.people; interests = x.interests; marks = x.marks; markSet = Set(x.marks)
        }
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.3
    }

    func save() {
        guard dirty else { return }
        dirty = false
        if people.count > 3000 {
            // Forget strangers first: people you never interacted with, oldest sighting first.
            let drop = people.values.filter { $0.interactions.isEmpty && $0.following != true }
                .sorted { $0.lastSeen < $1.lastSeen }.prefix(people.count - 3000)
            for p in drop { people.removeValue(forKey: p.handle.lowercased()) }
        }
        if marks.count > 4000 { marks.removeFirst(marks.count - 4000); markSet = Set(marks) }
        let data = XData(people: people, interests: interests, marks: marks)
        if let d = try? JSONEncoder().encode(data) { try? d.write(to: url, options: .atomic) }
    }

    func clear() {
        people = [:]; interests = [:]; marks = []; markSet = []; lastPosts = []; focus = nil
        try? FileManager.default.removeItem(at: url)
    }

    var stats: String {
        let inter = people.values.reduce(0) { $0 + $1.interactions.count }
        let fol = people.values.filter { $0.following == true }.count
        return "记得 \(people.count) 个人 · 已关注 \(fol) · 互动 \(inter) 次"
            + (lastReadCount >= 0 ? " · 上次读到 \(lastReadCount) 条帖子" : "")
    }

    // MARK: page detection

    static let browsers: Set<String> = ScreenReader.chromiumBrowsers.union(
        ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
         "org.mozilla.nightly", "com.google.Chrome.dev", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
         "company.thebrowser.dia", "app.zen-browser.zen", "com.kagi.kagimacOS", "com.openai.atlas", "ai.perplexity.comet",
         "com.operasoftware.OperaGX", "org.torproject.torbrowser", "net.waterfox.waterfox", "com.duckduckgo.macos.browser"])

    private static func stripCount(_ t: String) -> String {
        var s = t.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("("), let r = s.firstIndex(of: ")") { s = String(s[s.index(after: r)...]).trimmingCharacters(in: .whitespaces) }
        return s
    }

    private static let titleXRe = try! NSRegularExpression(pattern: "/ (X|Twitter)(\\s*[-—–|].*)?$")

    /// Title check, tolerant of what browsers append ("- Google Chrome", "- Personal", "and 3 more pages").
    static func isXTitle(_ t: String?) -> Bool {
        guard let t = t else { return false }
        let s = stripCount(t)
        if s == "X" || s.hasPrefix("X - ") || s.hasPrefix("X — ") { return true }
        if s.contains(" on X: ") || s.contains(" on X：") || s.hasPrefix("X 上的") || s.contains("在 X 上") { return true }
        let ns = s as NSString
        return titleXRe.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func hostPath(_ url: String) -> (host: String, path: String) {
        var u = url.lowercased().trimmingCharacters(in: .whitespaces)
        if let r = u.range(of: "://") { u = String(u[r.upperBound...]) }
        let host = String(u.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        return (host, String(u.dropFirst(host.count)))
    }

    static func isXURL(_ url: String) -> Bool {
        let h = hostPath(url).host
        return ["x.com", "twitter.com", "mobile.x.com", "mobile.twitter.com", "www.x.com", "www.twitter.com", "pro.x.com"].contains(h)
    }

    static func isPrivateURL(_ url: String) -> Bool {
        guard isXURL(url) else { return false }
        let p = hostPath(url).path
        for pre in ["/messages", "/i/chat", "/i/grok", "/settings", "/notifications", "/i/verified", "/i/account_access"] where p.hasPrefix(pre) {
            return true
        }
        return false
    }

    /// DMs, chat, settings: never read.
    static func isPrivate(_ t: String) -> Bool {
        let s = stripCount(t)
        for p in ["Messages", "私信", "消息", "Chat", "聊天", "Direct", "Settings", "设置", "Grok", "Notifications", "通知"] where s.hasPrefix(p) {
            return true
        }
        return false
    }

    // MARK: is an X page in front? (with a reason, for 设置 → 感知与记忆 → 检查刷推)

    struct XPage { let app: NSRunningApplication; let title: String; let url: String; let web: AXUIElement? }

    /// Plain-words reason for the last check, shown in settings.
    private(set) var status = "还没检查过"
    private var probeKey = ""
    private var probeAt = Date.distantPast
    private var probe: (web: AXUIElement?, url: String) = (nil, "")

    func currentPage(forceProbe: Bool = false) -> XPage? {
        guard AXIsProcessTrusted() else {
            status = "❌ 没有「辅助功能」权限：系统设置 → 隐私与安全性 → 辅助功能 → 打开 OrdCat"
            return nil
        }
        guard let app = hub.lastExternalApp, !app.isTerminated else { status = "还没看到你打开别的应用"; return nil }
        let bid = app.bundleIdentifier ?? ""
        guard let win = hub.shareableWindow(), win.app.processIdentifier == app.processIdentifier else {
            status = "❌ 读不到「\(app.localizedName ?? bid)」的窗口"
            return nil
        }
        let titleHit = XCompanion.isXTitle(win.title)
        guard XCompanion.browsers.contains(bid) || titleHit else {
            status = "最近用的是「\(app.localizedName ?? bid)」，不是浏览器（\(bid)）"
            return nil
        }
        let key = "\(app.processIdentifier)|\(win.title)"
        if forceProbe || key != probeKey || Date().timeIntervalSince(probeAt) > 15 {
            probe = hub.reader.webPage(pid: app.processIdentifier)
            probeKey = key; probeAt = Date()
        }
        let urlHit = XCompanion.isXURL(probe.url)
        guard urlHit || titleHit else {
            let addr = probe.url.isEmpty ? "地址读不到" : "地址 \(XCompanion.hostPath(probe.url).host)"
            status = "浏览器里不是 X 页面（标题「\(win.title.prefix(36))」，\(addr)）"
            return nil
        }
        status = "✅ 认出 X 页面（靠\(urlHit ? "网址" : "标题")）\(probe.web == nil ? "，但没找到网页内容区" : "")"
        return XPage(app: app, title: win.title, url: probe.url, web: probe.web)
    }

    /// An X page you allowed the cat to read (mode on, not DMs/settings/notifications).
    func readablePage() -> XPage? {
        guard let pg = currentPage(), !XCompanion.isPrivate(pg.title), !XCompanion.isPrivateURL(pg.url) else { return nil }
        return Prefs.xMode && Billing.isUnlocked("x") ? pg : nil
    }

    /// Full check for the settings button: detect, read once, say what happened.
    func diagnose() -> String {
        var lines: [String] = []
        lines.append("版本：\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
        lines.append("「陪你刷推」开关：\(Prefs.xMode ? "已打开" : "没打开")")
        guard let pg = currentPage(forceProbe: true) else { lines.append(status); return lines.joined(separator: "\n") }
        lines.append(status)
        lines.append("浏览器：\(pg.app.localizedName ?? "")（\(pg.app.bundleIdentifier ?? "")）")
        lines.append("标题：\(pg.title.prefix(60))")
        if !pg.url.isEmpty { lines.append("网址：\(XCompanion.hostPath(pg.url).host)\(XCompanion.hostPath(pg.url).path.prefix(40))") }
        if XCompanion.isPrivate(pg.title) || XCompanion.isPrivateURL(pg.url) {
            lines.append("🔒 这是私信/设置/通知页，小猫不读")
            return lines.joined(separator: "\n")
        }
        let t0 = Date()
        let ax = hub.reader.readAX(pid: pg.app.processIdentifier, maxNodes: 6000, budget: 2.0, root: pg.web)
        let parsed = XCompanion.parse(ax.elements, title: pg.title)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let handles = ax.elements.filter { $0.text.hasPrefix("@") && $0.text.count <= 16 }.count
        lines.append("读到页面元素 \(ax.elements.count) 个（\(ms) 毫秒），其中 @账号 \(handles) 个，认出帖子 \(parsed.posts.count) 条")
        if let f = parsed.focus { lines.append("这页的主角：@\(f)") }
        if let p = parsed.posts.first { lines.append("第一条：@\(p.handle)「\(p.text.prefix(30))」") }
        lines.append("回复框：\(composerStatus)")
        lines.append("技能订阅：\(Billing.statusLine("x"))")
        if ax.elements.count < 20 {
            lines.append("⚠️ 页面内容几乎读不到：浏览器可能没开放网页的辅助功能信息")
        } else if parsed.posts.isEmpty {
            let sample = ax.elements.prefix(400).filter { $0.text.count <= 30 }.suffix(12).map { "\($0.role)「\($0.text)」" }
            lines.append("⚠️ 读到了内容但没认出帖子。样例：" + sample.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    private(set) var lastReadCount = -1
    /// Last thing the reply-box watcher saw (for 检查刷推).
    private(set) var composerStatus = "还没点过回复框"
    /// A single post page (x.com/<user>/status/<id>).
    var onStatusPage: Bool { probe.url.contains("/status/") || XCompanion.titleName(lastTitleText) != nil }
    private var lastTitleText = ""
    /// The post a status page is about (the first one at the top).
    var mainPost: XPost? { onStatusPage ? lastPosts.first : nil }
    /// Replies on a status page, and how many of them look like 水评 / spam.
    var replyStats: (total: Int, water: Int, spam: Int) {
        guard onStatusPage, lastPosts.count > 1 else { return (0, 0, 0) }
        var w = 0, sp = 0
        for p in lastPosts.dropFirst() {
            let c = XCompanion.classify(p, isReply: true, words: [], accounts: [])
            if c.spam != nil { sp += 1 } else if c.water { w += 1 }
        }
        return (lastPosts.count - 1, w, sp)
    }
    private var scanning = false
    private let axQueue = DispatchQueue(label: "app.ordcat.xscan", qos: .utility)

    private func tick() {
        guard let pg = currentPage() else {
            onX = false; focus = nil
            save()
            return
        }
        onX = true
        if XCompanion.isPrivate(pg.title) || XCompanion.isPrivateURL(pg.url) {
            status += "（私信/设置/通知页，不读）"
            focus = nil; lastPosts = []; return
        }
        guard Prefs.xMode && Billing.isUnlocked("x") else {
            status += Prefs.xMode ? "，但「陪你刷推」订阅已到期" : "，但「陪你刷推」还没打开"
            if !Prefs.xOffered { Prefs.xOffered = true; onFirstVisit?() }
            return
        }
        let key = pg.url.isEmpty ? pg.title : pg.url
        let changed = key != lastTitle
        checkComposer(pg)
        guard !scanning, changed || (Date().timeIntervalSince(lastScan) > 2.5 && hub.idleSeconds() < 30) else { return }
        lastTitle = key
        lastScan = Date()
        scanning = true
        // Reading a big X page can take a second: do it off the main thread so the cat never stutters.
        let pid = pg.app.processIdentifier, web = pg.web, title = pg.title, app = pg.app
        axQueue.async { [weak self] in
            guard let self = self else { return }
            let ax = self.hub.reader.readAX(pid: pid, maxNodes: 5000, budget: 1.5, root: web)
            DispatchQueue.main.async {
                self.scanning = false
                self.apply(ax.elements, app: app, title: title, newPage: changed)
            }
        }
    }

    /// Read the X page now (also used right before filtering replies or drafting).
    @discardableResult
    func scanNow() -> [XPost] {
        guard let pg = readablePage() else { return [] }
        lastScan = Date()
        let ax = hub.reader.readAX(pid: pg.app.processIdentifier, maxNodes: 5000, budget: 1.2, root: pg.web)
        apply(ax.elements, app: pg.app, title: pg.title, newPage: false)
        return lastPosts
    }

    private func apply(_ elements: [ScreenElement], app: NSRunningApplication, title: String, newPage: Bool) {
        lastTitleText = title
        let parsed = XCompanion.parse(elements, title: title)
        initialScanOfPage = newPage
        lastPosts = parsed.posts
        lastReadCount = parsed.posts.count
        defer {
            onRead?(parsed.posts.count)
            if newPage { onPageChanged?() }
            let alerts = findAlerts(parsed.posts, title: title)
            if !alerts.isEmpty { onAlerts?(alerts) }
        }
        let now = Date()
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: now)

        for p in parsed.posts {
            touch(p.handle, name: p.name, today: today, now: now)
            for m in p.marks {
                let key = "\(m)|\(p.handle.lowercased())|\(p.text.prefix(40))"
                guard !markSet.contains(key) else { continue }
                markSet.insert(key); marks.append(key)
                let snippet = String(p.text.prefix(160))
                people[p.handle.lowercased()]?.interactions.append(XInteraction(kind: m, date: now, snippet: snippet))
                if !initialScanOfPage { onInteraction?(p.handle, m) }
                if let n = people[p.handle.lowercased()]?.interactions.count, n > 40 {
                    people[p.handle.lowercased()]?.interactions.removeFirst(n - 40)
                }
                if !p.text.isEmpty {
                    for w in hub.memory.keywords(p.text) where w.count >= 2 && Int(w) == nil && !w.hasPrefix("http") {
                        interests[w, default: 0] += (m == "bookmark" ? 2 : 1)
                    }
                    if interests.count > 400 {
                        let keep = interests.sorted { $0.value > $1.value }.prefix(250)
                        interests = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
                    }
                }
                hub.memory.add(kind: "x", app: "X", bundle: app.bundleIdentifier ?? "",
                               title: "在 X 上\(XCompanion.verb(m)) @\(p.handle)", content: p.text)
                dirty = true
            }
        }
        for (h, f) in parsed.follow {
            if people[h.lowercased()] == nil { touch(h, name: "", today: today, now: now) }
            if people[h.lowercased()]?.following != f { people[h.lowercased()]?.following = f; dirty = true }
        }
        focus = parsed.focus
        if newPage, let f = parsed.focus, people[f.lowercased()] != nil {
            people[f.lowercased()]?.visits += 1
            dirty = true
            if let p = people[f.lowercased()], p.known, announcedTitle != title {
                announcedTitle = title
                onKnownPerson?(p)
            }
        }
        if dirty && Date().timeIntervalSince(lastSave) > 20 { lastSave = Date(); save() }
    }
    private var lastSave = Date.distantPast

    private func touch(_ handle: String, name: String, today: String, now: Date) {
        let k = handle.lowercased()
        if var p = people[k] {
            if !name.isEmpty && p.name != name { p.name = name }
            p.lastSeen = now
            if p.seenDays.last != today { p.seenDays.append(today); if p.seenDays.count > 60 { p.seenDays.removeFirst() } }
            people[k] = p
        } else {
            people[k] = XPerson(handle: handle, name: name, firstSeen: now, lastSeen: now, seenDays: [today],
                                following: nil, interactions: [], visits: 0)
        }
        dirty = true
    }

    static func verb(_ m: String) -> String {
        switch m { case "like": return "点赞了"; case "bookmark": return "收藏了"; case "repost": return "转帖了"; default: return "看了" }
    }

    // MARK: parsing the page

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let handleRe = re("^@([A-Za-z0-9_]{1,15})$")
    private static let followingRe = re("^(?:Following|正在关注|已关注|Unfollow|取消关注|正在跟隨|已跟隨|取消跟隨|跟隨中|正在追蹤|追蹤中|已追蹤|取消追蹤)\\s*@([A-Za-z0-9_]{1,15})$")
    private static let followRe = re("^(?:Follow back|Follow|回关|关注|跟隨|回跟|追蹤|回追蹤)\\s*@([A-Za-z0-9_]{1,15})$")
    private static let timeRe = re("^(?:\\d+\\s*(?:s|m|h|d|秒|分钟|分鐘|分|小时|小時|天|時間)|\\d{1,2}月\\d{1,2}日|\\d{4}年\\d{1,2}月\\d{1,2}日|[A-Z][a-z]{2} \\d{1,2}(?:, \\d{4})?|\\d{1,2} [A-Z][a-z]{2}(?: \\d{4})?)$")
    /// The reply button closes every post, in any language ("12576 則回覆。回覆", "Reply", "回复").
    private static func isReplyButton(_ t: String) -> Bool {
        for k in ["回覆", "回复", "Repl", "repl", "返信", "답글", "Respon", "Répond", "Antwort"] where t.contains(k) { return true }
        return false
    }
    private static let countRe = re("^[0-9.,]+\\s*(?:[KkMm万千亿])?$")
    private static let profileRe = re("\\(@([A-Za-z0-9_]{1,15})\\)")

    private static func match(_ r: NSRegularExpression, _ s: String) -> String? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : ns.substring(with: m.range)
    }

    private static func marks(of button: String) -> Set<String> {
        var out = Set<String>()
        let likeK = ["Liked", "Unlike", "已喜欢", "取消喜欢", "已喜歡", "取消喜歡", "已按讚", "收回讚"]
        let bmK = ["Bookmarked", "Remove Bookmark", "已加入书签", "已添加书签", "删除书签", "移除书签", "已加入書籤", "移除書籤", "刪除書籤", "已新增書籤"]
        let rpK = ["Reposted", "Undo repost", "已转帖", "已转推", "撤销转帖", "已轉發", "取消轉發", "撤銷轉發", "已轉推", "已轉貼"]
        if likeK.contains(where: { button.contains($0) }) { out.insert("like") }
        if bmK.contains(where: { button.contains($0) }) { out.insert("bookmark") }
        if rpK.contains(where: { button.contains($0) }) { out.insert("repost") }
        return out
    }

    /// The name a post page or profile page is about, from the window title.
    private static func titleName(_ title: String) -> String? {
        let t = stripCount(title)
        if let r = t.range(of: " on X:") { return String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        for sep in [" 在 X 上", "在 X 上", " 在 X：", " 在 X:"] {
            if let r = t.range(of: sep), r.lowerBound > t.startIndex { return String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        }
        if t.hasPrefix("X 上的"), let r = t.range(of: "：") ?? t.range(of: ":") {
            return String(t[t.index(t.startIndex, offsetBy: 4)..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func isAdLabel(_ t: String) -> Bool { ["Ad", "广告", "推广", "Promoted", "廣告", "推廣", "宣傳"].contains(t) }

    /// Main parser: every post on X ends with its action row (reply · repost · like · views · bookmark · share).
    /// So: cut the page at reply buttons; each piece's first standalone @handle is the author. Works in any UI language.
    static func parse(_ els: [ScreenElement], title: String) -> (posts: [XPost], follow: [String: Bool], focus: String?) {
        let byRows = parseByActionRows(els, title: title)
        if !byRows.posts.isEmpty { return byRows }
        let old = parseByHeader(els, title: title)
        return (old.posts, byRows.follow.merging(old.follow) { a, _ in a }, old.focus ?? byRows.focus)
    }

    static func parseByActionRows(_ all: [ScreenElement], title: String) -> (posts: [XPost], follow: [String: Bool], focus: String?) {
        // Keep only the main column (where the action rows are), so the sidebar ("相關人士", "你可能會喜歡")
        // and the left menu never mix into posts.
        let replies = all.filter { $0.role == "按钮" && isReplyButton($0.text) }
        var els = all
        if let minX = replies.map({ $0.rect.minX }).min() {
            var maxX = replies.map { $0.rect.maxX }.max() ?? minX
            for r in replies {
                for e in all where e.role == "按钮" && abs(e.rect.midY - r.rect.midY) < 16 && e.rect.minX >= r.rect.minX && e.rect.minX - r.rect.minX < 700 {
                    maxX = max(maxX, e.rect.maxX)
                }
            }
            let lo = minX - 90, hi = maxX + 40
            els = all.filter { $0.rect.midX >= lo && $0.rect.midX <= hi }
        }
        var follow: [String: Bool] = [:]
        for e in all where e.role == "按钮" {
            let t = e.text.trimmingCharacters(in: .whitespaces)
            if let h = match(followingRe, t) { follow[h] = true } else if let h = match(followRe, t), follow[h] == nil { follow[h] = false }
        }
        var posts: [XPost] = []
        let mainName = titleName(title)
        var focus: String? = match(profileRe, title)
        var segStart = 0
        var i = 0
        while i < els.count {
            let e = els[i]
            let t = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard e.role == "按钮", isReplyButton(t) else { i += 1; continue }
            // The action row: this button and the buttons/links right after it on the same line.
            var marks = Set<String>()
            var rowRect = e.rect
            var j = i
            while j < els.count, abs(els[j].rect.midY - e.rect.midY) < 16, els[j].role == "按钮" || els[j].role == "链接" {
                marks.formUnion(XCompanion.marks(of: els[j].text)); rowRect = rowRect.union(els[j].rect); j += 1
            }
            // The piece of page before it: author = first standalone @handle, then the body.
            var author: (h: String, name: String, idx: Int)?
            for k in segStart..<i {
                let tk = els[k].text.trimmingCharacters(in: .whitespaces)
                guard els[k].role != "按钮", let h = match(handleRe, tk) else { continue }
                var name = ""
                if k > segStart {
                    let p = els[k - 1].text.trimmingCharacters(in: .whitespaces)
                    if match(handleRe, p) == nil, p.count <= 50, els[k - 1].role == "文本" || els[k - 1].role == "链接",
                       match(timeRe, p) == nil, p != "·" { name = p }
                }
                author = (h, name, k); break
            }
            if let a = author {
                var text = ""
                var rect = els[a.idx].rect
                var isAd = false
                for k in (a.idx + 1)..<i {
                    let tk = els[k].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    rect = rect.union(els[k].rect)
                    if isAdLabel(tk) { isAd = true; continue }
                    guard els[k].role == "文本" || els[k].role == "链接" || els[k].role == "标题" else { continue }
                    if tk.count < 2 || tk == "·" || tk == a.name || match(timeRe, tk) != nil || match(countRe, tk) != nil { continue }
                    if text.count < 1200, !text.contains(tk) { text += (text.isEmpty ? "" : " ") + tk }
                }
                posts.append(XPost(handle: a.h, name: a.name, text: text, rect: rect.union(rowRect), marks: marks, isAd: isAd))
                if focus == nil, let mn = mainName, a.name == mn { focus = a.h }
            }
            segStart = j
            i = j
        }
        if focus == nil, mainName != nil, let first = posts.first { focus = first.handle }
        return (posts, follow, focus)
    }

    static func parseByHeader(_ els: [ScreenElement], title: String) -> (posts: [XPost], follow: [String: Bool], focus: String?) {
        var follow: [String: Bool] = [:]
        var posts: [XPost] = []
        var cur: XPost?
        let mainName = titleName(title)
        var focus: String? = match(profileRe, title)
        var mainFound = false

        func isPostStart(_ i: Int, handle: String) -> (Bool, String) {
            let e = els[i]
            var name = ""
            if i > 0 {
                let p = els[i - 1]
                let sameRow = abs(p.rect.midY - e.rect.midY) < 14 && p.rect.minX < e.rect.minX
                let stacked = e.rect.minY - p.rect.maxY > -2 && e.rect.minY - p.rect.maxY < 12 && abs(p.rect.minX - e.rect.minX) < 8
                if (sameRow || stacked) && match(handleRe, p.text) == nil && p.text.count <= 50 { name = p.text }
            }
            if !mainFound, let mn = mainName, !mn.isEmpty {
                for k in max(0, i - 3)..<i where els[k].text.trimmingCharacters(in: .whitespaces) == mn { return (true, mn) }
            }
            for j in (i + 1)..<min(els.count, i + 4) {
                let n = els[j]
                if abs(n.rect.midY - e.rect.midY) > 14 { break }
                let t = n.text.trimmingCharacters(in: .whitespaces)
                if t == "·" || match(timeRe, t) != nil { return (true, name) }
            }
            return (false, name)
        }

        for (i, e) in els.enumerated() {
            let t = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if e.role == "按钮" {
                if let h = match(followingRe, t) { follow[h] = true; continue }
                if let h = match(followRe, t) { if follow[h] == nil { follow[h] = false }; continue }
                if cur != nil { cur!.marks.formUnion(marks(of: t)); cur!.rect = cur!.rect.union(e.rect) }
                continue
            }
            if let h = match(handleRe, t) {
                let (start, name) = isPostStart(i, handle: h)
                if start {
                    if var c = cur {
                        if !name.isEmpty && c.text.hasSuffix(name) { c.text = String(c.text.dropLast(name.count)).trimmingCharacters(in: .whitespaces) }
                        posts.append(c)
                    }
                    if !mainFound && mainName != nil && name == mainName { mainFound = true; if focus == nil { focus = h } }
                    cur = XPost(handle: h, name: name, text: "", rect: e.rect, marks: [], isAd: false)
                    continue
                }
            }
            guard cur != nil else { continue }
            if t.count < 2 || t == "·" || match(timeRe, t) != nil || match(countRe, t) != nil || t == cur!.name { continue }
            if isAdLabel(t) { cur!.isAd = true; continue }
            if e.role == "文本" || e.role == "链接" || e.role == "标题" {
                if cur!.text.count < 1200 { cur!.text += (cur!.text.isEmpty ? "" : " ") + t }
                cur!.rect = cur!.rect.union(e.rect)
            }
        }
        if let c = cur { posts.append(c) }
        if focus == nil, mainName != nil, let first = posts.first { focus = first.handle }
        return (posts, follow, focus)
    }

    // MARK: live alerts

    private static let spamWords = ["私信我", "私我", "加V", "加v", "加微", "微信", "VX", "vx", "领取", "領取", "免费送", "免費送", "空投", "白名单", "白名單",
        "点击链接", "點擊連結", "主页链接", "主頁連結", "进群", "進群", "电报", "電報", "t.me/", "Telegram", "DM me", "dm me", "link in bio",
        "Link in bio", "giveaway", "Giveaway", "airdrop", "Airdrop", "返佣", "带单", "帶單", "稳赚", "穩賺", "日赚", "日賺", "月入", "躺赚", "躺賺",
        "保本", "翻倍", "100x", "1000x", "代币", "代幣", "presale", "Presale", "whitelist", "OnlyFans", "onlyfans", "约炮", "約炮", "裸聊"]
    private static let waterPhrases: Set<String> = ["太棒了", "支持", "666", "6666", "+1", "哈哈", "哈哈哈", "哈哈哈哈", "顶", "頂", "沙发", "沙發", "前排",
        "牛", "牛逼", "厉害", "厲害", "同意", "说得好", "說得好", "好", "赞", "讚", "great", "nice", "amazing", "wow", "true", "this", "so true",
        "exactly", "facts", "based", "lol", "lmao", "yes", "agreed", "awesome", "cool", "fire", "love it", "gm", "gn", "wagmi", "lfg"]

    private static func meaningful(_ t: String) -> String {
        String(t.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "+" }.map(Character.init))
    }

    /// Local, instant: no model call while scrolling.
    static func classify(_ p: XPost, isReply: Bool, words: [String], accounts: Set<String>) -> (spam: String?, water: Bool, signal: String?) {
        let t = p.text
        var spam: String? = nil
        if p.isAd { spam = "广告" }
        else if let w = spamWords.first(where: { t.contains($0) }) { spam = "引流词「\(w)」" }
        else {
            let emoji = t.unicodeScalars.filter { $0.properties.isEmojiPresentation }.count
            if emoji >= 8 && (t.contains("http") || t.contains(".com") || t.contains("👇")) { spam = "满屏表情+链接" }
        }
        var signal: String? = nil
        if accounts.contains(p.handle.lowercased()) { signal = "特别关注 @\(p.handle)" }
        else if let w = words.first(where: { t.range(of: $0, options: .caseInsensitive) != nil }) { signal = "关键词「\(w)」" }
        var water = false
        if isReply && spam == nil {
            let m = meaningful(t).lowercased()
            let plain = t.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
            water = m.count <= 3 || waterPhrases.contains(plain) || waterPhrases.contains(m)
        }
        return (spam, water, signal)
    }

    private func findAlerts(_ posts: [XPost], title: String) -> [XAlert] {
        guard Prefs.xMode else { return [] }
        let isStatus = probe.url.contains("/status/") || XCompanion.titleName(title) != nil
        let words = Prefs.list(Prefs.xSignalWords)
        let accounts = Set(Prefs.list(Prefs.xSignalAccounts).map { $0.replacingOccurrences(of: "@", with: "").lowercased() })
        var out: [XAlert] = []
        for (i, p) in posts.enumerated() {
            let key = "\(p.handle.lowercased())|\(p.text.prefix(60))"
            guard !seenKeys.contains(key) else { continue }
            seenKeys.insert(key); seenOrder.append(key)
            if seenOrder.count > 3000 { seenKeys.remove(seenOrder.removeFirst()) }
            let c = XCompanion.classify(p, isReply: isStatus && i > 0, words: words, accounts: accounts)
            if let sg = c.signal, Prefs.xAlert("signal") { out.append(XAlert(kind: .signal, post: p, reason: sg)); continue }
            if let sp = c.spam, Prefs.xAlert("spam") { out.append(XAlert(kind: .spam, post: p, reason: sp)); continue }
            if c.water, Prefs.xAlert("water") { out.append(XAlert(kind: .water, post: p, reason: "水评")); continue }
            if let who = person(p.handle) {
                let n = who.interactions.count
                if n >= 2, Prefs.xAlert("known") {
                    out.append(XAlert(kind: .known, post: p, reason: "你和 TA 互动过 \(n) 次")); continue
                }
                if who.following == true, Prefs.xAlert("follow") {
                    out.append(XAlert(kind: .follow, post: p, reason: "你关注的人")); continue
                }
            }
        }
        return out
    }

    // MARK: reply box → reply ideas

    private static let replyingRe = re("^(?:Replying to|回覆給|回复给|回复|回覆|正在回复|返信先)\\s*@?([A-Za-z0-9_]{1,15})?")

    private func checkComposer(_ pg: XPage) {
        guard Prefs.xAlert("reply") else { return }
        guard let f = hub.reader.focusedField(pid: pg.app.processIdentifier) else { lastFocusKey = ""; return }
        guard f.role == "AXTextArea" || (f.role == "AXTextField" && f.hint.contains("回")) else { lastFocusKey = ""; return }
        composerStatus = "点到了输入框（\(f.role)\(f.hint.isEmpty ? "" : "：" + f.hint)）"
        let fk = "\(pg.url)|\(Int(f.rect.minY / 40))"
        guard fk != lastFocusKey else { return }
        lastFocusKey = fk
        let path = XCompanion.hostPath(pg.url).path
        let pid = pg.app.processIdentifier, web = pg.web, title = pg.title, url = pg.url
        axQueue.async { [weak self] in
            guard let self = self else { return }
            let ax = self.hub.reader.readAX(pid: pid, maxNodes: 5000, budget: 1.2, root: web)
            DispatchQueue.main.async {
                let els = ax.elements
                var target: String? = nil
                var isReply = path.contains("/status/")
                for (i, e) in els.enumerated() where e.rect.maxY <= f.rect.maxY + 4 {
                    let t = e.text.trimmingCharacters(in: .whitespaces)
                    guard let m = XCompanion.replyingRe.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) else { continue }
                    isReply = true
                    if m.range(at: 1).location != NSNotFound { target = (t as NSString).substring(with: m.range(at: 1)) }
                    else if i + 1 < els.count, let h = XCompanion.match(XCompanion.handleRe, els[i + 1].text) { target = h }
                }
                guard isReply else { self.composerStatus += "，但这是发新帖，不是回复"; return }   // a new post, not a reply
                let posts = XCompanion.parse(els, title: title).posts
                // The post you reply to sits above the box: the named one, else the nearest above, else the main post.
                let above = posts.filter { $0.rect.minY < f.rect.minY }
                let post = above.last(where: { target != nil && $0.handle.lowercased() == target!.lowercased() })
                    ?? (path.contains("/status/") ? posts.first : above.last) ?? posts.first
                let key = "\(url)|\(post?.handle ?? "")|\(post?.text.prefix(30) ?? "")"
                guard key != self.replyKey || Date().timeIntervalSince(self.replyAt) > 600 else { return }
                self.replyKey = key; self.replyAt = Date()
                self.composerStatus = "回复框 → 给 @\(post?.handle ?? "?") 想回复建议"
                self.onReplyComposer?(post)
            }
        }
    }

    // MARK: what the cat says

    func person(_ handle: String?) -> XPerson? {
        guard let h = handle else { return nil }
        return people[h.lowercased()]
    }

    func card(_ p: XPerson) -> String {
        let df = DateFormatter(); df.dateFormat = "M月d日"
        var lines: [String] = []
        lines.append("**\(p.name.isEmpty ? "@" + p.handle : p.name)**  @\(p.handle)")
        switch p.following {
        case .some(true): lines.append("• ✅ 你已经关注 TA 了")
        case .some(false): lines.append("• 你还没关注 TA")
        case .none: lines.append("• 还不确定你关注没（打开 TA 的主页我就知道了）")
        }
        lines.append("• 👀 第一次刷到：\(df.string(from: p.firstSeen))，一共在 \(p.seenDays.count) 天里见过")
        let l = p.count("like"), b = p.count("bookmark"), r = p.count("repost")
        if l + b + r == 0 {
            lines.append("• 你们还没有互动过")
        } else {
            var parts: [String] = []
            if l > 0 { parts.append("点赞 \(l) 次") }
            if b > 0 { parts.append("收藏 \(b) 条") }
            if r > 0 { parts.append("转帖 \(r) 次") }
            lines.append("• ❤️ 你" + parts.joined(separator: "、"))
            for it in p.interactions.suffix(2).reversed() {
                let s = it.snippet.count > 46 ? String(it.snippet.prefix(46)) + "…" : it.snippet
                if !s.isEmpty { lines.append("• \(df.string(from: it.date)) \(XCompanion.verb(it.kind))「\(s)」") }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The user's interests, learned from what they liked and bookmarked on X.
    func interestLine(_ n: Int = 10) -> String {
        let top = interests.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.prefix(n).map { $0.key }
        return top.isEmpty ? "" : "我平时关注的领域（从我在 X 上的点赞和收藏学来的）：" + top.joined(separator: "、")
    }

    /// Context for the model: who the main person is to me.
    func personContext() -> String? {
        guard let p = person(focus) else { return nil }
        let l = p.count("like"), b = p.count("bookmark")
        var s = "[关于这页的作者 @\(p.handle)：\(p.following == true ? "我已关注" : "我没关注")"
        if l + b > 0 { s += "，我点赞过 \(l) 次、收藏过 \(b) 条" }
        return s + "]"
    }

    /// Numbered replies for the filter prompt (the first post on a post page is the post itself).
    func repliesForFilter(limit: Int = 25) -> (text: String, posts: [XPost])? {
        let posts = scanNow()
        guard posts.count >= 2 else { return nil }
        let replies = Array(posts.dropFirst().prefix(limit))
        var s = "## 帖子\n@\(posts[0].handle)：\(posts[0].text.prefix(600))\n\n## 屏幕上能看到的评论\n"
        for (i, p) in replies.enumerated() {
            var line = "#\(i + 1) @\(p.handle)"
            if !p.name.isEmpty { line += "（\(p.name)）" }
            if p.isAd { line += "【广告】" }
            if let who = person(p.handle), who.following == true { line += "【我关注的人】" }
            line += "：" + (p.text.isEmpty ? "（只有图片或表情）" : String(p.text.prefix(220)))
            s += line.replacingOccurrences(of: "\n", with: " ") + "\n"
        }
        return (s, replies)
    }

    static func numbers(after label: String, in text: String) -> [Int] {
        guard let line = text.components(separatedBy: "\n").first(where: { $0.contains(label) }) else { return [] }
        let nums = line.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
        return nums
    }
}
