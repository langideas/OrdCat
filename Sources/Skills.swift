// OrdCat — 技能面板.
//
// Every skill the cat can learn lives in one place: 设置 → 技能. Each skill has an on/off switch and its own
// settings below the list. To add a new skill later: add one `Skill` in `SkillsPane.makeSkills()` with its
// switch getter/setter and a settings-view builder. Nothing else needs to change.

import Cocoa

let kPaneW: CGFloat = 500
let kDetailH: CGFloat = 420

struct Skill {
    let id: String
    let emoji: String
    let name: String
    let summary: String
    /// Opened by subscription (basic features are always free).
    let paid: Bool
    let isOn: () -> Bool
    let setOn: (Bool) -> Void
    /// Builds this skill's settings inside the given frame.
    let settings: (NSRect) -> NSView
}

/// Top-down layout (y grows downward), so rows stack naturally.
final class FlipView: NSView { override var isFlipped: Bool { true } }

/// A clickable row in the skills list: emoji + name + one-line summary + switch.
private final class SkillRow: NSView {
    var onSelect: (() -> Void)?
    var selected = false { didSet { layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor } }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.cornerRadius = 8 }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onSelect?() }
}

final class SkillsPane: NSObject, NSTextFieldDelegate {
    let view: NSView = FlipView(frame: NSRect(x: 0, y: 0, width: kPaneW, height: 560))
    weak var xbuddy: XCompanion?
    /// Called when a skill is switched (so the app can react right away).
    var onChanged: ((String, Bool) -> Void)?

    private var skills: [Skill] = []
    private var rows: [SkillRow] = []
    private var switches: [String: NSSwitch] = [:]
    private var badges: [String: NSButton] = [:]
    private var detail: NSView?
    private var selected = 0
    private var detailFrame = NSRect(x: 0, y: 0, width: kPaneW, height: kDetailH)

    // 陪你刷推 controls
    private var xChecks: [String: NSButton] = [:]
    private let xWords = NSTextField()
    private let xAccounts = NSTextField()
    private let xGap = NSPopUpButton()
    private let xStats = NSTextField(wrappingLabelWithString: "")
    private let gapOptions: [(String, Double)] = [("少：30 秒最多一次", 30), ("正常：8 秒最多一次", 8), ("多：随时提醒", 2)]

    func build(xbuddy: XCompanion?) {
        self.xbuddy = xbuddy
        skills = makeSkills()
        let W = kPaneW
        var y: CGFloat = 12
        let title = NSTextField(labelWithString: "技能")
        title.font = .boldSystemFont(ofSize: 15)
        title.frame = NSRect(x: 16, y: y, width: 120, height: 20)
        view.addSubview(title)
        y += 24
        let hint = NSTextField(wrappingLabelWithString: "基础功能免费，技能按订阅开启。打开开关就生效，点一行看它的设置。")
        hint.font = .systemFont(ofSize: 11.5)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: y, width: W - 32, height: 32)
        view.addSubview(hint)
        y += 36

