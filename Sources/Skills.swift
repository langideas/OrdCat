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

// MARK: - 技能栏 (v0.2.51)

/// Each skill's own icon, drawn in the same amber style as the rank icons (64×64 box).
enum SkillIcon {
    static func image(_ id: String, size: CGFloat, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let k = size / 64
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * k, y: y * k) }
            func capsule(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
                let r = min(w, h) / 2 * k
                NSBezierPath(roundedRect: NSRect(x: x * k, y: y * k, width: w * k, height: h * k), xRadius: r, yRadius: r).fill()
            }
            color.setFill(); color.setStroke()
            switch id {
            case "x":      // 喵推: a speech bubble with cat ears and two pupils
                let b = NSBezierPath()
                b.move(to: p(14, 22)); b.line(to: p(17, 8)); b.line(to: p(26, 18))
                b.line(to: p(38, 18)); b.line(to: p(47, 8)); b.line(to: p(50, 22))
                b.curve(to: p(54, 32), controlPoint1: p(53, 25), controlPoint2: p(54, 28))
                b.line(to: p(54, 40))
                b.curve(to: p(44, 50), controlPoint1: p(54, 46), controlPoint2: p(50, 50))
                b.line(to: p(30, 50)); b.line(to: p(20, 58)); b.line(to: p(22, 50))
                b.curve(to: p(10, 40), controlPoint1: p(14, 50), controlPoint2: p(10, 46))
                b.line(to: p(10, 32))
                b.curve(to: p(14, 22), controlPoint1: p(10, 28), controlPoint2: p(11, 25))
                b.close()
                b.lineWidth = 3.2 * k; b.lineJoinStyle = .round
                b.stroke()
                capsule(23, 27, 6, 15); capsule(35, 27, 6, 15)
            case "agent":  // 喵手: a paw
                let pad = NSBezierPath()
                pad.move(to: p(32, 33))
                pad.curve(to: p(48, 50), controlPoint1: p(41, 33), controlPoint2: p(50, 42))
                pad.curve(to: p(32, 55), controlPoint1: p(46, 56), controlPoint2: p(38, 55))
                pad.curve(to: p(16, 50), controlPoint1: p(26, 55), controlPoint2: p(18, 56))
                pad.curve(to: p(32, 33), controlPoint1: p(14, 42), controlPoint2: p(23, 33))
                pad.close(); pad.fill()
                capsule(9, 22, 9, 13); capsule(19.5, 10, 9, 14); capsule(35.5, 10, 9, 14); capsule(46, 22, 9, 13)
            default:       // 喵传: a cat pupil with sound waves on both sides
                capsule(27, 14, 10, 36)
                for r in [13.0, 22.0] as [CGFloat] {
                    for side in [-1.0, 1.0] as [CGFloat] {
                        let arc = NSBezierPath()
                        let start: CGFloat = side < 0 ? 140 : -40, end: CGFloat = side < 0 ? 220 : 40
                        arc.appendArc(withCenter: p(32, 32), radius: r * k + 6 * k, startAngle: start, endAngle: end)
                        arc.lineWidth = 3 * k; arc.lineCapStyle = .round
                        arc.stroke()
                    }
                }
            }
            return true
        }
    }
}

