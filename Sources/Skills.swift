// OrdCat — 技能面板.
//
// Every skill the cat can learn lives in one place: 设置 → 技能. Each skill has an on/off switch and its own
// settings below the list. To add a new skill later: add one `Skill` in `SkillsPane.makeSkills()` with its
// switch getter/setter and a settings-view builder. Nothing else needs to change.

import Cocoa


struct Skill {
    let id: String
    let emoji: String
    let name: String
    let summary: String
    /// Opened by subscription (basic features are always free).
    let paid: Bool
    let isOn: () -> Bool
    let setOn: (Bool) -> Void
    /// Builds this skill's settings (Auto Layout; stretched to the page width).
    let settings: () -> NSView
}

/// Top-down layout (y grows downward), so rows stack naturally.
final class FlipView: NSView { override var isFlipped: Bool { true } }

/// A clickable row in the skills list: emoji + name + one-line summary + badge + switch.
private final class SkillRow: NSView {
    var onSelect: (() -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
    override func mouseDown(with event: NSEvent) { onSelect?() }
}

final class SkillsPane: NSObject, NSTextFieldDelegate {
    weak var xbuddy: XCompanion?
    /// Called when a skill is switched (so the app can react right away).
    var onChanged: ((String, Bool) -> Void)?

    private var skills: [Skill] = []
    private var rows: [SkillRow] = []
    private var switches: [String: NSSwitch] = [:]
    private var badges: [String: NSButton] = [:]
    private var selected = 0
    private let detailHost = NSStackView()
    private let detailTitle = NSTextField(labelWithString: "")

    // 陪你刷推 controls
    private var xChecks: [String: NSSwitch] = [:]
    private let xWords = NSTextField()
    private let xAccounts = NSTextField()
    private let xGap = NSPopUpButton()
    private let xStats = SK.WrapLabel()
    private let gapOptions: [(String, Double)] = [("少：30 秒最多一次", 30), ("正常：8 秒最多一次", 8), ("多：随时提醒", 2)]

    func build(xbuddy: XCompanion?, into page: SK.Page) {
        self.xbuddy = xbuddy
        skills = makeSkills()
        page.hint("基础功能免费，技能按订阅开启。打开开关就生效，点一行看它的设置。")
        page.space(14)

        // Every skill is one full row; the list grows with the skills (the page scrolls, not the list).
        let list = SK.Group()
        for (i, sk) in skills.enumerated() {
            let r = SkillRow()
            r.translatesAutoresizingMaskIntoConstraints = false
            let em = NSTextField(labelWithString: sk.emoji)
            em.font = .systemFont(ofSize: 24)
            em.translatesAutoresizingMaskIntoConstraints = false
            let col = NSStackView()
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 2
            col.translatesAutoresizingMaskIntoConstraints = false
            let nm = SK.WrapLabel(sk.name, size: 13.5, secondary: false, weight: .semibold)
            let sm = SK.WrapLabel(sk.summary, size: 11.5)
            col.addArrangedSubview(nm); col.addArrangedSubview(sm)
            nm.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            sm.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            let right = NSStackView()
            right.orientation = .horizontal
            right.spacing = 10
            right.alignment = .centerY
            right.translatesAutoresizingMaskIntoConstraints = false
            if sk.paid {
                let b = NSButton(title: "", target: self, action: #selector(subscribe(_:)))
                b.bezelStyle = .inline
                b.font = .systemFont(ofSize: 11, weight: .medium)
                b.identifier = NSUserInterfaceItemIdentifier(sk.id)
                b.toolTip = "订阅、试用或输入订阅码"
                right.addArrangedSubview(b)
                badges[sk.id] = b
            }
            let sw = NSSwitch()
            sw.controlSize = .small
            sw.state = sk.isOn() ? .on : .off
            sw.identifier = NSUserInterfaceItemIdentifier(sk.id)
            sw.target = self
            sw.action = #selector(switched(_:))
            right.addArrangedSubview(sw)
            right.setContentHuggingPriority(.required, for: .horizontal)
            right.setContentCompressionResistancePriority(.required, for: .horizontal)
            switches[sk.id] = sw
            r.addSubview(em); r.addSubview(col); r.addSubview(right)
            NSLayoutConstraint.activate([
                r.heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
                em.leadingAnchor.constraint(equalTo: r.leadingAnchor, constant: 14),
                em.centerYAnchor.constraint(equalTo: r.centerYAnchor),
                em.widthAnchor.constraint(equalToConstant: 32),
                col.leadingAnchor.constraint(equalTo: em.trailingAnchor, constant: 8),
                col.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -12),
                col.topAnchor.constraint(greaterThanOrEqualTo: r.topAnchor, constant: 10),
                col.bottomAnchor.constraint(lessThanOrEqualTo: r.bottomAnchor, constant: -10),
                col.centerYAnchor.constraint(equalTo: r.centerYAnchor),
                right.trailingAnchor.constraint(equalTo: r.trailingAnchor, constant: -14),
                right.centerYAnchor.constraint(equalTo: r.centerYAnchor)])
            r.onSelect = { [weak self] in self?.select(i) }
            list.add(r)
            rows.append(r)
        }
        page.add(list)

        detailTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        page.space(26)
        page.add(detailTitle, full: false, gap: 10)
        detailHost.orientation = .vertical
        detailHost.alignment = .leading
        page.add(detailHost)
        select(0)
    }

