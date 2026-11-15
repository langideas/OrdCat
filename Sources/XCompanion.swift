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

    init(dir: URL, hub: ContextHub) {
        url = dir.appendingPathComponent("x_people.json")
        self.hub = hub
        if let d = try? Data(contentsOf: url), let x = try? JSONDecoder().decode(XData.self, from: d) {
            people = x.people; interests = x.interests; marks = x.marks; markSet = Set(x.marks)
        }
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 1.5
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
    }

    // MARK: page detection

    static let browsers: Set<String> = ScreenReader.chromiumBrowsers.union(
        ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox"])

    private static func stripCount(_ t: String) -> String {
        var s = t.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("("), let r = s.firstIndex(of: ")") { s = String(s[s.index(after: r)...]).trimmingCharacters(in: .whitespaces) }
        return s
    }

    static func isXTitle(_ t: String?) -> Bool {
        guard let t = t else { return false }
        let s = stripCount(t)
        return s.hasSuffix("/ X") || s.hasSuffix("/ Twitter") || s.hasSuffix("on X") || s == "X"
    }

    /// DMs, chat, settings: never read.
    static func isPrivate(_ t: String) -> Bool {
        let s = stripCount(t)
        for p in ["Messages", "私信", "消息", "Chat", "聊天", "Direct", "Settings", "设置", "Grok", "Notifications", "通知"] where s.hasPrefix(p) {
            return true
        }
        return false
    }

    private func tick() {
        guard AXIsProcessTrusted(), let app = hub.lastExternalApp, !app.isTerminated,
              XCompanion.browsers.contains(app.bundleIdentifier ?? ""),
              let win = hub.shareableWindow(), XCompanion.isXTitle(win.title) else {
            onX = false; focus = nil
            save()
            return
        }
        onX = true
        if XCompanion.isPrivate(win.title) { focus = nil; lastPosts = []; return }
        guard Prefs.xMode else {
            if !Prefs.xOffered { Prefs.xOffered = true; onFirstVisit?() }
            return
        }
        let changed = win.title != lastTitle
        guard changed || (Date().timeIntervalSince(lastScan) > 12 && hub.idleSeconds() < 60) else { return }
        lastTitle = win.title
        scan(app: app, title: win.title, newPage: changed)
    }

    /// Read the X page now (also used right before filtering replies or drafting).
    @discardableResult
    func scanNow() -> [XPost] {
        guard Prefs.xMode, let app = hub.lastExternalApp, !app.isTerminated,
              let win = hub.shareableWindow(), XCompanion.isXTitle(win.title), !XCompanion.isPrivate(win.title) else { return [] }
        scan(app: app, title: win.title, newPage: false)
        return lastPosts
    }

    private func scan(app: NSRunningApplication, title: String, newPage: Bool) {
        lastScan = Date()
        let ax = hub.reader.readAX(pid: app.processIdentifier, maxNodes: 3200, budget: 0.35)
        let parsed = XCompanion.parse(ax.elements, title: title)
        lastPosts = parsed.posts
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
    private static let followingRe = re("^(?:Following|正在关注|已关注|Unfollow|取消关注)\\s*@([A-Za-z0-9_]{1,15})$")
    private static let followRe = re("^(?:Follow back|Follow|回关|关注)\\s*@([A-Za-z0-9_]{1,15})$")
    private static let timeRe = re("^(?:\\d+\\s*(?:s|m|h|d|秒|分钟|小时|天)|\\d{1,2}月\\d{1,2}日|\\d{4}年\\d{1,2}月\\d{1,2}日|[A-Z][a-z]{2} \\d{1,2}(?:, \\d{4})?)$")
    private static let countRe = re("^[0-9.,]+\\s*(?:[KkMm万千亿])?$")
    private static let profileRe = re("\\(@([A-Za-z0-9_]{1,15})\\)")

    private static func match(_ r: NSRegularExpression, _ s: String) -> String? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : ns.substring(with: m.range)
    }

    private static func marks(of button: String) -> Set<String> {
        var out = Set<String>()
        if button.contains("Liked") || button.contains("已喜欢") || button.contains("取消喜欢") || button.contains("Unlike") { out.insert("like") }
        if button.contains("Bookmarked") || button.contains("已加入书签") || button.contains("已添加书签") || button.contains("删除书签") || button.contains("Remove Bookmark") { out.insert("bookmark") }
        if button.contains("Reposted") || button.contains("已转帖") || button.contains("已转推") || button.contains("Undo repost") || button.contains("撤销转帖") { out.insert("repost") }
        return out
    }

    /// The name a post page or profile page is about, from the window title.
    private static func titleName(_ title: String) -> String? {
        let t = stripCount(title)
        if let r = t.range(of: " on X:") { return String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        if t.hasPrefix("X 上的"), let r = t.range(of: "：") ?? t.range(of: ":") {
            return String(t[t.index(t.startIndex, offsetBy: 4)..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func parse(_ els: [ScreenElement], title: String) -> (posts: [XPost], follow: [String: Bool], focus: String?) {
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
            if t == "Ad" || t == "广告" || t == "推广" || t == "Promoted" { cur!.isAd = true; continue }
            if e.role == "文本" || e.role == "链接" || e.role == "标题" {
                if cur!.text.count < 1200 { cur!.text += (cur!.text.isEmpty ? "" : " ") + t }
                cur!.rect = cur!.rect.union(e.rect)
            }
        }
        if let c = cur { posts.append(c) }
        if focus == nil, mainName != nil, let first = posts.first { focus = first.handle }
        return (posts, follow, focus)
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
