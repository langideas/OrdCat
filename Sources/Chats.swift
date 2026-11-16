// OrdCat — conversations, categories and projects (the chat window's left sidebar).
// Everything stays on this Mac: history.json (messages) + chats.json (index).

import Cocoa

// MARK: - Models

struct ChatMessage: Codable {
    let role: String          // "user" | "assistant"
    var text: String
    var imageNames: [String]
    let date: Date
    var convo: String? = nil  // conversation id (nil only in old history, migrated on load)
}

struct Conversation: Codable {
    var id: String
    var title: String
    var category: String
    var project: String?
    var pinned: Bool
    var created: Date
    var updated: Date
    var autoTitle: Bool
    var autoCategory: Bool
    /// Renamed once by the model from what was actually said.
    var aiTitled: Bool? = nil
}

struct ChatProject: Codable {
    var id: String
    var name: String
    var emoji: String
    var pinned: Bool
    var created: Date
    var note: String          // standing instructions the cat keeps in mind for every chat in this project
}

private struct ChatIndex: Codable {
    var conversations: [Conversation]
    var projects: [ChatProject]
    var current: String?
}

/// Categories are decided locally from keywords (no extra model call, no extra cost). The user can change them.
struct ChatCategory { let name: String; let emoji: String; let words: [String] }
let kCategories: [ChatCategory] = [
    ChatCategory(name: "编程", emoji: "💻", words: ["代码", "报错", "bug", "error", "函数", "swift", "python", "java", "编译", "git", "api", "sql", "终端", "脚本", "debug", "xcode", "npm", "class ", "import "]),
    ChatCategory(name: "工作", emoji: "💼", words: ["工作", "会议", "老板", "同事", "客户", "邮件", "汇报", "项目", "简历", "面试", "方案", "合同", "ppt", "周报", "kpi", "产品"]),
    ChatCategory(name: "学习", emoji: "📚", words: ["学习", "考试", "作业", "论文", "单词", "翻译", "英语", "数学", "课程", "解释", "什么意思", "原理", "知识", "复习"]),
    ChatCategory(name: "理财", emoji: "💰", words: ["理财", "股票", "基金", "投资", "账户", "汇款", "银行", "税", "paypal", "支票", "信用卡", "收益", "比特币", "btc", "价格"]),
    ChatCategory(name: "创作", emoji: "🎨", words: ["设计", "海报", "文案", "写一", "故事", "诗", "标题", "logo", "视频", "剪辑", "配色", "小说", "画"]),
    ChatCategory(name: "网页", emoji: "🌐", words: ["这个页面", "这页", "网页", "文章", "总结一下"]),
    ChatCategory(name: "生活", emoji: "🏠", words: ["吃", "做饭", "旅行", "机票", "酒店", "健身", "睡", "天气", "购物", "买", "电影", "游戏", "医生", "身体"]),
    ChatCategory(name: "闲聊", emoji: "💬", words: []),
]
func categoryEmoji(_ name: String) -> String { kCategories.first { $0.name == name }?.emoji ?? "💬" }

// MARK: - Store

final class ChatStore {
    private(set) var messages: [ChatMessage] = []
    private(set) var conversations: [Conversation] = []
    private(set) var projects: [ChatProject] = []
    /// The conversation new messages go into. nil = a fresh chat that is created by its first message.
    private(set) var current: String?
    private var pendingProject: String?
    private var pendingTitle: String?
    private var pendingCategory: String?
    private var observers: [(Bool) -> Void] = []
    let dir: URL
    private var imagesDir: URL { dir.appendingPathComponent("images") }
    private var file: URL { dir.appendingPathComponent("history.json") }
    private var indexFile: URL { dir.appendingPathComponent("chats.json") }

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrdCat")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: file) {
            messages = (try? dec.decode([ChatMessage].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: indexFile), let idx = try? dec.decode(ChatIndex.self, from: data) {
            conversations = idx.conversations
            projects = idx.projects
            current = idx.current
        }
        migrate()
    }