        // Every skill is one full row; the list grows with the skills (the page scrolls, not the list).
        let rowH: CGFloat = 56
        for (i, sk) in skills.enumerated() {
            let r = SkillRow(frame: NSRect(x: 12, y: y, width: W - 24, height: rowH))
            let rw = r.frame.width
            let em = NSTextField(labelWithString: sk.emoji)
            em.font = .systemFont(ofSize: 24)
            em.frame = NSRect(x: 10, y: 13, width: 34, height: 30)
            r.addSubview(em)
            let nm = NSTextField(labelWithString: sk.name)
            nm.font = .boldSystemFont(ofSize: 13.5)
            nm.frame = NSRect(x: 50, y: 30, width: rw - 200, height: 18)
            r.addSubview(nm)
            let sm = NSTextField(labelWithString: sk.summary)
            sm.font = .systemFont(ofSize: 11.5)
            sm.textColor = .secondaryLabelColor
            sm.lineBreakMode = .byTruncatingTail
            sm.toolTip = sk.summary
            sm.frame = NSRect(x: 50, y: 10, width: rw - 200, height: 16)
            r.addSubview(sm)
            if sk.paid {
                let b = NSButton(title: "", target: self, action: #selector(subscribe(_:)))
                b.bezelStyle = .inline
                b.font = .systemFont(ofSize: 11, weight: .medium)
                b.identifier = NSUserInterfaceItemIdentifier(sk.id)
                b.frame = NSRect(x: rw - 146, y: 17, width: 84, height: 22)
                b.toolTip = "订阅、试用或输入订阅码"
                r.addSubview(b)
                badges[sk.id] = b
            }
            let sw = NSSwitch()
            sw.frame = NSRect(x: rw - 56, y: 16, width: 46, height: 24)
            sw.state = sk.isOn() ? .on : .off
            sw.identifier = NSUserInterfaceItemIdentifier(sk.id)
            sw.target = self
            sw.action = #selector(switched(_:))
            r.addSubview(sw)
            switches[sk.id] = sw
            r.onSelect = { [weak self] in self?.select(i) }
            view.addSubview(r)
            rows.append(r)
            y += rowH + 4
        }
        y += 6
        let line = NSBox(frame: NSRect(x: 16, y: y, width: W - 32, height: 1))
        line.boxType = .separator
        view.addSubview(line)
        y += 8
        detailFrame = NSRect(x: 0, y: y, width: W, height: kDetailH)
        view.setFrameSize(NSSize(width: W, height: y + kDetailH))
        select(0)
    }

