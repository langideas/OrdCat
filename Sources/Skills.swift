// OrdCat — 技能面板.
//
// Every skill the cat can learn lives in one place: 设置 → 技能. Each skill has an on/off switch and its own
// settings below the list. To add a new skill later: add one `Skill` in `SkillsPane.makeSkills()` with its
// switch getter/setter and a settings-view builder. Nothing else needs to change.

import Cocoa
import UniformTypeIdentifiers


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

/// The card a skill shows (hover on the bubble rail, click in 设置 → 技能). One layout for both:
///   header   icon · name ·········· [已点亮 / 未点亮]
///   intro
///   ─────
///   点亮条件 + what it takes to own it
///   ─────
///   footer   开启状态 ·········· switch / button (settings)  or  hint (rail)
/// 点亮 = the user owns the skill (shown only). The switch or a click on the rail turns it on and off;
/// for 喵传 that means start / stop listening.
enum SkillCard {
    static let width: CGFloat = 288
    private static let inset: CGFloat = 16

    static func make(id: String, name: String, summary: String, condition: String, lit: Bool,
                     stateText: String, active: Bool, controls: [NSView], hint: String?) -> NSViewController {
        let inner = width - inset * 2
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 0
        col.translatesAutoresizingMaskIntoConstraints = false

        func label(_ t: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, wrap: Bool = false) -> NSTextField {
            let l = wrap ? NSTextField(wrappingLabelWithString: t) : NSTextField(labelWithString: t)
            l.font = .systemFont(ofSize: size, weight: weight)
            l.textColor = color
            if wrap {
                l.preferredMaxLayoutWidth = inner
                l.widthAnchor.constraint(equalToConstant: inner).isActive = true
            } else {
                l.lineBreakMode = .byTruncatingTail
            }
            return l
        }
        func row(_ views: [NSView]) -> NSStackView {
            let r = NSStackView()
            r.orientation = .horizontal
            r.alignment = .centerY
            r.spacing = 8
            for v in views { r.addArrangedSubview(v) }
            r.widthAnchor.constraint(equalToConstant: inner).isActive = true
            return r
        }
        func spacer() -> NSView {
            let v = NSView()
            v.setContentHuggingPriority(.init(1), for: .horizontal)
            v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            return v
        }
        func line() -> NSView {
            let b = NSBox()
            b.boxType = .custom
            b.borderWidth = 0
            b.fillColor = NSColor.labelColor.withAlphaComponent(0.10)
            b.heightAnchor.constraint(equalToConstant: 1).isActive = true
            b.widthAnchor.constraint(equalToConstant: inner).isActive = true
            return b
        }

        // Header
        let ic = NSImageView(image: SkillIcon.image(id, size: 20, color: lit ? kAmber : NSColor.secondaryLabelColor))
        ic.widthAnchor.constraint(equalToConstant: 20).isActive = true
        ic.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let nm = label(name, size: 14, weight: .bold)
        let chip = NSTextField(labelWithString: " " + L10n.t(lit ? "已点亮" : "未点亮") + " ")
        chip.font = .systemFont(ofSize: 10.5, weight: .semibold)
        chip.textColor = lit ? kAmber : .secondaryLabelColor
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 4
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = (lit ? kAmber.withAlphaComponent(0.6) : NSColor.secondaryLabelColor.withAlphaComponent(0.4)).cgColor
        chip.layer?.backgroundColor = (lit ? kAmber.withAlphaComponent(0.12) : NSColor.clear).cgColor
        let head = row([ic, nm, spacer(), chip])

        let sm = label(summary, size: 12.5, wrap: true)
        let ct = label(L10n.t("点亮条件"), size: 11, weight: .semibold, color: kAmber)
        let cd = label(condition, size: 11.5, color: .secondaryLabelColor, wrap: true)

        // Footer: whether it is on now, then the switch / button, or what a click does.
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = (active ? NSColor.systemGreen : NSColor.secondaryLabelColor.withAlphaComponent(0.5)).cgColor
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let stl = label(stateText, size: 12, weight: .medium, color: active ? .labelColor : .secondaryLabelColor)
        var footer: [NSView] = [dot, stl, spacer()]
        if let h = hint { footer.append(label(h, size: 11, color: .tertiaryLabelColor)) }
        footer += controls
        let foot = row(footer)

        let parts: [(NSView, CGFloat)] = [(head, 10), (sm, 12), (line(), 10), (ct, 4), (cd, 12), (line(), 10), (foot, 0)]
        for (v, gap) in parts {
            col.addArrangedSubview(v)
            col.setCustomSpacing(gap, after: v)
        }

        let host = NSView()
        host.addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: inset),
            col.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -inset),
            col.topAnchor.constraint(equalTo: host.topAnchor, constant: 14),
            col.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -14),
            host.widthAnchor.constraint(equalToConstant: width)
        ])
        host.layoutSubtreeIfNeeded()
        let vc = NSViewController()
        vc.view = host
        vc.preferredContentSize = NSSize(width: width, height: ceil(host.fittingSize.height))
        return vc
    }
}

