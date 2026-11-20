// OrdCat — 功能「信号站📶」（设置 → 信号站；登录就能用）
//
// 用户把小猫从桌面看到的有价值信息分享到信号站。每次都先打开「发信号」窗口给主人审、改，
// 主人点「发出信号」才会发 —— 桌面内容绝不自动分享。
// 发的人选「情报等级」并设查看条件：最低小猫等级、最少喵友数、仅订阅会员、需要拥有的技能。
// 条件由服务器判断（supabase/signal.sql → signal_feed），不满足的人只拿到标题和缺少的条件，拿不到正文。
// 有自己能看的新信号时，小猫弹出提醒；点开显示完整信号。可以在作者那一行「加喵友」（单向关注）。

import Cocoa

extension Prefs {
    /// The cat pops up when a new signal I can read arrives (on by default).
    static var signalNotify: Bool { get { d.object(forKey: "signalNotify") as? Bool ?? true } set { d.set(newValue, forKey: "signalNotify") } }
    static var signalSeen: [String] { get { d.stringArray(forKey: "signalSeen") ?? [] } set { d.set(Array(newValue.suffix(400)), forKey: "signalSeen") } }
    /// First feed load marks what is already there as seen (no popup flood on first launch).
    static var signalPrimed: Bool { get { d.bool(forKey: "signalPrimed") } set { d.set(newValue, forKey: "signalPrimed") } }
}

struct Signal {
    let id: String
    let authorID: String
    let authorName: String
    let authorAvatar: String?
    let authorLevel: Int
    var authorFollowers: Int
    let authorMember: Bool
    let title: String
    let grade: Int
    let minLevel: Int
    let minFollowers: Int
    let memberOnly: Bool
    let needSkills: [String]
    let sourceApp: String
    let created: Date?
    let lacks: [String]
    let unlocked: Bool
    let body: String?
    var iFollow: Bool

