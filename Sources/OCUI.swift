// OrdCat — unified UI kit (v0.2.43): one button look for the whole app, amber brand, press animation.
//
// OCButton is a drop-in NSButton: `OCButton(title:target:action:)` keeps every target / action / enabled
// rule, but draws its own rounded "module" (fill + hairline border) instead of the system bezel.
// Style is picked from the title (保存 / 发布… = primary, 清空 / 删除… = danger) unless set explicitly.

import AppKit
import QuartzCore

enum OCStyle { case primary, secondary, neutral, danger }

final class OCButton: NSButton {
    /// Set to force a style; nil = choose from the title.
    var forcedStyle: OCStyle? { didSet { refresh() } }
    var style: OCStyle {
        get { forcedStyle ?? OCButton.auto(rawTitle ?? title) }
        set { forcedStyle = newValue }
    }
    private var small = false
    /// Compact pill for tight spots (chat bubble header): 20pt tall, 11pt text, small padding.
    var chip = false {
        didSet {
            layer?.cornerRadius = chip ? 6 : 8
            font = .systemFont(ofSize: chip ? 11 : (small ? 11 : 13), weight: .medium)
            invalidateIntrinsicContentSize(); refresh()
        }
    }
    /// The title as the code set it (before the English swizzle translates it), for picking the style.
    private var rawTitle: String?
    private var hovering = false
    private var pressing = false
    private var area: NSTrackingArea?

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        super.isBordered = false
        super.bezelStyle = .rounded
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        focusRingType = .none
        font = .systemFont(ofSize: 13, weight: .medium)
        refresh()
    }

    // The system bezel is never drawn; callers that set these keep working.
    override var isBordered: Bool { get { false } set { } }
    override var bezelStyle: NSButton.BezelStyle { get { super.bezelStyle } set { } }
    override var controlSize: NSControl.ControlSize {
        didSet {
            small = controlSize == .small || controlSize == .mini
            font = .systemFont(ofSize: (small || chip) ? 11 : 13, weight: .medium)
            invalidateIntrinsicContentSize(); refresh()
        }
    }
    override var title: String { willSet { if !newValue.isEmpty { rawTitle = newValue } } didSet { invalidateIntrinsicContentSize(); refresh() } }
    override var isEnabled: Bool { didSet { refresh() } }
    override var font: NSFont? { didSet { invalidateIntrinsicContentSize(); refresh() } }
    override var alignment: NSTextAlignment { didSet { refresh() } }
    override var contentTintColor: NSColor? { get { super.contentTintColor } set { } }

    static let primaryTitles: Set<String> = [
        "保存", "发布", "发布任务", "打开猫帮圈", "打开信号站", "发出信号", "提交答案", "立即更新",
        "登录 / 注册", "✏️  发起新对话", "分享当前桌面"]

    static func auto(_ t: String) -> OCStyle {
        let s = t.trimmingCharacters(in: .whitespaces)
        if primaryTitles.contains(s) { return .primary }
        for k in ["清空", "删除", "退出登录", "注销", "放弃", "移除", "清除"] where s.contains(k) { return .danger }
        if s == "取消" || s == "关闭" || s == "✕" { return .neutral }
        return .secondary
    }

    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        if chip { return NSSize(width: ceil(s.width + (title.count <= 1 ? 8 : 12)), height: 20) }
        let pad: CGFloat = (title.isEmpty && image != nil) ? 16 : (small ? 20 : 28)
        return NSSize(width: ceil(s.width + pad), height: small ? 24 : 30)
    }
    override func sizeToFit() { setFrameSize(intrinsicContentSize) }

    // MARK: colours

    private func colors() -> (bg: NSColor, border: NSColor, text: NSColor) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let step: CGFloat = pressing ? 2 : (hovering ? 1 : 0)
        switch style {
        case .primary:
            var bg = kAmber
            if pressing { bg = kAmber.blended(withFraction: 0.14, of: .black) ?? kAmber }
            else if hovering { bg = kAmber.blended(withFraction: 0.14, of: .white) ?? kAmber }
            return (bg, kAmber.withAlphaComponent(0), NSColor(srgbRed: 0.12, green: 0.13, blue: 0.13, alpha: 1))
        case .secondary:
            let text = dark ? kAmber : NSColor(srgbRed: 0.72, green: 0.43, blue: 0, alpha: 1)
            return (kAmber.withAlphaComponent(0.16 + 0.08 * step), kAmber.withAlphaComponent(0.35 + 0.1 * step), text)
        case .neutral:
            let base: NSColor = dark ? .white : .black
            return (base.withAlphaComponent(0.07 + 0.05 * step), base.withAlphaComponent(0.12), .labelColor)
        case .danger:
            return (NSColor.systemRed.withAlphaComponent(0.13 + 0.07 * step),
                    NSColor.systemRed.withAlphaComponent(0.3 + 0.1 * step), .systemRed)
        }
    }

    private var refreshing = false
    private func refresh() {
        guard let layer = layer, !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        var c: (bg: NSColor, border: NSColor, text: NSColor) = (.clear, .clear, .labelColor)
        effectiveAppearance.performAsCurrentDrawingAppearance { c = self.colors() }
        CATransaction.begin(); CATransaction.setAnimationDuration(0.12)
        layer.backgroundColor = c.bg.cgColor
        layer.borderColor = c.border.cgColor
        CATransaction.commit()
        super.contentTintColor = c.text
        let p = NSMutableParagraphStyle(); p.alignment = alignment == .left ? .left : .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? .systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: c.text, .paragraphStyle: p])
        alphaValue = isEnabled ? 1 : 0.4
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }

    // MARK: interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a); area = a
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressing = true; refresh(); squeeze(true)
        super.mouseDown(with: event)          // runs the tracking loop; fires the action on mouse-up inside
        pressing = false; refresh(); squeeze(false)
    }

    private func scaled(_ s: CGFloat) -> CATransform3D {
        let w = bounds.width / 2, h = bounds.height / 2
        var t = CATransform3DMakeTranslation(w, h, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -w, -h, 0)
    }

    private func squeeze(_ down: Bool) {
        guard let layer = layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let from = layer.presentation()?.transform ?? layer.transform
        let to = down ? scaled(0.96) : CATransform3DIdentity
        let a: CABasicAnimation
        if down {
            a = CABasicAnimation(keyPath: "transform")
            a.duration = 0.08
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        } else {
            let s = CASpringAnimation(keyPath: "transform")
            s.damping = 12; s.stiffness = 300; s.mass = 0.6; s.initialVelocity = 4
            s.duration = s.settlingDuration
            a = s
        }
        a.fromValue = NSValue(caTransform3D: from)
        a.toValue = NSValue(caTransform3D: to)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = to
        CATransaction.commit()
        layer.add(a, forKey: "oc.press")
    }
}

