// OrdCat — 设置 → 用户 → 会员 / 技能 / 小鱼干和加油包 (v0.2.64), plus the check after a Stripe checkout.
//
// Modelled on ChatGPT / Claude / Cursor plan pages: one "current plan" card, one plan picker (Free / Pro / Max side
// by side, monthly / yearly toggle with the yearly saving), one clear button per plan (开通 / 升级 / 降级 / 当前方案),
// banners for a failed renewal (past_due) and a cancelled plan, skills and add-ons in their own sections.
// Switching plans never opens a second checkout: stripe-checkout answers with the Stripe Portal for anyone who already
// has a plan, where upgrades are prorated right away and downgrades happen at the end of the period.
// All text goes through L10n.t (Look.swift has the English).

import Cocoa

struct CheckoutLink {
    let url: URL
    let id: String?          // cs_… for a Checkout Session; nil for the Portal
    let portal: Bool
    let reason: String?      // stripe-checkout: switch | current | pay_first | manage | payment | cancel
    let opened: Date
}

/// Prices in cents, VAT included (same table as stripe-checkout PLAN_CENTS and the website).
enum PlanPrice {
    static let month: [String: Int] = ["pro": 990, "max": 5900]
    static let year: [String: Int] = ["pro": 9500, "max": 56600]
    static let skill = 300, skillMember = 240
    static func eur(_ cents: Int) -> String {
        cents % 100 == 0 ? "€\(cents / 100)" : String(format: "€%.2f", Double(cents) / 100)
    }
}

/// The account's plan right now, from the subscription rows (Stripe or Dried Fish).
struct PlanState: Equatable {
    var plan = "free"            // free | pro | max
    var provider = ""            // stripe | fish | lemon
    var status = ""
    var interval: String?        // month | year
    var renewsAt: Date?
    var endsAt: Date?
    var cancelling = false
    var amountCents: Int?
    var pastDue: Bool { status == "past_due" || status == "unpaid" }
    var isStripe: Bool { provider == "stripe" }
    var isFree: Bool { plan == "free" }

    static func current() -> PlanState {
        var best: PlanState?
        for r in Account.shared.subRows {
            guard let skill = r["skill"] as? String, skill == "pro" || skill == "max" else { continue }
            let status = r["status"] as? String ?? ""
            if ["canceled", "cancelled", "expired", "incomplete_expired"].contains(status) { continue }
            let ends = Fish.parseDate(r["ends_at"]), renews = Fish.parseDate(r["renews_at"])
            if let e = ends ?? renews, e < Date() { continue }
            var s = PlanState()
            s.plan = skill
            s.provider = r["provider"] as? String ?? "stripe"
            s.status = status
            s.interval = (r["billing_interval"] as? String) ?? (r["fish_interval"] as? String)
            s.renewsAt = renews
            s.endsAt = ends
            if s.provider == "fish" { s.cancelling = !((r["auto_renew"] as? Bool) ?? false) }
            else { s.cancelling = (r["cancel_at_period_end"] as? Bool) ?? (renews == nil && ends != nil) }
            let cents = CatStats.int(r["amount_cents"])
            s.amountCents = cents > 0 ? cents : nil
            if let b = best {
                let better = (s.plan == "max" && b.plan != "max") || (s.plan == b.plan && s.isStripe && !b.isStripe)
                if !better { continue }
            }
            best = s
        }
        return best ?? PlanState()
    }

    /// Any Stripe subscription (plan or skill) → the Portal has something to manage.
    static var hasStripe: Bool { Account.shared.subRows.contains { ($0["provider"] as? String ?? "stripe") == "stripe" } }
}

func ocDay(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = L10n.english ? "d MMM yyyy" : "yyyy年M月d日"
    if L10n.english { f.locale = Locale(identifier: "en_GB") }
    return f.string(from: d)
}

// MARK: - after checkout

