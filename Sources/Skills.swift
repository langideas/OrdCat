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
    /// Builds this skill's settings inside the given frame.
    let settings: (NSRect) -> NSView
}

/// A clickable row in the skills list: emoji + name + one-line summary + switch.
private final class SkillRow: NSView {
    var onSelect: (() -> Void)?
    var selected = false { didSet { layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor } }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.cornerRadius = 8 }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { onSelect?() }
}

final class SkillsPane: NSObject, NSTextFieldDelegate {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 360))
    weak var xbuddy: XCompanion?
    /// Called when a skill is switched (so the app can react right away).
    var onChanged: ((String, Bool) -> Void)?

    private var skills: [Skill] = []
    private var rows: [SkillRow] = []
    private var switches: [String: NSSwitch] = [:]
    private var badges: [String: NSButton] = [:]
    private var detail: NSView?
    private var selected = 0
    private let detailFrame = NSRect(x: 0, y: 0, width: 470, height: 238)

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
        let title = NSTextField(labelWithString: "技能")
        title.font = .boldSystemFont(ofSize: 14)
        title.frame = NSRect(x: 16, y: 330, width: 80, height: 20)
        view.addSubview(title)
        let hint = NSTextField(labelWithString: "基础功能免费，技能按订阅开启。打开开关就生效，点一行看设置。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 70, y: 331, width: 390, height: 16)
        view.addSubview(hint)

        // List (scrolls when there are many skills).
        let rowH: CGFloat = 46
        let listH = max(CGFloat(skills.count) * (rowH + 4), rowH)
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: listH))
        for (i, sk) in skills.enumerated() {
            let y = listH - CGFloat(i + 1) * (rowH + 4) + 4
            let r = SkillRow(frame: NSRect(x: 0, y: y, width: 440, height: rowH))
            let em = NSTextField(labelWithString: sk.emoji)
            em.font = .systemFont(ofSize: 22)
            em.frame = NSRect(x: 8, y: 10, width: 32, height: 28)
            r.addSubview(em)
            let nm = NSTextField(labelWithString: sk.name)
            nm.font = .boldSystemFont(ofSize: 13)
            nm.frame = NSRect(x: 44, y: 24, width: 300, height: 18)
            r.addSubview(nm)
            let sm = NSTextField(labelWithString: sk.summary)
            sm.font = .systemFont(ofSize: 11)
            sm.textColor = .secondaryLabelColor
            sm.lineBreakMode = .byTruncatingTail
            sm.frame = NSRect(x: 44, y: 6, width: 250, height: 16)
            r.addSubview(sm)
            if sk.paid {
                let b = NSButton(title: "", target: self, action: #selector(subscribe(_:)))
                b.bezelStyle = .inline
                b.font = .systemFont(ofSize: 11, weight: .medium)
                b.identifier = NSUserInterfaceItemIdentifier(sk.id)
                b.frame = NSRect(x: 290, y: 12, width: 86, height: 22)
                b.toolTip = "订阅、试用或输入订阅码"
                r.addSubview(b)
                badges[sk.id] = b
            }
            let sw = NSSwitch()
            sw.frame = NSRect(x: 382, y: 11, width: 50, height: 24)
            sw.state = sk.isOn() ? .on : .off
            sw.identifier = NSUserInterfaceItemIdentifier(sk.id)
            sw.target = self
            sw.action = #selector(switched(_:))
            r.addSubview(sw)
            switches[sk.id] = sw
            r.onSelect = { [weak self] in self?.select(i) }
            doc.addSubview(r)
            rows.append(r)
        }
        let scroll = NSScrollView(frame: NSRect(x: 14, y: 246, width: 442, height: 80))
        scroll.documentView = doc
        scroll.hasVerticalScroller = skills.count > 1
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        view.addSubview(scroll)
        doc.scroll(NSPoint(x: 0, y: listH))

        let line = NSBox(frame: NSRect(x: 14, y: 240, width: 442, height: 1))
        line.boxType = .separator
        view.addSubview(line)
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
            // 以后的新技能加在这里。
        ]
    }

    private func xSettings(_ f: NSRect) -> NSView {
        let v = NSView(frame: f)
        let head = NSTextField(labelWithString: "有这些情况时弹窗提醒我：")
        head.font = .systemFont(ofSize: 12, weight: .medium)
        head.frame = NSRect(x: 16, y: 214, width: 300, height: 18)
        v.addSubview(head)
        let items: [(String, String, CGFloat, CGFloat)] = [
            ("signal", "📡 命中我的信号", 20, 190), ("spam", "🚫 营销号 / 广告", 240, 190),
            ("water", "🗑 帖子下的水评", 20, 166), ("known", "👋 互动过的人出现", 240, 166),
            ("follow", "🆕 我关注的人发帖", 20, 142), ("reply", "✍️ 点回复时给回复建议", 240, 142)
        ]
        for (k, t, x, y) in items {
            let b = NSButton(checkboxWithTitle: t, target: self, action: #selector(xAlertToggled(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(k)
            b.state = Prefs.xAlert(k) ? .on : .off
            b.frame = NSRect(x: x, y: y, width: 210, height: 20)
            v.addSubview(b)
            xChecks[k] = b
        }
        func lab(_ s: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            l.frame = NSRect(x: 4, y: y + 3, width: 84, height: 18)
            v.addSubview(l)
        }
        lab("关键词信号", 108)
        xWords.frame = NSRect(x: 94, y: 108, width: 356, height: 24)
        xWords.placeholderString = "例如：AI, 融资, 空投, OpenAI（逗号分隔）"
        xWords.stringValue = Prefs.xSignalWords
        xWords.delegate = self
        v.addSubview(xWords)
        lab("特别关注", 78)
        xAccounts.frame = NSRect(x: 94, y: 78, width: 356, height: 24)
        xAccounts.placeholderString = "例如：@elonmusk, @sama（TA 们一出现就提醒）"
        xAccounts.stringValue = Prefs.xSignalAccounts
        xAccounts.delegate = self
        v.addSubview(xAccounts)
        lab("提醒频率", 46)
        xGap.removeAllItems()
        for g in gapOptions { xGap.addItem(withTitle: g.0) }
        let cur = gapOptions.enumerated().min { abs($0.element.1 - Prefs.xAlertGap) < abs($1.element.1 - Prefs.xAlertGap) }?.offset ?? 1
        xGap.selectItem(at: cur)
        xGap.target = self
        xGap.action = #selector(gapChanged)
        xGap.frame = NSRect(x: 92, y: 44, width: 220, height: 26)
        v.addSubview(xGap)
        xStats.font = .systemFont(ofSize: 10.5)
        xStats.textColor = .secondaryLabelColor
        xStats.frame = NSRect(x: 16, y: 6, width: 220, height: 34)
        v.addSubview(xStats)
        let check = NSButton(title: "检查刷推", target: self, action: #selector(checkX))
        check.frame = NSRect(x: 240, y: 6, width: 104, height: 30)
        v.addSubview(check)
        let clear = NSButton(title: "清空刷推记忆", target: self, action: #selector(clearX))
        clear.frame = NSRect(x: 342, y: 6, width: 116, height: 30)
        v.addSubview(clear)
        refresh()
        return v
    }

    @objc private func xAlertToggled(_ b: NSButton) {
        Prefs.setXAlert(b.identifier?.rawValue ?? "", b.state == .on)
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