/// One skill in the bar: round icon, glow ring when lit (owned), green dot when on, lock when it still needs a subscription.
private final class SkillTile: NSView {
    var onClick: ((SkillTile) -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    private let disc = NSView()
    private let icon = NSImageView()
    private let lock = NSTextField(labelWithString: "🔒")
    private let onDot = NSView()
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
        onDot.wantsLayer = true
        onDot.layer?.cornerRadius = 6
        onDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        onDot.layer?.borderWidth = 2
        onDot.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
        onDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disc); disc.addSubview(icon); addSubview(lock); addSubview(onDot); addSubview(label)
        NSLayoutConstraint.activate([
            onDot.widthAnchor.constraint(equalToConstant: 12), onDot.heightAnchor.constraint(equalToConstant: 12),
            onDot.trailingAnchor.constraint(equalTo: disc.trailingAnchor, constant: 1),
            onDot.bottomAnchor.constraint(equalTo: disc.bottomAnchor, constant: 1),
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

    /// lit = owned (glow); active = switched on / running (green dot); locked = still needs a subscription.
    func show(lit: Bool, active: Bool, locked: Bool) {
        onDot.isHidden = !active || locked
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
    private let onDot = NSView()
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
        onDot.wantsLayer = true
        onDot.frame = NSRect(x: 23, y: 0, width: 9, height: 9)
        onDot.layer?.cornerRadius = 4.5
        onDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        onDot.layer?.borderWidth = 1.5
        onDot.layer?.borderColor = (Theme.isDark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
        addSubview(disc); disc.addSubview(icon); addSubview(lock); addSubview(onDot)
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
        onDot.isHidden = !it.active || it.locked
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

    /// Hover card: name, intro, how to light it up, whether it is on, and what a click does.
    private func card(_ it: SkillsPane.RailItem) -> NSViewController {
        SkillCard.make(id: id, name: it.name, summary: it.summary, condition: it.condition, lit: it.lit,
                       stateText: it.stateText, active: it.active, controls: [], hint: it.hint)
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
    private let agentWords = NSTextField()
    private let xStats = SK.WrapLabel()
    private let gapOptions: [(String, Double)] = [("少：30 秒最多一次", 30), ("正常：8 秒最多一次", 8), ("多：随时提醒", 2)]

    func build(xbuddy: XCompanion?, into page: SK.Page) {
        self.xbuddy = xbuddy
        skills = makeSkills()
        page.hint("拥有的技能会发光（点亮），开启中的右下角有绿点。点一个技能，看介绍、点亮条件和开关。")
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
        if on && !owned(sk) {
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

    /// 喵传's start / stop button in its card.
    @objc private func miaoButton(_ b: NSButton) {
        popover.close()
        toggle("miao")
    }

    /// What it takes to light this skill up (own it), in plain words.
    private func condition(_ sk: Skill) -> String {
        var lines: [String] = []
        if !sk.paid || !Billing.enabled {
            lines.append(L10n.t("公测期间免费，已经点亮。"))
        } else if Billing.isSubscribed(sk.id) {
            lines.append(L10n.t("已订阅，已经点亮。"))
        } else if Billing.trialStart(sk.id) != nil && Billing.trialLeft(sk.id) > 0 {
            lines.append(L10n.english ? "On trial, \(Billing.trialLeft(sk.id)) days left."
                                      : "试用中，还剩 \(Billing.trialLeft(sk.id)) 天。")
        } else {
            lines.append(L10n.english ? "Subscribe separately (\(Billing.price(sk.id))) to light it up. Free trial for \(Billing.trialDays) days first. 20% off with Pro; included in Max."
                                      : "单独订阅 \(Billing.price(sk.id)) 就能点亮，可以先免费试用 \(Billing.trialDays) 天。Pro 打 8 折，Max 已包含。")
        }
        switch sk.id {
        case "x", "agent": lines.append(L10n.t("开启时还需要：系统设置里的「辅助功能」权限。"))
        case "miao": lines.append(L10n.t("开始时还需要：「屏幕录制」和「语音识别」权限。"))
        default: break
        }
        return lines.joined(separator: "\n")
    }

    /// 点亮: the user owns this skill (free, subscribed or on trial). Display only.
    private func owned(_ sk: Skill) -> Bool { !sk.paid || Billing.isUnlocked(sk.id) }
    /// 开启: switched on (喵传: listening right now).
    private func active(_ sk: Skill) -> Bool {
        guard owned(sk) else { return false }
        return sk.id == "miao" ? MiaoChuan.shared.running : sk.isOn()
    }
    private func lit(_ sk: Skill) -> Bool { owned(sk) }
    private func locked(_ sk: Skill) -> Bool { !owned(sk) }
    private func stateText(_ sk: Skill) -> String {
        if sk.id == "miao" { return L10n.t(active(sk) ? "正在听" : "没在听") }
        return L10n.t(active(sk) ? "已开启" : "已关闭")
    }
    private func clickHint(_ sk: Skill) -> String {
        if locked(sk) { return L10n.t("点一下订阅") }
        if sk.id == "miao" { return L10n.t(active(sk) ? "点一下停止" : "点一下开始") }
        return L10n.t(active(sk) ? "点一下关闭" : "点一下开启")
    }

    // MARK: 弹窗左侧的竖版技能栏 (bubble rail)

    /// Posted after any skill switch changes, so the bubble's rail can follow.
    static let changed = Notification.Name("OrdCat.skillsChanged")
    struct RailItem {
        let id: String; let name: String; let summary: String; let condition: String
        let lit: Bool; let active: Bool; let locked: Bool; let stateText: String; let hint: String
    }

    private func ensureSkills() { if skills.isEmpty { skills = makeSkills() } }

    func railItems() -> [RailItem] {
        ensureSkills()
        return skills.map { sk in
            RailItem(id: sk.id, name: sk.name, summary: L10n.t(sk.summary), condition: condition(sk), lit: lit(sk),
                     active: active(sk), locked: locked(sk), stateText: stateText(sk), hint: clickHint(sk))
        }
    }

    /// One click on the rail: not owned yet → the subscribe sheet; otherwise switch it on or off.
    /// 喵传 starts listening right away (its start dialog only asks which app) or stops (asks whether to save).
    func toggle(_ id: String) {
        ensureSkills()
        guard let sk = skills.first(where: { $0.id == id }) else { return }
        guard owned(sk) else {
            Billing.showSubscribe(id, name: sk.name) { [weak self] in self?.refresh() }
            return
        }
        if id == "miao" {
            if MiaoChuan.shared.running { MiaoChuan.shared.requestStop() } else { MiaoChuan.shared.begin() }
            refresh()
            return
        }
        let on = !sk.isOn()
        sk.setOn(on)
        onChanged?(id, on)
        refresh()
    }

    /// The card that pops up from a tile: name, intro, condition, and the on/off switch (喵传: start / stop; not owned: subscribe).
    private func showCard(_ i: Int, from tile: NSView) {
        let sk = skills[i]
        var controls: [NSView] = []
        if locked(sk) {
            let b = OCButton(title: "订阅", target: self, action: #selector(subscribe(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(sk.id)
            b.style = .primary
            controls.append(b)
        } else if sk.id == "miao" {
            let b = OCButton(title: active(sk) ? "停止喵传" : "开始喵传", target: self, action: #selector(miaoButton(_:)))
            b.style = active(sk) ? .neutral : .primary
            controls.append(b)
        } else {
            let sw = NSSwitch()
            sw.controlSize = .small
            sw.state = active(sk) ? .on : .off
            sw.identifier = NSUserInterfaceItemIdentifier(sk.id)
            sw.target = self
            sw.action = #selector(switched(_:))
            switches[sk.id] = sw
            controls.append(sw)
        }
        popover.appearance = nil
        popover.contentViewController = SkillCard.make(id: sk.id, name: sk.name, summary: L10n.t(sk.summary), condition: condition(sk),
                                                       lit: lit(sk), stateText: stateText(sk), active: active(sk),
                                                       controls: controls, hint: nil)
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
            switches[sk.id]?.state = active(sk) ? .on : .off
            badges[sk.id]?.title = badge(sk.id)
            if i < tiles.count {
                tiles[i].show(lit: lit(sk), active: active(sk), locked: locked(sk))
            }
        }
        if popover.isShown, let open = (popover.contentViewController?.view), open.window != nil, selected < skills.count, selected < tiles.count {
            showCard(selected, from: tiles[selected])
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
                  isOn: { MiaoChuan.shared.running },
                  setOn: { on in
                      // 喵传 has no separate switch: on = start listening, off = stop.
                      if on { MiaoChuan.shared.begin() } else { MiaoChuan.shared.requestStop(allowContinue: false) }
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
        func sw(_ on: Bool, _ sel: Selector) -> NSSwitch {
            let s = NSSwitch()
            s.state = on ? .on : .off
            s.target = self
            s.action = sel
            return s
        }
        func pop(_ items: [String], _ index: Int, _ sel: Selector) -> NSPopUpButton {
            let p = NSPopUpButton()
            for t in items { p.addItem(withTitle: L10n.t(t)) }
            p.selectItem(at: index)
            p.target = self
            p.action = sel
            return p
        }

        // 怎么执行
        put(sectionLabel("怎么执行"), in: v, full: false, gap: 8)
        let g1 = SK.Group()
        g1.add(SK.toggle("每一步都先问我（推荐）", sw(Prefs.agentConfirm, #selector(agentConfirmToggled(_:))),
                         sub: "关掉后安全的步骤自动做，发送、付款、删除这类一定先问你"))
        g1.add(SK.row("速度", pop(AgentRules.speeds.map { $0.0 }, Prefs.agentSpeed, #selector(agentSpeedChanged(_:))), fill: false))
        let stepIdx = AgentRules.stepChoices.firstIndex(of: Prefs.agentMaxSteps) ?? 1
        g1.add(SK.row("最多走几步", pop(AgentRules.stepChoices.map { L10n.english ? "\($0) steps" : "\($0) 步" }, stepIdx,
                                     #selector(agentStepsChanged(_:))), fill: false))
        g1.add(SK.toggle("操作前标出位置", sw(Prefs.agentMark, #selector(agentMarkToggled(_:))),
                         sub: "要点的按钮先亮一圈琥珀色，再点"))
        put(g1, in: v, gap: 22)

        // 安全
        put(sectionLabel("安全"), in: v, full: false, gap: 8)
        let g2 = SK.Group()
        let blocked = Prefs.agentBlocked
        if blocked.isEmpty {
            g2.add(SK.info(SK.WrapLabel("没有不让碰的应用", size: 13)))
        }
        for (i, e) in blocked.enumerated() {
            let b = SK.button("移除", self, #selector(agentUnblock(_:)))
            b.tag = i
            g2.add(SK.info(SK.WrapLabel("🚫 " + AgentRules.displayName(e), size: 13, secondary: false), b))
        }
        let add = SK.button("＋ 添加应用…", self, #selector(agentAddBlocked(_:)))
        g2.add(SK.info(SK.WrapLabel("不让小猫碰的应用：它在这些应用里不点也不输入", size: 11), add))
        agentWords.placeholderString = L10n.t("例如：转发, 退款, 确认（逗号分隔）")
        agentWords.stringValue = Prefs.agentExtraWords
        agentWords.delegate = self
        g2.add(SK.row("也要先问我的词", agentWords))
        g2.add(SK.info(SK.WrapLabel("发送、发布、付款、删除、提交这类步骤和「不碰密码框」一直开着，不能关。", size: 11)))
        put(g2, in: v, gap: 22)

        // 隐私和提醒
        put(sectionLabel("隐私和提醒"), in: v, full: false, gap: 8)
        let g3 = SK.Group()
        g3.add(SK.toggle("读取输入框里已有的文字", sw(Prefs.agentReadFields, #selector(agentReadToggled(_:))),
                         sub: "关掉后只看按钮和输入框的名字，发给模型的内容更少"))
        g3.add(SK.toggle("做完或停下时在 🔔 里提醒", sw(Prefs.agentNotify, #selector(agentNotifyToggled(_:)))))
        put(g3, in: v, gap: 22)

        // 操作记录
        put(sectionLabel("操作记录"), in: v, full: false, gap: 8)
        let g4 = SK.Group()
        g4.add(SK.toggle("保存操作记录", sw(Prefs.agentKeepLog, #selector(agentKeepToggled(_:))),
                         sub: "每次做了什么、在哪个应用、结果怎样，只存在这台 Mac 上"))
        let keepIdx = AgentRules.keepChoices.firstIndex { $0.1 == Prefs.agentKeepDays } ?? 1
        g4.add(SK.row("保留多久", pop(AgentRules.keepChoices.map { $0.0 }, keepIdx, #selector(agentKeepDaysChanged(_:))), fill: false))
        g4.add(SK.info(SK.buttons([SK.button("📋 操作记录", self, #selector(agentOpenLog)),
                                   SK.button("清空记录", self, #selector(agentClearLog))])))
        put(g4, in: v, gap: 22)

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
    @objc private func agentSpeedChanged(_ p: NSPopUpButton) { Prefs.agentSpeed = max(0, p.indexOfSelectedItem) }
    @objc private func agentStepsChanged(_ p: NSPopUpButton) {
        Prefs.agentMaxSteps = AgentRules.stepChoices[min(max(0, p.indexOfSelectedItem), AgentRules.stepChoices.count - 1)]
    }
    @objc private func agentMarkToggled(_ b: NSSwitch) { Prefs.agentMark = b.state == .on }
    @objc private func agentReadToggled(_ b: NSSwitch) { Prefs.agentReadFields = b.state == .on }
    @objc private func agentNotifyToggled(_ b: NSSwitch) { Prefs.agentNotify = b.state == .on }
    @objc private func agentKeepToggled(_ b: NSSwitch) {
        let on = b.state == .on
        if !on && AgentLog.count > 0 {
            let clear = OCConfirm.ask(L10n.t("不再保存操作记录"), L10n.t("以后的操作不会再记下来。要不要顺便删掉已经保存的记录？"),
                                      ok: L10n.t("一起删掉"), danger: true)
            if clear { AgentLog.clear() }
        }
        Prefs.agentKeepLog = on
    }
    @objc private func agentKeepDaysChanged(_ p: NSPopUpButton) {
        let new = AgentRules.keepChoices[min(max(0, p.indexOfSelectedItem), AgentRules.keepChoices.count - 1)].1
        if new > 0 && (Prefs.agentKeepDays == 0 || new < Prefs.agentKeepDays) {
            let ok = OCConfirm.ask(L10n.t("改短保留时间？"), L10n.english ? "Runs older than \(new) days will be deleted." : "超过 \(new) 天的记录会被删掉。",
                                   ok: L10n.t("确认"))
            if !ok {
                p.selectItem(at: AgentRules.keepChoices.firstIndex { $0.1 == Prefs.agentKeepDays } ?? 1)
                return
            }
        }
        Prefs.agentKeepDays = new
        _ = AgentLog.all()   // applies the new limit
    }
    @objc private func agentOpenLog() { AgentLogWindow.shared.show() }
    @objc private func agentClearLog() {
        guard AgentLog.count > 0 else { return }
        guard OCConfirm.ask(L10n.t("清空全部操作记录？"), L10n.t("删除后找不回来。"), ok: L10n.t("清空"), danger: true) else { return }
        AgentLog.clear()
    }
    @objc private func agentUnblock(_ b: NSButton) {
        var list = Prefs.agentBlocked
        guard b.tag < list.count else { return }
        let name = AgentRules.displayName(list[b.tag])
        guard OCConfirm.ask(L10n.english ? "Let the cat use \(name) again?" : "让小猫可以操作「\(name)」？",
                            L10n.t("移除后，喵手可以在这个应用里点按钮和输入。"), ok: L10n.t("移除")) else { return }
        list.remove(at: b.tag)
        Prefs.agentBlocked = list
        select(selected)
    }
    @objc private func agentAddBlocked(_ b: NSButton) {
        let menu = NSMenu()
        let have = Set(Prefs.agentBlocked.map { $0.lowercased() })
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .filter { !have.contains(($0.bundleIdentifier ?? "").lowercased()) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for a in apps {
            let it = NSMenuItem(title: a.localizedName ?? a.bundleIdentifier ?? "?", action: #selector(agentBlockPicked(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = a.bundleIdentifier
            if let ic = a.icon { ic.size = NSSize(width: 16, height: 16); it.image = ic }
            menu.addItem(it)
        }
        if !apps.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: L10n.t("从「应用程序」里选…"), action: #selector(agentBlockChoose), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }
    @objc private func agentBlockPicked(_ it: NSMenuItem) {
        guard let id = it.representedObject as? String else { return }
        addBlocked(id, name: it.title)
    }
    @objc private func agentBlockChoose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.applicationBundle]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url else { return }
        let id = Bundle(url: url)?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
        addBlocked(id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
    }
    private func addBlocked(_ id: String, name: String) {
        guard OCConfirm.ask(L10n.english ? "Stop the cat from using \(name)?" : "不让小猫操作「\(name)」？",
                            L10n.t("喵手不会在这个应用里点按钮或输入，也不会打开它。"), ok: L10n.t("添加")) else { return }
        var list = Prefs.agentBlocked
        if !list.contains(where: { $0.lowercased() == id.lowercased() }) { list.append(id) }
        Prefs.agentBlocked = list
        select(selected)
    }

    private func miaoSettings() -> NSView {
        let v = column()
        put(SK.buttons([SK.button("🎧 开始喵传", self, #selector(miaoStart)),
                        SK.button("📂 喵传记录", self, #selector(miaoRecords))]), in: v, gap: 14)
        let info = SK.WrapLabel("""
        怎么用：先打开会议、视频会议或 X Spaces，再点「开始喵传」（菜单栏的小猫菜单里也有）。选好要听的应用和语言，屏幕下方会出现字幕条：上面一行是原话，下面一行是译文。

        • 点「刚才在说什么」，小猫总结最近几分钟
        • 声音只在本机转成文字，翻译只把文字发给你设置的模型
        • 点「停止」时可以选择保存记录：小猫用你的模型整理成原文、译文和要点，只存在这台 Mac 上
        • 保存的记录点上面的「📂 喵传记录」查看，可下载成 PDF、Word、Markdown、TXT、SRT 字幕或网页
        • 需要「屏幕录制」和「语音识别」权限
        • 多人抢话、口音重的时候可能识别错
        """, size: 12)
        put(info, in: v)
        return v
    }
    @objc private func miaoStart() { MiaoChuan.shared.begin() }
    @objc private func miaoRecords() { MiaoRecordsWindow.shared.show() }

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
        if agentWords.superview != nil { Prefs.agentExtraWords = agentWords.stringValue }
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
