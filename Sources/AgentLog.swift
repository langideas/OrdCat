// OrdCat — 喵手的设置和操作记录 (v0.2.56).
//
// Settings live in Prefs (UserDefaults). Each run of 喵手 is kept on this Mac as one JSON file:
//   ~/Library/Application Support/OrdCat/MiaoShou/runs.json   (newest first, at most 500 runs)
// Nothing here is sent anywhere. 设置 → 技能 → 喵手 → 📋 操作记录 opens the window.

import Cocoa

extension Prefs {
    /// 0 慢 · 1 正常 · 2 快
    static var agentSpeed: Int { get { d.object(forKey: "agentSpeed") as? Int ?? 1 } set { d.set(newValue, forKey: "agentSpeed") } }
    static var agentMaxSteps: Int { get { d.object(forKey: "agentMaxSteps") as? Int ?? 25 } set { d.set(newValue, forKey: "agentMaxSteps") } }
    /// Flash an amber ring on the target before clicking or typing.
    static var agentMark: Bool { get { d.object(forKey: "agentMark") as? Bool ?? true } set { d.set(newValue, forKey: "agentMark") } }
    /// Apps the cat never operates: bundle ids (or app names).
    static var agentBlocked: [String] {
        get { d.stringArray(forKey: "agentBlocked") ?? ["com.apple.keychainaccess", "com.apple.systempreferences", "com.apple.Terminal"] }
        set { d.set(newValue, forKey: "agentBlocked") }
    }
    /// Extra words that always need a yes, comma separated.
    static var agentExtraWords: String { get { d.string(forKey: "agentExtraWords") ?? "" } set { d.set(newValue, forKey: "agentExtraWords") } }
    /// Read the text already inside input boxes (sent to the model as context).
    static var agentReadFields: Bool { get { d.object(forKey: "agentReadFields") as? Bool ?? true } set { d.set(newValue, forKey: "agentReadFields") } }
    /// Put a 🔔 reminder when a run is done or stopped.
    static var agentNotify: Bool { get { d.object(forKey: "agentNotify") as? Bool ?? true } set { d.set(newValue, forKey: "agentNotify") } }
    static var agentKeepLog: Bool { get { d.object(forKey: "agentKeepLog") as? Bool ?? true } set { d.set(newValue, forKey: "agentKeepLog") } }
    /// Days to keep runs; 0 = keep them all.
    static var agentKeepDays: Int { get { d.object(forKey: "agentKeepDays") as? Int ?? 30 } set { d.set(newValue, forKey: "agentKeepDays") } }
}

enum AgentRules {
    static let speeds: [(String, Double)] = [("慢", 1.7), ("正常", 1.0), ("快", 0.6)]
    static let stepChoices = [10, 25, 50]
    static let keepChoices: [(String, Int)] = [("7 天", 7), ("30 天", 30), ("一直保留", 0)]

    static var speedFactor: Double { speeds[min(max(0, Prefs.agentSpeed), speeds.count - 1)].1 }

    static var extraWords: [String] {
        Prefs.agentExtraWords
            .components(separatedBy: CharacterSet(charactersIn: ",，、;；\n"))
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    static func isBlocked(_ app: NSRunningApplication?) -> Bool {
        guard let a = app else { return false }
        return isBlocked(bundle: a.bundleIdentifier, name: a.localizedName)
    }
    static func isBlocked(bundle: String?, name: String?) -> Bool {
        let n = (name ?? "").lowercased()
        return Prefs.agentBlocked.contains { e in
            let x = e.lowercased()
            return x == (bundle ?? "").lowercased() || (!n.isEmpty && x == n)
        }
    }
    /// Blocked entry by an app name the model asked to open ("Terminal", "终端").
    static func isBlocked(openName: String) -> Bool {
        let n = openName.lowercased().trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return false }
        for e in Prefs.agentBlocked {
            if e.lowercased() == n || displayName(e).lowercased() == n { return true }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: e),
               url.deletingPathExtension().lastPathComponent.lowercased() == n { return true }
        }
        return false
    }
    /// What to show for a blocked entry: the app's own name when the bundle id is installed.
    static func displayName(_ entry: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return entry
    }
}

/// A short amber ring around the element the cat is about to use.
enum AgentMark {
    private static var window: NSWindow?