/// Polls the account for up to 3 minutes after a checkout / portal visit and says what changed.
/// Stops on the first change or at the timeout (low power: 5 s for the first minute, then 10 s).
enum PayWatch {
    enum Kind { case plan(String), skill(String), fish, portal }
    private struct Snap: Equatable {
        var plan: PlanState
        var skills: [String]
        var fishPaid: Int
    }
    private static var kind: Kind = .portal
    private static var link: CheckoutLink?
    private static var base: Snap?
    private static var started = Date()
    private static var timer: Timer?
    private static var generation = 0

    private static func snap() -> Snap {
        let skills = ["x", "agent", "miao"].filter { (Account.shared.subscribedUntil($0) ?? .distantPast) > Date() }
        return Snap(plan: PlanState.current(), skills: skills, fishPaid: Fish.paid ?? 0)
    }

    private static func reload(_ done: @escaping () -> Void) {
        var left = 2
        let one = { left -= 1; if left == 0 { done() } }
        Account.shared.refreshSubscriptions { one() }
        Fish.refresh { one() }
    }

    static func start(_ k: Kind, link l: CheckoutLink) {
        timer?.invalidate()
        generation += 1
        let gen = generation
        kind = k; link = l; base = nil; started = Date()
        reload {
            guard gen == PayWatch.generation else { return }
            PayWatch.base = PayWatch.snap()
            PayWatch.schedule(gen)
        }
    }

    private static func schedule(_ gen: Int) {
        let age = Date().timeIntervalSince(started)
        timer = Timer.scheduledTimer(withTimeInterval: age < 60 ? 5 : 10, repeats: false) { _ in PayWatch.tick(gen) }
    }

    private static func tick(_ gen: Int) {
        guard gen == generation, let b = base else { return }
        reload {
            guard gen == PayWatch.generation else { return }
            let now = PayWatch.snap()
            if let msg = PayWatch.success(from: b, to: now) {
                PayWatch.stop()
                if let m = msg.0 { PayWatch.showSuccess(title: m, detail: msg.1) }
                return
            }
            if Date().timeIntervalSince(PayWatch.started) > 180 {
                PayWatch.stop()
                if case .portal = PayWatch.kind { return }
                if let l = PayWatch.link, !l.portal { PayWatch.showNotFinished(l) }
                return
            }
            PayWatch.schedule(gen)
        }
    }

    static func stop() { timer?.invalidate(); timer = nil; generation += 1 }

    /// (alert title or nil for a silent refresh, amber headline) when something landed.
    private static func success(from a: Snap, to b: Snap) -> (String?, String)? {
        switch kind {
        case .fish:
            guard b.fishPaid > a.fishPaid else { return nil }
            return (L10n.t("付款成功"), L10n.t("+\(b.fishPaid - a.fishPaid) 条小鱼干"))
        case .skill(let id):
            guard b.skills.contains(id), !a.skills.contains(id) else { return nil }
            return (L10n.t("付款成功"), L10n.t("\(Fish.itemName(id)) 已开通"))
        case .plan, .portal:
            let p = b.plan, o = a.plan
            if p.plan != o.plan {
                if p.isFree { return (nil, "") }
                let name = (MemberTier(p.plan) ?? .pro).name
                let up = o.isFree ? L10n.t("\(name) 已开通") : (p.plan == "max" ? L10n.t("已升级到 \(name)") : L10n.t("已换成 \(name)"))
                return (L10n.t(o.isFree ? "付款成功" : "方案已更新"), up)
            }
            if !p.isFree, p.interval != o.interval, p.interval != nil {
                return (L10n.t("方案已更新"), L10n.t(p.interval == "year" ? "已改为年付" : "已改为月付"))
            }
            if case .portal = kind, p != o || b.skills != a.skills { return (nil, "") }   // cancel / resume / card: just refresh
            return nil
        }
    }