    private func select(_ i: Int) {
        guard i < skills.count else { return }
        selected = i
        for (k, r) in rows.enumerated() { r.selected = k == i }
        detailTitle.stringValue = "\(skills[i].emoji) \(skills[i].name) · 设置"
        for v in detailHost.arrangedSubviews { detailHost.removeArrangedSubview(v); v.removeFromSuperview() }
        let d = skills[i].settings()
        d.translatesAutoresizingMaskIntoConstraints = false
        detailHost.addArrangedSubview(d)
        d.widthAnchor.constraint(equalTo: detailHost.widthAnchor).isActive = true
    }

    @objc private func switched(_ sw: NSSwitch) {
        let id = sw.identifier?.rawValue ?? ""
        guard let sk = skills.first(where: { $0.id == id }) else { return }
        let on = sw.state == .on
        if on && sk.paid && !Billing.isUnlocked(id) {
            sw.state = .off
            Billing.showSubscribe(id, name: sk.name) { [weak self] in
                if Billing.isUnlocked(id) { sk.setOn(true); self?.onChanged?(id, true) }
                self?.refresh()
            }
            refresh()
            return
        }
        sk.setOn(on)
        onChanged?(id, on)
        refresh()
    }

    /// Re-read every switch and status line (after the cat changed something itself).
    @objc private func subscribe(_ b: NSButton) {
        let id = b.identifier?.rawValue ?? ""
        guard let sk = skills.first(where: { $0.id == id }) else { return }
        Billing.showSubscribe(id, name: sk.name) { [weak self] in self?.refresh() }
    }

    private func badge(_ id: String) -> String {
        if !Billing.enabled { return "公测免费" }
        if Billing.isSubscribed(id) { return "已订阅" }
        if Billing.trialStart(id) != nil && Billing.trialLeft(id) > 0 { return "试用剩 \(Billing.trialLeft(id)) 天" }
        return Billing.price(id)
    }

    func refresh() {
        for sk in skills {
            switches[sk.id]?.state = sk.isOn() && (!sk.paid || Billing.isUnlocked(sk.id)) ? .on : .off
            badges[sk.id]?.title = badge(sk.id)
        }
        if let xb = xbuddy { xStats.stringValue = "\(xb.stats)\n订阅：\(Billing.statusLine("x"))" }
    }

    // MARK: the skills

    private func makeSkills() -> [Skill] {
        [
            Skill(id: "x", emoji: "🐦", name: "陪你刷推（X）",
                  summary: "认人、信号提醒、标出营销号和水评、点回复时给建议",
                  paid: true,
                  isOn: { Prefs.xMode },
                  setOn: { on in
                      Prefs.xMode = on
                      if on { Prefs.xOffered = true; _ = SelectionWatcher.trusted(prompt: true) }
                  },
                  settings: { [weak self] in self?.xSettings() ?? NSView() })
,
            Skill(id: "agent", emoji: "🤖", name: "帮我操作电脑",
                  summary: "说「帮我……」，小猫一步步替你点、输入、打开应用",
                  paid: true,
                  isOn: { Prefs.agentOn },
                  setOn: { on in
                      Prefs.agentOn = on
                      if on { _ = SelectionWatcher.trusted(prompt: true) }
                  },
                  settings: { [weak self] in self?.agentSettings() ?? NSView() })

,
            Skill(id: "miao", emoji: "🎧", name: "喵传",
                  summary: "实时听 Mac 里的会议、视频会议和 X Spaces，原话加翻译显示成字幕",
                  paid: true,
                  isOn: { Prefs.miaoOn },
                  setOn: { on in
                      Prefs.miaoOn = on
                      if !on { MiaoChuan.shared.stop() }
                  },
                  settings: { [weak self] in self?.miaoSettings() ?? NSView() })

            // 以后的新技能加在这里。
        ]
    }

