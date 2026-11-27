// OrdCat — 小鱼干储值（v0.2.62）.
//
// 1 € = 100 条小鱼干. Two buckets, both never expire:
//   充值鱼干 (paid)   bought with Stripe (设置 → 用户 → 小鱼干 → 充值); buys everything
//   奖励鱼干 (reward) new account, invites, 喵副本 rewards; full use on 喵副本, at most 30% of a plan / skill / 加油包
// The server (supabase/fish.sql) does every spend atomically; this file only shows and asks.

import Cocoa
import CryptoKit
import IOKit

struct FishPack {
    let id: String
    let eur: Int
    let fish: Int
}

enum Fish {
    static let changed = Notification.Name("OrdCatFishChanged")
    private static let d = UserDefaults.standard

    private(set) static var total: Int?
    private(set) static var paid: Int?
    private(set) static var reward: Int?
    private(set) static var plan = "free"
    private(set) static var prices: [String: Int] = [:]
    /// Plans / skills opened with fish: item, interval, ends_at, auto_renew.
    private(set) static var subs: [[String: Any]] = []

    // MARK: packs (config/remote.json → billing.fishPacks; built-in fallback)

    static let defaultPacks = [FishPack(id: "5", eur: 5, fish: 500), FishPack(id: "10", eur: 10, fish: 1050),
                               FishPack(id: "30", eur: 30, fish: 3300), FishPack(id: "100", eur: 100, fish: 11500)]

    static func applyRemote(_ arr: [[String: Any]]?) {
        guard let arr = arr else { return }
        let rows: [[String: Any]] = arr.compactMap { p in
            guard let id = p["id"] as? String, let fish = p["fish"] as? Int else { return nil }
            return ["id": id, "eur": p["eur"] as? Int ?? 0, "fish": fish]
        }
        if !rows.isEmpty { d.set(rows, forKey: "fish.packs") }
    }

    static var packs: [FishPack] {
        let rows = d.array(forKey: "fish.packs") as? [[String: Any]] ?? []
        let p = rows.compactMap { r -> FishPack? in
            guard let id = r["id"] as? String, let f = r["fish"] as? Int, f > 0 else { return nil }
            return FishPack(id: id, eur: r["eur"] as? Int ?? 0, fish: f)
        }
        return p.isEmpty ? defaultPacks : p
    }

    // MARK: prices (server values when known)

    static func price(_ item: String, yearly: Bool) -> Int {
        switch item {
        case "pro": return prices[yearly ? "pro.year" : "pro.month"] ?? (yearly ? 9504 : 990)
        case "max": return prices[yearly ? "max.year" : "max.month"] ?? (yearly ? 56640 : 5900)
        case "credits": return prices["credits"] ?? 300
        default: return prices["skill.month"] ?? 300
        }
    }

    static func itemName(_ item: String) -> String {
        switch item {
        case "pro": return "Pro"
        case "max": return "Max"
        case "x": return "喵推"
        case "agent": return "喵手"
        case "miao": return "喵传"
        case "credits": return "加油包"
        default: return item
        }
    }

    // MARK: device (anti-farm for invites): SHA-256 of IOPlatformUUID + app salt. The raw id never leaves the Mac.

