// OrdCat — 喵友列表、好友邀请、私信、客服 (v0.2.45).
// Server side: supabase/account2.sql (follow_list, invite_*, dm_*, support_id, user_card).

import Cocoa

struct PalUser {
    let id: String
    let name: String
    let username: String
    let avatarURL: String?
    let level: Int
    var iFollow: Bool
    let followsMe: Bool

    init?(_ o: [String: Any]) {
        guard let id = o["user_id"] as? String else { return nil }
        self.id = id
        let n = (o["display_name"] as? String) ?? ""
        let u = (o["username"] as? String) ?? ""
        name = n.isEmpty ? (u.isEmpty ? L10n.t("一只小猫") : u) : n
        username = u
        avatarURL = (o["avatar_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        level = CatStats.int(o["level"])
        iFollow = o["i_follow"] as? Bool ?? false
        followsMe = o["follows_me"] as? Bool ?? false
    }
}

enum Social {
    static var acct: Account { Account.shared }

    static func friendly(_ e: String) -> String {
        let l = e.lowercased()
        if l.contains("schema cache") || l.contains("could not find the function") || l.contains("does not exist") {
            return L10n.t("服务器还没开通这个功能（管理员需要在 Supabase 运行 supabase/account2.sql）")
        }
        return e
    }

    static func rpc(_ fn: String, _ args: [String: Any] = [:], done: @escaping (Any?, String?) -> Void) {
        guard acct.configured, acct.signedIn else { done(nil, L10n.t("先在 设置 → 用户 里登录账号")); return }
        acct.request("POST", "/rest/v1/rpc/" + fn, json: args) { o, e in done(o, e.map(friendly)) }
    }

    // MARK: avatars (small in-memory cache)
    private static var cache: [String: NSImage] = [:]
    static func avatar(_ url: String?, size: CGFloat, done: @escaping (NSImage) -> Void) {
        let fallback = acctFallback(size)
        guard let s = url, let u = URL(string: s) else { done(fallback); return }
        if let i = cache[s] { done(i); return }
        URLSession.shared.dataTask(with: u) { d, _, _ in
            let img = d.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                if let i = img { cache[s] = i }
                done(img ?? fallback)
            }
        }.resume()
    }
    private static func acctFallback(_ size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        NSColor(calibratedRed: 0.24, green: 0.24, blue: 0.235, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        let eyes = ordEyesImage(height: size * 0.34)
        eyes.draw(in: NSRect(x: (size - eyes.size.width) / 2, y: (size - eyes.size.height) / 2,
                             width: eyes.size.width, height: eyes.size.height))
        img.unlockFocus()
        return img
    }

    static func round(_ img: NSImage, _ s: CGFloat) -> NSImage {
        let out = NSImage(size: NSSize(width: s, height: s))
        out.lockFocus()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: s, height: s)).addClip()
        img.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
        out.unlockFocus()
        return out
    }

    // MARK: 客服
    static let supportEmail = "support@ordcat.de"

    /// In-app support: a private chat with the OrdCat support account when the server has one, else email.
    static func openSupport() {
        guard acct.configured, acct.signedIn else { mailSupport(); return }
        rpc("support_id") { o, _ in
            if let id = o as? String, !id.isEmpty {
                DMWindow.shared.open(peer: id, name: L10n.t("OrdCat 客服"))
            } else {
                mailSupport()
            }
        }
    }

    static func mailSupport() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let subject = "OrdCat \(v) " + (L10n.english ? "feedback" : "反馈")
        let body = (L10n.english ? "\n\n\n—\nOrdCat \(v) · macOS \(os)" : "\n\n\n—\nOrdCat \(v) · macOS \(os)")
        var c = URLComponents()
        c.scheme = "mailto"; c.path = supportEmail
        c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

    // MARK: unread private messages (checked every minute while signed in)
    private static var unreadTimer: Timer?
    private static var lastUnread = 0
    static var onUnread: ((Int) -> Void)?

    static func startUnreadWatch() {
        guard unreadTimer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { _ in checkUnread() }
        t.tolerance = 15
        RunLoop.main.add(t, forMode: .common)
        unreadTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { checkUnread() }
    }

    static func checkUnread() {
        guard acct.configured, acct.signedIn else { return }
        rpc("dm_unread") { o, e in
            guard e == nil else { return }
            let n = CatStats.int(o)
            if n > lastUnread, !DMWindow.shared.isVisible { onUnread?(n) }
            lastUnread = n
        }
    }
}

// MARK: - 喵友列表（关注我的 / 我关注的）