    private func select(_ i: Int) {
        guard i < skills.count else { return }
        selected = i
        for (k, r) in rows.enumerated() { r.selected = k == i }
        detail?.removeFromSuperview()
        let d = skills[i].settings(detailFrame)
        view.addSubview(d)
        detail = d
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
                  settings: { [weak self] f in self?.xSettings(f) ?? NSView(frame: f) })
,
            Skill(id: "agent", emoji: "🤖", name: "帮我操作电脑",
                  summary: "说「帮我……」，小猫一步步替你点、输入、打开应用",
                  paid: true,
                  isOn: { Prefs.agentOn },
                  setOn: { on in
                      Prefs.agentOn = on
                      if on { _ = SelectionWatcher.trusted(prompt: true) }
                  },
                  settings: { [weak self] f in self?.agentSettings(f) ?? NSView(frame: f) })
            // 以后的新技能加在这里。
        ]
    }

    private func xSettings(_ f: NSRect) -> NSView {
        let v = FlipView(frame: f)
        let W = f.width
        func section(_ t: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: t)
            l.font = .systemFont(ofSize: 12.5, weight: .semibold)
            l.frame = NSRect(x: 16, y: y, width: W - 32, height: 18)
            v.addSubview(l)
        }
        section("有这些情况时弹窗提醒我", 4)
        let colW = (W - 48) / 2
        let items: [(String, String)] = [
            ("autopost", "📝 点进帖子自动弹分析"), ("reply", "✍️ 点回复时给回复建议"),
            ("signal", "📡 命中我的信号"), ("spam", "🚫 营销号 / 广告"),
            ("water", "🗑 帖子下的水评"), ("known", "👋 互动过的人出现"),
            ("follow", "🆕 我关注的人发帖")
        ]
        for (n, (k, t)) in items.enumerated() {
            let b = NSButton(checkboxWithTitle: t, target: self, action: #selector(xAlertToggled(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(k)
            b.state = Prefs.xAlert(k) ? .on : .off
            b.frame = NSRect(x: 22 + CGFloat(n % 2) * (colW + 8), y: 28 + CGFloat(n / 2) * 25, width: colW, height: 20)
            v.addSubview(b)
            xChecks[k] = b
        }
        var y: CGFloat = 28 + 4 * 25 + 6
        let rs = NSButton(title: "回复建议设置…", target: self, action: #selector(replySettings))
        rs.bezelStyle = .rounded
        rs.frame = NSRect(x: 18, y: y, width: 150, height: 28)
        v.addSubview(rs)
        let rsHint = NSTextField(labelWithString: "几条、语气、长度、语言、关于我")
        rsHint.font = .systemFont(ofSize: 11)
        rsHint.textColor = .secondaryLabelColor
        rsHint.frame = NSRect(x: 176, y: y + 6, width: W - 192, height: 16)
        v.addSubview(rsHint)
        y += 44

        section("信号", y)
        y += 24
        let labW: CGFloat = 76
        func field(_ name: String, _ ctl: NSView, h: CGFloat = 24) {
            let l = NSTextField(labelWithString: name)
            l.alignment = .right
            l.frame = NSRect(x: 12, y: y + 4, width: labW, height: 18)
            v.addSubview(l)
            ctl.frame = NSRect(x: labW + 20, y: y, width: W - labW - 36, height: h)
            v.addSubview(ctl)
            y += h + 10
        }
        xWords.placeholderString = "例如：AI, 融资, 空投, OpenAI（逗号分隔）"
        xWords.stringValue = Prefs.xSignalWords
        xWords.delegate = self
        field("关键词", xWords)
        xAccounts.placeholderString = "例如：@elonmusk, @sama"
        xAccounts.stringValue = Prefs.xSignalAccounts
        xAccounts.delegate = self
        field("特别关注", xAccounts)
        xGap.removeAllItems()
        for g in gapOptions { xGap.addItem(withTitle: g.0) }
        let cur = gapOptions.enumerated().min { abs($0.element.1 - Prefs.xAlertGap) < abs($1.element.1 - Prefs.xAlertGap) }?.offset ?? 1
        xGap.selectItem(at: cur)
        xGap.target = self
        xGap.action = #selector(gapChanged)
        field("提醒频率", xGap, h: 26)
        xGap.frame.size.width = min(240, xGap.frame.width)

        let line = NSBox(frame: NSRect(x: 16, y: y, width: W - 32, height: 1))
        line.boxType = .separator
        v.addSubview(line)
        y += 10
        section("刷推记忆", y)
        y += 22
        xStats.font = .systemFont(ofSize: 11)
        xStats.textColor = .secondaryLabelColor
        xStats.frame = NSRect(x: 18, y: y, width: W - 36, height: 46)
        v.addSubview(xStats)
        y += 50
        let check = NSButton(title: "检查刷推", target: self, action: #selector(checkX))
        check.bezelStyle = .rounded
        check.frame = NSRect(x: 14, y: y, width: 110, height: 30)
        v.addSubview(check)
        let clear = NSButton(title: "清空刷推记忆", target: self, action: #selector(clearX))
        clear.bezelStyle = .rounded
        clear.frame = NSRect(x: 128, y: y, width: 130, height: 30)
        v.addSubview(clear)
        refresh()
        return v
    }

    private func agentSettings(_ f: NSRect) -> NSView {
        let v = FlipView(frame: f)
        let c = NSButton(checkboxWithTitle: "每一步都先问我（推荐）", target: self, action: #selector(agentConfirmToggled(_:)))
        c.state = Prefs.agentConfirm ? .on : .off
        c.frame = NSRect(x: 16, y: 6, width: f.width - 32, height: 20)
        v.addSubview(c)
        let info = NSTextField(wrappingLabelWithString: """
        怎么用：在聊天里说「帮我……」，比如「帮我在备忘录里新建一条：明天买猫粮」「帮我打开 Safari 搜索今天的天气」。也可以用「/做 」开头。

        小猫会看当前应用里能点的按钮和输入框，一次走一步。
        • 按 Esc 或点「停止」随时停下
        • 发送、发布、付款、删除这类步骤，就算选了自动也一定先问你
        • 密码框一律不碰
        • 需要「辅助功能」权限
        """)
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.frame = NSRect(x: 16, y: 36, width: f.width - 32, height: 190)
        v.addSubview(info)
        return v
    }
    @objc private func agentConfirmToggled(_ b: NSButton) { Prefs.agentConfirm = b.state == .on }

    @objc private func xAlertToggled(_ b: NSButton) {
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
