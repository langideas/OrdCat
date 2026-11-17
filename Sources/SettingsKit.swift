// OrdCat — 设置窗口的布局工具.
//
// The settings window is laid out with native Auto Layout, like macOS System Settings:
// a sidebar on the left, the page on the right. Nothing is scaled, so text stays sharp,
// and every page follows the window's width (text wraps, fields stretch).

import Cocoa

enum SK {
    static let labelW: CGFloat = 92

    /// A label that wraps to whatever width Auto Layout gives it (never scaled, never clipped).
    final class WrapLabel: NSTextField {
        init(_ s: String = "", size: CGFloat = 11.5, secondary: Bool = true, weight: NSFont.Weight = .regular) {
            super.init(frame: .zero)
            isEditable = false
            isSelectable = false
            isBordered = false
            isBezeled = false
            drawsBackground = false
            cell?.wraps = true
            cell?.isScrollable = false
            cell?.truncatesLastVisibleLine = false
            lineBreakMode = .byWordWrapping
            maximumNumberOfLines = 0
            font = .systemFont(ofSize: size, weight: weight)
            textColor = secondary ? .secondaryLabelColor : .labelColor
            translatesAutoresizingMaskIntoConstraints = false
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.defaultLow, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .vertical)
            stringValue = s
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            if abs(preferredMaxLayoutWidth - bounds.width) > 0.5 {
                preferredMaxLayoutWidth = bounds.width
                invalidateIntrinsicContentSize()
            }
        }
    }

    /// Shows or folds away its content without leaving the stack it sits in
    /// (hiding a stack's child would drop its width constraint).
    final class Fold: NSView {
        private let child: NSView
        private var open: [NSLayoutConstraint] = []
        private var shut: NSLayoutConstraint!
        init(_ child: NSView) {
            self.child = child
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: topAnchor),
                child.leadingAnchor.constraint(equalTo: leadingAnchor),
                child.trailingAnchor.constraint(equalTo: trailingAnchor)])
            open = [child.bottomAnchor.constraint(equalTo: bottomAnchor)]
            shut = heightAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate(open)
        }
        required init?(coder: NSCoder) { fatalError() }
        var folded = false {
            didSet {
                guard folded != oldValue else { return }
                child.isHidden = folded
                if folded { NSLayoutConstraint.deactivate(open); shut.isActive = true }
                else { shut.isActive = false; NSLayoutConstraint.activate(open) }
            }
        }
    }

    /// One settings page: a top-down column that fills the width of the window.
    final class Page: NSView {
        override var isFlipped: Bool { true }
        let stack = NSStackView()
        static let inset: CGFloat = 28
        init(title: String) {
            super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
            translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 22, left: Page.inset, bottom: 28, right: Page.inset)
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
            let t = NSTextField(labelWithString: title)
            t.font = .systemFont(ofSize: 22, weight: .bold)
            add(t, full: false, gap: 16)
        }
        required init?(coder: NSCoder) { fatalError() }

        /// Adds a view to the column; `full` stretches it to the column's width.
        func add(_ v: NSView, full: Bool = true, gap: CGFloat? = nil) {
            v.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(v)
            if full { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Page.inset).isActive = true }
            if let g = gap { stack.setCustomSpacing(g, after: v) }
        }
        func header(_ s: String) {
            if let last = stack.arrangedSubviews.last, last !== stack.arrangedSubviews.first {
                stack.setCustomSpacing(22, after: last)
            }
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 13, weight: .semibold)
            add(l, full: false, gap: 8)
        }
        func hint(_ s: String) { add(WrapLabel(s)) }
        func space(_ h: CGFloat = 12) {
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(h, after: last) }
        }

        /// Puts this page in a scroll view whose content follows the window's width.
        func scroller() -> NSScrollView {
            let sv = NSScrollView()
            sv.hasVerticalScroller = true
            sv.hasHorizontalScroller = false
            sv.autohidesScrollers = true
            sv.drawsBackground = false
            sv.borderType = .noBorder
            sv.translatesAutoresizingMaskIntoConstraints = false
            sv.documentView = self
            let clip = sv.contentView
            NSLayoutConstraint.activate([
                leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                topAnchor.constraint(equalTo: clip.topAnchor)])
            return sv
        }
    }

    /// A rounded group of rows, separated by thin lines (System Settings style).
    final class Group: NSView {
        let stack = NSStackView()
        init() {
            super.init(frame: .zero)
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 0
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor)])
        }
        required init?(coder: NSCoder) { fatalError() }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor
                layer?.borderColor = NSColor.separatorColor.cgColor
            }
            layer?.cornerRadius = 10
            layer?.borderWidth = 0.5
        }
        @discardableResult
        func add(_ row: NSView) -> NSView {
            if !stack.arrangedSubviews.isEmpty {
                let line = NSBox()
                line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return row
        }
    }

    /// Base row: at least 40pt tall, content vertically centred with 8pt breathing room.
    static func rowBox() -> NSView {
        let r = NSView()
        r.translatesAutoresizingMaskIntoConstraints = false
        r.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        let low = r.heightAnchor.constraint(equalToConstant: 40)
        low.priority = .init(200)
        low.isActive = true
        return r
    }
    private static func fit(_ v: NSView, in r: NSView) {
        v.topAnchor.constraint(greaterThanOrEqualTo: r.topAnchor, constant: 8).isActive = true
        v.bottomAnchor.constraint(lessThanOrEqualTo: r.bottomAnchor, constant: -8).isActive = true
        v.centerYAnchor.constraint(equalTo: r.centerYAnchor).isActive = true
    }

    /// 「标题 …… 控件」 row. `fill` stretches the control (text fields); otherwise it keeps its size.
    static func row(_ title: String, _ control: NSView, fill: Bool = true, maxW: CGFloat? = nil) -> NSView {
        let r = rowBox()
        let l = WrapLabel(title, size: 13, secondary: false)
        control.translatesAutoresizingMaskIntoConstraints = false
        r.addSubview(l); r.addSubview(control)
        fit(l, in: r); fit(control, in: r)
        l.leadingAnchor.constraint(equalTo: r.leadingAnchor, constant: 14).isActive = true
        l.widthAnchor.constraint(equalToConstant: labelW).isActive = true
        control.trailingAnchor.constraint(equalTo: r.trailingAnchor, constant: -14).isActive = true
        if fill && maxW == nil {
            control.leadingAnchor.constraint(equalTo: l.trailingAnchor, constant: 10).isActive = true
        } else {
            control.leadingAnchor.constraint(greaterThanOrEqualTo: l.trailingAnchor, constant: 10).isActive = true
            if let m = maxW {
                let w = control.widthAnchor.constraint(equalToConstant: m)
                w.priority = .init(700)
                w.isActive = true
            }
        }
        return r
    }

    /// Switch row: title (and an optional grey line under it) on the left, switch on the right.
    static func toggle(_ title: String, _ sw: NSSwitch, sub: String? = nil) -> NSView {
        let r = rowBox()
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2
        col.translatesAutoresizingMaskIntoConstraints = false
        let t = WrapLabel(title, size: 13, secondary: false)
        col.addArrangedSubview(t)
        t.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        if let s = sub {
            let d = WrapLabel(s, size: 11)
            col.addArrangedSubview(d)
            d.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        }
        sw.translatesAutoresizingMaskIntoConstraints = false
        sw.controlSize = .small
        r.addSubview(col); r.addSubview(sw)
        fit(col, in: r)
        sw.centerYAnchor.constraint(equalTo: r.centerYAnchor).isActive = true
        col.leadingAnchor.constraint(equalTo: r.leadingAnchor, constant: 14).isActive = true
        col.trailingAnchor.constraint(equalTo: sw.leadingAnchor, constant: -12).isActive = true
        sw.trailingAnchor.constraint(equalTo: r.trailingAnchor, constant: -14).isActive = true
        sw.setContentHuggingPriority(.required, for: .horizontal)
        sw.setContentCompressionResistancePriority(.required, for: .horizontal)
        return r
    }

    /// Free row: any view on the left that wraps, an optional control on the right.
    static func info(_ left: NSView, _ right: NSView? = nil) -> NSView {
        let r = rowBox()
        left.translatesAutoresizingMaskIntoConstraints = false
        r.addSubview(left)
        fit(left, in: r)
        left.leadingAnchor.constraint(equalTo: r.leadingAnchor, constant: 14).isActive = true
        if let c = right {
            c.translatesAutoresizingMaskIntoConstraints = false
            r.addSubview(c)
            c.centerYAnchor.constraint(equalTo: r.centerYAnchor).isActive = true
            c.trailingAnchor.constraint(equalTo: r.trailingAnchor, constant: -14).isActive = true
            left.trailingAnchor.constraint(equalTo: c.leadingAnchor, constant: -12).isActive = true
            c.setContentHuggingPriority(.required, for: .horizontal)
            c.setContentCompressionResistancePriority(.required, for: .horizontal)
        } else {
            left.trailingAnchor.constraint(equalTo: r.trailingAnchor, constant: -14).isActive = true
        }
        return r
    }

    /// A line of buttons; `trailing` pushes them to the right edge.
    static func buttons(_ bs: [NSView], trailing: Bool = false) -> NSView {
        let s = NSStackView(views: bs)
        s.orientation = .horizontal
        s.spacing = 8
        s.alignment = .centerY
        s.translatesAutoresizingMaskIntoConstraints = false
        if trailing {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            s.insertArrangedSubview(spacer, at: 0)
        }
        // Wrap so the row can be stretched to the column's width without stretching the buttons.
        s.setHuggingPriority(.init(1), for: .horizontal)
        return s
    }

    static func button(_ title: String, _ target: AnyObject, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: sel)
        b.bezelStyle = .rounded
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }
}