/// One skill in the bar: round icon, glow ring when lit, lock when it still needs something, name below.
private final class SkillTile: NSView {
    var onClick: ((SkillTile) -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    private let disc = NSView()
    private let icon = NSImageView()
    private let lock = NSTextField(labelWithString: "🔒")
    private let label = NSTextField(labelWithString: "")
    private let id: String

    init(skill: Skill) {
        id = skill.id
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        disc.wantsLayer = true
        disc.layer?.cornerRadius = 30
        disc.layer?.borderWidth = 2
        disc.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        lock.font = .systemFont(ofSize: 12)
        lock.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = skill.name
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disc); disc.addSubview(icon); addSubview(lock); addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 96),
            heightAnchor.constraint(equalToConstant: 108),
            disc.widthAnchor.constraint(equalToConstant: 60), disc.heightAnchor.constraint(equalToConstant: 60),
            disc.centerXAnchor.constraint(equalTo: centerXAnchor),
            disc.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 34), icon.heightAnchor.constraint(equalToConstant: 34),
            icon.centerXAnchor.constraint(equalTo: disc.centerXAnchor), icon.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            lock.trailingAnchor.constraint(equalTo: disc.trailingAnchor, constant: 4),
            lock.bottomAnchor.constraint(equalTo: disc.bottomAnchor, constant: 2),
            label.topAnchor.constraint(equalTo: disc.bottomAnchor, constant: 8),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor)])
        toolTip = L10n.t(skill.summary)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// lit = switched on and usable; locked = still needs a subscription.
    func show(lit: Bool, locked: Bool) {
        let c = lit ? kAmber : NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        icon.image = SkillIcon.image(id, size: 34, color: c)
        disc.layer?.backgroundColor = (lit ? kAmber.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.05)).cgColor
        disc.layer?.borderColor = (lit ? kAmber : NSColor.white.withAlphaComponent(0.12)).cgColor
        label.textColor = lit ? .labelColor : .secondaryLabelColor
        lock.isHidden = !locked
        disc.layer?.removeAnimation(forKey: "glow")
        if lit {
            disc.layer?.masksToBounds = false
            disc.layer?.shadowColor = kAmber.cgColor
            disc.layer?.shadowOffset = .zero
            disc.layer?.shadowRadius = 10
            disc.layer?.shadowOpacity = 0.75
            let g = CABasicAnimation(keyPath: "shadowOpacity")
            g.fromValue = 0.35; g.toValue = 0.9; g.duration = 1.8
            g.autoreverses = true; g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            disc.layer?.add(g, forKey: "glow")
        } else {
            disc.layer?.shadowOpacity = 0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
    }
    override func mouseDown(with event: NSEvent) { onClick?(self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// One icon in the bubble's left rail: small round disc, amber glow when lit, card on hover, click to switch.
final class SkillRailIcon: NSView {
    let id: String
    var onClick: ((String) -> Void)?
    private let disc = NSView()
    private let icon = NSImageView()
    private let lock = NSTextField(labelWithString: "🔒")
    private var item: SkillsPane.RailItem?
    private let popover = NSPopover()
    private var hovering = false

    init(id: String) {
        self.id = id
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        wantsLayer = true
        disc.wantsLayer = true
        disc.frame = bounds
        disc.layer?.cornerRadius = 16
        disc.layer?.borderWidth = 1.5
        disc.layer?.masksToBounds = false
        icon.frame = bounds.insetBy(dx: 7, dy: 7)
        icon.imageScaling = .scaleProportionallyUpOrDown
        lock.font = .systemFont(ofSize: 8)
        lock.frame = NSRect(x: 20, y: -3, width: 14, height: 12)
        addSubview(disc); disc.addSubview(icon); addSubview(lock)
        popover.behavior = .applicationDefined
        popover.animates = false
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ it: SkillsPane.RailItem) {
        item = it
        let c = it.lit ? kAmber : Theme.fg.withAlphaComponent(0.45)
        icon.image = SkillIcon.image(id, size: 18, color: c)
        disc.layer?.backgroundColor = (it.lit ? kAmber.withAlphaComponent(0.14) : Theme.fg.withAlphaComponent(0.06)).cgColor
        disc.layer?.borderColor = (it.lit ? kAmber : Theme.fg.withAlphaComponent(0.14)).cgColor
        lock.isHidden = !it.locked
        disc.layer?.removeAnimation(forKey: "glow")
        if it.lit {
            disc.layer?.shadowColor = kAmber.cgColor
            disc.layer?.shadowOffset = .zero
            disc.layer?.shadowRadius = 6
            disc.layer?.shadowOpacity = 0.7
            let g = CABasicAnimation(keyPath: "shadowOpacity")
            g.fromValue = 0.3; g.toValue = 0.85; g.duration = 1.8
            g.autoreverses = true; g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            disc.layer?.add(g, forKey: "glow")
        } else {
            disc.layer?.shadowOpacity = 0
        }
        if popover.isShown { popover.contentViewController = card(it) }
    }

    /// Hover card: name, intro, how to light it up, and what a click does.
    private func card(_ it: SkillsPane.RailItem) -> NSViewController {
        let vc = NSViewController()
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        col.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let head = NSStackView()
        head.orientation = .horizontal
        head.spacing = 6
        let ic = NSImageView(image: SkillIcon.image(id, size: 18, color: kAmber))
        let nm = NSTextField(labelWithString: it.name)
        nm.font = .systemFont(ofSize: 13, weight: .bold)
        let st = NSTextField(labelWithString: L10n.t(it.lit ? "已点亮" : "未点亮"))
        st.font = .systemFont(ofSize: 11, weight: .medium)
        st.textColor = it.lit ? kAmber : .secondaryLabelColor
        for v in [ic, nm, st] as [NSView] { head.addArrangedSubview(v) }
        let sm = NSTextField(wrappingLabelWithString: it.summary)
        sm.font = .systemFont(ofSize: 12)
        let ct = NSTextField(labelWithString: L10n.t("点亮条件"))
        ct.font = .systemFont(ofSize: 11, weight: .semibold)
        ct.textColor = kAmber
        let cd = NSTextField(wrappingLabelWithString: it.condition)
        cd.font = .systemFont(ofSize: 11)
        cd.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: L10n.t(it.lit ? "点一下关闭" : (it.locked ? "点一下订阅" : "点一下打开")))
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = .tertiaryLabelColor
        for v in [head, sm, ct, cd, hint] as [NSView] { col.addArrangedSubview(v) }
        for v in [sm, cd] { v.widthAnchor.constraint(equalToConstant: 230).isActive = true }
        col.setCustomSpacing(10, after: sm)
        col.setCustomSpacing(10, after: cd)
        vc.view = col
        return vc
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        guard let it = item else { return }
        popover.appearance = Theme.bubbleAppearance
        popover.contentViewController = card(it)
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minX)
    }
    override func mouseExited(with event: NSEvent) { hovering = false; popover.close() }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { popover.close() } }
    override func mouseDown(with event: NSEvent) { onClick?(id) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class SkillsPane: NSObject, NSTextFieldDelegate {
    weak var xbuddy: XCompanion?
    /// Called when a skill is switched (so the app can react right away).
    var onChanged: ((String, Bool) -> Void)?

    private var skills: [Skill] = []
    private var tiles: [SkillTile] = []
    private var switches: [String: NSSwitch] = [:]
    private var badges: [String: NSButton] = [:]
    private var conditionLabels: [String: NSTextField] = [:]
    private var statusLabels: [String: NSTextField] = [:]
    private let popover = NSPopover()
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
        page.hint("点亮的技能会发光。点一个技能，看它的介绍和点亮条件。")
        page.space(14)

        // 技能栏: one tile per skill, left to right; the settings of the selected skill show below.
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.alignment = .top
        for (i, sk) in skills.enumerated() {
            let t = SkillTile(skill: sk)
            t.onClick = { [weak self] tile in
                self?.select(i)
                self?.showCard(i, from: tile)
            }
            bar.addArrangedSubview(t)
            tiles.append(t)
        }
        let barWrap = NSView()
        barWrap.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        barWrap.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: barWrap.leadingAnchor, constant: 8),
            bar.topAnchor.constraint(equalTo: barWrap.topAnchor, constant: 6),
            bar.bottomAnchor.constraint(equalTo: barWrap.bottomAnchor, constant: -6),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: barWrap.trailingAnchor, constant: -8)])
        let group = SK.Group()
        group.add(barWrap)
        page.add(group)
        popover.behavior = .transient
        refresh()

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
        for (k, t) in tiles.enumerated() { t.selected = k == i }
        detailTitle.stringValue = "\(skills[i].name) · 设置"
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

    /// What it takes to light this skill up, in plain words.
    private func condition(_ sk: Skill) -> String {
        var lines: [String] = []
        if !sk.paid || !Billing.enabled {
            lines.append(L10n.t("公测期间免费，打开开关就能点亮。"))
        } else if Billing.isSubscribed(sk.id) {
            lines.append(L10n.t("已订阅，打开开关就能点亮。"))
        } else if Billing.trialStart(sk.id) != nil && Billing.trialLeft(sk.id) > 0 {
            lines.append(L10n.english ? "On trial, \(Billing.trialLeft(sk.id)) days left. Turn it on to light it up."
                                      : "试用中，还剩 \(Billing.trialLeft(sk.id)) 天，打开开关就能点亮。")
        } else {
            lines.append(L10n.english ? "Subscribe separately (\(Billing.price(sk.id))). Free trial for \(Billing.trialDays) days first."
                                      : "单独订阅 \(Billing.price(sk.id))，可以先免费试用 \(Billing.trialDays) 天。")
        }
        switch sk.id {
        case "x", "agent": lines.append(L10n.t("还需要：系统设置里的「辅助功能」权限。"))
        case "miao": lines.append(L10n.t("还需要：「屏幕录制」和「语音识别」权限。"))
        default: break
        }
        return lines.joined(separator: "\n")
    }

    private func lit(_ sk: Skill) -> Bool { sk.isOn() && (!sk.paid || Billing.isUnlocked(sk.id)) }

    // MARK: 弹窗左侧的竖版技能栏 (bubble rail)

    /// Posted after any skill switch changes, so the bubble's rail can follow.
    static let changed = Notification.Name("OrdCat.skillsChanged")
    struct RailItem { let id: String; let name: String; let summary: String; let condition: String; let lit: Bool; let locked: Bool }

    private func ensureSkills() { if skills.isEmpty { skills = makeSkills() } }

    func railItems() -> [RailItem] {
        ensureSkills()
        return skills.map { sk in
            RailItem(id: sk.id, name: sk.name, summary: L10n.t(sk.summary), condition: condition(sk), lit: lit(sk),
                     locked: sk.paid && Billing.enabled && !Billing.isUnlocked(sk.id))
        }
    }

    /// One click on the rail: lit → off; off → on; still locked → the subscribe sheet.
    func toggle(_ id: String) {
        ensureSkills()
        guard let sk = skills.first(where: { $0.id == id }) else { return }
        if lit(sk) {
            sk.setOn(false)
        } else if sk.paid && !Billing.isUnlocked(id) {
            Billing.showSubscribe(id, name: sk.name) { [weak self] in
                if Billing.isUnlocked(id) { sk.setOn(true) }
                self?.refresh()
            }
            return
        } else {
            sk.setOn(true)
        }
        refresh()
    }

    /// The card that pops up from a tile: name, intro, condition, and the switch (or subscribe).
    private func showCard(_ i: Int, from tile: NSView) {
        let sk = skills[i]
        let vc = NSViewController()
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 8
        col.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        let head = NSStackView()
        head.orientation = .horizontal
        head.spacing = 8
        let ic = NSImageView(image: SkillIcon.image(sk.id, size: 22, color: kAmber))
        let nm = NSTextField(labelWithString: sk.name)
        nm.font = .systemFont(ofSize: 15, weight: .bold)
        head.addArrangedSubview(ic); head.addArrangedSubview(nm)
        let sm = NSTextField(wrappingLabelWithString: L10n.t(sk.summary))
        sm.font = .systemFont(ofSize: 12)
        let ct = NSTextField(labelWithString: L10n.t("点亮条件"))
        ct.font = .systemFont(ofSize: 12, weight: .semibold)
        ct.textColor = kAmber
        let cd = NSTextField(wrappingLabelWithString: condition(sk))
        cd.font = .systemFont(ofSize: 12)
        cd.textColor = .secondaryLabelColor
        conditionLabels[sk.id] = cd
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        let st = NSTextField(labelWithString: L10n.t(lit(sk) ? "已点亮" : "未点亮"))
        st.font = .systemFont(ofSize: 12, weight: .medium)
        st.textColor = lit(sk) ? kAmber : .secondaryLabelColor
        statusLabels[sk.id] = st
        row.addArrangedSubview(st)
        if sk.paid && Billing.enabled && !Billing.isSubscribed(sk.id) {
            let b = OCButton(title: "订阅", target: self, action: #selector(subscribe(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(sk.id)
            row.addArrangedSubview(b)
        }
        let sw = NSSwitch()
        sw.controlSize = .small
        sw.state = lit(sk) ? .on : .off
        sw.identifier = NSUserInterfaceItemIdentifier(sk.id)
        sw.target = self
        sw.action = #selector(switched(_:))
        row.addArrangedSubview(sw)
        switches[sk.id] = sw
        for v in [head, sm, ct, cd, row] as [NSView] { col.addArrangedSubview(v) }
        for v in [sm, cd] { v.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        col.setCustomSpacing(12, after: sm)
        col.setCustomSpacing(12, after: cd)
        vc.view = col
        popover.contentViewController = vc
        popover.show(relativeTo: tile.bounds, of: tile, preferredEdge: .maxY)
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
        for (i, sk) in skills.enumerated() {
            switches[sk.id]?.state = lit(sk) ? .on : .off
            badges[sk.id]?.title = badge(sk.id)
            conditionLabels[sk.id]?.stringValue = condition(sk)
            statusLabels[sk.id]?.stringValue = L10n.t(lit(sk) ? "已点亮" : "未点亮")
            statusLabels[sk.id]?.textColor = lit(sk) ? kAmber : .secondaryLabelColor
            if i < tiles.count {
                tiles[i].show(lit: lit(sk), locked: sk.paid && Billing.enabled && !Billing.isUnlocked(sk.id))
            }
        }
        if let xb = xbuddy { xStats.stringValue = "\(xb.stats)\n订阅：\(Billing.statusLine("x"))" }
        NotificationCenter.default.post(name: SkillsPane.changed, object: nil)
    }

    // MARK: the skills

    private func makeSkills() -> [Skill] {
        [
            Skill(id: "x", emoji: "🐦", name: "喵推",
                  summary: "陪你刷 X，认人、标出营销号和水评、帮你想回复",
                  paid: true,
                  isOn: { Prefs.xMode },
                  setOn: { on in
                      Prefs.xMode = on
                      if on { Prefs.xOffered = true; _ = SelectionWatcher.trusted(prompt: true) }
                  },
                  settings: { [weak self] in self?.xSettings() ?? NSView() })
,
            Skill(id: "agent", emoji: "🤖", name: "喵手",
                  summary: "说「帮我……」，小猫替你一步步点、输入、开应用",
                  paid: true,
                  isOn: { Prefs.agentOn },
                  setOn: { on in
                      Prefs.agentOn = on
                      if on { _ = SelectionWatcher.trusted(prompt: true) }
                  },
                  settings: { [weak self] in self?.agentSettings() ?? NSView() })

,
            Skill(id: "miao", emoji: "🎧", name: "喵传",
                  summary: "会议和 X Spaces 实时字幕加翻译，随时问刚才在说什么",
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
        a.messageText = "喵推 · 检查结果"
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