    private static func showSuccess(title: String, detail: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = "已经可以用了。确认邮件会发到你付款时填的邮箱。"
        let l = NSTextField(labelWithString: detail)
        l.font = .systemFont(ofSize: 17, weight: .bold)
        l.textColor = kAmber
        l.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        a.accessoryView = l
        a.addButton(withTitle: "好")
        let id = link?.id
        if id != nil { a.addButton(withTitle: "查看结算单") }
        NotifCenter.shared.add("🎉 " + title + " · " + detail, open: "account")
        if a.runModal() == .alertSecondButtonReturn, let s = id, let u = URL(string: "https://ordcat.de/thanks.html?session_id=\(s)") {
            NSWorkspace.shared.open(u)
        }
    }

    /// One gentle notice per checkout. Doesn't bring OrdCat to the front; it waits behind the browser.
    private static func showNotFinished(_ l: CheckoutLink) {
        let a = NSAlert()
        a.messageText = "这笔订单还没完成，没有扣款。要继续付款吗？"
        a.informativeText = "如果你其实已经付了款，可能还在处理中，到账后会自动生效。"
        let fresh = Date().timeIntervalSince(l.opened) < 23 * 3600      // Stripe Checkout pages last 24 hours
        a.addButton(withTitle: fresh ? "继续付款" : "好")
        a.addButton(withTitle: "算了").keyEquivalent = "\u{1b}"
        if a.runModal() == .alertFirstButtonReturn && fresh {
            NSWorkspace.shared.open(l.url)
            start(kind, link: l)
        }
    }
}

// MARK: - plan card

private final class PlanCard: NSView {
    let id: String
    private var on = false
    let name = SK.WrapLabel("", size: 15, secondary: false, weight: .bold)
    let price = SK.WrapLabel("", size: 18, secondary: false, weight: .bold)
    let sub = SK.WrapLabel("", size: 11)
    let features = SK.WrapLabel("", size: 11.5)
    let button = OCButton(title: "", target: nil, action: nil)

    init(id: String) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let col = NSStackView(views: [name, price, sub, features, button])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        col.setCustomSpacing(10, after: features)
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        for v in [name, price, sub, features] as [NSView] { v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
        button.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        button.bezelStyle = .rounded
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            col.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)])
        let b = button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        b.priority = .init(250)
        b.isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor
            layer?.borderColor = on ? kAmber.cgColor : NSColor.separatorColor.cgColor
        }
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = on ? 1.5 : 0.5
    }
    /// Amber outline on the plan the account has now.
    func highlight(_ v: Bool) { on = v; needsDisplay = true; needsLayout = true; updateLayer() }
}

// MARK: - the section

final class MembershipSection: NSObject {
    private let acc = Account.shared
    var onOpenSkills: (() -> Void)?