    /// A top-down column used for one skill's settings.
    private func column() -> NSStackView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 10
        return v
    }
    private func put(_ x: NSView, in v: NSStackView, full: Bool = true, gap: CGFloat? = nil) {
        x.translatesAutoresizingMaskIntoConstraints = false
        v.addArrangedSubview(x)
        if full { x.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        if let g = gap { v.setCustomSpacing(g, after: x) }
    }
    private func sectionLabel(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    private func xSettings() -> NSView {
        let v = column()
        put(sectionLabel("有这些情况时弹窗提醒我"), in: v, full: false, gap: 8)
        let items: [(String, String)] = [
            ("autopost", "📝 点进帖子自动弹分析"), ("reply", "✍️ 点回复时给回复建议"),
            ("signal", "📡 命中我的信号"), ("spam", "🚫 营销号 / 广告"),
            ("water", "🗑 帖子下的水评"), ("known", "👋 互动过的人出现"),
            ("follow", "🆕 我关注的人发帖")
        ]
        let g = SK.Group()
        for (k, t) in items {
            let s = NSSwitch()
            s.identifier = NSUserInterfaceItemIdentifier(k)
            s.state = Prefs.xAlert(k) ? .on : .off
            s.target = self
            s.action = #selector(xAlertToggled(_:))
            xChecks[k] = s
            g.add(SK.toggle(t, s))
        }
        let rs = SK.button("回复建议设置…", self, #selector(replySettings))
        g.add(SK.info(SK.WrapLabel("回复建议：几条、语气、长度、语言、关于我", size: 13, secondary: false), rs))
        put(g, in: v, gap: 22)

        put(sectionLabel("信号"), in: v, full: false, gap: 8)
        xWords.placeholderString = "例如：AI, 融资, 空投, OpenAI（逗号分隔）"
        xWords.stringValue = Prefs.xSignalWords
        xWords.delegate = self
        xAccounts.placeholderString = "例如：@elonmusk, @sama"
        xAccounts.stringValue = Prefs.xSignalAccounts
        xAccounts.delegate = self
        xGap.removeAllItems()
        for o in gapOptions { xGap.addItem(withTitle: o.0) }
        let cur = gapOptions.enumerated().min { abs($0.element.1 - Prefs.xAlertGap) < abs($1.element.1 - Prefs.xAlertGap) }?.offset ?? 1
        xGap.selectItem(at: cur)
        xGap.target = self
        xGap.action = #selector(gapChanged)
        for f in [xWords, xAccounts] {
            f.font = .systemFont(ofSize: 13)
            f.usesSingleLineMode = true
            f.cell?.isScrollable = true
            f.cell?.wraps = false
        }
        let g2 = SK.Group()
        g2.add(SK.row("关键词", xWords))
        g2.add(SK.row("特别关注", xAccounts))
        g2.add(SK.row("提醒频率", xGap, fill: false, maxW: 240))
        put(g2, in: v, gap: 22)

        put(sectionLabel("刷推记忆"), in: v, full: false, gap: 8)
        put(xStats, in: v)
        put(SK.buttons([SK.button("检查刷推", self, #selector(checkX)),
                        SK.button("清空刷推记忆", self, #selector(clearX))]), in: v)
        refresh()
        return v
    }

    private func agentSettings() -> NSView {
        let v = column()
        let s = NSSwitch()
        s.state = Prefs.agentConfirm ? .on : .off
        s.target = self
        s.action = #selector(agentConfirmToggled(_:))
        let g = SK.Group()
        g.add(SK.toggle("每一步都先问我（推荐）", s))
        put(g, in: v, gap: 14)
        let info = SK.WrapLabel("""
        怎么用：在聊天里说「帮我……」，比如「帮我在备忘录里新建一条：明天买猫粮」「帮我打开 Safari 搜索今天的天气」。也可以用「/做 」开头。

        小猫会看当前应用里能点的按钮和输入框，一次走一步。
        • 按 Esc 或点「停止」随时停下
        • 发送、发布、付款、删除这类步骤，就算选了自动也一定先问你
        • 密码框一律不碰
        • 需要「辅助功能」权限
        """, size: 12)
        put(info, in: v)
        return v
    }
    @objc private func agentConfirmToggled(_ b: NSSwitch) { Prefs.agentConfirm = b.state == .on }

    private func miaoSettings() -> NSView {
        let v = column()
        put(SK.buttons([SK.button("🎧 开始喵传", self, #selector(miaoStart))]), in: v, gap: 14)
        let info = SK.WrapLabel("""
        怎么用：先打开会议、视频会议或 X Spaces，再点「开始喵传」（菜单栏的小猫菜单里也有）。选好要听的应用和语言，屏幕下方会出现字幕条：上面一行是原话，下面一行是译文。

        • 点「刚才在说什么」，小猫总结最近几分钟
        • 声音只在本机转成文字，翻译只把文字发给你设置的模型
        • 字幕不保存，点「停止」就清掉
        • 需要「屏幕录制」和「语音识别」权限
        • 多人抢话、口音重的时候可能识别错
        """, size: 12)
        put(info, in: v)
        return v
    }
    @objc private func miaoStart() { MiaoChuan.shared.begin() }

    @objc private func xAlertToggled(_ b: NSSwitch) {
        Prefs.setXAlert(b.identifier?.rawValue ?? "", b.state == .on)
    }

    /// 回复建议的自定义：几条、语气、长度、语言、关于我，以及点一条后是否直接填进回复框。
    @objc private func replySettings() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 236))
        func lab(_ t: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: t)
            l.alignment = .right
            l.frame = NSRect(x: 0, y: y + 3, width: 70, height: 18)
            v.addSubview(l)
        }
        func pop(_ items: [String], _ sel: Int, _ y: CGFloat) -> NSPopUpButton {
            let p = NSPopUpButton(frame: NSRect(x: 76, y: y, width: 220, height: 26))
            p.addItems(withTitles: items)
            p.selectItem(at: sel)
            v.addSubview(p)
            return p
        }
        lab("几条", 206); let count = pop(["1 条", "2 条", "3 条", "4 条", "5 条"], Prefs.xReplyCount - 1, 204)
        lab("语气", 174); let tone = pop(Prefs.xReplyTones, Prefs.xReplyTone, 172)
        lab("长度", 142); let len = pop(Prefs.xReplyLengths.map { $0.0 }, Prefs.xReplyLength, 140)
        lab("语言", 110); let lang = pop(Prefs.xReplyLangs, Prefs.xReplyLang, 108)
        lab("关于我", 76)
        let me = NSTextField(frame: NSRect(x: 78, y: 48, width: 296, height: 52))
        me.placeholderString = "比如：我做量化交易，用第一人称，别用 emoji，多给干货"
        me.stringValue = Prefs.xReplyPersona
        me.cell?.wraps = true
        me.cell?.isScrollable = false
        me.usesSingleLineMode = false
        v.addSubview(me)
        let fill = NSButton(checkboxWithTitle: "点一条直接填进 X 的回复框（只填不发，你自己点回复）", target: nil, action: nil)
        fill.state = Prefs.xReplyFill ? .on : .off
        fill.frame = NSRect(x: 0, y: 14, width: 380, height: 20)
        v.addSubview(fill)
        let a = NSAlert()
        a.messageText = "回复建议设置"
        a.informativeText = "点回复框或「想回复」时，小猫按这里的要求给你想回复。"
        a.accessoryView = v
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Prefs.xReplyCount = count.indexOfSelectedItem + 1
        Prefs.xReplyTone = max(0, tone.indexOfSelectedItem)
        Prefs.xReplyLength = max(0, len.indexOfSelectedItem)
        Prefs.xReplyLang = max(0, lang.indexOfSelectedItem)
        Prefs.xReplyPersona = me.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Prefs.xReplyFill = fill.state == .on
    }

    @objc private func gapChanged() {
        let i = max(0, xGap.indexOfSelectedItem)
        Prefs.xAlertGap = gapOptions[min(i, gapOptions.count - 1)].1
    }

    func controlTextDidChange(_ n: Notification) { saveFields() }
    func controlTextDidEndEditing(_ n: Notification) { saveFields() }
    private func saveFields() {
        Prefs.xSignalWords = xWords.stringValue
        Prefs.xSignalAccounts = xAccounts.stringValue
    }

    @objc private func checkX() {
        guard let xb = xbuddy else { return }
        let report = xb.diagnose()
        refresh()
        let a = NSAlert()
        a.messageText = "陪你刷推 · 检查结果"
        a.informativeText = report + "\n\n提示：先切到浏览器打开 x.com，再回到这里点「检查刷推」。"
        a.addButton(withTitle: "复制结果")
        a.addButton(withTitle: "好")
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    @objc private func clearX() {
        let a = NSAlert()
        a.messageText = "清空刷推记忆？"
        a.informativeText = "小猫会忘掉在 X 上记住的人、互动和兴趣，不能恢复。"
        a.addButton(withTitle: "清空")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { xbuddy?.clear(); refresh() }
    }
}