/// Amber look for the app's segmented tabs (猫帮圈 / 信号站 windows).
func ocStyleTabs(_ s: NSSegmentedControl) {
    s.segmentStyle = .rounded
    s.selectedSegmentBezelColor = kAmber
}

/// A rounded card container (Moments-style feed items).
final class OCCard: NSView {
    var hoverable = true
    private var hovering = false { didSet { refresh() } }
    private var area: NSTrackingArea?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func refresh() {
        var bg = NSColor.clear, border = NSColor.clear
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let base: NSColor = dark ? .white : .black
            bg = base.withAlphaComponent(self.hovering ? 0.07 : 0.04)
            border = base.withAlphaComponent(self.hovering ? 0.12 : 0.08)
        }
        layer?.backgroundColor = bg.cgColor
        layer?.borderColor = border.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        guard hoverable else { return }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a); area = a
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

/// Short relative time like 朋友圈: 刚刚 / 5分钟前 / 3小时前 / 2天前 / 11月20日.
func ocRelativeTime(_ d: Date) -> String {
    let s = -d.timeIntervalSinceNow
    if s < 60 { return L10n.english ? "just now" : "刚刚" }
    if s < 3600 { let m = Int(s / 60); return L10n.english ? "\(m) min ago" : "\(m)分钟前" }
    if s < 86400 { let h = Int(s / 3600); return L10n.english ? "\(h) h ago" : "\(h)小时前" }
    if s < 86400 * 7 { let n = Int(s / 86400); return L10n.english ? "\(n) d ago" : "\(n)天前" }
    let f = DateFormatter(); f.dateFormat = L10n.english ? "MMM d" : "M月d日"
    return f.string(from: d)
}


/// One confirm popup for every save and account action (Lang 2026-11-23: 所有保存都要弹窗确认).
enum OCConfirm {
    /// Returns true when the user presses the first button. `info` should say what will change.
    @discardableResult
    static func ask(_ title: String, _ info: String = "", ok: String = "确认", danger: Bool = false, icon: NSImage? = nil) -> Bool {
        let a = NSAlert()
        a.alertStyle = danger ? .critical : .informational
        a.messageText = title
        a.informativeText = info
        if let i = icon { a.icon = i }
        a.addButton(withTitle: ok)
        let cancel = a.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    /// "旧 → 新" lines for the fields that actually changed; empty when nothing changed.
    static func diff(_ rows: [(String, String, String)]) -> String {
        rows.filter { $0.1 != $0.2 }.map { r in
            let a = r.1.isEmpty ? "（空）" : r.1, b = r.2.isEmpty ? "（空）" : r.2
            return "\(r.0)：\(a) → \(b)"
        }.joined(separator: "\n")
    }
}