    /// `r` is in Accessibility coordinates (top-left origin of the main screen).
    static func flash(_ r: CGRect, for seconds: Double) {
        guard let main = NSScreen.screens.first else { return }
        let pad: CGFloat = 6
        let frame = NSRect(x: r.minX - pad, y: main.frame.maxY - r.maxY - pad, width: r.width + pad * 2, height: r.height + pad * 2)
        window?.orderOut(nil)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .screenSaver
        w.ignoresMouseEvents = true
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        v.layer?.cornerRadius = min(12, frame.height / 2)
        v.layer?.borderWidth = 3
        v.layer?.borderColor = kAmber.cgColor
        v.layer?.backgroundColor = kAmber.withAlphaComponent(0.10).cgColor
        v.layer?.shadowColor = kAmber.cgColor
        v.layer?.shadowRadius = 8
        v.layer?.shadowOpacity = 0.8
        v.layer?.shadowOffset = .zero
        w.contentView = v
        w.orderFrontRegardless()
        window = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if window === w { w.orderOut(nil); window = nil }
        }
    }
}

struct AgentRun: Codable {
    let id: String
    let goal: String
    var app: String
    let start: Date
    var end: Date
    var steps: [String]
    /// "done" 完成 · "stopped" 停下 · "failed" 没成功
    var result: String
    var note: String
}

enum AgentLog {
    static let changed = Notification.Name("OrdCat.agentLogChanged")
    private static let maxRuns = 500

    static var file: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrdCat/MiaoShou", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("runs.json")
    }

    static func all() -> [AgentRun] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var runs = (try? dec.decode([AgentRun].self, from: data)) ?? []
        let days = Prefs.agentKeepDays
        if days > 0 {
            let cut = Date().addingTimeInterval(-Double(days) * 86400)
            let kept = runs.filter { $0.start >= cut }
            if kept.count != runs.count { runs = kept; write(runs) }
        }
        return runs
    }

    private static func write(_ runs: [AgentRun]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(Array(runs.prefix(maxRuns))) {
            try? data.write(to: file, options: [.atomic])
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func add(_ r: AgentRun) {
        guard Prefs.agentKeepLog else { return }
        var runs = all()
        runs.insert(r, at: 0)
        write(runs)
    }
    static func delete(_ id: String) { write(all().filter { $0.id != id }) }
    static func clear() { write([]) }
    static var count: Int { all().count }

    static func resultLabel(_ r: AgentRun) -> String {
        switch r.result {
        case "done": return L10n.t("✅ 完成")
        case "failed": return L10n.t("⚠️ 没成功")
        default: return L10n.t("⏹ 停下了")
        }
    }

    static func text(_ r: AgentRun) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let secs = max(1, Int(r.end.timeIntervalSince(r.start)))
        let dur = secs < 60 ? (L10n.english ? "\(secs) s" : "\(secs) 秒") : (L10n.english ? "\(secs / 60) min" : "\(secs / 60) 分钟")
        var s = L10n.english ? "Task: \(r.goal)\nApp: \(r.app)\nStarted: \(f.string(from: r.start)) · \(dur)\nResult: \(resultLabel(r))\n"
                             : "要做的事：\(r.goal)\n应用：\(r.app)\n开始：\(f.string(from: r.start)) · 用时 \(dur)\n结果：\(resultLabel(r))\n"
        if !r.note.isEmpty { s += (L10n.english ? "Cat says: " : "小猫说：") + r.note + "\n" }
        s += "\n" + (L10n.english ? "Steps" : "步骤") + "\n"
        if r.steps.isEmpty { s += L10n.english ? "(no steps)\n" : "（没有执行步骤）\n" }
        for (i, st) in r.steps.enumerated() { s += "\(i + 1). \(st)\n" }
        return s
    }
}

