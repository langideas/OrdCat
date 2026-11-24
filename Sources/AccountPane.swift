// OrdCat — 设置 → 账号.

import Cocoa
import UniformTypeIdentifiers

final class AccountPane: NSObject, NSTextFieldDelegate {
    private let acc = Account.shared
    private let avatar = NSImageView()
    private let nameTag = NSImageView()      // PRO / MAX tag after the level icons
    private let headerName = SK.WrapLabel("", size: 15, secondary: false, weight: .bold)
    private let levelText = NSTextField(labelWithString: "")
    private let levelIcons = NSImageView()
    private let headerStats = SK.WrapLabel("", size: 11.5)
    private let nameField = NSTextField()
    private let userField = NSTextField()
    private let profileStatus = SK.WrapLabel()
    private let userHint = SK.WrapLabel()
    private enum UserState { case none, checking, ok, taken, bad, unknown }
    private var userState: UserState = .none
    private var userCheck: DispatchWorkItem?
    private let loginLine = NSTextField(labelWithString: "")
    private let method = NSSegmentedControl(labels: ["邮箱", "手机号"], trackingMode: .selectOne, target: nil, action: nil)
    private let idField = NSTextField()
    private let codeField = NSTextField()
    private let passField = NSSecureTextField()
    private let loginMode = NSSegmentedControl(labels: ["验证码", "密码"], trackingMode: .selectOne, target: nil, action: nil)
    private let forgotBtn = OCButton(title: "忘记密码？", target: nil, action: nil)
    private let passwordBtn = OCButton(title: "设置密码", target: nil, action: nil)
    private let palsBtn = OCButton(title: "喵友 0", target: nil, action: nil)
    private let followingBtn = OCButton(title: "关注 0", target: nil, action: nil)
    private let sendBtn = OCButton(title: "发送验证码", target: nil, action: nil)
    private let loginBtn = OCButton(title: "登录 / 注册", target: nil, action: nil)
    private let logoutBtn = OCButton(title: "退出登录", target: nil, action: nil)
    private let loginStatus = SK.WrapLabel()
    private let subLines = SK.WrapLabel()
    private let memberLine = SK.WrapLabel()
    private let memberStatus = SK.WrapLabel()
    private let billingCycle = NSSegmentedControl(labels: ["月付", "年付（省 20%）"], trackingMode: .selectOne, target: nil, action: nil)
    private let dataStatus = SK.WrapLabel()
    private var loginFold: SK.Fold?
    var onOpenSkills: (() -> Void)?

    override init() {
        super.init()
        acc.observe { [weak self] in self?.refresh() }
        NotificationCenter.default.addObserver(forName: CatLevel.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refreshHeader()
        }
    }