    static let deviceHash: String = {
        var uuid = ""
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if service != 0 {
            if let v = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String { uuid = v }
            IOObjectRelease(service)
        }
        if uuid.isEmpty {
            uuid = UserDefaults.standard.string(forKey: "fish.deviceFallback") ?? UUID().uuidString
            UserDefaults.standard.set(uuid, forKey: "fish.deviceFallback")
        }
        let digest = SHA256.hash(data: Data((uuid + "|ordcat.device.v1").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }()

    // MARK: server

    static func refresh(_ done: (() -> Void)? = nil) {
        guard Account.shared.signedIn else { done?(); return }
        Social.rpc("fish_status", ["p_device": deviceHash]) { o, _ in
            if let s = o as? [String: Any] {
                Fish.total = CatStats.int(s["total"])
                Fish.paid = CatStats.int(s["paid"])
                Fish.reward = CatStats.int(s["reward"])
                Fish.plan = s["plan"] as? String ?? "free"
                var pr: [String: Int] = [:]
                for (k, v) in (s["prices"] as? [String: Any]) ?? [:] { pr[k] = CatStats.int(v) }
                Fish.prices = pr
                Fish.subs = s["subs"] as? [[String: Any]] ?? []
            }
            NotificationCenter.default.post(name: Fish.changed, object: nil)
            done?()
        }
    }

    /// "🐟 1160 条小鱼干（充值 1050 · 奖励 110）"
    static var line: String {
        guard let t = total else { return L10n.t("🐟 小鱼干：—") }
        return L10n.t("🐟 小鱼干：\(t)（充值 \(paid ?? 0) · 奖励 \(reward ?? 0)）")
    }

    static func parseDate(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return d }
        // Postgres json can use a space and a short offset: 2026-12-25 07:42:00.123+00
        let g = DateFormatter()
        g.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm:ss.SSSSSSXXX", "yyyy-MM-dd HH:mm:ss.SSSSSSX", "yyyy-MM-dd HH:mm:ssX", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXX"] {
            g.dateFormat = fmt
            if let d = g.date(from: s) { return d }
        }
        return nil
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Fish plans that are still running, for the 小鱼干 card: "Pro 有效期到 2026-12-25（自动续费）".
    static var subsLine: String {
        let rows: [String] = subs.compactMap { s in
            guard let item = s["item"] as? String, let end = parseDate(s["ends_at"]), end > Date() else { return nil }
            let auto = s["auto_renew"] as? Bool ?? false
            return auto ? "\(itemName(item)) 有效期到 \(day(end))（自动续费）" : "\(itemName(item)) 有效期到 \(day(end))"
        }
        return rows.map { L10n.t($0) }.joined(separator: " · ")
    }

    // MARK: 自定义金额 (same tiers as supabase/functions/_shared/fish.ts; the server recomputes, this is only the preview)

    static let customMin = 5
    static let customMax = 10000

    /// 1 € = 100 fish; ≥ €10 +5 %, ≥ €30 +10 %, ≥ €100 +15 % (floor): €5 = 500, €10 = 1050, €29 = 3045, €100 = 11500.
    static func fishFor(eur: Int) -> Int {
        let pct = eur >= 100 ? 15 : eur >= 30 ? 10 : eur >= 10 ? 5 : 0
        return eur * 100 * (100 + pct) / 100
    }

    /// Whole euros €5 – €10,000, else nil ("7.5", "4", "10001", "" are nil).
    static func customEur(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && $0.isNumber }), t.count <= 4,
              let n = Int(t), n >= customMin, n <= customMax else { return nil }
        return n
    }

    /// "€25 → 2625 条小鱼干（多送 125 条）"
    static func customPreview(_ s: String) -> String {
        guard let e = customEur(s) else { return L10n.t("请输入 €5 – €10,000 的整数金额") }
        let f = fishFor(eur: e), bonus = f - e * 100
        return L10n.t(bonus > 0 ? "€\(e) → \(f) 条小鱼干（多送 \(bonus) 条）" : "€\(e) → \(f) 条小鱼干")
    }

    // MARK: 充值 (Stripe)

    /// Pack chooser (four packs + 自定义金额) → Stripe Checkout in the browser. `status` gets progress lines.
    static func topUp(status: @escaping (String) -> Void) {
        guard Account.shared.signedIn else { status(L10n.t("先登录账号（设置 → 用户）")); return }
        let list = packs
        let a = NSAlert()
        a.messageText = "充值小鱼干"
        a.informativeText = "1 € = 100 条小鱼干，买得多送得多。充值鱼干永久有效，可以开会员和技能，也能在喵副本发任务。通过 Stripe 安全付款。"
        let box = FishTopUpBox(packs: list)
        a.accessoryView = box.view
        a.addButton(withTitle: "去付款")
        a.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var body: [String: Any] = ["item": "fish", "locale": L10n.english ? "en" : "zh"]
        if box.isCustom {
            guard let eur = customEur(box.field.stringValue) else {
                status("⚠️ " + L10n.t("自定义金额要是 €5 – €10,000 之间的整数欧元"))
                return
            }
            body["amount_eur"] = eur
        } else {
            let i = box.pop.indexOfSelectedItem
            guard i >= 0, i < list.count else { return }
            body["pack"] = list[i].id
        }
        status(L10n.t("正在打开付款页面…"))
        Account.shared.request("POST", "/functions/v1/stripe-checkout", json: body) { obj, err in
            let o = obj as? [String: Any]
            if let u = (o?["url"] as? String).flatMap(URL.init(string:)) {
                NSWorkspace.shared.open(u)
                status(L10n.t("在浏览器里付完款回来就好，小鱼干会自动到账。"))
                // Watch for the fish to land (≤ 3 min), then say so; a gentle note if the order wasn't finished.
                PayWatch.start(.fish, link: CheckoutLink(url: u, id: o?["id"] as? String, portal: false, reason: nil, opened: Date()))
            } else {
                status("⚠️ " + L10n.t((o?["error"] as? String) ?? err ?? "付款服务还没开通"))
            }
        }
    }

    // MARK: 用小鱼干买

    /// Ask with OCConfirm, then spend. item: pro | max | x | agent | miao | credits.
    static func buy(_ item: String, yearly: Bool = false, autoRenew: Bool = false,
                    status: @escaping (String) -> Void, done: (() -> Void)? = nil) {
        guard Account.shared.signedIn else { status(L10n.t("先登录账号（设置 → 用户）")); return }
        Fish.refresh {
            let cost = Fish.price(item, yearly: yearly && (item == "pro" || item == "max"))
            let r = Fish.reward ?? 0, p = Fish.paid ?? 0
            let fromReward = min(r, cost * 30 / 100)
            let needPaid = cost - fromReward
            let name = Fish.itemName(item)
            if p < needPaid {
                let a = NSAlert()
                a.messageText = "充值鱼干不够"
                a.informativeText = "\(name) 要 \(cost) 条小鱼干：奖励鱼干最多抵 30%（这次能抵 \(fromReward) 条），还要 \(needPaid) 条充值鱼干，你现在有 \(p) 条。"
                a.addButton(withTitle: "去充值")
                a.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn { Fish.topUp(status: status) }
                return
            }
            let what: String
            switch item {
            case "credits": what = "加油包 = 1500 条托管模型额度，不过期。"
            case "pro", "max": what = yearly ? "开通 365 天。" : "开通 30 天。"
            default: what = "开通 30 天。"
            }
            let renew = item == "credits" ? "" : (autoRenew ? "到期自动用小鱼干续费，随时可以关。" : "到期不自动续费。")
            guard OCConfirm.ask("用小鱼干买\(name)？",
                                L10n.t("要 \(cost) 条小鱼干：奖励鱼干 \(fromReward) 条 + 充值鱼干 \(needPaid) 条。") + L10n.t(what)
                                    + (renew.isEmpty ? "" : L10n.t(renew)),
                                ok: "确认购买") else { return }
            status(L10n.t("正在购买…"))
            Social.rpc("fish_buy", ["p_item": item, "p_interval": yearly ? "year" : "month", "p_auto": autoRenew]) { o, e in
                if let e = e { status("⚠️ " + L10n.t(e)); return }
                let res = o as? [String: Any] ?? [:]
                if let end = Fish.parseDate(res["ends_at"]) {
                    status(L10n.t("✅ \(name) 已开通，到 \(Fish.day(end))"))
                } else {
                    status(L10n.t("✅ 已买好\(name)"))
                }
                Fish.refresh()
                Account.shared.pull()
                done?()
            }
        }
    }

    /// Turn auto-renew on or off for every running fish plan / skill.
    static func setAutoRenew(_ on: Bool, status: @escaping (String) -> Void) {
        let items: [String] = subs.compactMap { s in
            guard let item = s["item"] as? String, let end = parseDate(s["ends_at"]), end > Date() else { return nil }
            return item
        }
        guard !items.isEmpty else { return }
        var left = items.count
        for item in items {
            Social.rpc("fish_set_autorenew", ["p_item": item, "p_on": on]) { _, e in
                if let e = e { status("⚠️ " + L10n.t(e)) }
                left -= 1
                if left == 0 { Fish.refresh() }
            }
        }
    }

    // MARK: 流水

    static func reasonText(_ r: String) -> String {
        if r.hasPrefix("buy:") || r.hasPrefix("renew:") {
            let rest = r.split(separator: ":").last.map(String.init) ?? ""
            let parts = rest.split(separator: ".").map(String.init)
            let item = itemName(parts.first ?? "")
            let year = parts.count > 1 && parts[1] == "year"
            if r.hasPrefix("renew:") { return year ? "小鱼干自动续费 \(item)（年付）" : "小鱼干自动续费 \(item)" }
            if parts.first == "credits" { return "买加油包" }
            return year ? "用小鱼干开通 \(item)（年付）" : "用小鱼干开通 \(item)"
        }
        switch r {
        case "welcome": return "新账号礼物"
        case "invite": return "邀请奖励"
        case "invite_topup": return "好友充值奖励"
        case "topup": return "充值"
        case "post": return "发布喵副本任务"
        case "refund": return "任务取消退回"
        case "reward": return "喵副本任务奖励"
        case "raid_post": return "发起组队副本"
        case "raid_pay": return "组队副本报酬"
        case "raid_usage": return "借猫报酬"
        case "raid_refund": return "组队副本退回"
        case "raid_appeal_fee": return "副本申诉费"
        case "raid_bonus": return "副本完成奖励"
        default: return r
        }
    }
}

