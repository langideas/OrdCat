// OrdCat — 设置 → 账号.

import Cocoa
import UniformTypeIdentifiers

final class AccountPane: NSObject {
    private let acc = Account.shared
    private let avatar = NSImageView()
    private let headerName = SK.WrapLabel("", size: 15, secondary: false, weight: .bold)
    private let levelText = NSTextField(labelWithString: "")
    private let levelIcons = NSImageView()
    private let headerStats = SK.WrapLabel("", size: 11.5)
    private let nameField = NSTextField()
    private let userField = NSTextField()
    private let profileStatus = SK.WrapLabel()
    private let loginLine = NSTextField(labelWithString: "")
    private let method = NSSegmentedControl(labels: ["邮箱", "手机号"], trackingMode: .selectOne, target: nil, action: nil)
    private let idField = NSTextField()
    private let codeField = NSTextField()
    private let sendBtn = OCButton(title: "发送验证码", target: nil, action: nil)
    private let loginBtn = OCButton(title: "登录 / 注册", target: nil, action: nil)
    private let logoutBtn = OCButton(title: "退出登录", target: nil, action: nil)
    private let loginStatus = SK.WrapLabel()
    private let subLines = SK.WrapLabel()
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
        method.selectedSegment = 0
        sendBtn.target = self; sendBtn.action = #selector(sendCode)
        sendBtn.bezelStyle = .rounded
        loginBtn.target = self; loginBtn.action = #selector(verify)
        loginBtn.bezelStyle = .rounded
        loginBtn.keyEquivalent = "\r"
        let lg = SK.Group()
        lg.add(SK.row("方式", method, fill: false))
        lg.add(SK.info(input(idField, ""), sendBtn))
        lg.add(SK.info(input(codeField, "6 位验证码"), loginBtn))
        let fold = SK.Fold(lg)
        loginFold = fold
        p.add(fold)
        p.add(loginStatus)

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
        let levelRow = NSStackView(views: [levelText, levelIcons])
        levelRow.spacing = 6
        levelRow.alignment = .centerY
        levelRow.translatesAutoresizingMaskIntoConstraints = false
        let right = NSStackView(views: [headerName, levelRow, headerStats])
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
        let member = CatLevel.isMember
        avatar.image = memberAvatar(acc.avatarImage(size: 144), member: member, size: 64)
        avatar.toolTip = member ? L10n.t("订阅会员") : nil
        headerName.stringValue = acc.profile.displayName
        let lc = CatLevel.shared
        let lv = lc.level
        levelText.stringValue = "Lv\(lv)"
        levelIcons.image = RankIcon.strip(level: lv, height: 16)
        levelIcons.toolTip = CatLevel.partsText(level: lv)
        let fans = lc.followers
        headerStats.stringValue = L10n.english
            ? "\(lc.days) days together · \(lc.daysToNext) days to next level · \(fans) followers"
            : "已陪伴 \(lc.days) 天 · 距下一级还差 \(lc.daysToNext) 天 · 喵友 \(fans)"
    }

    func refresh() {
        refreshHeader()
        nameField.stringValue = acc.profile.displayName
        userField.stringValue = acc.profile.username
        loginLine.stringValue = acc.accountLine
        logoutBtn.isHidden = !acc.signedIn
        loginFold?.folded = acc.signedIn || !acc.configured
        if !acc.configured {
            loginStatus.stringValue = "邮箱 / 手机号注册即将开放。现在名称和头像先保存在本机，开通后登录会自动同步。"
        } else if acc.signedIn {
            loginStatus.stringValue = "订阅绑定在这个账号上，换一台 Mac 登录同一个账号就能继续用。"
        }
        methodChanged()
        var lines: [String] = ["基础功能（聊天、语音、分享页面、桌面感知、记忆）一直免费。"]
        for (id, name) in [("x", "陪你刷推"), ("agent", "帮我操作电脑")] {
            lines.append("• \(name)：\(Billing.statusLine(id))")
        }
        subLines.stringValue = lines.joined(separator: "\n")
    }

    @objc private func methodChanged() {
        idField.placeholderString = method.selectedSegment == 0 ? "you@example.com" : "手机号，例如 0912345678"
    }

    @objc private func pickAvatar() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = "选一张图片做头像"
        guard p.runModal() == .OK, let u = p.url else { return }
        profileStatus.stringValue = "正在保存…"
        acc.setAvatar(from: u) { [weak self] err in self?.profileStatus.stringValue = err ?? "✅ 头像已更新" }
    }

    @objc private func saveProfile() {
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
        sendBtn.isEnabled = false
        loginStatus.stringValue = "正在发送…"
        acc.sendCode(email: isEmail ? v : nil, phone: isEmail ? nil : v) { [weak self] err in
            guard let self = self else { return }
            self.loginStatus.stringValue = err.map { "⚠️ " + $0 } ?? "✅ 验证码已发出，\(self.isEmail ? "去邮箱" : "看短信")查收，填在下面。"
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.sendBtn.isEnabled = true }
        }
    }

    @objc private func verify() {
        let code = codeField.stringValue.trimmingCharacters(in: .whitespaces)
        guard code.count >= 4 else { loginStatus.stringValue = "先填验证码"; return }
        loginStatus.stringValue = "正在登录…"
        acc.verify(email: isEmail ? idValue : nil, phone: isEmail ? nil : idValue, code: code) { [weak self] err in
            guard let self = self else { return }
            self.loginStatus.stringValue = err.map { "⚠️ " + $0 } ?? "✅ 登录成功"
            self.codeField.stringValue = ""
            self.refresh()
        }
    }

    @objc private func logout() {
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