    init?(_ r: [String: Any]) {
        guard let id = r["id"] as? String, let title = r["title"] as? String else { return nil }
        self.id = id
        authorID = r["author_id"] as? String ?? ""
        authorName = r["author_name"] as? String ?? ""
        authorAvatar = (r["author_avatar"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        authorLevel = CatStats.int(r["author_level"])
        authorFollowers = CatStats.int(r["author_followers"])
        authorMember = r["author_member"] as? Bool ?? false
        self.title = title
        grade = max(1, min(4, CatStats.int(r["grade"])))
        minLevel = CatStats.int(r["min_level"])
        minFollowers = CatStats.int(r["min_followers"])
        memberOnly = r["member_only"] as? Bool ?? false
        needSkills = r["need_skills"] as? [String] ?? []
        sourceApp = r["source_app"] as? String ?? ""
        lacks = r["lacks"] as? [String] ?? []
        unlocked = r["unlocked"] as? Bool ?? false
        body = r["body"] as? String
        iFollow = r["i_follow"] as? Bool ?? false
        let s = r["created_at"] as? String ?? ""
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        created = f1.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    var who: String { authorName.isEmpty ? L10n.t("一只小猫") : authorName }
    var gradeText: String { SignalStation.gradeText(grade) }
    /// "需要：小猫等级 Lv5、喵友 ≥ 10" — what I'm missing to read it.
    var lacksText: String { lacks.map(SignalStation.condText).joined(separator: L10n.english ? ", " : "、") }
    /// Every view condition the sharer set, for the detail view.
    var condsText: String {
        var c: [String] = []
        if minLevel > 0 { c.append("level:\(minLevel)") }
        if minFollowers > 0 { c.append("followers:\(minFollowers)") }
        if memberOnly { c.append("member") }
        c += needSkills.map { "skill:" + $0 }
        return c.isEmpty ? L10n.t("所有人可看") : c.map(SignalStation.condText).joined(separator: L10n.english ? ", " : "、")
    }
    var timeText: String {
        guard let d = created else { return "" }
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}

final class SignalStation: NSObject {
    static let shared = SignalStation()
    static let grades = ["普通", "优质", "稀有", "绝密"]
    /// Skills a sharer can require (ids from Skills.swift). "Owned" = a valid subscription to it on the account.
    static let skills: [(String, String)] = [("x", "陪你刷推"), ("agent", "帮我操作电脑")]

    /// Shows a message next to the cat (set by the app delegate).
    var present: ((String, [(String, () -> Void)], Double) -> Void)?
    var openAccount: (() -> Void)?
    /// Reads the window the user is looking at, once, when they ask (set by the app delegate). Text is already redacted.
    var captureDesktop: (() async -> (app: String, title: String, text: String)?)?

    private var timer: Timer?
    private var lastNotify = Date.distantPast
    private var window: SignalWindow?
    private var composer: SignalComposeWindow?
    private var details: [SignalDetailWindow] = []
    private var observers: [() -> Void] = []

    private var acct: Account { Account.shared }
    var ready: Bool { acct.configured && acct.signedIn }
    var myID: String { acct.profile.userID ?? "" }
    var myName: String {
        let p = acct.profile
        return p.displayName.isEmpty ? (p.username.isEmpty ? "一只小猫" : p.username) : p.displayName
    }

    func observe(_ f: @escaping () -> Void) { observers.append(f) }
    func changed() { DispatchQueue.main.async { self.observers.forEach { $0() } } }

    static func gradeText(_ g: Int) -> String {
        let i = max(1, min(4, g)) - 1
        return String(repeating: "📶", count: 1) + " " + L10n.t(grades[i] + "情报")
    }
    static func skillName(_ id: String) -> String { skills.first { $0.0 == id }?.1 ?? id }
    /// "level:5" → "小猫等级 Lv5", "followers:10" → "喵友 ≥ 10", "member" → "订阅会员", "skill:x" → "技能「陪你刷推」".
    static func condText(_ c: String) -> String {
        if c.hasPrefix("level:") { return "\(L10n.t("小猫等级")) Lv\(c.dropFirst(6))" }
        if c.hasPrefix("followers:") { return "\(L10n.t("喵友")) ≥ \(c.dropFirst(10))" }
        if c == "member" { return L10n.t("订阅会员") }
        if c.hasPrefix("skill:") {
            let n = L10n.t(skillName(String(c.dropFirst(6))))
            return L10n.english ? "Skill “\(n)”" : "技能「\(n)」"
        }
        return c
    }

    // MARK: lifecycle

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard ready, Prefs.signalNotify, Date().timeIntervalSince(lastNotify) > 10 * 60 else { return }
        notifyNew()
    }

    /// New signals I can read → one popup; each signal is announced once.
    private func notifyNew() {
        lastNotify = Date()
        feed(mine: false) { [weak self] ss, err in
            guard let self = self, err == nil else { return }
            var seen = Prefs.signalSeen
            if !Prefs.signalPrimed {
                Prefs.signalPrimed = true
                Prefs.signalSeen = seen + ss.map(\.id)
                return
            }
            let fresh = ss.filter { $0.unlocked && $0.authorID != self.myID && !seen.contains($0.id) }
            seen.append(contentsOf: ss.map(\.id).filter { !seen.contains($0) })
            Prefs.signalSeen = seen
            guard let first = fresh.first else { return }
            let more = fresh.count > 1 ? (L10n.english ? " (+\(fresh.count - 1) more)" : "（还有 \(fresh.count - 1) 条）") : ""
            let text = L10n.english
                ? "📶 New signal from \(first.who): “\(first.title)”\(more)"
                : "📶 信号站有新信号：\(first.who) 发来「\(first.title)」\(more)"
            self.present?(text, [(L10n.t("查看信号"), { [weak self] in self?.showDetail(first) }),
                                 (L10n.t("打开信号站"), { [weak self] in self?.showWindow() }),
                                 (L10n.t("不再提醒"), { Prefs.signalNotify = false; SignalStation.shared.changed() })], 25)
        }
    }

    // MARK: server

    private func rpc(_ fn: String, _ args: [String: Any], done: @escaping (Any?, String?) -> Void) {
        acct.request("POST", "/rest/v1/rpc/\(fn)", json: args) { obj, err in done(obj, err.map(SignalStation.friendly)) }
    }

    /// Server errors in plain words. Missing functions / tables = signal.sql hasn't been run on the server yet.
    static func friendly(_ e: String) -> String {
        let l = e.lowercased()
        if l.contains("schema cache") || l.contains("could not find the function")
            || (l.contains("does not exist") && (l.contains("signal") || l.contains("cat_") || l.contains("follow"))) {
            return L10n.t("信号站服务器还没开通好（管理员需要在 Supabase 运行 supabase/signal.sql）")
        }
        return e
    }

    func feed(mine: Bool, done: @escaping ([Signal], String?) -> Void) {
        guard ready else { done([], L10n.t("还没登录")); return }
        rpc("signal_feed", ["p_mine": mine, "p_limit": 60]) { obj, err in
            done(((obj as? [[String: Any]]) ?? []).compactMap(Signal.init), err)
        }
    }

    func fetch(_ id: String, done: @escaping (Signal?, String?) -> Void) {
        rpc("signal_feed", ["p_mine": false, "p_limit": 1, "p_id": id]) { obj, err in
            done(((obj as? [[String: Any]]) ?? []).compactMap(Signal.init).first, err)
        }
    }

    /// 加喵友 / 取消喵友. Calls back with the author's new 喵友 count and whether I follow them now.
    func follow(_ user: String, on: Bool, done: @escaping (Int?, Bool, String?) -> Void) {
        guard ready else { needLogin(); done(nil, !on, nil); return }
        rpc("follow_set", ["p_user": user, "p_on": on]) { obj, err in
            let o = obj as? [String: Any]
            done(o.map { CatStats.int($0["followers"]) }, (o?["i_follow"] as? Bool) ?? !on, err)
            if err == nil { CatLevel.shared.refresh() }
        }
    }

    func delete(_ s: Signal, done: @escaping () -> Void) {
        rpc("signal_delete", ["p_id": s.id]) { [weak self] _, err in
            if let e = err { self?.present?(e, [], 6) }
            done()
        }
    }

    // MARK: sharing (always through the review window)

    /// "发信号：…" / "/信号 …" in chat → the text to prefill (may be empty), or nil.
    static func postIntent(_ text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["/信号", "发信号"] where s.hasPrefix(p) {
            var rest = String(s.dropFirst(p.count))
            while let c = rest.first, " ：:，,".contains(c) { rest.removeFirst() }
            return rest
        }
        return nil
    }

    /// Opens the review window. With no text, the cat reads the desktop window you're looking at to fill it in.
    func compose(prefill: String = "") {
        guard ready else { needLogin(); return }
        let w = SignalComposeWindow(station: self)
        composer = w
        w.show()
        if prefill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { w.readDesktop() }
        else { w.fill(app: "", title: "", text: Redactor.clean(prefill)) }
    }

    func post(title: String, body: String, grade: Int, minLevel: Int, minFollowers: Int, memberOnly: Bool,
              skills: [String], sourceApp: String, done: @escaping (String?) -> Void) {
        var args: [String: Any] = [
            "p_title": String(Redactor.clean(title).prefix(80)), "p_body": String(Redactor.clean(body).prefix(8000)),
            "p_grade": grade, "p_min_level": minLevel, "p_min_followers": minFollowers, "p_member_only": memberOnly,
            "p_need_skills": skills, "p_name": myName, "p_source_app": String(sourceApp.prefix(80))]
        args["p_avatar"] = acct.profile.avatarURL ?? NSNull()
        rpc("signal_post", args) { [weak self] _, err in
            guard let self = self else { return }
            if let e = err { done(e); return }
            done(nil)
            self.window?.reload()
            self.present?(L10n.t("信号发出去啦 📶 满足条件的小猫会收到提醒。"), [], 6)
        }
    }

    // MARK: windows

    func showWindow(tab: Int = 0) {
        guard ready else { needLogin(); return }
        if window == nil { window = SignalWindow(station: self) }
        window?.show(tab: tab)
    }

    func showDetail(_ s: Signal) {
        let w = SignalDetailWindow(signal: s, station: self)
        w.onClose = { [weak self, weak w] in self?.details.removeAll { $0 === w } }
        details.append(w)
        w.show()
        // Get the latest (full body, 喵友 count) from the server.
        fetch(s.id) { fresh, _ in if let f = fresh { w.update(f) } }
    }

    func needLogin() {
        let msg = acct.configured ? L10n.t("信号站要先登录账号。") : L10n.t("账号服务还在开通中，暂时用不了信号站。")
        present?(msg, acct.configured ? [(L10n.t("去登录"), { [weak self] in self?.openAccount?() })] : [], 8)
    }
}

// MARK: - helpers

private func sigLabel(_ s: String, size: CGFloat = 12, bold: Bool = false, gray: Bool = false) -> NSTextField {
    let l = SK.WrapLabel(s, size: size, secondary: gray, weight: bold ? .semibold : .regular)
    return l
}

/// A round avatar view with the member badge, filled in when the picture arrives.
private func avatarView(_ url: String?, member: Bool, size: CGFloat) -> NSImageView {
    let v = NSImageView()
    v.translatesAutoresizingMaskIntoConstraints = false
    v.imageScaling = .scaleProportionallyUpOrDown
    v.widthAnchor.constraint(equalToConstant: size).isActive = true
    v.heightAnchor.constraint(equalToConstant: size).isActive = true
    v.image = memberAvatar(AvatarCache.placeholder(size * 2), member: member, size: size)
    AvatarCache.shared.load(url) { [weak v] img in
        if let i = img { v?.image = memberAvatar(i, member: member, size: size) }
    }
    return v
}

/// "Lv N" + tier icons, for author rows.
private func levelView(_ level: Int, height: CGFloat = 13) -> NSView {
    let iv = NSImageView(image: RankIcon.strip(level: level, height: height))
    iv.translatesAutoresizingMaskIntoConstraints = false
    let l = NSTextField(labelWithString: "Lv\(level)")
    l.font = .systemFont(ofSize: 11, weight: .semibold)
    l.textColor = .secondaryLabelColor
    let s = NSStackView(views: [l, iv])
    s.spacing = 3
    s.alignment = .centerY
    s.toolTip = "Lv\(level) · " + CatLevel.partsText(level: level)
    return s
}

// MARK: - 信号站 window: 信号流 / 我发出的

final class SignalWindow: NSObject, NSWindowDelegate {
    private unowned let station: SignalStation
    private var win: NSWindow!
    private let tabs = NSSegmentedControl(labels: ["信号流", "我发出的"], trackingMode: .selectOne, target: nil, action: nil)
    private let list = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private var items: [Signal] = []
    private var gen = 0

    init(station: SignalStation) {
        self.station = station
        super.init()
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
                       styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        win.title = "📶 信号站"
        win.minSize = NSSize(width: 520, height: 380)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.setFrameAutosaveName("OrdCatSignals")
        let root = NSView()
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        let share = NSButton(title: "分享当前桌面", target: self, action: #selector(share))
        share.bezelStyle = .rounded
        share.toolTip = "小猫读一下你正在看的窗口，先给你审、改，你点「发出信号」才会发"
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshNow))
        refresh.bezelStyle = .rounded
        let hint = SK.WrapLabel("满足条件的信号能看全文；不满足的只显示标题和还差什么。", size: 11.5)
        let top = NSStackView(views: [tabs, NSView(), refresh, share])
        top.spacing = 8
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        let doc = FlipView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        for v in [top, hint, scroll, status] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 12),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -12),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -8)])
        win.contentView = root
    }

    func show(tab: Int) {
        tabs.selectedSegment = max(0, min(1, tab))
        if !win.isVisible { win.center() }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        reload()
    }

    @objc private func tabChanged() { reload() }
    @objc private func share() { station.compose() }
    @objc private func refreshNow() { reload() }

    func reload() {
        guard win.isVisible else { return }
        gen += 1
        let g = gen
        status.stringValue = L10n.t("正在加载…")
        station.feed(mine: tabs.selectedSegment == 1) { [weak self] ss, err in
            guard let self = self, g == self.gen else { return }
            self.items = ss
            self.status.stringValue = err.map { L10n.t("没连上：") + $0 } ?? (L10n.english ? "\(ss.count) signals" : "共 \(ss.count) 条")
            self.render()
        }
    }

    private func render() {
        for v in list.arrangedSubviews { list.removeArrangedSubview(v); v.removeFromSuperview() }
        if items.isEmpty {
            let l = SK.WrapLabel(tabs.selectedSegment == 0 ? "信号站还没有信号，分享一条试试？" : "你还没发过信号。", size: 13)
            list.addArrangedSubview(l)
            l.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            return
        }
        let me = station.myID
        for (i, s) in items.enumerated() {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let av = avatarView(s.authorAvatar, member: s.authorMember, size: 34)
            let name = NSTextField(labelWithString: s.who)
            name.font = .systemFont(ofSize: 12.5, weight: .semibold)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let fans = NSTextField(labelWithString: "\(L10n.t("喵友")) \(s.authorFollowers)")
            fans.font = .systemFont(ofSize: 11)
            fans.textColor = .secondaryLabelColor
            let authorLine = NSStackView(views: [name, levelView(s.authorLevel), fans])
            authorLine.spacing = 8
            authorLine.alignment = .centerY
            let lock = s.unlocked ? "" : "🔒 "
            let title = sigLabel(lock + s.title, size: 13.5, bold: true)
            var metaText = s.gradeText
            if !s.timeText.isEmpty { metaText += " · " + s.timeText }
            if !s.sourceApp.isEmpty { metaText += " · " + L10n.t("来自") + " " + s.sourceApp }
            if tabs.selectedSegment == 1 { metaText += " · " + L10n.t("谁能看：") + s.condsText }
            let meta = sigLabel(metaText, size: 11.5, gray: true)
            let teaser: NSTextField
            if s.unlocked {
                teaser = sigLabel(String((s.body ?? "").prefix(200)), size: 12, gray: true)
            } else {
                teaser = sigLabel(L10n.t("还差：") + s.lacksText, size: 12, gray: true)
                teaser.textColor = .systemOrange
            }
            let col = NSStackView(views: [authorLine, title, meta, teaser])
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 3
            col.translatesAutoresizingMaskIntoConstraints = false
            for l in [title, meta, teaser] { l.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
            authorLine.widthAnchor.constraint(lessThanOrEqualTo: col.widthAnchor).isActive = true
            if s.unlocked && (s.body ?? "").isEmpty { teaser.isHidden = true }
            let acts = NSStackView()
            acts.orientation = .vertical
            acts.alignment = .trailing
            acts.spacing = 6
            acts.translatesAutoresizingMaskIntoConstraints = false
            acts.setContentHuggingPriority(.required, for: .horizontal)
            acts.setContentCompressionResistancePriority(.required, for: .horizontal)
            var buttons: [(String, Selector)] = [(s.unlocked ? "查看" : "看看条件", #selector(openSignal(_:)))]
            if s.authorID == me {
                if tabs.selectedSegment == 1 { buttons.append(("删除", #selector(remove(_:)))) }
            } else {
                buttons.append((s.iFollow ? "已是喵友" : "加喵友", #selector(follow(_:))))
            }
            for (t, sel) in buttons {
                let b = NSButton(title: t, target: self, action: sel)
                b.bezelStyle = .rounded
                b.controlSize = .small
                b.tag = i
                acts.addArrangedSubview(b)
            }
            row.addSubview(av); row.addSubview(col); row.addSubview(acts)
            let line = NSBox()
            line.boxType = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(line)
            NSLayoutConstraint.activate([
                av.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
                av.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
                av.bottomAnchor.constraint(lessThanOrEqualTo: line.topAnchor, constant: -10),
                col.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
                col.leadingAnchor.constraint(equalTo: av.trailingAnchor, constant: 10),
                col.trailingAnchor.constraint(equalTo: acts.leadingAnchor, constant: -12),
                col.bottomAnchor.constraint(lessThanOrEqualTo: line.topAnchor, constant: -10),
                acts.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
                acts.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
                acts.bottomAnchor.constraint(lessThanOrEqualTo: line.topAnchor, constant: -10),
                line.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                line.bottomAnchor.constraint(equalTo: row.bottomAnchor)])
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    private func item(_ b: NSButton) -> Signal? { b.tag < items.count ? items[b.tag] : nil }
    @objc private func openSignal(_ b: NSButton) { if let s = item(b) { station.showDetail(s) } }
    @objc private func follow(_ b: NSButton) {
        guard let s = item(b) else { return }
        b.isEnabled = false
        station.follow(s.authorID, on: !s.iFollow) { [weak self] n, now, err in
            b.isEnabled = true
            if let e = err { self?.status.stringValue = e; return }
            guard let self = self else { return }
            for k in self.items.indices where self.items[k].authorID == s.authorID {
                self.items[k].iFollow = now
                if let n = n { self.items[k].authorFollowers = n }
            }
            self.render()
        }
    }
    @objc private func remove(_ b: NSButton) {
        guard let s = item(b) else { return }
        let a = NSAlert()
        a.messageText = L10n.english ? "Delete “\(s.title)”?" : "删除「\(s.title)」？"
        a.informativeText = "删除后别人就看不到这条信号了。"
        a.addButton(withTitle: "删除")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { station.delete(s) { [weak self] in self?.reload() } }
    }
}

// MARK: - 一条信号（详情）

final class SignalDetailWindow: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    private unowned let station: SignalStation
    private var signal: Signal
    private var win: NSWindow!
    private let avatarHost = NSView()
    private let name = NSTextField(labelWithString: "")
    private let levelHost = NSStackView()
    private let fans = NSTextField(labelWithString: "")
    private let followBtn = NSButton(title: "", target: nil, action: nil)
    private let title = SK.WrapLabel("", size: 16, secondary: false, weight: .bold)
    private let meta = SK.WrapLabel("", size: 11.5)
    private let text = NSTextView()
    private let copyBtn = NSButton(title: "复制内容", target: nil, action: nil)

    init(signal: Signal, station: SignalStation) {
        self.signal = signal
        self.station = station
        super.init()
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                       styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "📶 信号"
        win.minSize = NSSize(width: 420, height: 340)
        win.isReleasedWhenClosed = false
        win.delegate = self
        let root = NSView()
        avatarHost.translatesAutoresizingMaskIntoConstraints = false
        avatarHost.widthAnchor.constraint(equalToConstant: 44).isActive = true
        avatarHost.heightAnchor.constraint(equalToConstant: 44).isActive = true
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fans.font = .systemFont(ofSize: 11.5)
        fans.textColor = .secondaryLabelColor
        levelHost.spacing = 0
        let nameLine = NSStackView(views: [name, levelHost])
        nameLine.spacing = 8
        nameLine.alignment = .centerY
        let who = NSStackView(views: [nameLine, fans])
        who.orientation = .vertical
        who.alignment = .leading
        who.spacing = 3
        followBtn.bezelStyle = .rounded
        followBtn.target = self
        followBtn.action = #selector(toggleFollow)
        let head = NSStackView(views: [avatarHost, who, NSView(), followBtn])
        head.spacing = 10
        head.alignment = .centerY
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 6, height: 8)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        copyBtn.bezelStyle = .rounded
        copyBtn.target = self
        copyBtn.action = #selector(copyBody)
        let close = NSButton(title: "关闭", target: self, action: #selector(closeWin))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        let row = NSStackView(views: [NSView(), copyBtn, close])
        for v in [head, title, meta, scroll, row] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            title.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            meta.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            meta.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)])
        win.contentView = root
        update(signal)
    }

    func update(_ s: Signal) {
        signal = s
        for v in avatarHost.subviews { v.removeFromSuperview() }
        let av = avatarView(s.authorAvatar, member: s.authorMember, size: 44)
        avatarHost.addSubview(av)
        av.leadingAnchor.constraint(equalTo: avatarHost.leadingAnchor).isActive = true
        av.topAnchor.constraint(equalTo: avatarHost.topAnchor).isActive = true
        name.stringValue = s.who
        for v in levelHost.arrangedSubviews { levelHost.removeArrangedSubview(v); v.removeFromSuperview() }
        levelHost.addArrangedSubview(levelView(s.authorLevel, height: 14))
        var f = "\(L10n.t("喵友")) \(s.authorFollowers)"
        if s.authorMember { f += " · " + L10n.t("订阅会员") }
        fans.stringValue = f
        let mine = s.authorID == station.myID
        followBtn.isHidden = mine
        followBtn.title = s.iFollow ? L10n.t("已是喵友") : L10n.t("加喵友")
        followBtn.toolTip = s.iFollow ? L10n.t("点一下取消喵友") : nil
        title.stringValue = (s.unlocked ? "" : "🔒 ") + s.title
        var m = s.gradeText
        if !s.timeText.isEmpty { m += " · " + s.timeText }
        if !s.sourceApp.isEmpty { m += " · " + L10n.t("来自") + " " + s.sourceApp }
        m += "\n" + L10n.t("谁能看：") + s.condsText
        meta.stringValue = m
        if s.unlocked {
            text.string = s.body ?? ""
            text.textColor = .labelColor
        } else {
            text.string = (L10n.english
                ? "This signal is locked. You still need: \(s.lacksText)\n\nSpend a moment with your cat each day to level up, gain more followers, or subscribe to unlock it."
                : "这条信号还看不了，还差：\(s.lacksText)\n\n每天和小猫互动一下就能涨等级；多交喵友、开通订阅也能解锁。")
            text.textColor = .secondaryLabelColor
        }
        copyBtn.isEnabled = s.unlocked
    }

    func show() {
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleFollow() {
        let s = signal
        followBtn.isEnabled = false
        station.follow(s.authorID, on: !s.iFollow) { [weak self] n, now, err in
            guard let self = self else { return }
            self.followBtn.isEnabled = true
            if let e = err { self.meta.stringValue = e; return }
            var u = self.signal
            u.iFollow = now
            if let n = n { u.authorFollowers = n }
            self.update(u)
        }
    }
    @objc private func copyBody() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(signal.title)\n\n\(signal.body ?? "")", forType: .string)
    }
    @objc private func closeWin() { win.close() }
    func windowWillClose(_ n: Notification) { onClose?() }
}

// MARK: - 发信号（审核 / 编辑窗口，发之前必经）

final class SignalComposeWindow: NSObject, NSWindowDelegate {
    private unowned let station: SignalStation
    private var win: NSWindow!
    private let source = NSTextField(labelWithString: "")
    private let titleField = NSTextField()
    private let body = NSTextView()
    private let grade = NSPopUpButton()
    private let minLevel = NSComboBox()
    private let minFans = NSComboBox()
    private let memberOnly = NSButton(checkboxWithTitle: "仅订阅会员", target: nil, action: nil)
    private var skillBoxes: [(String, NSButton)] = []
    private let status = NSTextField(labelWithString: "")
    private let postButton = NSButton(title: "发出信号", target: nil, action: nil)
    private let refine = NSButton(title: "小猫帮我提炼", target: nil, action: nil)
    private let llm = LLM()
    private var sourceApp = ""
    private var raw = ""
    private var busy = false

    init(station: SignalStation) {
        self.station = station
        super.init()
        let W: CGFloat = 620, H: CGFloat = 640
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H), styleMask: [.titled, .closable],
                       backing: .buffered, defer: false)
        win.title = "📶 发信号 · 先审再发"
        win.isReleasedWhenClosed = false
        win.delegate = self
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        let fx: CGFloat = 104, fw: CGFloat = W - fx - 20

        func lab(_ t: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: t)
            l.alignment = .right
            l.frame = NSRect(x: 8, y: y + 4, width: fx - 16, height: 18)
            v.addSubview(l)
        }
        func small(_ l: NSTextField, _ r: NSRect) {
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.frame = r
            v.addSubview(l)
        }

        let info = NSTextField(wrappingLabelWithString: "这些内容来自你的屏幕。小猫已自动给密码、Key、卡号打码，但请你再看一遍，删掉不想公开的部分。只有你点「发出信号」才会发出去。")
        small(info, NSRect(x: 20, y: H - 50, width: W - 40, height: 34))

        lab("来源", H - 84)
        source.lineBreakMode = .byTruncatingTail
        source.frame = NSRect(x: fx, y: H - 80, width: fw - 128, height: 18)
        v.addSubview(source)
        let reread = NSButton(title: "重新读取桌面", target: self, action: #selector(rereadDesktop))
        reread.bezelStyle = .rounded
        reread.frame = NSRect(x: W - 20 - 124, y: H - 87, width: 124, height: 28)
        v.addSubview(reread)

        lab("标题", H - 120)
        titleField.frame = NSRect(x: fx, y: H - 120, width: fw, height: 24)
        titleField.placeholderString = "一句话说清这条信号（2–80 字）"
        v.addSubview(titleField)

        lab("内容", H - 154)
        let scroll = NSScrollView(frame: NSRect(x: fx, y: H - 380, width: fw, height: 226))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        body.frame = NSRect(x: 0, y: 0, width: fw - 18, height: 226)
        body.isRichText = false
        body.font = .systemFont(ofSize: 12.5)
        body.isAutomaticQuoteSubstitutionEnabled = false
        body.isAutomaticTextReplacementEnabled = false
        body.autoresizingMask = [.width]
        body.isVerticallyResizable = true
        body.textContainer?.widthTracksTextView = true
        scroll.documentView = body
        v.addSubview(scroll)
        refine.bezelStyle = .rounded
        refine.target = self
        refine.action = #selector(doRefine)
        refine.toolTip = "用你的模型把读到的内容提炼成标题和几条要点，提炼完你还可以再改"
        refine.frame = NSRect(x: fx - 4, y: H - 414, width: 140, height: 28)
        v.addSubview(refine)
        small(status, NSRect(x: fx + 142, y: H - 407, width: fw - 142, height: 16))
        status.lineBreakMode = .byTruncatingTail

        lab("情报等级", H - 450)
        grade.frame = NSRect(x: fx, y: H - 452, width: 150, height: 26)
        for (i, g) in SignalStation.grades.enumerated() { grade.addItem(withTitle: "\(String(repeating: "▮", count: i + 1)) \(g)情报") }
        v.addSubview(grade)

        lab("谁能看", H - 490)
        let lvLabel = NSTextField(labelWithString: "小猫等级至少")
        lvLabel.frame = NSRect(x: fx, y: H - 486, width: 96, height: 18)
        v.addSubview(lvLabel)
        minLevel.frame = NSRect(x: fx + 98, y: H - 490, width: 70, height: 26)
        minLevel.addItems(withObjectValues: ["0", "1", "3", "5", "10", "20", "30"])
        minLevel.stringValue = "0"
        minLevel.completes = false
        v.addSubview(minLevel)
        let fansLabel = NSTextField(labelWithString: "喵友至少")
        fansLabel.frame = NSRect(x: fx + 186, y: H - 486, width: 70, height: 18)
        v.addSubview(fansLabel)
        minFans.frame = NSRect(x: fx + 258, y: H - 490, width: 80, height: 26)
        minFans.addItems(withObjectValues: ["0", "1", "5", "10", "50", "100"])
        minFans.stringValue = "0"
        minFans.completes = false
        v.addSubview(minFans)

        memberOnly.frame = NSRect(x: fx, y: H - 522, width: 140, height: 20)
        v.addSubview(memberOnly)
        let needs = NSTextField(labelWithString: "需要技能：")
        needs.frame = NSRect(x: fx + 146, y: H - 520, width: 74, height: 18)
        v.addSubview(needs)
        var x = fx + 220
        for (id, n) in SignalStation.skills {
            let b = NSButton(checkboxWithTitle: n, target: nil, action: nil)
            b.sizeToFit()
            b.frame = NSRect(x: x, y: H - 522, width: b.frame.width + 4, height: 20)
            x += b.frame.width + 10
            v.addSubview(b)
            skillBoxes.append((id, b))
        }
        let condTip = NSTextField(wrappingLabelWithString: "不满足条件的人只能看到标题和还差什么，看不到内容。「需要技能」= 对方的账号订阅了这个技能。")
        small(condTip, NSRect(x: fx, y: H - 560, width: fw, height: 30))

        let cancel = NSButton(title: "取消", target: self, action: #selector(doCancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: W - 236, y: 12, width: 100, height: 30)
        v.addSubview(cancel)
        postButton.bezelStyle = .rounded
        postButton.keyEquivalent = "\r"
        postButton.keyEquivalentModifierMask = [.command]
        postButton.target = self
        postButton.action = #selector(doPost)
        postButton.frame = NSRect(x: W - 132, y: 12, width: 116, height: 30)
        v.addSubview(postButton)
        let keyTip = NSTextField(labelWithString: "⌘↩ 发出信号")
        small(keyTip, NSRect(x: 20, y: 20, width: 220, height: 16))

        win.contentView = v
        win.initialFirstResponder = titleField
    }

    func show() {
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// Ask the app to read the window the user was looking at (never sent anywhere until they press 发出信号).
    func readDesktop() {
        guard let cap = station.captureDesktop else { status.stringValue = L10n.t("读不到桌面内容"); return }
        status.stringValue = L10n.t("正在读取你正在看的窗口…")
        source.stringValue = "…"
        Task { @MainActor in
            let got = await cap()
            if let g = got, !g.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.fill(app: g.app, title: g.title, text: g.text)
                self.status.stringValue = L10n.t("读好了，看一遍再发；也可以让小猫帮你提炼。")
            } else {
                self.source.stringValue = L10n.t("（没读到内容）")
                self.status.stringValue = L10n.t("没读到这个窗口的文字：可能是没给「辅助功能」权限，或这个应用被排除了。可以直接自己写。")
            }
        }
    }

    func fill(app: String, title: String, text: String) {
        sourceApp = app
        raw = text
        source.stringValue = [app, title].filter { !$0.isEmpty }.joined(separator: " · ")
        if source.stringValue.isEmpty { source.stringValue = L10n.t("聊天里写的") }
        if titleField.stringValue.isEmpty {
            let first = title.isEmpty ? (text.split(separator: "\n").first.map(String.init) ?? "") : title
            titleField.stringValue = String(first.prefix(80))
        }
        body.string = String(text.prefix(8000))
    }

    @objc private func rereadDesktop() { readDesktop() }

    @objc private func doRefine() {
        let src = (raw.isEmpty ? body.string : raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty else { status.stringValue = L10n.t("先读取桌面或写点内容"); return }
        guard !Prefs.base.trimmingCharacters(in: .whitespaces).isEmpty else {
            status.stringValue = L10n.t("还没设置聊天模型（设置 → 模型）"); return
        }
        guard !busy else { return }
        busy = true
        refine.isEnabled = false
        status.stringValue = L10n.t("小猫正在提炼…")
        let lang = L10n.english ? "English" : "简体中文"
        let prompt = """
        下面是用户屏幕上一个窗口里的文字（已打码）。把其中最有价值、值得分享给别人的信息提炼成一条「信号」，用\(lang)：
        第一行是标题（不超过 30 字，不要加「标题：」），空一行，然后 3–6 条要点，每条一行以「• 」开头，最后可以加一行来源链接（如果原文里有）。
        不要编造原文没有的内容，不要包含任何个人隐私（姓名、手机号、邮箱、账号、密码、地址）。

        \(String(src.prefix(9000)))
        """
        llm.stream([["role": "user", "content": prompt]], context: "这次只按要求输出信号内容，不要多说别的。",
                   onDelta: { _ in }, onDone: { [weak self] text, err in
            guard let self = self else { return }
            self.busy = false
            self.refine.isEnabled = true
            let out = Redactor.clean((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            guard !out.isEmpty else { self.status.stringValue = L10n.t("没提炼成：") + (err ?? ""); return }
            var lines = out.components(separatedBy: "\n")
            let t = lines.removeFirst().trimmingCharacters(in: CharacterSet(charactersIn: " #*「」\""))
            self.titleField.stringValue = String(t.prefix(80))
            self.body.string = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            self.status.stringValue = L10n.t("提炼好了，看一遍再发。")
        })
    }

    @objc private func doCancel() { win.close() }

    @objc private func doPost() {
        let t = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = body.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { status.stringValue = L10n.t("标题至少 2 个字"); return }
        guard !b.isEmpty else { status.stringValue = L10n.t("内容还是空的"); return }
        let lv = max(0, min(999, Int(minLevel.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0))
        let fans = max(0, min(1_000_000, Int(minFans.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0))
        let skills = skillBoxes.filter { $0.1.state == .on }.map { $0.0 }
        postButton.isEnabled = false
        status.stringValue = L10n.t("正在发出…")
        station.post(title: t, body: b, grade: grade.indexOfSelectedItem + 1, minLevel: lv, minFollowers: fans,
                     memberOnly: memberOnly.state == .on, skills: skills, sourceApp: sourceApp) { [weak self] err in
            guard let self = self else { return }
            self.postButton.isEnabled = true
            if let e = err { self.status.stringValue = L10n.t("没发出去：") + e; return }
            self.win.close()
        }
    }

    func windowWillClose(_ n: Notification) { llm.cancel() }
}

// MARK: - 设置 → 信号站

final class SignalPane: NSObject {
    private let line = SK.WrapLabel("", size: 13, secondary: false)
    private let notify = NSSwitch()

    func build(into p: SK.Page) {
        p.hint("把小猫在桌面上看到的有价值信息分享给别的小猫。每次都先给你审、改，你点「发出信号」才会发。你可以设谁能看：小猫等级、喵友数、订阅会员、拥有的技能。")
        let g0 = SK.Group()
        g0.add(SK.info(line))
        p.add(g0)
        p.add(SK.buttons([SK.button("打开信号站", self, #selector(openStation)),
                          SK.button("分享当前桌面", self, #selector(share)),
                          SK.button("我发出的", self, #selector(mine))]))

        p.header("提醒")
        notify.target = self
        notify.action = #selector(notifyToggled(_:))
        let g = SK.Group()
        g.add(SK.toggle("有我能看的新信号时提醒我", notify, sub: "大约每 10 分钟看一次，每条信号只提醒一次"))
        p.add(g)

        p.header("怎么用")
        p.hint("""
        • 分享：点「分享当前桌面」，或在聊天里说「发信号：……」/「/信号」。小猫读一下你正在看的窗口，打开发信号窗口让你审、改；可以让小猫帮你提炼。
        • 情报等级：普通 / 优质 / 稀有 / 绝密，告诉大家这条有多重要。
        • 谁能看：不满足条件的人只看到标题和还差什么，内容不会发到他们那里。
        • 小猫等级：每天和小猫互动一次算一个活跃天，Lv1 要 5 天，越往后越多，没有上限。等级显示在「用户」页。
        • 喵友：在信号作者那一行点「加喵友」；喵友数 = 加你为喵友的人数。
        """)
        refresh()
        SignalStation.shared.observe { [weak self] in self?.refresh() }
        Account.shared.observe { [weak self] in self?.refresh() }
    }

    func refresh() {
        let acc = Account.shared
        line.stringValue = acc.configured && acc.signedIn
            ? L10n.t("📶 已登录，可以分享和接收信号")
            : (acc.configured ? L10n.t("📶 先登录账号（设置 → 用户）才能用信号站") : L10n.t("📶 账号服务还在开通中"))
        notify.state = Prefs.signalNotify ? .on : .off
    }

    @objc private func notifyToggled(_ s: NSSwitch) { Prefs.signalNotify = s.state == .on }
    @objc private func openStation() { SignalStation.shared.showWindow() }
    @objc private func share() { SignalStation.shared.compose() }
    @objc private func mine() { SignalStation.shared.showWindow(tab: 1) }
}