/// 充值 window body: the four packs, then 「自定义金额」 (whole euros €5 – €10,000) with a live "€X → Y 条小鱼干" preview.
/// Typing an amount selects 自定义金额 by itself.
private final class FishTopUpBox: NSObject, NSTextFieldDelegate {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 112))
    let pop = NSPopUpButton(frame: NSRect(x: 0, y: 84, width: 460, height: 26), pullsDown: false)
    let field = NSTextField(frame: NSRect(x: 132, y: 52, width: 100, height: 22))
    private let preview = NSTextField(labelWithString: "")
    private let customIndex: Int

    init(packs: [FishPack]) {
        customIndex = packs.count
        super.init()
        for p in packs {
            let bonus = p.fish - p.eur * 100
            pop.addItem(withTitle: L10n.t(bonus > 0 ? "€\(p.eur) · \(p.fish) 条（多送 \(bonus) 条）" : "€\(p.eur) · \(p.fish) 条"))
        }
        pop.addItem(withTitle: L10n.t("自定义金额"))
        pop.selectItem(at: min(1, max(0, packs.count - 1)))
        pop.target = self
        pop.action = #selector(popChanged)

        let label = NSTextField(labelWithString: L10n.t("自定义金额（€）"))
        label.frame = NSRect(x: 0, y: 54, width: 128, height: 18)
        field.placeholderString = "5 – 10000"
        field.delegate = self
        preview.frame = NSRect(x: 0, y: 4, width: 480, height: 40)
        preview.font = .systemFont(ofSize: 12)
        preview.lineBreakMode = .byWordWrapping
        preview.maximumNumberOfLines = 2
        preview.preferredMaxLayoutWidth = 480
        for v in [pop, label, field, preview] as [NSView] { view.addSubview(v) }
        update()
    }

    var isCustom: Bool { pop.indexOfSelectedItem == customIndex }

    @objc private func popChanged() {
        update()
        if isCustom { field.window?.makeFirstResponder(field) }
    }

    func controlTextDidChange(_ obj: Notification) {
        if !isCustom { pop.selectItem(at: customIndex) }
        update()
    }

    private func update() {
        let text = field.stringValue
        if isCustom {
            preview.stringValue = Fish.customPreview(text)
            preview.textColor = !text.isEmpty && Fish.customEur(text) == nil ? .systemRed : .labelColor
        } else {
            preview.stringValue = L10n.t("自定义金额：€5 – €10,000 整数；满 €10 多送 5%，满 €30 多送 10%，满 €100 多送 15%")
            preview.textColor = .secondaryLabelColor
        }
    }
}

