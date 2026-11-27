// OrdCat — 🔔 通知中心 (v0.2.51).
//
// One bell at the top right of the settings window. Two tabs:
//   消息 — private-message conversations (live from the server, unread counts)
//   提醒 — things the cat told you in a bubble that are worth finding again later
//          (new signals, 喵副本 tasks and answers, new versions). Kept on this Mac, newest 80.
// To log a new kind of reminder: NotifCenter.shared.add("text", open: "<handler key>") and register the
// handler key in AppDelegate (handlers["…"] = { … }).

import Cocoa

struct NotifItem: Codable {
    let id: String
    let text: String
    let date: Date
    var read: Bool
    /// Handler key run when the row is clicked ("signal", "square", "update", "dms"…).
    let open: String
}

final class NotifCenter {
    static let shared = NotifCenter()
    private let key = "notif.items"
    private(set) var items: [NotifItem] = []
    private(set) var threads: [DMThread] = []
    /// Unread private messages (from the server's dm_unread).
    var dmUnread = 0 { didSet { if dmUnread != oldValue { changed() } } }
    var handlers: [String: () -> Void] = [:]
    private var observers: [UUID: () -> Void] = [:]

    private init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([NotifItem].self, from: d) { items = v }
    }

    var unreadReminders: Int { items.filter { !$0.read }.count }
    var unreadCount: Int { unreadReminders + dmUnread }

    func add(_ text: String, open: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let first = items.first, first.text == t, !first.read { return }   // no doubles
        items.insert(NotifItem(id: UUID().uuidString, text: t, date: Date(), read: false, open: open), at: 0)
        if items.count > 80 { items.removeLast(items.count - 80) }
        save()
    }

    func open(_ item: NotifItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].read = true; save() }
        handlers[item.open]?()
    }

    func markAllRead() {
        for i in items.indices { items[i].read = true }
        save()
    }

    func clear() { items.removeAll(); save() }

    func loadThreads(_ done: @escaping () -> Void) {
        guard Account.shared.configured, Account.shared.signedIn else { threads = []; done(); return }
        Social.rpc("dm_threads") { [weak self] o, e in
            DispatchQueue.main.async {
                if e == nil { self?.threads = ((o as? [[String: Any]]) ?? []).compactMap(DMThread.init) }
                done()
            }
        }
    }

    @discardableResult
    func observe(_ f: @escaping () -> Void) -> UUID {
        let id = UUID(); observers[id] = f; return id
    }
    func stopObserving(_ id: UUID) { observers[id] = nil }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
        changed()
    }
    private func changed() {
        DispatchQueue.main.async { self.observers.values.forEach { $0() } }
    }
}

// MARK: - The bell (titlebar accessory of the settings window)

