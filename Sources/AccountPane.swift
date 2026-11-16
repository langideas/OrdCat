// OrdCat — 设置 → 账号.

import Cocoa
import UniformTypeIdentifiers

final class AccountPane: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 640))
    private let acc = Account.shared
    private let avatar = NSImageView()
    private let nameField = NSTextField()
    private let userField = NSTextField()
    private let profileStatus = NSTextField(labelWithString: "")
    private let loginLine = NSTextField(labelWithString: "")
    private let method = NSSegmentedControl(labels: ["邮箱", "手机号"], trackingMode: .selectOne, target: nil, action: nil)
    private let idField = NSTextField()
    private let codeField = NSTextField()
    private let sendBtn = NSButton(title: "发送验证码", target: nil, action: nil)
    private let loginBtn = NSButton(title: "登录 / 注册", target: nil, action: nil)
    private let logoutBtn = NSButton(title: "退出登录", target: nil, action: nil)
    private let loginStatus = NSTextField(labelWithString: "")
    private let subLines = NSTextField(labelWithString: "")
    private let dataStatus = NSTextField(labelWithString: "")
    private var loginViews: [NSView] = []
    var onOpenSkills: (() -> Void)?

    override init() {
        super.init()
        build()
        acc.observe { [weak self] in self?.refresh() }
    }

    private func section(_ t: String, _ y: CGFloat) {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.frame = NSRect(x: 16, y: y, width: 300, height: 18)
        view.addSubview(l)
        let line = NSBox(frame: NSRect(x: 16, y: y - 6, width: 438, height: 1))
        line.boxType = .separator
        view.addSubview(line)
    }
    private func label(_ t: String, _ y: CGFloat) {
        let l = NSTextField(labelWithString: t)
        l.alignment = .right
        l.frame = NSRect(x: 100, y: y + 3, width: 60, height: 18)
        view.addSubview(l)
    }
    private func button(_ t: String, _ sel: Selector, _ frame: NSRect) -> NSButton {
        let b = NSButton(title: t, target: self, action: sel)
        b.bezelStyle = .rounded
        b.frame = frame
        view.addSubview(b)
        return b
    }
    private func small(_ l: NSTextField, _ frame: NSRect) {
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 3
        l.frame = frame
        view.addSubview(l)
    }

    private func build() {
        // 个人资料
        section("个人资料", 606)
        avatar.frame = NSRect(x: 20, y: 512, width: 72, height: 72)
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 36
        avatar.layer?.masksToBounds = true
        view.addSubview(avatar)
        _ = button("更换头像", #selector(pickAvatar), NSRect(x: 14, y: 478, width: 86, height: 28))
        label("名称", 552)
        nameField.frame = NSRect(x: 166, y: 552, width: 200, height: 24)
        nameField.placeholderString = "小猫怎么称呼你"
        view.addSubview(nameField)
        label("用户名", 520)
        userField.frame = NSRect(x: 166, y: 520, width: 200, height: 24)
        userField.placeholderString = "字母、数字或下划线"
        view.addSubview(userField)
        _ = button("保存", #selector(saveProfile), NSRect(x: 372, y: 518, width: 76, height: 28))
        small(profileStatus, NSRect(x: 166, y: 484, width: 280, height: 30))

        // 账号与登录
        section("账号与登录", 452)
        loginLine.font = .systemFont(ofSize: 12)
        loginLine.frame = NSRect(x: 20, y: 420, width: 330, height: 18)
        view.addSubview(loginLine)
        logoutBtn.target = self; logoutBtn.action = #selector(logout)
        logoutBtn.bezelStyle = .rounded
        logoutBtn.frame = NSRect(x: 360, y: 414, width: 90, height: 28)
        view.addSubview(logoutBtn)
        method.target = self; method.action = #selector(methodChanged)
        method.selectedSegment = 0
        method.frame = NSRect(x: 20, y: 386, width: 140, height: 24)
        view.addSubview(method)
        idField.frame = NSRect(x: 166, y: 386, width: 180, height: 24)
        view.addSubview(idField)
        sendBtn.target = self; sendBtn.action = #selector(sendCode)
        sendBtn.bezelStyle = .rounded
        sendBtn.frame = NSRect(x: 350, y: 384, width: 100, height: 28)
        view.addSubview(sendBtn)
        codeField.frame = NSRect(x: 166, y: 352, width: 180, height: 24)
        codeField.placeholderString = "6 位验证码"
        view.addSubview(codeField)
        loginBtn.target = self; loginBtn.action = #selector(verify)
        loginBtn.bezelStyle = .rounded
        loginBtn.keyEquivalent = "\r"
        loginBtn.frame = NSRect(x: 350, y: 350, width: 100, height: 28)
        view.addSubview(loginBtn)
        small(loginStatus, NSRect(x: 20, y: 316, width: 430, height: 30))
        loginViews = [method, idField, sendBtn, codeField, loginBtn]

        // 订阅与付款
        section("订阅与付款", 290)
        subLines.font = .systemFont(ofSize: 12)
        subLines.maximumNumberOfLines = 4
        subLines.lineBreakMode = .byWordWrapping
        subLines.frame = NSRect(x: 20, y: 214, width: 430, height: 66)
        view.addSubview(subLines)
        _ = button("管理订阅", #selector(openSkills), NSRect(x: 14, y: 178, width: 110, height: 28))
        _ = button("管理付款方式", #selector(openPortal), NSRect(x: 128, y: 178, width: 120, height: 28))
        _ = button("刷新订阅", #selector(refreshSubs), NSRect(x: 252, y: 178, width: 100, height: 28))

        // 数据管理
        section("数据管理", 146)
        _ = button("导出我的数据", #selector(exportData), NSRect(x: 14, y: 104, width: 120, height: 28))
        _ = button("清除本机数据", #selector(wipeLocal), NSRect(x: 138, y: 104, width: 120, height: 28))
        let del = button("注销账号", #selector(deleteAccount), NSRect(x: 262, y: 104, width: 100, height: 28))
        del.contentTintColor = .systemRed
        small(dataStatus, NSRect(x: 20, y: 40, width: 430, height: 56))
        dataStatus.stringValue = "聊天记录、记忆和刷推记忆都只存在这台 Mac 上。导出会打包到「下载」文件夹；注销会删除云端账号、头像和订阅绑定（已付的订阅请先在「管理付款方式」里取消）。"
        refresh()
    }

    func refresh() {
        avatar.image = acc.avatarImage(size: 144)
        nameField.stringValue = acc.profile.displayName
        userField.stringValue = acc.profile.username
        loginLine.stringValue = acc.accountLine
        logoutBtn.isHidden = !acc.signedIn
        for v in loginViews { v.isHidden = acc.signedIn || !acc.configured }
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