    /// Old single-list history → conversations, split where the user went quiet for 3+ hours.
    private func migrate() {
        let orphans = messages.indices.filter { messages[$0].convo == nil }
        guard !orphans.isEmpty else { return }
        var made: [Conversation] = []
        var cur: Conversation?
        var lastDate: Date?
        for i in orphans {
            let m = messages[i]
            if cur == nil || m.date.timeIntervalSince(lastDate ?? m.date) > 3 * 3600 {
                if let c = cur { made.append(c) }
                cur = Conversation(id: UUID().uuidString, title: "", category: "闲聊", project: nil, pinned: false,
                                   created: m.date, updated: m.date, autoTitle: true, autoCategory: true)
            }
            messages[i].convo = cur!.id
            cur!.updated = m.date
            lastDate = m.date
            if cur!.title.isEmpty && m.role == "user" {
                cur!.title = ChatStore.makeTitle(m.text)
                cur!.category = ChatStore.classify(m.text)
            }
        }
        if let c = cur { made.append(c) }
        for i in made.indices where made[i].title.isEmpty { made[i].title = "之前的聊天" }
        conversations += made
        if current == nil { current = made.last?.id }
        save(); saveIndex()
    }

    // MARK: observing (structural = the list of chats/projects changed, not just streaming text)
    func observe(_ f: @escaping (Bool) -> Void) { observers.append(f) }
    func notify(structural: Bool = true) { for o in observers { o(structural) } }

    // MARK: reading
    var currentConversation: Conversation? { current.flatMap { id in conversations.first { $0.id == id } } }
    var currentMessages: [ChatMessage] {
        guard let c = current else { return [] }
        return messages.filter { $0.convo == c }
    }
    /// Project the next message belongs to (the open chat's, or the one a fresh chat was started in).
    var currentProject: ChatProject? {
        let pid = currentConversation?.project ?? (current == nil ? pendingProject : nil)
        return pid.flatMap { id in projects.first { $0.id == id } }
    }
    var pendingTitleShown: String? { current == nil ? pendingTitle : nil }
    func project(_ id: String?) -> ChatProject? { id.flatMap { i in projects.first { $0.id == i } } }
    /// Pinned first, then most recent.
    var sortedConversations: [Conversation] {
        conversations.sorted { a, b in a.pinned != b.pinned ? a.pinned : a.updated > b.updated }
    }
    var sortedProjects: [ChatProject] {
        projects.sorted { a, b in a.pinned != b.pinned ? a.pinned : a.created > b.created }
    }
    func contains(_ convoID: String, text q: String) -> Bool {
        messages.contains { $0.convo == convoID && $0.text.range(of: q, options: .caseInsensitive) != nil }
    }
    /// Seconds since anything was said in the open chat (∞ for a fresh chat).
    var idleTime: TimeInterval {
        guard let c = currentConversation else { return .infinity }
        return Date().timeIntervalSince(c.updated)
    }