    private func button(_ t: String, _ sel: Selector) -> NSButton { SK.button(t, self, sel) }
    private func input(_ f: NSTextField, _ placeholder: String) -> NSTextField {
        f.placeholderString = placeholder
        f.font = .systemFont(ofSize: 13)
        f.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    func build(into p: SK.Page) {
        // 个人资料: header card (avatar + 更换头像 | name, level, days), then the fields.
        p.header("个人资料")
        let head = SK.Group()
        head.add(profileHeader())
        p.add(head)
        p.hint("头像和名称会显示在聊天窗口左下角。")
        let g1 = SK.Group()
        g1.add(SK.row("名称", input(nameField, "小猫怎么称呼你")))
        g1.add(SK.row("用户名", input(userField, "字母、数字或下划线")))
        p.add(g1)
        userHint.font = .systemFont(ofSize: 11.5)
        userHint.stringValue = ""
        p.add(userHint)
        userField.delegate = self
        p.add(SK.buttons([button("保存", #selector(saveProfile))], trailing: true))
        p.add(profileStatus)

        // 账号与登录
        p.header("账号与登录")
        loginLine.font = .systemFont(ofSize: 13)
        loginLine.lineBreakMode = .byTruncatingTail
        loginLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        logoutBtn.target = self; logoutBtn.action = #selector(logout)
        logoutBtn.bezelStyle = .rounded
        let g2 = SK.Group()
        g2.add(SK.info(loginLine, logoutBtn))
        p.add(g2)
        method.target = self; method.action = #selector(methodChanged)
        sendBtn.target = self; sendBtn.action = #selector(sendCode)
        sendBtn.bezelStyle = .rounded
        loginBtn.target = self; loginBtn.action = #selector(verify)
        loginBtn.bezelStyle = .rounded
        loginBtn.keyEquivalent = "\r"
        loginMode.target = self; loginMode.action = #selector(loginModeChanged)
        loginMode.selectedSegment = 0
        ocStyleTabs(loginMode)
        method.selectedSegment = 0
        let modes = NSStackView(views: [method, loginMode])
        modes.spacing = 10
        // Code and password share one row; only one shows at a time.
        let cred = NSView()
        cred.translatesAutoresizingMaskIntoConstraints = false
        for f in [input(codeField, "6 位验证码"), passField] as [NSTextField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            cred.addSubview(f)
            NSLayoutConstraint.activate([f.leadingAnchor.constraint(equalTo: cred.leadingAnchor),
                                         f.trailingAnchor.constraint(equalTo: cred.trailingAnchor),
                                         f.centerYAnchor.constraint(equalTo: cred.centerYAnchor)])
        }
        cred.heightAnchor.constraint(equalToConstant: 24).isActive = true
        passField.placeholderString = "密码（至少 8 位）"
        passField.font = .systemFont(ofSize: 13)
        passField.isHidden = true
        forgotBtn.target = self; forgotBtn.action = #selector(forgot)
        forgotBtn.chip = true
        forgotBtn.style = .neutral
        forgotBtn.isHidden = true
        let lg = SK.Group()
        lg.add(SK.row("方式", modes, fill: false))
        lg.add(SK.info(input(idField, ""), sendBtn))
        lg.add(SK.info(cred, loginBtn))
        let fold = SK.Fold(lg)
        loginFold = fold
        p.add(fold)
        p.add(SK.buttons([forgotBtn]))
        passwordBtn.target = self; passwordBtn.action = #selector(changePassword)
        p.add(SK.buttons([passwordBtn]))
        p.add(loginStatus)

        // 会员: 托管模型额度（不用自己的 Key）
        p.header("会员")
        memberLine.font = .systemFont(ofSize: 12.5)
        memberLine.textColor = .labelColor
        billingCycle.selectedSegment = 1      // 主推年付（Lang 2026-11-24）
        let gm = SK.Group()
        gm.add(SK.info(memberLine))
        gm.add(SK.row("付款方式", billingCycle, fill: false))
        p.add(gm)
        p.add(SK.buttons([button("开通 Pro", #selector(buyPro)), button("开通 Max", #selector(buyMax)),
                          button("加油包", #selector(buyTopup)), button("管理会员", #selector(manageMember))]))
        p.add(memberStatus)

        // 订阅与付款
        p.header("订阅与付款")
        subLines.font = .systemFont(ofSize: 12.5)
        subLines.textColor = .labelColor
        let g3 = SK.Group()
        g3.add(SK.info(subLines))
        p.add(g3)
        p.add(SK.buttons([button("管理订阅", #selector(openSkills)), button("管理付款方式", #selector(openPortal)),
                          button("刷新订阅", #selector(refreshSubs))]))

        // 数据管理
        p.header("数据管理")
        p.add(dataStatus)
        let del = button("注销账号", #selector(deleteAccount))
        del.contentTintColor = .systemRed
        p.add(SK.buttons([button("导出我的数据", #selector(exportData)), button("清除本机数据", #selector(wipeLocal)), del]))
        dataStatus.stringValue = "聊天记录、记忆和刷推记忆都只存在这台 Mac 上。导出会打包到「下载」文件夹；注销会删除云端账号、头像和订阅绑定（已付的订阅请先在「管理付款方式」里取消）。"
        refresh()
    }

    /// Left: 64pt avatar (member ring + eyes chip when subscribed) with 更换头像 under it.
    /// Right: display name, level (Lv N + 猫冠/猫眼/猫瞳/星芒), then days together / to next level / 喵友.
    private func profileHeader() -> NSView {
        let r = NSView()
        r.translatesAutoresizingMaskIntoConstraints = false
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.widthAnchor.constraint(equalToConstant: 64).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let change = button("更换头像", #selector(pickAvatar))
        change.controlSize = .small
        change.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let left = NSStackView(views: [avatar, change])
        left.orientation = .vertical
        left.alignment = .centerX
        left.spacing = 8
        left.translatesAutoresizingMaskIntoConstraints = false
        left.setContentHuggingPriority(.required, for: .horizontal)
        left.setContentCompressionResistancePriority(.required, for: .horizontal)

        levelText.font = .systemFont(ofSize: 13, weight: .semibold)
        levelText.textColor = .labelColor
        levelIcons.imageScaling = .scaleNone
        levelIcons.setContentHuggingPriority(.required, for: .horizontal)
        nameTag.imageScaling = .scaleNone
        nameTag.setContentHuggingPriority(.required, for: .horizontal)
        nameTag.setContentCompressionResistancePriority(.required, for: .horizontal)
        nameTag.isHidden = true
        let levelRow = NSStackView(views: [levelText, levelIcons, nameTag])
        levelRow.spacing = 6
        levelRow.alignment = .centerY
        levelRow.translatesAutoresizingMaskIntoConstraints = false
        palsBtn.target = self; palsBtn.action = #selector(showPals)
        followingBtn.target = self; followingBtn.action = #selector(showFollowing)
        let invite = OCButton(title: "🎁 邀请好友", target: self, action: #selector(showInvite))
        for b in [palsBtn, followingBtn, invite] { b.chip = true; b.style = .secondary }
        palsBtn.toolTip = L10n.t("看看谁关注了你")
        let socialRow = NSStackView(views: [palsBtn, followingBtn, invite])
        socialRow.spacing = 6
        let right = NSStackView(views: [headerName, levelRow, headerStats, socialRow])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 5
        right.translatesAutoresizingMaskIntoConstraints = false
        headerName.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        headerStats.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        levelRow.widthAnchor.constraint(lessThanOrEqualTo: right.widthAnchor).isActive = true

        r.addSubview(left); r.addSubview(right)
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: r.topAnchor, constant: 14),
            left.bottomAnchor.constraint(equalTo: r.bottomAnchor, constant: -14),
            left.leadingAnchor.constraint(equalTo: r.leadingAnchor, constant: 14),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 16),
            right.trailingAnchor.constraint(equalTo: r.trailingAnchor, constant: -14),
            right.centerYAnchor.constraint(equalTo: r.centerYAnchor),
            right.topAnchor.constraint(greaterThanOrEqualTo: r.topAnchor, constant: 14),
            right.bottomAnchor.constraint(lessThanOrEqualTo: r.bottomAnchor, constant: -14)])
        return r
    }

    private func refreshHeader() {
        let tier = CatLevel.tier
        avatar.image = memberAvatar(acc.avatarImage(size: 144), tier: tier, size: 64)
        avatar.toolTip = tier == .none ? nil : tier.name
        headerName.stringValue = acc.profile.displayName
        nameTag.image = memberTagImage(tier, height: 16)
        nameTag.isHidden = tier == .none
        nameTag.toolTip = tier == .none ? nil : tier.name
        let lc = CatLevel.shared
        let lv = lc.level
        levelText.stringValue = "Lv\(lv)"
        levelIcons.image = RankIcon.strip(level: lv, height: 16)
        levelIcons.toolTip = CatLevel.partsText(level: lv)
        let fans = lc.followers
        let following = lc.mine?.following ?? 0
        headerStats.stringValue = L10n.english
            ? "\(lc.days) days together · \(lc.hoursToNextDay)h online to the next day · \(lc.daysToNext) days to next level"
            : "已陪伴 \(lc.days) 天 · 再在线 \(lc.hoursToNextDay) 小时满一天 · 距下一级还差 \(lc.daysToNext) 天"
        headerStats.toolTip = L10n.t("OrdCat 运行满 24 小时算陪伴 1 天，可以分多次累计；Mac 睡眠时不算。")
        palsBtn.title = L10n.english ? "Cat Pals \(fans)" : "喵友 \(fans)"
        followingBtn.title = L10n.english ? "Following \(following)" : "关注 \(following)"
    }

    func refresh() {
        refreshHeader()
        nameField.stringValue = acc.profile.displayName
        userField.stringValue = acc.profile.username
        userState = .none; userHint.stringValue = ""
        loginLine.stringValue = acc.accountLine
        logoutBtn.isHidden = !acc.signedIn
        passwordBtn.isHidden = !acc.signedIn
        passwordBtn.title = acc.hasPassword ? "修改密码" : "设置密码"
        forgotBtn.isHidden = acc.signedIn || loginMode.selectedSegment != 1
        loginFold?.folded = acc.signedIn || !acc.configured
        if !acc.configured {
            loginStatus.stringValue = "邮箱 / 手机号注册即将开放。现在名称和头像先保存在本机，开通后登录会自动同步。"
        } else if acc.signedIn {
            loginStatus.stringValue = "订阅绑定在这个账号上，换一台 Mac 登录同一个账号就能继续用。"
        }
        methodChanged()
        var lines: [String] = ["基础功能（聊天、语音、分享页面、桌面感知、记忆）一直免费。"]
        for (id, name) in [("x", "喵推"), ("agent", "喵手")] {
            lines.append("• \(name)：\(Billing.statusLine(id))")
        }
        subLines.stringValue = lines.joined(separator: "\n")
        refreshMember()
    }

    // MARK: 会员

    private static let plans: [String: (zh: String, en: String)] = [
        "pro": ("Pro €9.9/月（年付 €95，省 20%）· 每月 3000 条，看图，听写 300 分钟，技能 8 折",
                "Pro €9.9/mo (€95/yr, save 20%) · 3,000 messages a month, image viewing, 300 min dictation, 20% off skills"),
        "max": ("Max €59/月（年付 €566，省 20%）· 每月 25000 条，可选高级模型，听写 1200 分钟，包含全部技能",
                "Max €59/mo (€566/yr, save 20%) · 25,000 messages a month, premium models, 1,200 min dictation, all skills included"),
    ]

    private func refreshMember() {
        let base = L10n.english
            ? "Free: bring your own model key and everything works. Members get OrdCat's hosted models with no key: pick 「OrdCat 托管」 in Settings → Model."
            : "免费版：填自己的模型 Key，所有功能都能用。会员不用 Key，直接用 OrdCat 托管模型（设置 → 模型 选「OrdCat 托管」）。"
        let offer = L10n.english ? "\n• \(AccountPane.plans["pro"]!.en)\n• \(AccountPane.plans["max"]!.en)\n• Top-up: €2.99 for 1,500 messages, never expire"
                                 : "\n• \(AccountPane.plans["pro"]!.zh)\n• \(AccountPane.plans["max"]!.zh)\n• 加油包：€2.99 = 1500 条，不过期"
        guard acc.signedIn else { memberLine.stringValue = base + offer; return }
        acc.credits { [weak self] o, err in
            guard let self = self else { return }
            guard let o = o else { self.memberLine.stringValue = base + offer; return }
            let plan = o["plan"] as? String ?? "free"
            let left = o["monthly_left"] as? Int ?? 0, total = o["monthly_total"] as? Int ?? 0
            let bonus = o["bonus"] as? Int ?? 0
            let today = o["today_used"] as? Int ?? 0, cap = o["daily_cap"] as? Int ?? 0
            var reset = ""
            if let e = o["period_end"] as? String {
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = f.date(from: e) ?? ISO8601DateFormatter().date(from: e) {
                    let df = DateFormatter(); df.dateFormat = L10n.english ? "MMM d" : "M月d日"
                    reset = df.string(from: d)
                }
            }
            var line: String
            switch plan {
            case "pro", "max":
                let name = (MemberTier(plan) ?? .pro).name
                line = L10n.english
                    ? "✨ \(name) · \(left) of \(total) left this month (resets \(reset)) · top-up \(bonus) · today \(today)/\(cap)"
                    : "✨ \(name) · 本月还剩 \(left) / \(total) 条（\(reset) 重置）· 加油包 \(bonus) 条 · 今天已用 \(today) / \(cap)"
            default:
                line = L10n.english ? "Free plan · hosted trial \(bonus) messages left" : "免费版 · 托管模型试用还剩 \(bonus) 条"
                line += offer
            }
            if err != nil { line = base + offer }
            self.memberLine.stringValue = line
        }
    }

    private func openStripe(item: String?, title: String, info: String, portal: Bool = false) {
        guard acc.signedIn else { memberStatus.stringValue = L10n.t("先登录账号（设置 → 用户）"); return }
        guard OCConfirm.ask(title, info, ok: L10n.english ? "Continue" : "去付款") else { return }
        memberStatus.stringValue = L10n.english ? "Opening the payment page…" : "正在打开付款页面…"
        acc.stripeLink(item: item, yearly: billingCycle.selectedSegment == 1, portal: portal) { [weak self] url, err in
            guard let self = self else { return }
            if let u = url {
                NSWorkspace.shared.open(u)
                self.memberStatus.stringValue = L10n.english ? "Finish paying in your browser, then come back here: your plan updates by itself."
                                                             : "在浏览器里付完款回来就好，会员会自动生效（没变就点「刷新订阅」）。"
            } else {
                self.memberStatus.stringValue = "⚠️ " + (err ?? "")
            }
        }
    }

    @objc private func buyPro() {
        let y = billingCycle.selectedSegment == 1
        openStripe(item: "pro", title: L10n.english ? "Get Pro?" : "开通 Pro？",
                   info: L10n.english ? (y ? "€95 a year (save 20%)" : "€9.9 a month") + ". 3,000 messages a month with OrdCat's hosted models, no key needed, image viewing, 300 min dictation, 20% off skills. Paid securely with Stripe; cancel anytime."
                                      : (y ? "€95/年（省 20%）" : "€9.9/月") + "，每月 3000 条托管模型额度，不用自己的 Key，可以看图，听写 300 分钟，技能 8 折。通过 Stripe 安全付款，随时可以取消。")
    }

    @objc private func buyMax() {
        let y = billingCycle.selectedSegment == 1
        openStripe(item: "max", title: L10n.english ? "Get Max?" : "开通 Max？",
                   info: L10n.english ? (y ? "€566 a year (save 20%)" : "€59 a month") + ". 25,000 messages a month, premium models, 1,200 min dictation, and every skill included. Paid securely with Stripe; cancel anytime."
                                      : (y ? "€566/年（省 20%）" : "€59/月") + "，每月 25000 条额度，可选高级模型，听写 1200 分钟，包含全部技能。通过 Stripe 安全付款，随时可以取消。")
    }

    @objc private func buyTopup() {
        openStripe(item: "topup", title: L10n.english ? "Buy a top-up?" : "买一个加油包？",
                   info: L10n.english ? "€2.99 for 1,500 messages that never expire, used after your monthly credits." : "€2.99 = 1500 条，不过期，月额度用完后自动接着用。")
    }

    @objc private func manageMember() {
        openStripe(item: nil, title: L10n.english ? "Manage membership?" : "管理会员？",
                   info: L10n.english ? "Opens Stripe's page to change plan, update your card, see invoices or cancel."
                                      : "打开 Stripe 的管理页面：换方案、换卡、看发票或取消订阅。", portal: true)
    }

    @objc private func methodChanged() {
        idField.placeholderString = method.selectedSegment == 0 ? "you@example.com" : "手机号，例如 0912345678"
    }

    @objc private func pickAvatar() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = "选一张图片做头像"
        guard p.runModal() == .OK, let u = p.url else { return }
        guard OCConfirm.ask("用这张图片做头像？", "头像会显示在聊天窗口、猫帮圈和信号站里\(acc.signedIn ? "，并同步到你的账号" : "")。",
                            ok: "换上", icon: NSImage(contentsOf: u)) else { return }
        profileStatus.stringValue = "正在保存…"
        acc.setAvatar(from: u) { [weak self] err in self?.profileStatus.stringValue = err ?? "✅ 头像已更新" }
    }

    @objc private func saveProfile() {
        let n = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
        if userState == .taken { profileStatus.stringValue = "⚠️ 这个用户名已经有人用了，换一个吧"; return }
        if userState == .bad { profileStatus.stringValue = "⚠️ 用户名只能用 3–20 个字母、数字或下划线"; return }
        let changes = OCConfirm.diff([("名称", acc.profile.displayName, n),
                                      ("用户名", acc.profile.username.isEmpty ? "" : "@" + acc.profile.username, u.isEmpty ? "" : "@" + u)])
        guard !changes.isEmpty else { profileStatus.stringValue = "没有改动"; return }
        guard OCConfirm.ask("保存个人资料？", changes, ok: "保存") else { return }
        profileStatus.stringValue = "正在保存…"
        acc.update(displayName: nameField.stringValue, username: userField.stringValue) { [weak self] err in
            self?.profileStatus.stringValue = err ?? "✅ 已保存"
        }
    }

    private var isEmail: Bool { method.selectedSegment == 0 }
    private var idValue: String { idField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    @objc private func sendCode() {
        let v = idValue
        if isEmail && !(v.contains("@") && v.contains(".")) { loginStatus.stringValue = "邮箱格式不对"; return }
        if !isEmail && v.filter({ $0.isNumber }).count < 8 { loginStatus.stringValue = "手机号不对"; return }
        guard OCConfirm.ask("把验证码发到 \(v)？", isEmail ? "去邮箱查收 6 位验证码，填进来就能登录；没有账号会自动注册。" : "短信会收到 6 位验证码，填进来就能登录；没有账号会自动注册。",
                            ok: "发送") else { return }
        sendBtn.isEnabled = false
        loginStatus.stringValue = "正在发送…"
        acc.sendCode(email: isEmail ? v : nil, phone: isEmail ? nil : v) { [weak self] err in
            guard let self = self else { return }
            self.loginStatus.stringValue = err.map { "⚠️ " + $0 } ?? "✅ 验证码已发出，\(self.isEmail ? "去邮箱" : "看短信")查收，填在下面。"
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.sendBtn.isEnabled = true }
        }
    }

    @objc private func loginModeChanged() {
        let pw = loginMode.selectedSegment == 1
        passField.isHidden = !pw
        codeField.isHidden = pw
        sendBtn.isHidden = pw
        forgotBtn.isHidden = !pw || acc.signedIn
        loginStatus.stringValue = pw ? L10n.t("设置过密码的账号可以直接用密码登录。") : ""
    }

    @objc private func forgot() {
        loginMode.selectedSegment = 0
        loginModeChanged()
        loginStatus.stringValue = L10n.t("忘记密码：先用验证码登录，登录后点「修改密码」设一个新的。")
    }

    @objc private func changePassword() {
        let change = acc.hasPassword
        let cur = NSSecureTextField(), new1 = NSSecureTextField(), new2 = NSSecureTextField()
        cur.placeholderString = L10n.t("当前密码")
        new1.placeholderString = L10n.t("新密码（8 到 72 位）")
        new2.placeholderString = L10n.t("再输一次新密码")
        let fields: [NSTextField] = change ? [cur, new1, new2] : [new1, new2]
        // 格式要求 + 实时检查（v0.2.51）
        let rules = NSTextField(wrappingLabelWithString: L10n.t(change
            ? "密码要求：8 到 72 位，字母、数字、符号都可以，区分大小写，不能和旧密码一样。建议字母加数字。"
            : "密码要求：8 到 72 位，字母、数字、符号都可以，区分大小写。建议字母加数字。"))
        rules.font = .systemFont(ofSize: 11)
        rules.textColor = .secondaryLabelColor
        let check = NSTextField(labelWithString: "")
        check.font = .systemFont(ofSize: 11)
        let box = NSStackView(views: fields + [rules, check])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 8
        box.frame = NSRect(x: 0, y: 0, width: 260, height: CGFloat(fields.count) * 30 + 64)
        for v in (fields as [NSView]) + [rules, check] { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        let a = NSAlert()
        a.messageText = change ? "修改密码" : "设置密码"
        a.informativeText = change ? "忘了当前密码？退出后用验证码登录，再来这里设新密码（不用填当前密码）。"
                                   : "设好后可以用邮箱 / 手机号 + 密码登录，验证码登录也照样能用。"
        a.accessoryView = box
        let save = a.addButton(withTitle: "保存")
        a.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        a.window.initialFirstResponder = fields.first
        func recheck() {
            let p = new1.stringValue, n = p.count
            var lines: [String] = []
            lines.append(n == 0 ? "○ " + L10n.t("8 到 72 位") : (n >= 8 && n <= 72 ? "✓ " : "✗ ") + L10n.t("8 到 72 位") + "（\(n)）")
            if !new2.stringValue.isEmpty { lines.append((p == new2.stringValue ? "✓ " : "✗ ") + L10n.t("两次输入一致")) }
            check.stringValue = lines.joined(separator: "   ")
            let ok = n >= 8 && n <= 72 && p == new2.stringValue
            check.textColor = ok ? .systemGreen : .secondaryLabelColor
            save.isEnabled = ok
        }
        recheck()
        let obs = fields.map { f in
            NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: f, queue: .main) { _ in recheck() }
        }
        let answer = a.runModal()
        obs.forEach { NotificationCenter.default.removeObserver($0) }
        guard answer == .alertFirstButtonReturn else { return }
        guard new1.stringValue.count >= 8, new1.stringValue.count <= 72 else { loginStatus.stringValue = "⚠️ " + L10n.t("密码要 8 到 72 位"); return }
        guard new1.stringValue == new2.stringValue else { loginStatus.stringValue = "⚠️ " + L10n.t("两次输入的新密码不一样"); return }
        loginStatus.stringValue = L10n.t("正在保存…")
        // Fresh code login (forgot flow) may change without the old password; otherwise check it.
        let current = change && !cur.stringValue.isEmpty ? cur.stringValue : nil
        acc.setPassword(new1.stringValue, current: current) { [weak self] err in
            self?.loginStatus.stringValue = err.map { "⚠️ " + $0 } ?? L10n.t("✅ 密码已保存")
            self?.refresh()
        }
    }

    @objc private func showPals() { FollowListWindow.shared.show(kind: 0) }
    @objc private func showFollowing() { FollowListWindow.shared.show(kind: 1) }
    @objc private func showInvite() { InviteWindow.shared.show() }

    @objc private func verify() {
        if loginMode.selectedSegment == 1 {
            let pw = passField.stringValue
            guard pw.count >= 6 else { loginStatus.stringValue = L10n.t("先填密码"); return }
            guard OCConfirm.ask(L10n.english ? "Sign in as \(idValue)?" : "用 \(idValue) 登录？", "登录后名称、头像和订阅会同步到这个账号。", ok: "登录") else { return }
            loginStatus.stringValue = "正在登录…"
            acc.signIn(email: isEmail ? idValue : nil, phone: isEmail ? nil : idValue, password: pw) { [weak self] err in
                guard let self = self else { return }
                self.loginStatus.stringValue = err.map { "⚠️ " + $0 } ?? "✅ 登录成功"
                if err == nil { self.passField.stringValue = ""; Prefs.d.set(true, forKey: "account.hasPassword") }
                self.refresh()
            }
            return
        }
        let code = codeField.stringValue.trimmingCharacters(in: .whitespaces)
        guard code.count >= 4 else { loginStatus.stringValue = "先填验证码"; return }
        guard OCConfirm.ask("用 \(idValue) 登录？", "登录后名称、头像和订阅会同步到这个账号。", ok: "登录") else { return }
        loginStatus.stringValue = "正在登录…"
        acc.verify(email: isEmail ? idValue : nil, phone: isEmail ? nil : idValue, code: code) { [weak self] err in
            guard let self = self else { return }
            self.loginStatus.stringValue = err.map { "⚠️ " + $0 } ?? "✅ 登录成功"
            self.codeField.stringValue = ""
            self.refresh()
        }
    }

    @objc private func logout() {
        guard OCConfirm.ask("退出登录？", "本机的聊天记录和设置会保留；订阅和信号站要重新登录才能用。", ok: "退出登录", danger: true) else { return }
        acc.signOut()
        loginStatus.stringValue = "已退出登录"
        refresh()
    }

    @objc private func openSkills() { onOpenSkills?() }

    @objc private func openPortal() {
        if let u = acc.portalURL { NSWorkspace.shared.open(u); return }
        // Lemon Squeezy's buyer page: find orders, update the card, cancel.
        NSWorkspace.shared.open(URL(string: "https://app.lemonsqueezy.com/my-orders")!)
    }

    @objc private func refreshSubs() {
        guard acc.signedIn else {
            Billing.refresh("x"); Billing.refresh("agent"); refresh()
            return
        }
        loginStatus.stringValue = "正在刷新订阅…"
        acc.pull { [weak self] in self?.loginStatus.stringValue = "✅ 订阅已刷新"; self?.refresh() }
    }

    @objc private func exportData() {
        guard OCConfirm.ask("导出我的数据？", "聊天记录、记忆和设置会打包成一个文件，放到「下载」文件夹（不含模型 Key）。", ok: "导出") else { return }
        dataStatus.stringValue = "正在打包…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let out = self?.acc.exportData()
            DispatchQueue.main.async {
                guard let out = out else { self?.dataStatus.stringValue = "⚠️ 导出失败"; return }
                self?.dataStatus.stringValue = "✅ 已导出到：\(out.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([out])
            }
        }
    }

    // MARK: 用户名 live check (format right away, availability after a short pause)

    func controlTextDidChange(_ n: Notification) {
        guard (n.object as? NSTextField) === userField else { return }
        userCheck?.cancel()
        let u = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
        if u.isEmpty || u == acc.profile.username { setUser(.none, ""); return }
        guard Account.validUsername(u) else {
            setUser(.bad, u.count < 3 ? "✗ 至少 3 个字符" : (u.count > 20 ? "✗ 最多 20 个字符" : "✗ 只能用字母、数字或下划线"))
            return
        }
        setUser(.checking, "正在检查…")
        let w = DispatchWorkItem { [weak self] in
            self?.acc.usernameAvailable(u) { ok, err in
                guard let self = self, self.userField.stringValue.replacingOccurrences(of: "@", with: "").trimmingCharacters(in: .whitespaces) == u else { return }
                switch ok {
                case true?: self.setUser(.ok, "✓ @\(u) 可以使用")
                case false?: self.setUser(.taken, "✗ @\(u) 已经被占用了")
                case nil: self.setUser(.unknown, err ?? "格式没问题；联网后会再确认是否被占用")
                }
            }
        }
        userCheck = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
    }

    private func setUser(_ s: UserState, _ text: String) {
        userState = s
        userHint.stringValue = text
        switch s {
        case .ok: userHint.textColor = .systemGreen
        case .taken, .bad: userHint.textColor = .systemRed
        default: userHint.textColor = .secondaryLabelColor
        }
    }

    private func confirm(_ title: String, _ info: String, _ ok: String) -> Bool {
        let a = NSAlert()
        a.alertStyle = .critical
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "取消")
        return a.runModal() == .alertFirstButtonReturn
    }

    @objc private func wipeLocal() {
        guard confirm("清除这台 Mac 上的所有 OrdCat 数据？",
                      "聊天记录、记忆、刷推记忆、头像和所有设置都会删除，模型 Key 也会清掉，小猫会重新启动。无法恢复，建议先导出。",
                      "全部清除") else { return }
        acc.wipeLocalData()
        relaunch()
    }

    @objc private func deleteAccount() {
        if !acc.signedIn {
            if confirm("你还没登录云端账号", "要清除这台 Mac 上的所有 OrdCat 数据吗？", "清除本机数据") {
                acc.wipeLocalData(); relaunch()
            }
            return
        }
        guard confirm("永久注销账号？",
                      "会删除云端账号、个人资料、头像和订阅绑定，并清除本机所有数据。已付费的订阅请先在「管理付款方式」里取消，否则会继续扣费。无法恢复。",
                      "永久注销") else { return }
        dataStatus.stringValue = "正在注销…"
        acc.deleteAccount { [weak self] err in
            guard let self = self else { return }
            if let e = err { self.dataStatus.stringValue = "⚠️ " + e; return }
            self.acc.wipeLocalData()
            self.relaunch()
        }
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "ordcat-relaunch", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