/// 流水 window: every change to your 小鱼干, newest first.
final class FishLedgerWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = FishLedgerWindow()
    private var win: NSWindow?
    private let table = NSTableView()
    private let head = SK.WrapLabel("", size: 12.5, secondary: false)
    private var rows: [[String: Any]] = []

    func show() {
        if win == nil { build() }
        load()
        win?.center()
        NSApp.activate(ignoringOtherApps: true)
        win?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "小鱼干充值记录"
        w.minSize = NSSize(width: 420, height: 300)
        w.isReleasedWhenClosed = false
        for (id, title, width) in [("time", "时间", 140.0), ("delta", "变动", 80.0), ("kind", "类型", 90.0), ("reason", "说明", 220.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = L10n.t(title)
            c.width = CGFloat(width)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(head)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            head.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            head.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        w.contentView = root
        win = w
    }

    private func load() {
        head.stringValue = Fish.line
        Fish.refresh { [weak self] in self?.head.stringValue = Fish.line }
        Social.rpc("fish_history", ["p_limit": 300]) { [weak self] o, e in
            guard let self = self else { return }
            if let e = e { self.head.stringValue = "⚠️ " + e; return }
            self.rows = o as? [[String: Any]] ?? []
            self.table.reloadData()
            if self.rows.isEmpty { self.head.stringValue = Fish.line + "\n" + L10n.t("还没有流水") }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let r = rows[row]
        var text = ""
        var color = NSColor.labelColor
        switch id {
        case "time":
            if let d = Fish.parseDate(r["created_at"]) {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
                text = f.string(from: d)
            }
            color = .secondaryLabelColor
        case "delta":
            let n = CatStats.int(r["delta"])
            text = n > 0 ? "+\(n)" : "\(n)"
            color = n > 0 ? .systemGreen : .labelColor
        case "kind":
            text = L10n.t((r["kind"] as? String) == "paid" ? "充值鱼干" : "奖励鱼干")
        default:
            text = L10n.t(Fish.reasonText(r["reason"] as? String ?? ""))
        }
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 12)
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        return f
    }
}