    private let bannerText = SK.WrapLabel("", size: 12.5, secondary: false)
    private let bannerBtn = OCButton(title: "更新付款方式", target: nil, action: nil)
    private let banner = SK.Group()
    private let planTitle = SK.WrapLabel("", size: 15, secondary: false, weight: .bold)
    private let planLines = SK.WrapLabel("", size: 12)
    private let manageBtn = OCButton(title: "管理订阅", target: nil, action: nil)
    private let cycle = NSSegmentedControl(labels: ["月付", "年付 · 省 20%"], trackingMode: .selectOne, target: nil, action: nil)
    private let cycleNote = SK.WrapLabel("", size: 11.5)
    private let cards = ["free", "pro", "max"].map { PlanCard(id: $0) }
    private let status = SK.WrapLabel()
    private let skillLines = SK.WrapLabel("", size: 12.5, secondary: false)
    private let skillBuy = OCButton(title: "订阅技能", target: nil, action: nil)
    private let fishLine = SK.WrapLabel("", size: 12.5, secondary: false)
    private let fishAuto = NSButton(checkboxWithTitle: "用小鱼干开通的会员和技能到期自动续费", target: nil, action: nil)
    private let addonStatus = SK.WrapLabel()
    private var credits: [String: Any]?
    private var bannerAction: (() -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: Fish.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refreshAddons()
        }
    }

    private func btn(_ t: String, _ sel: Selector) -> NSButton { SK.button(t, self, sel) }

    func build(into p: SK.Page) {
        // ---------- 会员 ----------
        p.header("会员")
        bannerBtn.target = self; bannerBtn.action = #selector(bannerTapped)
        bannerText.textColor = .labelColor
        banner.add(SK.info(bannerText, bannerBtn))
        banner.isHidden = true
        p.add(banner)

        manageBtn.target = self; manageBtn.action = #selector(manage)
        let gm = SK.Group()
        let head = NSStackView(views: [planTitle, planLines])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 3
        planTitle.widthAnchor.constraint(equalTo: head.widthAnchor).isActive = true
        planLines.widthAnchor.constraint(equalTo: head.widthAnchor).isActive = true
        gm.add(SK.info(head, manageBtn))
        p.add(gm)

        cycle.selectedSegment = 1            // 主推年付（Lang 2026-11-24）
        cycle.target = self; cycle.action = #selector(cycleChanged)
        ocStyleTabs(cycle)
        let cyc = NSStackView(views: [cycle, cycleNote])
        cyc.spacing = 10
        cyc.alignment = .centerY
        p.add(cyc, full: false, gap: 8)

        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = 10
        for c in cards {
            c.button.target = self
            c.button.action = #selector(cardTapped(_:))
            c.button.identifier = NSUserInterfaceItemIdentifier(c.id)
            c.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        }
        p.add(row)
        p.hint("价格含增值税，通过 Stripe 安全付款。升级马上生效，差价按当期剩余天数折算；降级和取消在当期结束时生效，之前照常使用。")
        p.add(status)

        // ---------- 技能 ----------
        p.header("技能")
        let gs = SK.Group()
        gs.add(SK.info(skillLines))
        p.add(gs)
        p.hint("技能单独订阅，任何会员都不包含：每个 €3/月，Pro / Max 会员 €2.4/月（8 折）。也可以用小鱼干开。")
        skillBuy.target = self; skillBuy.action = #selector(buySkill)
        p.add(SK.buttons([skillBuy, btn("用小鱼干开技能", #selector(fishSkill)), btn("技能设置", #selector(openSkills))]))

        // ---------- 小鱼干和加油包 ----------
        p.header("小鱼干和加油包")
        let gf = SK.Group()
        gf.add(SK.info(fishLine))
        p.add(gf)
        p.hint("1 € = 100 条小鱼干，买得多送得多，永久有效。充值鱼干什么都能买；奖励鱼干（新号、邀请、喵副本奖励）在喵副本里随便用，开会员、技能和加油包时最多抵 30%。加油包 = 300 条小鱼干换 1500 条托管消息，不过期。")
        p.add(SK.buttons([btn("充值小鱼干", #selector(fishTopUp)), btn("买加油包", #selector(buyTopup)),
                          btn("用小鱼干开会员", #selector(fishPlan)), btn("流水", #selector(fishLedger)),
                          btn("刷新", #selector(refreshAll))]))
        fishAuto.target = self; fishAuto.action = #selector(fishAutoChanged)
        fishAuto.state = Prefs.d.bool(forKey: "fish.autoRenew") ? .on : .off
        fishAuto.font = .systemFont(ofSize: 12)
        p.add(SK.buttons([fishAuto]))
        p.add(addonStatus)
        refresh()
    }

    // MARK: refresh

    func refresh() {
        refreshPlan()
        refreshSkills()
        refreshAddons()
        guard acc.signedIn else { credits = nil; refreshPlan(); return }
        acc.credits { [weak self] o, _ in
            self?.credits = o
            self?.refreshPlan()
        }
    }

    private var yearly: Bool { cycle.selectedSegment == 1 }

    private func refreshPlan() {
        let s = PlanState.current()
        // banner
        bannerAction = nil
        if s.isStripe && s.pastDue {
            bannerText.stringValue = L10n.t("⚠️ 上次续费没扣款成功。更新付款方式后 Stripe 会自动重试，期间会员照常可用。")
            bannerBtn.title = "更新付款方式"
            bannerAction = { [weak self] in self?.portal(flow: "payment") }
        } else if s.isStripe && s.cancelling, let end = s.endsAt ?? s.renewsAt {
            bannerText.stringValue = L10n.t("已取消自动续费：\((MemberTier(s.plan) ?? .pro).name) 将于 \(ocDay(end)) 结束，之后回到免费版。")
            bannerBtn.title = "恢复订阅"
            bannerAction = { [weak self] in self?.portal(flow: nil) }
        }
        banner.isHidden = bannerAction == nil

        // current plan card
        var lines: [String] = []
        if !acc.signedIn {
            planTitle.stringValue = L10n.t("免费版")
            lines.append(L10n.t("登录后可以开通会员，也能用小鱼干。"))
        } else if s.isFree {
            planTitle.stringValue = L10n.t("免费版")
            lines.append(L10n.t("用自己的模型 Key，所有功能都能用。"))
        } else {
            let name = (MemberTier(s.plan) ?? .pro).name
            let per = s.interval == "year" ? L10n.t("年付") : (s.interval == "month" ? L10n.t("月付") : "")
            let tag = s.pastDue ? L10n.t("扣款失败") : (s.cancelling ? L10n.t("已取消") : L10n.t("有效"))
            planTitle.stringValue = [name, per, tag].filter { !$0.isEmpty }.joined(separator: " · ")
            if s.provider == "fish" {
                if let e = s.endsAt { lines.append(L10n.t(s.cancelling ? "用小鱼干开通，有效期到 \(ocDay(e))" : "用小鱼干开通，\(ocDay(e)) 自动用小鱼干续费")) }
            } else if s.pastDue {
                lines.append(L10n.t("上次续费没扣款成功，Stripe 会自动重试。"))
            } else if s.cancelling, let e = s.endsAt ?? s.renewsAt {
                lines.append(L10n.t("将于 \(ocDay(e)) 结束，之后回到免费版。"))
            } else if let r = s.renewsAt {
                let amt = s.amountCents.map { " · " + PlanPrice.eur($0) } ?? ""
                lines.append(L10n.t("下次续费：\(ocDay(r))") + amt)
            }
        }
        if let o = credits {
            let left = CatStats.int(o["monthly_left"]), total = CatStats.int(o["monthly_total"])
            let bonus = CatStats.int(o["bonus"])
            let today = CatStats.int(o["today_used"]), cap = CatStats.int(o["daily_cap"])
            if (o["plan"] as? String ?? "free") == "free" {
                lines.append(L10n.t("托管模型试用还剩 \(bonus) 条"))
            } else {
                var l = L10n.t("本月托管消息还剩 \(left) / \(total) 条")
                if let e = Fish.parseDate(o["period_end"]) { l += L10n.t("，\(ocDay(e)) 重置") }
                lines.append(l)
                lines.append(L10n.t("今天已用 \(today) / \(cap) 条 · 加油包余额 \(bonus) 条"))
            }
        }
        planLines.stringValue = lines.joined(separator: "\n")
        manageBtn.isHidden = !(acc.signedIn && PlanState.hasStripe)

        // plan picker
        cycleNote.stringValue = yearly ? L10n.t("年付按月价 × 12 计原价，约 8 折") : ""
        for c in cards { fill(c, s) }
    }

    private func fill(_ c: PlanCard, _ s: PlanState) {
        let y = yearly
        switch c.id {
        case "free":
            c.name.stringValue = L10n.t("免费版")
            c.price.stringValue = "€0"
            c.sub.stringValue = L10n.t("一直免费")
            c.features.stringValue = L10n.t("用自己的模型 Key\n托管模型试用 100 条\n额度用完每天 30 条慢速消息")
        default:
            let m = PlanPrice.month[c.id]!, yr = PlanPrice.year[c.id]!
            c.name.stringValue = c.id == "pro" ? "Pro" : "Max"
            c.price.stringValue = y ? L10n.t("\(PlanPrice.eur(yr))/年") : L10n.t("\(PlanPrice.eur(m))/月")
            c.sub.stringValue = y
                ? L10n.t("折合 \(PlanPrice.eur(Int((Double(yr) / 12).rounded())))/月 · 原价 \(PlanPrice.eur(m * 12)) · 省 \(PlanPrice.eur(m * 12 - yr))")
                : L10n.t("按月付，随时取消")
            c.features.stringValue = c.id == "pro"
                ? L10n.t("每月 3000 条托管消息\n可以看图 · 听写 300 分钟\n技能 8 折")
                : L10n.t("每月 25000 条托管消息\n高级模型 · 听写 1200 分钟\n技能 8 折")
        }
        let (title, enabled) = cta(c.id, s)
        c.button.title = title
        c.button.isEnabled = enabled
        c.button.style = enabled ? (rank(c.id) > rank(s.plan) ? .primary : .secondary) : .neutral
        c.highlight(c.id == s.plan)
    }

    private func rank(_ p: String) -> Int { p == "max" ? 2 : (p == "pro" ? 1 : 0) }

    /// Button text for a plan card, and whether it does something.
    private func cta(_ id: String, _ s: PlanState) -> (String, Bool) {
        let wantInterval = yearly ? "year" : "month"
        if id == "free" {
            if s.isFree { return ("当前方案", false) }
            if s.isStripe && !s.cancelling { return ("降级到免费版", true) }
            if let e = s.endsAt ?? s.renewsAt, s.cancelling { return (L10n.t("\(ocDay(e)) 回到免费版"), false) }
            return ("到期回到免费版", false)
        }
        let name = id == "pro" ? "Pro" : "Max"
        if id == s.plan {
            if s.provider == "fish" { return ("当前方案（小鱼干）", false) }
            if s.cancelling { return ("恢复订阅", true) }
            if let iv = s.interval, iv != wantInterval { return (wantInterval == "year" ? "改为年付" : "改为月付", true) }
            return ("当前方案", false)
        }
        if s.isFree || !s.isStripe { return (L10n.t("开通 \(name)"), true) }
        return (rank(id) > rank(s.plan) ? L10n.t("升级到 \(name)") : L10n.t("降级到 \(name)"), true)
    }

    // MARK: actions

    @objc private func cycleChanged() { refreshPlan() }
    @objc private func bannerTapped() { bannerAction?() }
    @objc private func manage() { portal(flow: nil) }

    @objc private func cardTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        guard acc.signedIn else { status.stringValue = L10n.t("先登录账号（设置 → 用户）"); return }
        let s = PlanState.current()
        let name = id == "pro" ? "Pro" : "Max"
        if id == "free" {
            guard OCConfirm.ask("降级到免费版？", "会打开 Stripe 的取消页面。取消后不再续费，当期结束前照常使用，之后自动回到免费版。结束前随时可以恢复。",
                                ok: "继续") else { return }
            portal(flow: "cancel", item: s.plan)
            return
        }
        if id == s.plan && s.cancelling {
            guard OCConfirm.ask("恢复订阅？", "会打开 Stripe 的订阅管理页面，点「续订」就能恢复，之后照常自动续费。", ok: "继续") else { return }
            portal(flow: nil)
            return
        }
        let m = PlanPrice.month[id]!, yr = PlanPrice.year[id]!
        let price = yearly ? L10n.t("\(PlanPrice.eur(yr))/年（原价 \(PlanPrice.eur(m * 12))，省 \(PlanPrice.eur(m * 12 - yr))）") : L10n.t("\(PlanPrice.eur(m))/月")
        let title: String, info: String
        if s.isFree || !s.isStripe {
            title = L10n.t("开通 \(name)？")
            let what = id == "pro" ? "每月 3000 条托管消息，不用自己的 Key，可以看图，听写 300 分钟，技能 8 折。"
                                   : "每月 25000 条托管消息，可选高级模型，听写 1200 分钟，技能 8 折。"
            info = price + "。" + L10n.t(what) + L10n.t("会打开 Stripe 付款页，付完回到这里，几秒后自动生效。")
        } else if id == s.plan {
            title = yearly ? "改为年付？" : "改为月付？"
            info = L10n.t("新价格：") + price + "。" + L10n.t("会打开 Stripe 的确认页面，确认后从下个计费周期开始，或者按剩余天数折算。")
        } else if rank(id) > rank(s.plan) {
            title = L10n.t("升级到 \(name)？")
            info = price + "。" + L10n.t("会打开 Stripe 的确认页面：马上升级，差价按当期剩余天数折算，不会多出一份订阅。")
        } else {
            title = L10n.t("降级到 \(name)？")
            info = price + "。" + L10n.t("会打开 Stripe 的确认页面：降级在当期结束时生效，之前照常使用现在的方案。")
        }
        guard OCConfirm.ask(title, info, ok: "继续") else { return }
        status.stringValue = L10n.t("正在打开付款页面…")
        acc.stripeLink(item: id, yearly: yearly) { [weak self] link, err in
            guard let self = self else { return }
            guard let l = link else { self.status.stringValue = "⚠️ " + L10n.t(err ?? ""); return }
            NSWorkspace.shared.open(l.url)
            self.status.stringValue = L10n.t(l.portal ? "在 Stripe 页面确认就好，回来后这里会自动更新。"
                                                      : "在浏览器里付完款回来就好，会员会自动生效。")
            PayWatch.start(l.portal ? .portal : .plan(id), link: l)
        }
    }

    private func portal(flow: String?, item: String? = nil) {
        guard acc.signedIn else { status.stringValue = L10n.t("先登录账号（设置 → 用户）"); return }
        status.stringValue = L10n.t("正在打开 Stripe…")
        acc.stripeLink(item: item, portal: true, flow: flow) { [weak self] link, err in
            guard let self = self else { return }
            guard let l = link else { self.status.stringValue = "⚠️ " + L10n.t(err ?? ""); return }
            NSWorkspace.shared.open(l.url)
            self.status.stringValue = L10n.t("在 Stripe 页面确认就好，回来后这里会自动更新。")
            PayWatch.start(.portal, link: l)
        }
    }

    // MARK: skills

    private func refreshSkills() {
        let member = !PlanState.current().isFree
        skillLines.stringValue = ["x", "agent", "miao"].map { id in
            "• " + L10n.t(Fish.itemName(id)) + " · " + L10n.t(Billing.statusLine(id))
        }.joined(separator: "\n") + "\n" + L10n.t(member ? "你是会员：每个技能 €2.4/月。" : "每个技能 €3/月，Pro / Max 会员 €2.4/月。")
        skillBuy.isHidden = !Billing.enabled
    }

    @objc private func buySkill() {
        guard acc.signedIn else { addonStatus.stringValue = L10n.t("先登录账号（设置 → 用户）"); return }
        let member = !PlanState.current().isFree
        let a = NSAlert()
        a.messageText = "订阅技能"
        a.informativeText = member ? "€2.4/月（会员 8 折），通过 Stripe 付款，随时可以取消。" : "€3/月，通过 Stripe 付款，随时可以取消。Pro / Max 会员 €2.4/月。"
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        let ids = ["x", "agent", "miao"]
        for id in ids { pop.addItem(withTitle: L10n.t(Fish.itemName(id))) }
        a.accessoryView = pop
        a.addButton(withTitle: "去付款")
        a.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let i = pop.indexOfSelectedItem
        guard i >= 0, i < ids.count else { return }
        let id = ids[i]
        addonStatus.stringValue = L10n.t("正在打开付款页面…")
        acc.stripeLink(item: id) { [weak self] link, err in
            guard let self = self else { return }
            guard let l = link else { self.addonStatus.stringValue = "⚠️ " + L10n.t(err ?? ""); return }
            NSWorkspace.shared.open(l.url)
            self.addonStatus.stringValue = L10n.t(l.portal ? "这个技能已经订阅了，在 Stripe 页面可以管理。" : "在浏览器里付完款回来就好，技能会自动开通。")
            PayWatch.start(l.portal ? .portal : .skill(id), link: l)
        }
    }

    @objc private func fishSkill() {
        let a = NSAlert()
        a.messageText = "用小鱼干开技能"
        a.informativeText = "每个技能 \(Fish.price("x", yearly: false)) 条小鱼干 / 30 天（Pro / Max 会员 8 折）。奖励鱼干最多抵 30%。"
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        let ids = ["x", "agent", "miao"]
        for id in ids { pop.addItem(withTitle: L10n.t(Fish.itemName(id))) }
        a.accessoryView = pop
        a.addButton(withTitle: "下一步")
        a.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let i = pop.indexOfSelectedItem
        guard i >= 0, i < ids.count else { return }
        Fish.buy(ids[i], autoRenew: fishAutoOn, status: { [weak self] in self?.addonStatus.stringValue = $0 }) { [weak self] in
            self?.refresh()
        }
    }

    @objc private func openSkills() { onOpenSkills?() }

    // MARK: Dried Fish + top-up

    private func refreshAddons() {
        guard acc.signedIn else { fishLine.stringValue = L10n.t("登录后就有小鱼干：新账号送 100 条。"); return }
        var s = Fish.line
        let subs = Fish.subsLine
        if !subs.isEmpty { s += "\n" + subs }
        fishLine.stringValue = s
    }

    private var fishAutoOn: Bool { fishAuto.state == .on }

    @objc private func fishTopUp() { Fish.topUp { [weak self] in self?.addonStatus.stringValue = $0 } }
    @objc private func fishLedger() {
        guard acc.signedIn else { addonStatus.stringValue = L10n.t("先登录账号（设置 → 用户）"); return }
        FishLedgerWindow.shared.show()
    }
    @objc private func buyTopup() {
        Fish.buy("credits", status: { [weak self] in self?.addonStatus.stringValue = $0 }) { [weak self] in self?.refresh() }
    }
    @objc private func fishPlan() {
        let a = NSAlert()
        a.messageText = "用小鱼干开会员"
        a.informativeText = yearly ? "年付：Pro \(Fish.price("pro", yearly: true)) 条，Max \(Fish.price("max", yearly: true)) 条小鱼干（365 天）。奖励鱼干最多抵 30%。"
                                   : "月付：Pro \(Fish.price("pro", yearly: false)) 条，Max \(Fish.price("max", yearly: false)) 条小鱼干（30 天）。奖励鱼干最多抵 30%。"
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        pop.addItem(withTitle: "Pro")
        pop.addItem(withTitle: "Max")
        a.accessoryView = pop
        a.addButton(withTitle: "下一步")
        a.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let item = pop.indexOfSelectedItem == 1 ? "max" : "pro"
        Fish.buy(item, yearly: yearly, autoRenew: fishAutoOn, status: { [weak self] in self?.addonStatus.stringValue = $0 }) { [weak self] in
            self?.refresh()
        }
    }
    @objc private func fishAutoChanged() {
        let on = fishAutoOn
        let running = Fish.subs.contains { (Fish.parseDate($0["ends_at"]) ?? .distantPast) > Date() }
        if running && acc.signedIn {
            let ok = OCConfirm.ask(on ? "到期自动用小鱼干续费？" : "关掉自动续费？",
                                   on ? "用小鱼干开通的会员和技能到期前一天会自动扣小鱼干续上；小鱼干不够就不续，也不会扣钱。"
                                      : "到期后就不再自动扣小鱼干续费。",
                                   ok: on ? "打开" : "关掉")
            if !ok { fishAuto.state = on ? .off : .on; return }
            Fish.setAutoRenew(on) { [weak self] in self?.addonStatus.stringValue = $0 }
        }
        Prefs.d.set(on, forKey: "fish.autoRenew")
    }
    @objc private func refreshAll() {
        addonStatus.stringValue = L10n.t("正在刷新…")
        Fish.refresh()
        acc.pull { [weak self] in
            self?.addonStatus.stringValue = L10n.t("✅ 已刷新")
            self?.refresh()
        }
    }
}