    // MARK: writing messages
    func append(_ m: ChatMessage) {
        var m = m
        if current == nil {
            let c = Conversation(id: UUID().uuidString,
                                 title: pendingTitle ?? (m.role == "user" ? ChatStore.makeTitle(m.text) : "新对话"),
                                 category: pendingCategory ?? (m.role == "user" ? ChatStore.classify(m.text) : "闲聊"),
                                 project: pendingProject, pinned: false, created: m.date, updated: m.date,
                                 autoTitle: pendingTitle == nil, autoCategory: pendingCategory == nil)
            conversations.append(c)
            current = c.id
            pendingProject = nil; pendingTitle = nil; pendingCategory = nil
        }
        m.convo = current
        messages.append(m)
        if let i = conversations.firstIndex(where: { $0.id == current }) {
            conversations[i].updated = m.date
            // Re-guess the category from the first few user turns until the user sets one.
            if m.role == "user" && conversations[i].autoCategory {
                let turns = messages.filter { $0.convo == current && $0.role == "user" }.prefix(4).map { $0.text }
                if turns.count <= 4 { conversations[i].category = ChatStore.classify(turns.joined(separator: "\n")) }
            }
            if m.role == "user" && conversations[i].autoTitle && conversations[i].title == "新对话" {
                conversations[i].title = ChatStore.makeTitle(m.text)
            }
        }
        save(); saveIndex(); notify()
    }
    func updateLast(_ text: String) {
        guard !messages.isEmpty else { return }
        messages[messages.count - 1].text = text
        notify(structural: false)
    }
    func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(messages) { try? data.write(to: file, options: .atomic) }
    }
    private func saveIndex() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let idx = ChatIndex(conversations: conversations, projects: projects, current: current)
        if let data = try? enc.encode(idx) { try? data.write(to: indexFile, options: .atomic) }
    }
    func clear() {
        messages.removeAll()
        conversations.removeAll()
        current = nil
        pendingProject = nil; pendingTitle = nil; pendingCategory = nil
        try? FileManager.default.removeItem(at: imagesDir)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        save(); saveIndex(); notify()
    }
    func saveImage(_ data: Data) -> String? {
        let name = UUID().uuidString + ".jpg"
        do { try data.write(to: imageURL(name)); return name } catch { return nil }
    }
    func imageURL(_ name: String) -> URL { imagesDir.appendingPathComponent(name) }

    // MARK: conversations
    /// Start a fresh chat; it is only saved once something is said in it.
    func startNew(project: String? = nil, title: String? = nil, category: String? = nil) {
        current = nil
        pendingProject = project
        pendingTitle = title.map { ChatStore.makeTitle($0) }
        pendingCategory = category
        saveIndex(); notify()
    }
    func select(_ id: String) {
        guard conversations.contains(where: { $0.id == id }), current != id else { return }
        current = id
        saveIndex(); notify()
    }
    private func edit(_ id: String, _ f: (inout Conversation) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        f(&conversations[i])
        saveIndex(); notify()
    }
    /// Does this conversation still want a better title?
    func wantsAITitle(_ id: String) -> Bool {
        guard let c = conversations.first(where: { $0.id == id }) else { return false }
        return c.aiTitled != true && (c.autoTitle || c.category == "网页")
    }
    func setAITitle(_ id: String, _ t: String) {
        var t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」《》'#*。.：:"))
        if let nl = t.firstIndex(of: "\n") { t = String(t[..<nl]) }
        guard !t.isEmpty, t.count <= 24, wantsAITitle(id) else { return }
        edit(id) { $0.title = t; $0.aiTitled = true }
    }
    func rename(_ id: String, to t: String) {
        let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        edit(id) { $0.title = t; $0.autoTitle = false }
    }
    func setCategory(_ id: String, _ c: String) { edit(id) { $0.category = c; $0.autoCategory = false } }
    func move(_ id: String, toProject p: String?) { edit(id) { $0.project = p } }
    func togglePin(_ id: String) { edit(id) { $0.pinned.toggle() } }
    func deleteConversation(_ id: String) {
        for m in messages where m.convo == id {
            for n in m.imageNames { try? FileManager.default.removeItem(at: imageURL(n)) }
        }
        messages.removeAll { $0.convo == id }
        conversations.removeAll { $0.id == id }
        if current == id { current = nil }
        save(); saveIndex(); notify()
    }

    // MARK: projects
    @discardableResult
    func createProject(name: String) -> String {
        let (emoji, rest) = ChatStore.splitEmoji(name)
        let p = ChatProject(id: UUID().uuidString, name: rest.isEmpty ? "新项目" : rest, emoji: emoji ?? "📁",
                            pinned: false, created: Date(), note: "")
        projects.append(p)
        saveIndex(); notify()
        return p.id
    }
    private func editProject(_ id: String, _ f: (inout ChatProject) -> Void) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        f(&projects[i])
        saveIndex(); notify()
    }
    func renameProject(_ id: String, to name: String) {
        let (emoji, rest) = ChatStore.splitEmoji(name)
        guard !rest.isEmpty else { return }
        editProject(id) { $0.name = rest; if let e = emoji { $0.emoji = e } }
    }
    func setProjectNote(_ id: String, _ note: String) { editProject(id) { $0.note = note } }
    func toggleProjectPin(_ id: String) { editProject(id) { $0.pinned.toggle() } }
    /// Deleting a project keeps its chats (they go back to 全部) unless asked to delete them too.
    func deleteProject(_ id: String, withChats: Bool) {
        if withChats {
            for c in conversations where c.project == id { deleteConversation(c.id) }
        } else {
            for i in conversations.indices where conversations[i].project == id { conversations[i].project = nil }
        }
        projects.removeAll { $0.id == id }
        if pendingProject == id { pendingProject = nil }
        saveIndex(); notify()
    }

    // MARK: helpers
    static func makeTitle(_ text: String) -> String {
        var t = text
        if let r = t.range(of: "\n\n【附件：") { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "新对话" }
        return t.count > 22 ? String(t.prefix(22)) + "…" : t
    }
    static func classify(_ text: String) -> String {
        let s = text.lowercased()
        var best = "闲聊", bestScore = 0
        for c in kCategories {
            let score = c.words.reduce(0) { $0 + (s.contains($1) ? 1 : 0) }
            if score > bestScore { best = c.name; bestScore = score }
        }
        return best
    }
    static func splitEmoji(_ s: String) -> (String?, String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let f = t.first, f.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) else { return (nil, t) }
        return (String(f), String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Sidebar (like Gemini's: new chat, search, projects, all chats with a category filter)

final class ChatSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    enum Row {
        case header(String, filter: Bool)
        case newProject
        case project(ChatProject)
        case moreProjects(Int)
        case convo(Conversation)
        case empty(String)
    }
    let view = NSVisualEffectView()
    private let store: ChatStore
    private let table = NSTableView()
    private let search = NSSearchField()
    private var rows: [Row] = []
    private var selectedProject: String?
    private var categoryFilter: String?
    private var showAllProjects = false
    private var syncing = false
    weak var window: NSWindow?

    init(store: ChatStore) {
        self.store = store
        super.init()
        build()
    }

    private func build() {
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 600)

        let newB = NSButton(title: "✏️  发起新对话", target: self, action: #selector(newChat))
        newB.bezelStyle = .rounded
        newB.alignment = .left
        newB.keyEquivalent = "n"
        newB.keyEquivalentModifierMask = [.command]
        newB.toolTip = "开一个新对话（⌘N）"
        newB.frame = NSRect(x: 10, y: 600 - 44, width: 220, height: 30)
        newB.autoresizingMask = [.width, .minYMargin]
        view.addSubview(newB)

        search.frame = NSRect(x: 12, y: 600 - 78, width: 216, height: 24)
        search.autoresizingMask = [.width, .minYMargin]
        search.placeholderString = "搜索聊天记录"
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)
        view.addSubview(search)

        // Bottom-left: the account (avatar + name) → 设置 → 账号.
        accountButton.frame = NSRect(x: 8, y: 6, width: 224, height: 36)
        accountButton.autoresizingMask = [.width, .maxYMargin]
        accountButton.isBordered = false
        accountButton.alignment = .left
        accountButton.imagePosition = .imageLeading
        accountButton.imageScaling = .scaleProportionallyDown
        accountButton.font = .systemFont(ofSize: 13, weight: .medium)
        accountButton.target = self
        accountButton.action = #selector(openAccount)
        accountButton.toolTip = "账号与设置"
        view.addSubview(accountButton)
        let sep = NSBox(frame: NSRect(x: 8, y: 46, width: 224, height: 1))
        sep.boxType = .separator
        sep.autoresizingMask = [.width, .maxYMargin]
        view.addSubview(sep)
        refreshAccount()
        Account.shared.observe { [weak self] in self?.refreshAccount() }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 50, width: 240, height: 600 - 88 - 50))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.resizingMask = .autoresizingMask
        col.width = 228
        col.maxWidth = 2000
        table.addTableColumn(col)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .sourceList
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        view.addSubview(scroll)
        // Titles use the full sidebar width (the column used to stay 100 pt wide → "X 上的…").
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView,
                                               queue: .main) { [weak self] _ in
            guard let t = self?.table, let col = t.tableColumns.first else { return }
            col.width = max(120, t.enclosingScrollView?.contentView.bounds.width ?? 228)
        }
        reload()
    }

    // MARK: data
    func reload() {
        var r: [Row] = []
        r.append(.header("项目", filter: false))
        r.append(.newProject)
        let ps = store.sortedProjects
        let shownPs = showAllProjects ? ps : Array(ps.prefix(5))
        for p in shownPs { r.append(.project(p)) }
        if ps.count > 5 && !showAllProjects { r.append(.moreProjects(ps.count)) }

        var head = "全部"
        if let p = store.project(selectedProject) { head = "\(p.emoji) \(p.name)" }
        if let c = categoryFilter { head += " · \(categoryEmoji(c)) \(c)" }
        r.append(.header(head, filter: true))
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        let list = store.sortedConversations.filter { c in
            (selectedProject == nil || c.project == selectedProject) &&
            (categoryFilter == nil || c.category == categoryFilter) &&
            (q.isEmpty || c.title.range(of: q, options: .caseInsensitive) != nil || store.contains(c.id, text: q))
        }
        if list.isEmpty {
            r.append(.empty(q.isEmpty ? (selectedProject != nil ? "这个项目里还没有对话" : "还没有对话") : "没找到相关的聊天"))
        }
        for c in list { r.append(.convo(c)) }
        rows = r
        table.reloadData()
        syncSelection()
    }
    private func syncSelection() {
        syncing = true
        if let cur = store.current, let i = rows.firstIndex(where: { if case .convo(let c) = $0 { return c.id == cur }; return false }) {
            table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        syncing = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return row == 0 ? 22 : 30 }
        return 26
    }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if syncing { return true }
        if case .convo = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        var trailing: CGFloat = -6
        switch rows[row] {
        case .header(let t, filter: let filter):
            tf.stringValue = t
            tf.font = .systemFont(ofSize: 11, weight: .semibold)
            tf.textColor = .secondaryLabelColor
            if filter {
                let b = NSButton(title: categoryFilter == nil ? "分类 ▾" : "\(categoryEmoji(categoryFilter!)) ▾",
                                 target: self, action: #selector(showFilter(_:)))
                b.isBordered = false
                b.font = .systemFont(ofSize: 11)
                b.contentTintColor = .secondaryLabelColor
                b.toolTip = "按分类筛选"
                b.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(b)
                NSLayoutConstraint.activate([b.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                                             b.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
                trailing = -60
                if selectedProject != nil || categoryFilter != nil {
                    let x = NSButton(title: "✕", target: self, action: #selector(clearFilters))
                    x.isBordered = false
                    x.font = .systemFont(ofSize: 11)
                    x.contentTintColor = .secondaryLabelColor
                    x.toolTip = "显示全部对话"
                    x.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(x)
                    NSLayoutConstraint.activate([x.trailingAnchor.constraint(equalTo: b.leadingAnchor, constant: -2),
                                                 x.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
                    trailing = -80
                }
            }
        case .newProject:
            tf.stringValue = "＋  新建项目"
            tf.font = .systemFont(ofSize: 13)
        case .project(let p):
            tf.stringValue = "\(p.emoji)  \(p.name)" + (p.pinned ? "  📌" : "")
            tf.font = .systemFont(ofSize: 13, weight: p.id == selectedProject ? .semibold : .regular)
            if p.id == selectedProject { tf.textColor = kAmber }
        case .moreProjects(let n):
            tf.stringValue = "⋯  所有项目（\(n)）"
            tf.font = .systemFont(ofSize: 13)
            tf.textColor = .secondaryLabelColor
        case .convo(let c):
            tf.stringValue = "\(categoryEmoji(c.category))  \(c.title)" + (c.pinned ? "  📌" : "")
            tf.font = .systemFont(ofSize: 13, weight: c.id == store.current ? .semibold : .regular)
            tf.toolTip = c.title
        case .empty(let t):
            tf.stringValue = t
            tf.font = .systemFont(ofSize: 12)
            tf.textColor = .tertiaryLabelColor
        }
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: trailing),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: actions
    @objc func newChat() {
        store.startNew(project: selectedProject)
    }
    @objc private func searchChanged() { reload() }
    func controlTextDidChange(_ obj: Notification) { reload() }
    @objc private func clearFilters() { selectedProject = nil; categoryFilter = nil; reload() }

    @objc private func clicked() {
        let r = table.clickedRow
        guard r >= 0 && r < rows.count else { return }
        switch rows[r] {
        case .newProject: askNewProject()
        case .project(let p):
            selectedProject = selectedProject == p.id ? nil : p.id
            reload()
        case .moreProjects: showAllProjects = true; reload()
        case .convo(let c): store.select(c.id)
        default: break
        }
    }

    @objc private func showFilter(_ sender: NSButton) {
        let m = NSMenu()
        let all = NSMenuItem(title: "全部分类", action: #selector(pickCategory(_:)), keyEquivalent: "")
        all.target = self
        all.state = categoryFilter == nil ? .on : .off
        m.addItem(all)
        m.addItem(.separator())
        for c in kCategories {
            let n = store.conversations.filter { $0.category == c.name && (selectedProject == nil || $0.project == selectedProject) }.count
            let it = NSMenuItem(title: "\(c.emoji) \(c.name)（\(n)）", action: #selector(pickCategory(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = c.name
            it.state = categoryFilter == c.name ? .on : .off
            m.addItem(it)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }
    @objc private func pickCategory(_ it: NSMenuItem) { categoryFilter = it.representedObject as? String; reload() }

    // MARK: right-click menu
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let r = table.clickedRow
        func add(_ t: String, _ sel: Selector, _ obj: Any? = nil) {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            it.target = self
            it.representedObject = obj
            menu.addItem(it)
        }
        guard r >= 0 && r < rows.count else {
            add("✏️ 发起新对话", #selector(newChat))
            add("＋ 新建项目", #selector(newProjectMenu))
            menu.addItem(.separator())
            add("清空全部聊天记录…", #selector(clearAll))
            return
        }
        switch rows[r] {
        case .convo(let c):
            add("重命名…", #selector(renameConvo(_:)), c.id)
            add(c.pinned ? "取消置顶" : "📌 置顶", #selector(pinConvo(_:)), c.id)
            let cat = NSMenuItem(title: "更改分类", action: nil, keyEquivalent: "")
            let cm = NSMenu()
            for k in kCategories {
                let it = NSMenuItem(title: "\(k.emoji) \(k.name)", action: #selector(setCat(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = [c.id, k.name]
                it.state = c.category == k.name ? .on : .off
                cm.addItem(it)
            }
            cat.submenu = cm
            menu.addItem(cat)
            let mv = NSMenuItem(title: "移到项目", action: nil, keyEquivalent: "")
            let pm = NSMenu()
            for p in store.sortedProjects {
                let it = NSMenuItem(title: "\(p.emoji) \(p.name)", action: #selector(moveConvo(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = [c.id, p.id]
                it.state = c.project == p.id ? .on : .off
                pm.addItem(it)
            }
            if c.project != nil {
                pm.addItem(.separator())
                let out = NSMenuItem(title: "移出项目", action: #selector(moveConvo(_:)), keyEquivalent: "")
                out.target = self
                out.representedObject = [c.id, ""]
                pm.addItem(out)
            }
            pm.addItem(.separator())
            let np = NSMenuItem(title: "＋ 新建项目并移入…", action: #selector(moveToNewProject(_:)), keyEquivalent: "")
            np.target = self
            np.representedObject = c.id
            pm.addItem(np)
            mv.submenu = pm
            menu.addItem(mv)
            menu.addItem(.separator())
            add("删除对话…", #selector(deleteConvo(_:)), c.id)
        case .project(let p):
            add("在这个项目里新对话", #selector(newChatInProject(_:)), p.id)
            add("项目说明（小猫会记住）…", #selector(editNote(_:)), p.id)
            add("重命名…", #selector(renameProject(_:)), p.id)
            add(p.pinned ? "取消置顶" : "📌 置顶", #selector(pinProject(_:)), p.id)
            menu.addItem(.separator())
            add("删除项目…", #selector(deleteProject(_:)), p.id)
        default:
            add("✏️ 发起新对话", #selector(newChat))
            add("＋ 新建项目", #selector(newProjectMenu))
        }
    }

    private func prompt(_ title: String, info: String = "", value: String = "", ok: String = "好") -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        f.stringValue = value
        a.accessoryView = f
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "取消")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let v = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
    private func confirm(_ title: String, _ info: String, ok: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "取消")
        return a.runModal() == .alertFirstButtonReturn
    }

    @objc private func newProjectMenu() { askNewProject() }
    @discardableResult
    private func askNewProject() -> String? {
        guard let name = prompt("新建项目", info: "比如「OrdCat🐈‍⬛」「健身计划🏋️」。名字前面可以放一个表情当图标。", ok: "创建") else { return nil }
        let id = store.createProject(name: name)
        selectedProject = id
        store.startNew(project: id)
        reload()
        return id
    }
    @objc private func newChatInProject(_ it: NSMenuItem) {
        guard let id = it.representedObject as? String else { return }
        selectedProject = id
        store.startNew(project: id)
    }
    @objc private func renameConvo(_ it: NSMenuItem) {
        guard let id = it.representedObject as? String, let c = store.conversations.first(where: { $0.id == id }),
              let t = prompt("重命名对话", value: c.title) else { return }
        store.rename(id, to: t)
    }
    @objc private func pinConvo(_ it: NSMenuItem) { if let id = it.representedObject as? String { store.togglePin(id) } }
    @objc private func setCat(_ it: NSMenuItem) {
        guard let a = it.representedObject as? [String], a.count == 2 else { return }
        store.setCategory(a[0], a[1])
    }
    @objc private func moveConvo(_ it: NSMenuItem) {
        guard let a = it.representedObject as? [String], a.count == 2 else { return }
        store.move(a[0], toProject: a[1].isEmpty ? nil : a[1])
    }
    @objc private func moveToNewProject(_ it: NSMenuItem) {
        guard let cid = it.representedObject as? String,
              let name = prompt("新建项目", info: "这个对话会移到新项目里。", ok: "创建") else { return }
        let pid = store.createProject(name: name)
        store.move(cid, toProject: pid)
    }
    @objc private func deleteConvo(_ it: NSMenuItem) {
        guard let id = it.representedObject as? String,
              confirm("删除这个对话？", "删除后无法恢复。", ok: "删除") else { return }
        store.deleteConversation(id)
    }
    @objc private func renameProject(_ it: NSMenuItem) {
        guard let id = it.representedObject as? String, let p = store.project(id),
              let t = prompt("重命名项目", value: "\(p.emoji)\(p.name)") else { return }
        store.renameProject(id, to: t)
    }
    @objc private func pinProject(_ it: NSMenuItem) { if let id = it.representedObject as? String { store.toggleProjectPin(id) } }
    @objc private func editNote(_ it: NSMenuItem) {
        guard let id = it.representedObject as? String, let p = store.project(id) else { return }
        let a = NSAlert()
        a.messageText = "\(p.emoji) \(p.name) · 项目说明"
        a.informativeText = "写下这个项目的背景、要求或偏好。在这个项目里的每个对话，小猫都会先看这段说明。"
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 140))
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        let tv = NSTextView(frame: sv.bounds)
        tv.autoresizingMask = [.width]
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 13)
        tv.string = p.note
        sv.documentView = tv
        a.accessoryView = sv
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "取消")
        a.window.initialFirstResponder = tv
        if a.runModal() == .alertFirstButtonReturn {
            store.setProjectNote(id, String(tv.string.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000)))
        }
    }
    @objc private func deleteProject(_ it: NSMenuItem) {
        guard let id = it.representedObject as? String, let p = store.project(id) else { return }
        let n = store.conversations.filter { $0.project == id }.count
        let a = NSAlert()
        a.messageText = "删除项目「\(p.name)」？"
        a.informativeText = n == 0 ? "项目里没有对话。" : "项目里有 \(n) 个对话。可以只删项目、把对话留在「全部」里。"
        a.addButton(withTitle: "只删项目")
        if n > 0 { a.addButton(withTitle: "连对话一起删") }
        a.addButton(withTitle: "取消")
        let r = a.runModal()
        if r == .alertFirstButtonReturn {
            store.deleteProject(id, withChats: false)
        } else if n > 0 && r == .alertSecondButtonReturn {
            store.deleteProject(id, withChats: true)
        } else { return }
        if selectedProject == id { selectedProject = nil }
        reload()
    }
    var onClearAll: (() -> Void)?
    @objc private func clearAll() { onClearAll?() }
    let accountButton = NSButton(title: "", target: nil, action: nil)
    var onAccount: (() -> Void)?
    @objc private func openAccount() { onAccount?() }
    func refreshAccount() {
        let a = Account.shared
        let img = a.avatarImage(size: 56)
        let side: CGFloat = 26
        let round = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            NSBezierPath(ovalIn: r).addClip()
            img.draw(in: r)
            return true
        }
        accountButton.image = round
        let sub = a.signedIn ? "" : (a.configured ? "  · 未登录" : "")
        accountButton.title = "  " + a.profile.displayName + sub + "   ⚙︎"
    }
}