// MARK: - Sidebar

/// The left column: one row per page, an SF Symbol and a title, like System Settings.
final class SettingsSidebar: NSView {
    private var rows: [Item] = []
    var onSelect: ((Int) -> Void)?

    private final class Item: NSView {
        let icon = NSImageView()
        let title: NSTextField
        var onClick: (() -> Void)?
        var selected = false { didSet { needsDisplay = true; title.textColor = selected ? .white : .labelColor; icon.contentTintColor = selected ? .white : .controlAccentColor } }
        init(symbol: String, title t: String) {
            title = NSTextField(labelWithString: t)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: t)
            icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
            icon.contentTintColor = .controlAccentColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            title.font = .systemFont(ofSize: 13)
            title.translatesAutoresizingMaskIntoConstraints = false
            title.lineBreakMode = .byTruncatingTail
            addSubview(icon); addSubview(title)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 30),
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 20),
                title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                title.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        required init?(coder: NSCoder) { fatalError() }
        override func draw(_ dirtyRect: NSRect) {
            guard selected else { return }
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        override func mouseDown(with event: NSEvent) { onClick?() }
    }

    init(items: [(String, String)]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let fx = NSVisualEffectView()
        fx.material = .sidebar
        fx.blendingMode = .behindWindow
        fx.state = .followsWindowActiveState
        fx.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fx)
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 2
        s.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(s)
        NSLayoutConstraint.activate([
            fx.topAnchor.constraint(equalTo: topAnchor), fx.bottomAnchor.constraint(equalTo: bottomAnchor),
            fx.leadingAnchor.constraint(equalTo: leadingAnchor), fx.trailingAnchor.constraint(equalTo: trailingAnchor),
            s.topAnchor.constraint(equalTo: fx.topAnchor, constant: 14),
            s.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 10),
            s.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -10)])
        for (i, (sym, t)) in items.enumerated() {
            let it = Item(symbol: sym, title: t)
            it.onClick = { [weak self] in self?.select(i); self?.onSelect?(i) }
            s.addArrangedSubview(it)
            it.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
            rows.append(it)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(_ i: Int) {
        for (k, r) in rows.enumerated() { r.selected = k == i }
    }
}