final class FollowListWindow: NSObject, NSWindowDelegate {
    static let shared = FollowListWindow()
    private var win: NSWindow!
    private let tabs = NSSegmentedControl(labels: ["喵友（关注我的）", "我关注的"], trackingMode: .selectOne, target: nil, action: nil)
    private let list = NSStackView()
    private let status = SK.WrapLabel("", size: 12)
    private var users: [PalUser] = []
    private var gen = 0

    func show(kind: Int = 0) {
        if win == nil { build() }
        tabs.selectedSegment = kind
        reload()
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func build() {
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                       styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "喵友"
        win.minSize = NSSize(width: 340, height: 320)
        win.isReleasedWhenClosed = false
        win.delegate = self
        tabs.target = self; tabs.action = #selector(reload)
        ocStyleTabs(tabs)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        list.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        for v in [tabs, status, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            status.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 12),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -12),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor)])
        win.contentView = root
    }

    @objc func reload() {
        gen += 1
        let g = gen
        status.stringValue = L10n.t("正在加载…")
        for v in list.arrangedSubviews { v.removeFromSuperview() }
        let kind = tabs.selectedSegment == 1 ? "following" : "followers"
        Social.rpc("follow_list", ["p_kind": kind, "p_limit": 300]) { [weak self] o, e in
            guard let self = self, g == self.gen else { return }
            if let e = e { self.status.stringValue = "⚠️ " + e; return }
            self.users = ((o as? [[String: Any]]) ?? []).compactMap(PalUser.init)
            if self.users.isEmpty {
                self.status.stringValue = kind == "following"
                    ? L10n.t("你还没关注别的小猫。在信号站和猫帮圈里点「加喵友」就能关注。")
                    : L10n.t("还没有喵友关注你。把邀请码发给朋友，一起养猫吧。")
            } else {
                self.status.stringValue = L10n.english ? "\(self.users.count) in total" : "共 \(self.users.count) 位"
            }
            for (i, u) in self.users.enumerated() { self.list.addArrangedSubview(self.row(u, i)) }
        }
    }

    private func row(_ u: PalUser, _ i: Int) -> NSView {
        let pic = NSImageView()
        pic.translatesAutoresizingMaskIntoConstraints = false
        pic.widthAnchor.constraint(equalToConstant: 34).isActive = true
        pic.heightAnchor.constraint(equalToConstant: 34).isActive = true
        Social.avatar(u.avatarURL, size: 68) { img in pic.image = Social.round(img, 34) }
        let name = NSTextField(labelWithString: u.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        var sub = "Lv\(u.level)"
        if !u.username.isEmpty { sub = "@\(u.username) · " + sub }
        if u.iFollow && u.followsMe { sub += L10n.english ? " · mutual" : " · 互相关注" }
        let detail = NSTextField(labelWithString: sub)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let texts = NSStackView(views: [name, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let follow = OCButton(title: u.iFollow ? "已关注" : "关注", target: self, action: #selector(toggleFollow(_:)))
        follow.chip = true
        follow.style = u.iFollow ? .neutral : .primary
        follow.tag = i
        var views: [NSView] = [pic, texts, NSView()]
        if u.followsMe || u.iFollow {
            let dm = OCButton(title: "私信", target: self, action: #selector(message(_:)))
            dm.chip = true
            dm.style = .secondary
            dm.tag = i
            dm.toolTip = L10n.t("对方关注你之后才能发私信")
            views.append(dm)
        }
        views.append(follow)
        let r = NSStackView(views: views)
        r.spacing = 10
        r.alignment = .centerY
        r.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        r.translatesAutoresizingMaskIntoConstraints = false
        r.widthAnchor.constraint(equalToConstant: max(300, (win?.frame.width ?? 400) - 24)).isActive = true
        return r
    }

    @objc private func toggleFollow(_ b: NSButton) {
        guard b.tag < users.count else { return }
        let u = users[b.tag]
        let on = !u.iFollow
        if !on {
            guard OCConfirm.ask(L10n.english ? "Unfollow \(u.name)?" : "取消关注 \(u.name)？",
                                L10n.t("取消后对方的信号可能就看不到了。"), ok: "取消关注", danger: true) else { return }
        }
        b.isEnabled = false
        SignalStation.shared.follow(u.id, on: on) { [weak self] _, now, err in
            b.isEnabled = true
            if let e = err { self?.status.stringValue = "⚠️ " + e; return }
            self?.users[b.tag].iFollow = now
            b.title = now ? "已关注" : "关注"
            (b as? OCButton)?.style = now ? .neutral : .primary
        }
    }

    @objc private func message(_ b: NSButton) {
        guard b.tag < users.count else { return }
        DMWindow.shared.open(peer: users[b.tag].id, name: users[b.tag].name)
    }
}

/// Top-down layout for scroll documents.
final class FlippedView: NSView { override var isFlipped: Bool { true } }

// MARK: - 好友邀请

final class InviteWindow: NSObject {
    static let shared = InviteWindow()
    private var win: NSWindow?
    private let codeLabel = NSTextField(labelWithString: "······")
    private let info = SK.WrapLabel("", size: 12)
    private let redeemField = NSTextField()
    private let status = SK.WrapLabel("", size: 12)
    private var code = ""

    func show() {
        if win == nil { build() }
        load()
        win?.center()
        NSApp.activate(ignoringOtherApps: true)
        win?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 330), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "邀请好友"
        w.isReleasedWhenClosed = false
        let title = SK.WrapLabel("把邀请码发给朋友。朋友注册后 7 天内填上，你们俩各得 50 小鱼干，还会自动互加喵友。", size: 12.5, secondary: false)
        codeLabel.font = .monospacedSystemFont(ofSize: 30, weight: .bold)
        codeLabel.textColor = kAmber
        codeLabel.alignment = .center
        codeLabel.isSelectable = true
        let copyCode = OCButton(title: "复制邀请码", target: self, action: #selector(copyCode))
        copyCode.style = .primary
        let copyLink = OCButton(title: "复制邀请链接", target: self, action: #selector(copyLink))
        let btns = NSStackView(views: [copyCode, copyLink])
        btns.spacing = 8
        let sep = NSBox(); sep.boxType = .separator
        let redeemTitle = SK.WrapLabel("有朋友的邀请码？", size: 12.5, secondary: false)
        redeemField.placeholderString = "填 6 位邀请码"
        redeemField.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        let redeem = OCButton(title: "领取", target: self, action: #selector(redeem))
        let rr = NSStackView(views: [redeemField, redeem])
        rr.spacing = 8
        let stack = NSStackView(views: [title, codeLabel, info, btns, sep, redeemTitle, rr, status])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [title, info, status, sep, rr] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true }
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: root.topAnchor),
                                     stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                                     stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                     stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor)])
        w.contentView = root
        win = w
    }

    private func load() {
        info.stringValue = L10n.t("正在获取你的邀请码…")
        Social.rpc("invite_my_code") { [weak self] o, e in
            guard let self = self else { return }
            if let e = e { self.info.stringValue = "⚠️ " + e; return }
            let d = o as? [String: Any] ?? [:]
            self.code = d["code"] as? String ?? ""
            self.codeLabel.stringValue = self.code
            let n = CatStats.int(d["invited"])
            self.info.stringValue = L10n.english ? "\(n) friends joined with your code" : "已经有 \(n) 位朋友用了你的邀请码"
        }
    }

    private var link: String { "https://ordcat.de/?invite=\(code)" }

    @objc private func copyCode() { copy(code) }
    @objc private func copyLink() {
        copy(L10n.english ? "Come raise an AI cat with me on OrdCat: \(link) (invite code \(code))"
                          : "来 OrdCat 领养一只 AI 小猫吧：\(link)（邀请码 \(code)）")
    }
    private func copy(_ s: String) {
        guard !code.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        status.stringValue = L10n.t("✅ 已复制")
    }

    @objc private func redeem() {
        let c = redeemField.stringValue.trimmingCharacters(in: .whitespaces).uppercased()
        guard c.count == 6 else { status.stringValue = L10n.t("邀请码是 6 位"); return }
        guard OCConfirm.ask(L10n.english ? "Use invite code \(c)?" : "使用邀请码 \(c)？",
                            L10n.t("每个账号只能填一次。填好后你们俩各得 50 小鱼干，并互加喵友。"), ok: "领取") else { return }
        status.stringValue = L10n.t("正在领取…")
        Social.rpc("invite_redeem", ["p_code": c]) { [weak self] _, e in
            self?.status.stringValue = e.map { "⚠️ " + $0 } ?? L10n.t("🐟 领到 50 小鱼干，已经互加喵友啦")
            if e == nil { CatLevel.shared.refresh() }
        }
    }
}

// MARK: - 私信

struct DMThread {
    let peer: String
    let name: String
    let avatarURL: String?
    let last: String
    let lastAt: Date?
    let unread: Int
    let isSupport: Bool
    init?(_ o: [String: Any]) {
        guard let p = o["peer_id"] as? String else { return nil }
        peer = p
        let n = (o["display_name"] as? String) ?? "", u = (o["username"] as? String) ?? ""
        isSupport = o["is_support"] as? Bool ?? false
        name = isSupport ? L10n.t("OrdCat 客服") : (n.isEmpty ? (u.isEmpty ? L10n.t("一只小猫") : u) : n)
        avatarURL = (o["avatar_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        last = (o["last_body"] as? String) ?? ""
        lastAt = DMWindow.parse(o["last_at"] as? String)
        unread = CatStats.int(o["unread"])
    }
}

final class DMWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = DMWindow()
    private var win: NSWindow?
    private let threadList = NSStackView()
    private let transcript = NSTextView()
    private let header = NSTextField(labelWithString: "")
    private let input = NSTextField()
    private var sendBtn: OCButton!
    private let status = SK.WrapLabel("", size: 11.5)
    private var threads: [DMThread] = []
    private var peer: String?
    private var peerName = ""
    private var poll: Timer?
    private var sending = false

    var isVisible: Bool { win?.isVisible ?? false }

    static func parse(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    func show() { open(peer: nil, name: "") }

    func open(peer p: String?, name: String) {
        if win == nil { build() }
        if let p = p { peer = p; peerName = name }
        loadThreads()
        loadMessages()
        win?.center()
        NSApp.activate(ignoringOtherApps: true)
        win?.makeKeyAndOrderFront(nil)
        if poll == nil {
            let t = Timer(timeInterval: 6, repeats: true) { [weak self] _ in
                guard let self = self, self.isVisible else { return }
                self.loadMessages(quiet: true); self.loadThreads()
            }
            RunLoop.main.add(t, forMode: .common)
            poll = t
        }
    }

    func windowWillClose(_ notification: Notification) { poll?.invalidate(); poll = nil }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "私信"
        w.minSize = NSSize(width: 560, height: 360)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("OrdCatDM")

        // Left: conversations
        threadList.orientation = .vertical
        threadList.alignment = .leading
        threadList.spacing = 2
        threadList.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        threadList.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(threadList)
        let leftScroll = NSScrollView()
        leftScroll.hasVerticalScroller = true
        leftScroll.drawsBackground = false
        leftScroll.documentView = doc
        let support = OCButton(title: "💬 联系客服", target: self, action: #selector(contactSupport))
        support.chip = true
        support.style = .secondary
        let left = NSView()
        for v in [leftScroll, support] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; left.addSubview(v) }

        // Right: messages
        header.font = .systemFont(ofSize: 14, weight: .semibold)
        transcript.isEditable = false
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 10, height: 10)
        let tScroll = NSScrollView()
        tScroll.hasVerticalScroller = true
        tScroll.drawsBackground = false
        tScroll.documentView = transcript
        transcript.autoresizingMask = [.width]
        input.placeholderString = "写私信…（回车发送）"
        input.font = .systemFont(ofSize: 13)
        input.target = self
        input.action = #selector(send)
        sendBtn = OCButton(title: "发送", target: self, action: #selector(send))
        sendBtn.style = .primary
        let right = NSView()
        for v in [header, tScroll, input, sendBtn, status] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; right.addSubview(v) }

        let root = NSView()
        let line = NSBox(); line.boxType = .separator
        for v in [left, line, right] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: root.topAnchor), left.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor), left.widthAnchor.constraint(equalToConstant: 220),
            line.topAnchor.constraint(equalTo: root.topAnchor), line.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: left.trailingAnchor), line.widthAnchor.constraint(equalToConstant: 1),
            right.topAnchor.constraint(equalTo: root.topAnchor), right.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            right.leadingAnchor.constraint(equalTo: line.trailingAnchor), right.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            leftScroll.topAnchor.constraint(equalTo: left.topAnchor), leftScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            leftScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            leftScroll.bottomAnchor.constraint(equalTo: support.topAnchor, constant: -8),
            support.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 12),
            support.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -12),
            doc.widthAnchor.constraint(equalTo: leftScroll.contentView.widthAnchor),
            threadList.topAnchor.constraint(equalTo: doc.topAnchor), threadList.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            threadList.trailingAnchor.constraint(equalTo: doc.trailingAnchor), threadList.bottomAnchor.constraint(equalTo: doc.bottomAnchor),

            header.topAnchor.constraint(equalTo: right.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -16),
            tScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            tScroll.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            tScroll.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            tScroll.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -10),
            input.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 14),
            input.trailingAnchor.constraint(equalTo: sendBtn.leadingAnchor, constant: -8),
            input.heightAnchor.constraint(equalToConstant: 28),
            input.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            sendBtn.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            sendBtn.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -14),
            status.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 14),
            status.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -14),
            status.bottomAnchor.constraint(equalTo: right.bottomAnchor, constant: -10)])
        w.contentView = root
        win = w
    }

    private func loadThreads() {
        Social.rpc("dm_threads") { [weak self] o, e in
            guard let self = self else { return }
            if let e = e { self.status.stringValue = "⚠️ " + e; return }
            self.threads = ((o as? [[String: Any]]) ?? []).compactMap(DMThread.init)
            for v in self.threadList.arrangedSubviews { v.removeFromSuperview() }
            if let p = self.peer, !self.threads.contains(where: { $0.peer == p }) {
                self.threadList.addArrangedSubview(self.threadRow(name: self.peerName, last: L10n.t("新对话"), unread: 0, peer: p))
            }
            for t in self.threads {
                self.threadList.addArrangedSubview(self.threadRow(name: t.name, last: t.last, unread: t.unread, peer: t.peer))
            }
            if self.threads.isEmpty && self.peer == nil {
                self.header.stringValue = L10n.t("还没有私信")
                self.status.stringValue = L10n.t("在喵友列表里点「私信」开始聊天。对方关注你之后才能发私信。")
            }
        }
    }

    private func threadRow(name: String, last: String, unread: Int, peer p: String) -> NSView {
        let title = (unread > 0 ? "● " : "") + name + "\n" + (last.count > 26 ? String(last.prefix(26)) + "…" : last)
        let b = NSButton(title: "", target: self, action: #selector(pick(_:)))
        b.isBordered = false
        b.alignment = .left
        b.identifier = NSUserInterfaceItemIdentifier(p)
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para])
        let firstLine = (title as NSString).range(of: "\n").location
        if firstLine != NSNotFound {
            s.addAttributes([.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                             .foregroundColor: unread > 0 ? kAmber : NSColor.labelColor], range: NSRange(location: 0, length: firstLine))
        }
        b.attributedTitle = s
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        b.layer?.backgroundColor = (p == peer ? kAmber.withAlphaComponent(0.16) : NSColor.clear).cgColor
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        b.widthAnchor.constraint(equalToConstant: 206).isActive = true
        return b
    }

    @objc private func pick(_ b: NSButton) {
        guard let p = b.identifier?.rawValue else { return }
        peer = p
        peerName = threads.first(where: { $0.peer == p })?.name ?? peerName
        loadMessages()
        loadThreads()
    }

    private func loadMessages(quiet: Bool = false) {
        guard let p = peer else {
            header.stringValue = L10n.t("私信"); transcript.string = ""; input.isEnabled = false; sendBtn.isEnabled = false
            return
        }
        header.stringValue = peerName
        input.isEnabled = true; sendBtn.isEnabled = true
        if !quiet { status.stringValue = L10n.t("正在加载…") }
        Social.rpc("dm_messages", ["p_with": p, "p_limit": 100]) { [weak self] o, e in
            guard let self = self, self.peer == p else { return }
            if let e = e { self.status.stringValue = "⚠️ " + e; return }
            if !quiet || self.status.stringValue == L10n.t("正在加载…") { self.status.stringValue = "" }
            let rows = ((o as? [[String: Any]]) ?? []).reversed()
            let out = NSMutableAttributedString()
            let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"
            for r in rows {
                let mine = r["from_me"] as? Bool ?? false
                let body = r["body"] as? String ?? ""
                let t = DMWindow.parse(r["created_at"] as? String).map { df.string(from: $0) } ?? ""
                let para = NSMutableParagraphStyle()
                para.alignment = mine ? .right : .left
                para.paragraphSpacing = 10
                out.append(NSAttributedString(string: (mine ? L10n.t("我") : self.peerName) + "  " + t + "\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: para]))
                out.append(NSAttributedString(string: body + "\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: mine ? kAmber : NSColor.labelColor, .paragraphStyle: para]))
            }
            if out.string != self.transcript.string {
                self.transcript.textStorage?.setAttributedString(out)
                self.transcript.scrollToEndOfDocument(nil)
            }
        }
    }

    @objc private func send() {
        guard let p = peer, !sending else { return }
        let t = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        sending = true
        sendBtn.isEnabled = false
        Social.rpc("dm_send", ["p_to": p, "p_body": t]) { [weak self] _, e in
            guard let self = self else { return }
            self.sending = false
            self.sendBtn.isEnabled = true
            if let e = e { self.status.stringValue = "⚠️ " + e; return }
            self.input.stringValue = ""
            self.loadMessages(quiet: true)
            self.loadThreads()
        }
    }

    @objc private func contactSupport() { Social.openSupport() }
}