final class NotifBell: NSTitlebarAccessoryViewController {
    private let button = NSButton()
    private let badge = NSTextField(labelWithString: "")
    private let popover = NSPopover()
    private var token: UUID?

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 44, height: 28))
        button.title = "🔔"
        button.font = .systemFont(ofSize: 15)
        button.isBordered = false
        button.target = self
        button.action = #selector(toggle)
        button.toolTip = L10n.t("消息和提醒")
        button.frame = NSRect(x: 6, y: 2, width: 28, height: 24)
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.drawsBackground = false
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = 7
        badge.frame = NSRect(x: 24, y: 14, width: 16, height: 14)
        v.addSubview(button); v.addSubview(badge)
        view = v
        popover.behavior = .transient
        token = NotifCenter.shared.observe { [weak self] in self?.update() }
        update()
    }

    func update() {
        let n = NotifCenter.shared.unreadCount
        badge.isHidden = n == 0
        badge.stringValue = n > 99 ? "99+" : "\(n)"
        var f = badge.frame
        f.size.width = n > 9 ? 22 : 16
        badge.frame = f
    }

    @objc func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        show()
    }

    func show() {
        let panel = NotifPanel()
        panel.close = { [weak self] in self?.popover.performClose(nil) }
        popover.contentViewController = panel
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

// MARK: - The panel

final class NotifPanel: NSViewController {
    var close: (() -> Void)?
    private let tabs = NSSegmentedControl(labels: ["消息", "提醒"], trackingMode: .selectOne, target: nil, action: nil)
    private let list = NSStackView()
    private let empty = NSTextField(labelWithString: "")
    private let allRead = OCButton(title: "全部已读", target: nil, action: nil)
    private var token: UUID?
    private let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = L10n.english ? "MMM d, HH:mm" : "M月d日 HH:mm"
        return f
    }()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 420))
        tabs.target = self
        tabs.action = #selector(reload)
        tabs.selectedSegment = NotifCenter.shared.dmUnread > 0 || NotifCenter.shared.unreadReminders == 0 ? 0 : 1
        tabs.translatesAutoresizingMaskIntoConstraints = false
        allRead.target = self
        allRead.action = #selector(markAll)
        allRead.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlipView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs); root.addSubview(allRead); root.addSubview(scroll); root.addSubview(empty)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            allRead.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            allRead.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -8),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor)])
        view = root
        token = NotifCenter.shared.observe { [weak self] in self?.reload() }
        reload()
        NotifCenter.shared.loadThreads { [weak self] in self?.reload() }
    }

    deinit { if let t = token { NotifCenter.shared.stopObserving(t) } }

    @objc private func reload() {
        for v in list.arrangedSubviews { v.removeFromSuperview() }
        let c = NotifCenter.shared
        if tabs.selectedSegment == 0 {
            allRead.isHidden = true
            if !Account.shared.signedIn {
                empty.stringValue = L10n.t("登录后能在这里收发私信")
            } else if c.threads.isEmpty {
                empty.stringValue = L10n.t("还没有私信。在喵友列表里点「私信」开始聊天。")
            } else { empty.stringValue = "" }
            for t in c.threads {
                add(row(title: t.name, text: t.last, date: t.lastAt, unread: t.unread > 0, count: t.unread) { [weak self] in
                    self?.close?()
                    DMWindow.shared.open(peer: t.peer, name: t.name)
                })
            }
        } else {
            allRead.isHidden = c.unreadReminders == 0
            empty.stringValue = c.items.isEmpty ? L10n.t("还没有提醒") : ""
            for it in c.items {
                add(row(title: nil, text: it.text, date: it.date, unread: !it.read, count: 0) { [weak self] in
                    self?.close?()
                    NotifCenter.shared.open(it)
                })
            }
        }
        empty.isHidden = empty.stringValue.isEmpty
    }

    private func add(_ v: NSView) {
        list.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    private func row(title: String?, text: String, date: Date?, unread: Bool, count: Int, open: @escaping () -> Void) -> NSView {
        let r = NotifRow()
        r.onClick = open
        r.translatesAutoresizingMaskIntoConstraints = false
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = (unread ? kAmber : .clear).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2
        col.translatesAutoresizingMaskIntoConstraints = false
        if let t = title {
            let n = NSTextField(labelWithString: count > 0 ? "\(t)  ·  \(count)" : t)
            n.font = .systemFont(ofSize: 12.5, weight: .semibold)
            col.addArrangedSubview(n)
        }
        let body = NSTextField(wrappingLabelWithString: L10n.t(text))
        body.font = .systemFont(ofSize: 12, weight: unread && title == nil ? .medium : .regular)
        body.textColor = title == nil ? .labelColor : .secondaryLabelColor
        body.maximumNumberOfLines = 3
        body.lineBreakMode = .byTruncatingTail
        col.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        if let d = date {
            let tm = NSTextField(labelWithString: df.string(from: d))
            tm.font = .systemFont(ofSize: 10.5)
            tm.textColor = .tertiaryLabelColor
            col.addArrangedSubview(tm)
        }
        r.addSubview(dot); r.addSubview(col)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: r.leadingAnchor, constant: 8),
            dot.topAnchor.constraint(equalTo: r.topAnchor, constant: 14),
            col.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            col.trailingAnchor.constraint(equalTo: r.trailingAnchor, constant: -8),
            col.topAnchor.constraint(equalTo: r.topAnchor, constant: 8),
            col.bottomAnchor.constraint(equalTo: r.bottomAnchor, constant: -8)])
        return r
    }

    @objc private func markAll() { NotifCenter.shared.markAllRead() }
}

private final class NotifRow: NSView {
    var onClick: (() -> Void)?
    private var hover = false { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func draw(_ dirtyRect: NSRect) {
        guard hover else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