/// 📋 喵手操作记录: list on the left, steps on the right; 再做一次 / 删除 / 清空.
final class AgentLogWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let shared = AgentLogWindow()
    /// Start 喵手 again with the same words.
    var onRerun: ((String) -> Void)?

    private var window: NSWindow?
    private let table = NSTableView()
    private let textView = NSTextView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private var rerunButton: OCButton!
    private var deleteButton: OCButton!
    private var clearButton: OCButton!
    private var runs: [AgentRun] = []

    func show() {
        if window == nil { build() }
        reload(keep: nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = L10n.t("📋 喵手操作记录")
        w.minSize = NSSize(width: 620, height: 360)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        let root = w.contentView!

        let col = NSTableColumn(identifier: .init("r"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 52
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let detailScroll = NSScrollView()
        detailScroll.documentView = textView
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false

        rerunButton = OCButton(title: "再做一次", target: self, action: #selector(doRerun))
        rerunButton.style = .primary
        deleteButton = OCButton(title: "删除", target: self, action: #selector(doDelete))
        clearButton = OCButton(title: "清空全部", target: self, action: #selector(doClear))
        clearButton.style = .danger
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [clearButton, spacer, deleteButton, rerunButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        empty.stringValue = L10n.t("还没有操作记录。\n跟小猫说「帮我……」，每次操作都会记在这里。只存在这台 Mac 上。")
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 13)
        empty.translatesAutoresizingMaskIntoConstraints = false

        for v in [listScroll, sep, bar, detailScroll, empty] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            listScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listScroll.topAnchor.constraint(equalTo: root.topAnchor),
            listScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            listScroll.widthAnchor.constraint(equalToConstant: 260),
            sep.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor),
            sep.topAnchor.constraint(equalTo: root.topAnchor),
            sep.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sep.widthAnchor.constraint(equalToConstant: 1),
            bar.leadingAnchor.constraint(equalTo: sep.trailingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            detailScroll.leadingAnchor.constraint(equalTo: sep.trailingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detailScroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            detailScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: AgentLog.changed, object: nil)
        window = w
    }

    @objc private func changed(_ n: Notification) {
        guard window?.isVisible == true else { return }
        reload(keep: selected?.id)
    }

    private var selected: AgentRun? {
        let r = table.selectedRow
        return r >= 0 && r < runs.count ? runs[r] : nil
    }

    private func reload(keep id: String?) {
        runs = AgentLog.all()
        table.reloadData()
        let row = id.flatMap { i in runs.firstIndex { $0.id == i } } ?? (runs.isEmpty ? -1 : 0)
        if row >= 0 { table.selectRowIndexes([row], byExtendingSelection: false) }
        let has = !runs.isEmpty
        empty.isHidden = has
        for v in [table.enclosingScrollView, textView.enclosingScrollView, rerunButton, deleteButton, clearButton] as [NSView?] {
            v?.isHidden = !has
        }
        showSelected()
    }

    private func showSelected() {
        guard let r = selected else { textView.string = ""; return }
        textView.textStorage?.setAttributedString(NSAttributedString(string: AgentLog.text(r), attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
        textView.scrollToBeginningOfDocument(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { runs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = runs[row]
        let v = NSTableCellView()
        let t = NSTextField(labelWithString: "")
        t.attributedStringValue = NSAttributedString(string: r.goal, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        t.lineBreakMode = .byTruncatingTail
        let f = DateFormatter()
        f.dateFormat = L10n.english ? "MMM d HH:mm" : "M月d日 HH:mm"
        let s = NSTextField(labelWithString: "")
        s.attributedStringValue = NSAttributedString(string: "\(f.string(from: r.start)) · \(r.app) · \(AgentLog.resultLabel(r))",
                                                     attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        s.lineBreakMode = .byTruncatingTail
        for x in [t, s] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            t.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            t.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            s.leadingAnchor.constraint(equalTo: t.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: t.trailingAnchor),
            s.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 3)
        ])
        return v
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showSelected() }

    @objc private func doRerun() {
        guard let r = selected else { return }
        guard OCConfirm.ask(L10n.t("让小猫再做一次？"), r.goal, ok: L10n.t("再做一次")) else { return }
        window?.orderOut(nil)
        onRerun?(r.goal)
    }

    @objc private func doDelete() {
        guard let r = selected else { return }
        guard OCConfirm.ask(L10n.t("删除这条操作记录？"), r.goal + "\n" + L10n.t("删除后找不回来。"), ok: L10n.t("删除"), danger: true) else { return }
        AgentLog.delete(r.id)
    }

    @objc private func doClear() {
        guard OCConfirm.ask(L10n.t("清空全部操作记录？"), L10n.t("删除后找不回来。"), ok: L10n.t("清空"), danger: true) else { return }
        AgentLog.clear()
    }
}
