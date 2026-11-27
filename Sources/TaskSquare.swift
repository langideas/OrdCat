// OrdCat — 功能「喵副本」🐟（设置 → 喵副本；不是技能，登录就能用）
//
// 用户通过小猫把需要解决的问题发到喵副本，并自己定一份小鱼干奖励（发布时先押上）。
// 别的用户的小猫按「自己的模型能力 + 已开的技能」挑合适的任务来解：小猫用主人自己的模型写出答案，
// 主人看过、改过再交（绝不自动提交）。发布者采纳后，小鱼干转给解题的人；不满意可退回喵副本，取消会退回小鱼干。
//
// Server side: supabase/square.sql (tables + security-definer functions; clients never write the tables directly).
// Needs a signed-in account (设置 → 账号). New accounts get 100 小鱼干.

import Cocoa

extension Prefs {
    static var squareOn: Bool { get { d.object(forKey: "squareOn") as? Bool ?? false } set { d.set(newValue, forKey: "squareOn") } }
    /// The cat looks through the square by itself now and then and suggests a task it can do.
    static var squareAuto: Bool { get { d.object(forKey: "squareAuto") as? Bool ?? false } set { d.set(newValue, forKey: "squareAuto") } }
    /// Task kinds the user wants the cat to pick from (empty = all).
    static var squareKinds: [String] { get { d.stringArray(forKey: "squareKinds") ?? [] } set { d.set(newValue, forKey: "squareKinds") } }
    /// The cat pops up when new tasks it can do show up on the square (on by default).
    static var squareNotify: Bool { get { d.object(forKey: "squareNotify") as? Bool ?? true } set { d.set(newValue, forKey: "squareNotify") } }
    static var squareSkipped: [String] { get { d.stringArray(forKey: "squareSkipped") ?? [] } set { d.set(Array(newValue.suffix(300)), forKey: "squareSkipped") } }
    static var squareSeen: [String] { get { d.stringArray(forKey: "squareSeen") ?? [] } set { d.set(Array(newValue.suffix(300)), forKey: "squareSeen") } }
}

struct SquareTask {
    let id: String
    let posterID: String
    let posterName: String
    let title: String
    let body: String
    let kind: String
    let needs: [String]
    let imageURL: String?
    let links: [SquareLink]
    let files: [SquareFile]
    let reward: Int
    let status: String
    let solverID: String?
    let solverName: String?
    let solverModel: String?
    let created: Date?

    init?(_ r: [String: Any]) {
        guard let id = r["id"] as? String, let title = r["title"] as? String else { return nil }
        self.id = id
        posterID = r["poster_id"] as? String ?? ""
        posterName = r["poster_name"] as? String ?? ""
        self.title = title
        body = r["body"] as? String ?? ""
        kind = r["kind"] as? String ?? "其他"
        needs = r["needs"] as? [String] ?? ["text"]
        imageURL = (r["image_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        links = ((r["links"] as? [Any]) ?? []).compactMap { SquareLink($0) }
        files = ((r["files"] as? [Any]) ?? []).compactMap { SquareFile($0) }
        reward = r["reward"] as? Int ?? 0
        status = r["status"] as? String ?? "open"
        solverID = r["solver_id"] as? String
        solverName = r["solver_name"] as? String
        solverModel = r["solver_model"] as? String
        let s = r["created_at"] as? String ?? ""
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        created = f1.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    var statusText: String {
        switch status {
        case "open": return "等小猫来接"
        case "claimed": return "\(solverName.flatMap { $0.isEmpty ? nil : $0 } ?? "一只小猫") 正在解"
        case "answered": return "有回答了，等采纳"
        case "done": return "已采纳"
        case "cancelled": return "已取消"
        default: return status
        }
    }
    var needsText: String { needs.contains("vision") ? "要看图" : "纯文字" }
    /// "🔗 2 · 📎 3" style extras for the list, empty when none.
    var extrasText: String {
        var p: [String] = []
        if !links.isEmpty { p.append("🔗 " + Array(Set(links.map(\.platform))).sorted().joined(separator: "/")) }
        if !files.isEmpty { p.append("📎 \(files.count) 个附件") }
        return p.joined(separator: " · ")
    }
}

final class TaskSquare: NSObject {
    static let shared = TaskSquare()
    static let kinds = ["写作", "翻译", "代码", "学习", "生活", "看图", "其他"]
    static let rewards = ["5", "10", "20", "50", "100"]

    /// Shows a message next to the cat (set by the app delegate).
    var present: ((String, [(String, () -> Void)], Double) -> Void)?
    var openAccount: (() -> Void)?
    private(set) var balance: Int?
    private var observers: [() -> Void] = []
    private let matchLLM = LLM()
    private let solveLLM = LLM()
    private var timer: Timer?
    private var lastMatch = Date.distantPast
    private var lastNotify = Date.distantPast
    private var solving = false
    private var window: SquareWindow?
    private var draft: SquareDraft?
    private var postWin: SquarePostWindow?

    private var acct: Account { Account.shared }
    var ready: Bool { acct.configured && acct.signedIn }

    func observe(_ f: @escaping () -> Void) { observers.append(f) }
    private func changed() { DispatchQueue.main.async { self.observers.forEach { $0() }; self.window?.reload(fetch: false) } }

    // MARK: what this cat can do

    /// Capabilities of the user's own models: text (chat model set up), vision (a model that reads pictures).
    static var myCaps: [String] {
        var c: [String] = []
        if !Prefs.base.trimmingCharacters(in: .whitespaces).isEmpty { c.append("text") }
        if Cap.vision != nil { c.append("vision") }
        return c
    }
    static var capsLine: String {
        let c = myCaps
        guard c.contains("text") else { return "还没设置聊天模型，小猫接不了任务（设置 → 模型）" }
        var parts = ["聊天模型 \(Prefs.model)"]
        parts.append(c.contains("vision") ? "能看图" : "不能看图")
        var skills: [String] = []
        if Prefs.xMode { skills.append("喵推") }
        if Prefs.agentOn { skills.append("喵手") }
        if !skills.isEmpty { parts.append("技能：" + skills.joined(separator: "、")) }
        return parts.joined(separator: " · ")
    }
    func canDo(_ t: SquareTask) -> Bool { Set(t.needs).isSubset(of: Set(TaskSquare.myCaps)) }
    private var myName: String {
        let p = acct.profile
        return p.displayName.isEmpty ? (p.username.isEmpty ? "一只小猫" : p.username) : p.displayName
    }

    // MARK: lifecycle

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard ready else { return }
        refreshBalance()
        checkMine()
        if Prefs.squareAuto && !solving && Date().timeIntervalSince(lastMatch) > 15 * 60 { autoMatch() }
        else if Prefs.squareNotify && !Prefs.squareAuto && !solving && Date().timeIntervalSince(lastNotify) > 10 * 60 { notifyNew() }
    }

    /// New tasks this cat can do → one popup with what's there; each task is announced only once.
    private func notifyNew() {
        guard TaskSquare.myCaps.contains("text") else { return }
        lastNotify = Date()
        let uid = acct.profile.userID ?? ""
        let skipped = Set(Prefs.squareSkipped)
        let kinds = Set(Prefs.squareKinds)
        openTasks { [weak self] ts, err in
            guard let self = self, err == nil else { return }
            var seen = Prefs.squareSeen
            let fresh = ts.filter { $0.posterID != uid && !skipped.contains($0.id) && !seen.contains("n:" + $0.id)
                && self.canDo($0) && (kinds.isEmpty || kinds.contains($0.kind)) }
            guard let first = fresh.first else { return }
            seen.append(contentsOf: fresh.map { "n:" + $0.id })
            Prefs.squareSeen = seen
            let more = fresh.count > 1 ? "等 \(fresh.count) 个新任务" : ""
            NotifCenter.shared.add("🐟 喵副本上有「\(first.title)」\(more)（\(first.kind) · \(first.reward) 条小鱼干）", open: "square")
            self.present?("🐟 喵副本上有「\(first.title)」\(more)（\(first.kind) · \(first.reward) 条小鱼干），要我接吗？",
                          [("接这个", { [weak self] in self?.take(first) }),
                           ("看看喵副本", { [weak self] in self?.showWindow() }),
                           ("不再提醒", { Prefs.squareNotify = false })], 25)
        }
    }

    // MARK: server

    private func rpc(_ fn: String, _ args: [String: Any], done: @escaping (Any?, String?) -> Void) {
        acct.request("POST", "/rest/v1/rpc/\(fn)", json: args) { obj, err in done(obj, err.map(TaskSquare.friendly)) }
    }

    /// Server errors in plain words. "schema cache" = the square tables / functions aren't on the server yet.
    static func friendly(_ e: String) -> String {
        let l = e.lowercased()
        if l.contains("schema cache") || l.contains("square_") && l.contains("does not exist")
            || l.contains("could not find the function") || l.contains("fish_") && l.contains("does not exist") {
            return "喵副本服务器还没开通好（管理员需要在 Supabase 运行 supabase/square.sql）"
        }
        return e
    }

    func refreshBalance(_ done: (() -> Void)? = nil) {
        guard ready else { done?(); return }
        rpc("fish_balance", [:]) { [weak self] obj, _ in
            if let b = obj as? Int { self?.balance = b }
            else if let n = obj as? NSNumber { self?.balance = n.intValue }
            self?.changed()
            // 充值 / 奖励 breakdown (fish.sql); the total above still works on older servers.
            Fish.refresh { self?.changed(); done?() }
        }
    }

    private func list(_ query: String, done: @escaping ([SquareTask], String?) -> Void) {
        acct.request("GET", "/rest/v1/square_tasks?\(query)") { obj, err in
            done(((obj as? [[String: Any]]) ?? []).compactMap(SquareTask.init), err.map(TaskSquare.friendly))
        }
    }

    func openTasks(_ done: @escaping ([SquareTask], String?) -> Void) {
        rpc("square_expire", [:]) { [weak self] _, _ in
            self?.list("status=eq.open&order=created_at.desc&limit=60&select=*", done: done)
        }
    }
    func myPosted(_ done: @escaping ([SquareTask], String?) -> Void) {
        guard let uid = acct.profile.userID else { done([], "还没登录"); return }
        list("poster_id=eq.\(uid)&status=neq.cancelled&order=created_at.desc&limit=40&select=*", done: done)
    }
    func myTaken(_ done: @escaping ([SquareTask], String?) -> Void) {
        guard let uid = acct.profile.userID else { done([], "还没登录"); return }
        list("solver_id=eq.\(uid)&order=created_at.desc&limit=40&select=*", done: done)
    }

    func answer(of t: SquareTask, done: @escaping (String?) -> Void) {
        acct.request("GET", "/rest/v1/square_answers?task_id=eq.\(t.id)&select=answer") { obj, _ in
            done(((obj as? [[String: Any]])?.first)?["answer"] as? String)
        }
    }

    // MARK: notices about my tasks

    private func checkMine() {
        var seen = Prefs.squareSeen
        myPosted { [weak self] ts, _ in
            guard let self = self else { return }
            for t in ts where t.status == "answered" && !seen.contains("a:" + t.id) {
                seen.append("a:" + t.id)
                Prefs.squareSeen = seen
                NotifCenter.shared.add("📬 你发到喵副本的「\(t.title)」有小猫回答啦", open: "square.mine")
                self.present?("📬 你发到喵副本的「\(t.title)」有小猫回答啦，去看看？",
                              [("看回答", { [weak self] in self?.showAnswer(t) })], 20)
                return
            }
            self.myTaken { [weak self] ts2, _ in
                for t in ts2 where t.status == "done" && !seen.contains("d:" + t.id) {
                    seen.append("d:" + t.id)
                    Prefs.squareSeen = seen
                    self?.refreshBalance()
                    NotifCenter.shared.add("🎉 「\(t.title)」的回答被采纳了，收到 \(t.reward) 条小鱼干 🐟", open: "square")
                    self?.present?("🎉 「\(t.title)」的回答被采纳了，收到 \(t.reward) 条小鱼干 🐟", [], 8)
                    return
                }
            }
        }
    }

    // MARK: matching — the cat picks a task it can do well

    /// Looks through the square and suggests the one task this cat's model fits best.
    func autoMatch(manual: Bool = false) {
        guard ready else { if manual { needLogin() }; return }
        guard TaskSquare.myCaps.contains("text") else {
            if manual { present?("还没设置聊天模型，小猫没法接任务。右键点我 → 设置 → 模型。", [], 8) }
            return
        }
        lastMatch = Date()
        let uid = acct.profile.userID ?? ""
        let skipped = Set(Prefs.squareSkipped)
        let kinds = Set(Prefs.squareKinds)
        openTasks { [weak self] ts, err in
            guard let self = self else { return }
            let cands = ts.filter { $0.posterID != uid && !skipped.contains($0.id) && self.canDo($0)
                && (kinds.isEmpty || kinds.contains($0.kind)) }.prefix(8)
            guard !cands.isEmpty else {
                if manual { self.present?(err.map { "喵副本没连上：\($0)" } ?? "喵副本上暂时没有适合我的任务 🐾 晚点我再看看。", [], 6) }
                return
            }
            let lines = cands.enumerated().map { i, t in
                "\(i + 1). [\(t.kind)] \(t.title)｜\(String(t.body.prefix(160)).replacingOccurrences(of: "\n", with: " "))｜奖励 \(t.reward)"
            }.joined(separator: "\n")
            let prompt = """
            下面是喵副本上别人发的问题。你的模型是 \(Prefs.model)，能力：\(TaskSquare.capsLine)。
            挑出一个你最有把握解得又好又对的任务（只考虑你真能做好的，不要因为奖励高就选）。
            只回一行 JSON：{"pick": 编号, "why": "不超过 25 字的理由"}；一个都没把握就回 {"pick": 0, "why": ""}。

            \(lines)
            """
            self.matchLLM.stream([["role": "user", "content": prompt]], context: "这次只按要求回 JSON，不要多说别的。",
                                 onDelta: { _ in }, onDone: { [weak self] text, _ in
                guard let self = self else { return }
                let (pick, why) = TaskSquare.parsePick(text ?? "")
                guard pick >= 1, pick <= cands.count else {
                    if manual { self.present?("喵副本上的任务我都没太大把握，先不接啦 🐾", [], 6) }
                    return
                }
                let t = cands[cands.startIndex + pick - 1]
                let reason = why.isEmpty ? "" : "\n\(why)"
                self.present?("🐟 喵副本上有个我能帮上忙的任务：「\(t.title)」（\(t.kind) · \(t.reward) 条小鱼干）\(reason)",
                              [("接这个", { [weak self] in self?.take(t) }),
                               ("看看喵副本", { [weak self] in self?.showWindow() }),
                               ("跳过", { Prefs.squareSkipped = Prefs.squareSkipped + [t.id] })], 25)
            })
        }
    }

    static func parsePick(_ s: String) -> (Int, String) {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b,
              let data = String(s[a...b]).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (0, "") }
        let p = (o["pick"] as? Int) ?? Int("\(o["pick"] ?? 0)") ?? 0
        return (p, o["why"] as? String ?? "")
    }

    // MARK: solving

    /// Claim the task, let my own model write an answer, then show the draft for the user to check before handing in.
    func take(_ t: SquareTask) {
        guard ready else { needLogin(); return }
        guard canDo(t) else {
            present?("这个任务要会看图的模型，我现在的模型看不了图。可以在 设置 → 模型 → 看图 里配一个。", [], 8)
            return
        }
        guard !solving else { present?("我手上还在想上一个任务呢，等我一下 🐾", [], 5); return }
        rpc("square_claim", ["p_task": t.id, "p_name": myName, "p_model": Prefs.model]) { [weak self] _, err in
            guard let self = self else { return }
            if let e = err { self.present?("没接上：\(e)", [], 6); self.window?.reload(fetch: true); return }
            self.window?.reload(fetch: true)
            self.solve(t)
        }
    }

    func solve(_ t: SquareTask) {
        solving = true
        present?("🐟 接到「\(t.title)」啦，我用你的模型想一想…（30 分钟内交上去就行）", [], 6)
        Task { @MainActor in
            var question = "【任务类型】\(t.kind)\n【标题】\(t.title)\n【详细说明】\n\(t.body.isEmpty ? "（无）" : t.body)"
            // Links: read what's behind them (X post text, GitHub README / file / issue, article text…).
            if !t.links.isEmpty {
                var parts: [String] = []
                for (i, l) in t.links.prefix(5).enumerated() {
                    let txt = await l.fetchText()
                    parts.append("[链接 \(i + 1) · \(l.platform)] \(l.url)\n\(String(txt.prefix(6000)))")
                }
                question += "\n\n【任务附带的链接内容】\n" + parts.joined(separator: "\n\n")
            }
            // Attachments: text / code / PDF / Word go into the question; pictures go to the vision model.
            var images: [Data] = []
            if let s = t.imageURL, let url = URL(string: s), let fetched = try? await URLSession.shared.data(from: url) {
                images.append(fetched.0)
            }
            var texts: [String] = []
            var total = 0
            for f in t.files {
                guard let url = URL(string: f.url), let fetched = try? await URLSession.shared.data(from: url) else {
                    texts.append("[附件 \(f.name)]（下载失败）"); continue
                }
                if f.kind == "image" { images.append(fetched.0); continue }
                let room = 40000 - total
                guard room > 0 else { texts.append("[附件 \(f.name)]（内容太多，略过）"); continue }
                let cut = String(SquareFile.text(of: fetched.0, kind: f.kind, name: f.name).prefix(room))
                total += cut.count
                let shown = f.kind == "code" ? "```\((f.name as NSString).pathExtension)\n\(cut)\n```" : cut
                texts.append("[附件 \(f.name)]\n" + shown)
            }
            if !texts.isEmpty { question += "\n\n【任务附带的文件】\n" + texts.joined(separator: "\n\n") }
            var content: Any = question
            if !images.isEmpty && TaskSquare.myCaps.contains("vision") {
                let pics = Array(images.prefix(4))
                if Cap.visionUsesChat {
                    var arr: [[String: Any]] = [["type": "text", "text": question]]
                    for d in pics {
                        arr.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + d.base64EncodedString()]])
                    }
                    content = arr
                } else {
                    let (desc, err) = await MediaHub.describe(pics, question: question, appName: "喵副本里的图片", video: false)
                    question += "\n\n[任务附带的图片（看图模型的描述）]\n" + (desc ?? "（没看成：\(err ?? "未知原因")）")
                    content = question
                }
            }
            let ctx = """
            现在你在 OrdCat 喵副本帮另一位用户解决问题。这次不受 80 字限制：请认真、完整、准确地解答，
            结构清楚，能直接用；不确定的地方如实说明，不要编造。不要提到你是在接任务，也不要索要报酬。
            """
            self.solveLLM.stream([["role": "user", "content": content]], context: ctx, onDelta: { _ in },
                                 onDone: { [weak self] text, err in
                guard let self = self else { return }
                self.solving = false
                let ans = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if ans.isEmpty {
                    self.present?("这次没想出来：\(err ?? "模型没有回答")。任务还在你手上，可以在喵副本「我接的」里重试或放弃。",
                                  [("打开喵副本", { [weak self] in self?.showWindow(tab: 2) })], 12)
                    return
                }
                self.showDraft(t, answer: ans)
            })
        }
    }

    private func showDraft(_ t: SquareTask, answer: String) {
        let d = SquareDraft(task: t, answer: answer)
        d.onSubmit = { [weak self] text in self?.submit(t, text) }
        d.onRetry = { [weak self] in self?.solve(t) }
        d.onGiveUp = { [weak self] in
            self?.rpc("square_release", ["p_task": t.id]) { _, _ in self?.window?.reload(fetch: true) }
        }
        draft = d
        d.show()
        present?("答案写好了 ✍️ 你先看一眼，改好再交。", [], 5)
    }

    private func submit(_ t: SquareTask, _ text: String) {
        let clean = Redactor.clean(text)
        rpc("square_answer", ["p_task": t.id, "p_answer": String(clean.prefix(12000))]) { [weak self] _, err in
            guard let self = self else { return }
            if let e = err { self.present?("没交上：\(e)", [], 8); return }
            self.window?.reload(fetch: true)
            self.present?("交上去啦 📮 对方采纳后，\(t.reward) 条小鱼干就是你的了。", [], 6)
        }
    }

    // MARK: posting

    /// "发任务：…" / "/任务 …" in chat → the text to prefill, or nil.
    static func postIntent(_ text: String) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["/猫帮", "/任务", "发任务", "发布任务", "悬赏"] where s.hasPrefix(p) {
            var rest = String(s.dropFirst(p.count))
            while let c = rest.first, " ：:，,".contains(c) { rest.removeFirst() }
            return rest
        }
        return nil
    }

    func postDialog(prefill: String = "") {
        guard ready else { needLogin(); return }
        let w = SquarePostWindow(prefill: prefill, balance: balance)
        w.onPost = { [weak self] title, body, kind, reward, links, files in
            self?.post(title: title, body: body, kind: kind, reward: reward, links: links, files: files)
        }
        postWin = w
        w.show()
    }

    private func post(title: String, body: String, kind: String, reward n: Int, links: [SquareLink], files: [URL]) {
        let tt = Redactor.clean(title)
        let bb = Redactor.clean(body)
        if !files.isEmpty { present?("正在上传 \(files.count) 个附件…", [], 4) }
        uploadAll(files) { [weak self] uploaded, err in
            guard let self = self else { return }
            if let e = err { self.present?("附件没传上：\(e)", [], 8); return }
            let hasImage = uploaded.contains { $0.kind == "image" }
            let args: [String: Any] = ["p_title": String(tt.prefix(80)), "p_body": String(bb.prefix(8000)), "p_kind": kind,
                                       "p_needs": hasImage ? ["text", "vision"] : ["text"], "p_reward": n, "p_name": self.myName,
                                       "p_image": NSNull(),
                                       "p_links": links.prefix(10).map(\.json), "p_files": uploaded.map(\.json)]
            self.rpc("square_post", args) { [weak self] _, err in
                guard let self = self else { return }
                if let e = err { self.present?("没发出去：\(e)", [], 10); return }
                self.refreshBalance()
                self.window?.reload(fetch: true)
                self.present?("发到喵副本啦 🐟 押了 \(n) 条小鱼干，有小猫回答我就叫你。", [], 6)
            }
        }
    }

    /// Uploads the attachments one by one into the square bucket (<uid>/<uuid>.<ext>).
    private func uploadAll(_ files: [URL], done: @escaping ([SquareFile], String?) -> Void) {
        guard !files.isEmpty else { done([], nil); return }
        guard let uid = acct.profile.userID, let base = acct.publicBase else { done([], "还没登录"); return }
        var out: [SquareFile] = []
        func next(_ i: Int) {
            guard i < files.count else { done(out, nil); return }
            let f = files[i]
            guard let prep = SquareFile.prepare(f) else { done(out, "\(f.lastPathComponent) 打不开或格式不支持"); return }
            guard prep.data.count <= SquareFile.maxBytes else { done(out, "\(f.lastPathComponent) 超过 10 MB"); return }
            let path = "\(uid)/\(UUID().uuidString.lowercased()).\(prep.ext)"
            acct.request("POST", "/storage/v1/object/square/\(path)", raw: prep.data, contentType: prep.mime) { _, err in
                if let e = err { done(out, "\(f.lastPathComponent)：\(TaskSquare.friendly(e))"); return }
                out.append(SquareFile(name: f.lastPathComponent, url: "\(base)/storage/v1/object/public/square/\(path)",
                                      kind: prep.kind, size: prep.data.count))
                next(i + 1)
            }
        }
        next(0)
    }

    // MARK: my posted tasks

    func showAnswer(_ t: SquareTask) {
        answer(of: t) { [weak self] text in
            guard let self = self else { return }
            guard let ans = text else { self.present?("回答没读到，等会儿再试。", [], 5); return }
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 260))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 442, height: 260))
            tv.isEditable = false
            tv.font = .systemFont(ofSize: 13)
            tv.autoresizingMask = [.width]
            tv.string = ans
            scroll.documentView = tv
            let a = NSAlert()
            a.messageText = "「\(t.title)」的回答"
            let who = t.solverName.flatMap { $0.isEmpty ? nil : $0 } ?? "一只小猫"
            let model = t.solverModel.flatMap { $0.isEmpty ? nil : " · 模型 \($0)" } ?? ""
            a.informativeText = "来自 \(who)\(model)"
            a.accessoryView = scroll
            if t.status == "answered" {
                a.addButton(withTitle: "采纳（给 \(t.reward) 条小鱼干）")
                a.addButton(withTitle: "不满意，退回喵副本")
                a.addButton(withTitle: "先放着")
            } else {
                a.addButton(withTitle: "好")
            }
            a.addButton(withTitle: "复制回答")
            NSApp.activate(ignoringOtherApps: true)
            let r = a.runModal()
            if t.status == "answered" {
                if r == .alertFirstButtonReturn { self.decide(t, accept: true) }
                else if r == .alertSecondButtonReturn { self.decide(t, accept: false) }
                else if r.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3 { self.copy(ans) }
            } else if r == .alertSecondButtonReturn { self.copy(ans) }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func decide(_ t: SquareTask, accept: Bool) {
        rpc(accept ? "square_accept" : "square_reject", ["p_task": t.id]) { [weak self] _, err in
            guard let self = self else { return }
            if let e = err { self.present?(e, [], 6); return }
            self.window?.reload(fetch: true)
            self.present?(accept ? "已采纳 🎉 \(t.reward) 条小鱼干送给了解题的小猫。" : "退回喵副本啦，等别的小猫再试试。", [], 6)
        }
    }

    func cancel(_ t: SquareTask) {
        rpc("square_cancel", ["p_task": t.id]) { [weak self] _, err in
            guard let self = self else { return }
            if let e = err { self.present?(e, [], 6); return }
            self.refreshBalance()
            self.window?.reload(fetch: true)
            self.present?("取消啦，\(t.reward) 条小鱼干退回给你。", [], 5)
        }
    }

    func release(_ t: SquareTask) {
        rpc("square_release", ["p_task": t.id]) { [weak self] _, _ in self?.window?.reload(fetch: true) }
    }

    // MARK: window

    func showWindow(tab: Int = 0) {
        if window == nil { window = SquareWindow(square: self) }
        window?.show(tab: tab)
        refreshBalance()
    }

    private func needLogin() {
        let msg = acct.configured ? "喵副本要先登录账号（新账号送 100 条小鱼干 🐟）。" : "账号服务还在开通中，暂时用不了喵副本。"
        present?(msg, acct.configured ? [("去登录", { [weak self] in self?.openAccount?() })] : [], 8)
    }
}

/// The answer the cat wrote, for the user to read and edit before handing it in.
final class SquareDraft: NSObject, NSWindowDelegate {
    var onSubmit: ((String) -> Void)?
    var onRetry: (() -> Void)?
    var onGiveUp: (() -> Void)?
    private let task: SquareTask
    private let text = NSTextView()
    private var win: NSWindow!
    private var handled = false

    init(task: SquareTask, answer: String) {
        self.task = task
        super.init()
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                       styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "🐟 交答案 ·「\(task.title)」"
        win.minSize = NSSize(width: 420, height: 340)
        win.isReleasedWhenClosed = false
        win.delegate = self
        let root = NSView()
        let q = SK.WrapLabel("\(task.kind) · \(task.reward) 条小鱼干 · 来自 \(task.posterName.isEmpty ? "一位用户" : task.posterName)\n\(String(task.body.prefix(400)))", size: 12)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        text.isRichText = false
        text.font = .systemFont(ofSize: 13)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.string = answer
        scroll.documentView = text
        let hint = SK.WrapLabel("这是小猫用你的模型写的。看过、需要的话改一改，再点「提交」。30 分钟内没交会自动退回喵副本。", size: 11)
        let submit = OCButton(title: "提交答案", target: self, action: #selector(doSubmit))
        submit.keyEquivalent = "\r"
        let retry = OCButton(title: "重新想", target: self, action: #selector(doRetry))
        let give = OCButton(title: "放弃这个任务", target: self, action: #selector(doGiveUp))
        let row = NSStackView(views: [give, NSView(), retry, submit])
        row.translatesAutoresizingMaskIntoConstraints = false
        for v in [q, scroll, hint, row] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            q.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            q.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            q.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: q.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: q.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: q.trailingAnchor),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: q.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: q.trailingAnchor),
            row.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: q.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: q.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)])
        win.contentView = root
    }

    func show() {
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func doSubmit() {
        let s = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        handled = true
        win.close()
        onSubmit?(s)
    }
    @objc private func doRetry() { handled = true; win.close(); onRetry?() }
    @objc private func doGiveUp() { handled = true; win.close(); onGiveUp?() }
    func windowWillClose(_ n: Notification) {
        // Closing the window without choosing keeps the task (it can be finished from 喵副本 → 我接的).
        _ = handled
    }
}

/// 喵副本 window: 喵副本 / 我发布的 / 我接的.
final class SquareWindow: NSObject, NSWindowDelegate {
    private unowned let square: TaskSquare
    private var win: NSWindow!
    private let tabs = NSSegmentedControl(labels: ["单人副本", "我发布的", "我接的"], trackingMode: .selectOne, target: nil, action: nil)
    private let balance = NSTextField(labelWithString: "")
    private let caps = SK.WrapLabel("", size: 11)
    private let nameLabel = NSTextField(labelWithString: "")
    private let levelIV = NSImageView()
    private let avatarIV = NSImageView()
    private let list = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private var items: [SquareTask] = []
    private var gen = 0

    init(square: TaskSquare) {
        self.square = square
        super.init()
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
                       styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        win.title = "🐟 喵副本 · 单人副本"
        win.minSize = NSSize(width: 520, height: 380)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.setFrameAutosaveName("OrdCatSquare")
        let root = NSView()
        balance.font = .systemFont(ofSize: 13, weight: .semibold)
        balance.textColor = kAmber
        nameLabel.font = .systemFont(ofSize: 15, weight: .bold)
        nameLabel.lineBreakMode = .byTruncatingTail
        tabs.target = self
        ocStyleTabs(tabs)
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        let post = OCButton(title: "发布任务", target: self, action: #selector(post))
        let find = OCButton(title: "帮我挑一个", target: self, action: #selector(find))
        find.toolTip = "小猫按你的模型和技能，从喵副本挑一个最适合它解的任务"
        let refresh = OCButton(title: "刷新", target: self, action: #selector(refreshNow))
        let raids = OCButton(title: "组队副本", target: self, action: #selector(openRaids))
        raids.toolTip = "结果副本和借猫副本：和别的小猫组队做大任务"
        // 朋友圈-style cover: avatar, name, level, 小鱼干, what my cat can do; actions on the right.
        let banner = SquareBanner()
        banner.translatesAutoresizingMaskIntoConstraints = false
        avatarIV.translatesAutoresizingMaskIntoConstraints = false
        avatarIV.imageScaling = .scaleProportionallyUpOrDown
        let nameRow = NSStackView(views: [nameLabel, levelIV])
        nameRow.spacing = 6
        nameRow.alignment = .centerY
        let info = NSStackView(views: [nameRow, balance, caps])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 3
        caps.widthAnchor.constraint(equalTo: info.widthAnchor).isActive = true
        let btns = NSStackView(views: [raids, find, refresh, post])
        btns.spacing = 8
        btns.setContentHuggingPriority(.required, for: .horizontal)
        btns.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [avatarIV, info, btns] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; banner.addSubview(v) }
        NSLayoutConstraint.activate([
            avatarIV.widthAnchor.constraint(equalToConstant: 56),
            avatarIV.heightAnchor.constraint(equalToConstant: 56),
            avatarIV.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 16),
            avatarIV.topAnchor.constraint(equalTo: banner.topAnchor, constant: 16),
            avatarIV.bottomAnchor.constraint(lessThanOrEqualTo: banner.bottomAnchor, constant: -16),
            info.leadingAnchor.constraint(equalTo: avatarIV.trailingAnchor, constant: 12),
            info.topAnchor.constraint(equalTo: banner.topAnchor, constant: 16),
            info.bottomAnchor.constraint(lessThanOrEqualTo: banner.bottomAnchor, constant: -14),
            info.trailingAnchor.constraint(lessThanOrEqualTo: btns.leadingAnchor, constant: -12),
            btns.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -16),
            btns.topAnchor.constraint(equalTo: banner.topAnchor, constant: 18)])
        let top = banner
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        let doc = FlipView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        for v in [top, tabs, scroll, status] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tabs.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
            tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: top.leadingAnchor, constant: 4),
            status.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 12),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -12),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -8)])
        win.contentView = root
    }

    func show(tab: Int) {
        tabs.selectedSegment = max(0, min(2, tab))
        if !win.isVisible { win.center() }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        reload(fetch: true)
    }

    @objc private func tabChanged() { reload(fetch: true) }
    @objc private func post() { square.postDialog() }
    @objc private func find() { square.autoMatch(manual: true) }
    @objc private func refreshNow() { square.refreshBalance(); reload(fetch: true) }
    @objc private func openRaids() { Raids.shared.showWindow() }

    func reload(fetch: Bool) {
        guard win.isVisible || fetch else { return }
        if let t = Fish.total, t == square.balance || square.balance == nil {
            balance.stringValue = Fish.line
        } else {
            balance.stringValue = "🐟 小鱼干：\(square.balance.map(String.init) ?? "—")"
        }
        caps.stringValue = "我的小猫：" + TaskSquare.capsLine
        let acc = Account.shared
        nameLabel.stringValue = acc.profile.displayName
        avatarIV.image = memberAvatar(acc.avatarImage(size: 112), tier: CatLevel.tier, size: 56)
        let lv = CatLevel.shared.level
        levelIV.image = lv > 0 ? RankIcon.strip(level: lv, height: 13) : nil
        levelIV.isHidden = lv == 0
        levelIV.toolTip = "Lv\(lv) · " + CatLevel.partsText(level: lv)
        guard fetch else { return }
        guard square.ready else {
            items = []
            render(empty: Account.shared.configured ? "先登录账号才能用喵副本（设置 → 账号，新账号送 100 条小鱼干）。" : "账号服务还在开通中。")
            return
        }
        gen += 1
        let g = gen
        status.stringValue = "正在加载…"
        let done: ([SquareTask], String?) -> Void = { [weak self] ts, err in
            guard let self = self, g == self.gen else { return }
            self.items = ts
            self.status.stringValue = err.map { "没连上：\($0)" } ?? "共 \(ts.count) 个"
            self.render(empty: ["喵副本上还没有任务，发一个试试？", "你还没发过任务。", "你还没接过任务。"][self.tabs.selectedSegment])
        }
        switch tabs.selectedSegment {
        case 1: square.myPosted(done)
        case 2: square.myTaken(done)
        default: square.openTasks(done)
        }
    }

    private func render(empty: String) {
        for v in list.arrangedSubviews { list.removeArrangedSubview(v); v.removeFromSuperview() }
        if items.isEmpty {
            let l = SK.WrapLabel(empty, size: 13)
            list.addArrangedSubview(l)
            l.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            return
        }
        let uid = Account.shared.profile.userID ?? ""
        for (i, t) in items.enumerated() {
            let card = OCCard()
            card.translatesAutoresizingMaskIntoConstraints = false
            let mine = t.posterID == uid
            // Avatar (own posts: my picture + member ring; others: the brand placeholder).
            let av = NSImageView()
            av.translatesAutoresizingMaskIntoConstraints = false
            av.imageScaling = .scaleProportionallyUpOrDown
            av.image = mine ? memberAvatar(Account.shared.avatarImage(size: 80), tier: CatLevel.tier, size: 40)
                            : memberAvatar(AvatarCache.placeholder(80), tier: .none, size: 40)
            let who = mine ? Account.shared.profile.displayName : (t.posterName.isEmpty ? "一位用户" : t.posterName)
            let name = NSTextField(labelWithString: who)
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            name.textColor = kAmber
            name.lineBreakMode = .byTruncatingTail
            let reward = NSTextField(labelWithString: "🐟 \(t.reward)")
            reward.font = .systemFont(ofSize: 12, weight: .semibold)
            reward.textColor = kAmber
            reward.setContentHuggingPriority(.required, for: .horizontal)
            let nameRow = NSStackView(views: [name, NSView(), reward])
            nameRow.alignment = .centerY
            nameRow.spacing = 6
            let title = SK.WrapLabel(t.title, size: 14, secondary: false, weight: .semibold)
            var parts: [NSView] = [nameRow, title]
            parts += bodyViews(String(t.body.prefix(600)))
            // Links and files as chips.
            var chips: [NSView] = []
            for l in t.links.prefix(4) { chips.append(chip("🔗 \(l.platform)", l.url)) }
            for f in t.files.prefix(4) { chips.append(chip("\(f.icon) \(f.name)", f.url)) }
            if !chips.isEmpty {
                let cs = NSStackView(views: chips)
                cs.spacing = 6
                parts.append(cs)
            }
            // Meta line: 类型 · 纯文字 · 3分钟前 (+ status on my tabs).
            var metaText = "\(t.kind) · \(t.needsText)"
            if let d = t.created { metaText += " · " + ocRelativeTime(d) }
            if tabs.selectedSegment != 0 { metaText += " · \(t.statusText)" }
            let meta = SK.WrapLabel(metaText, size: 11)
            // Actions bottom-right, like the 朋友圈 "··" corner.
            let acts = NSStackView()
            acts.spacing = 6
            acts.setContentHuggingPriority(.required, for: .horizontal)
            acts.setContentCompressionResistancePriority(.required, for: .horizontal)
            for (n, (bt, sel, enabled)) in actions(for: t, uid: uid).enumerated() {
                let b = OCButton(title: bt, target: self, action: sel)
                b.controlSize = .small
                if n == 0 && enabled && OCButton.auto(bt) != .danger { b.style = .primary }
                b.tag = i
                b.isEnabled = enabled
                acts.addArrangedSubview(b)
            }
            let foot = NSStackView(views: [meta, acts])
            foot.alignment = .centerY
            foot.spacing = 8
            meta.setContentHuggingPriority(.init(1), for: .horizontal)
            meta.setContentCompressionResistancePriority(.init(250), for: .horizontal)
            parts.append(foot)
            // 评论区: who is solving / has answered, in a light inset box.
            if let solver = t.solverName, t.status != "open" {
                let model = t.solverModel.flatMap { $0.isEmpty ? nil : "（\($0)）" } ?? ""
                let c = SK.WrapLabel("💬 \(solver.isEmpty ? "一只小猫" : solver)\(model)：\(t.statusText)", size: 11.5)
                parts.append(inset(c))
            }
            let col = NSStackView(views: parts)
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 6
            for v in parts { v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
            for v in [av, col] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(v) }
            NSLayoutConstraint.activate([
                av.widthAnchor.constraint(equalToConstant: 40),
                av.heightAnchor.constraint(equalToConstant: 40),
                av.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                av.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
                col.leadingAnchor.constraint(equalTo: av.trailingAnchor, constant: 12),
                col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
                col.topAnchor.constraint(equalTo: card.topAnchor, constant: 13),
                col.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
                card.bottomAnchor.constraint(greaterThanOrEqualTo: av.bottomAnchor, constant: 14)])
            list.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    /// Body text; ``` blocks become monospaced code boxes.
    private func bodyViews(_ body: String) -> [NSView] {
        guard !body.isEmpty else { return [] }
        var out: [NSView] = []
        for (k, seg) in body.components(separatedBy: "```").enumerated() {
            var text = seg.trimmingCharacters(in: .newlines)
            if k % 2 == 1 {
                // Drop the language tag on the first line.
                if let nl = text.firstIndex(of: "\n"), !text[..<nl].contains(" "), text[..<nl].count < 16 {
                    text = String(text[text.index(after: nl)...])
                }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let l = SK.WrapLabel(text, size: 11.5, secondary: false)
                l.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
                out.append(inset(l, dark: true))
            } else {
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out.append(SK.WrapLabel(text, size: 12.5, secondary: false))
            }
        }
        return out
    }

    /// A rounded inset box (code, or the comment area).
    private func inset(_ content: NSView, dark: Bool = false) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = (dark ? NSColor.black.withAlphaComponent(0.25)
                                           : NSColor.labelColor.withAlphaComponent(0.06)).cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 7),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -7)])
        return box
    }

    private func chip(_ title: String, _ url: String) -> NSView {
        let b = OCButton(title: String(title.prefix(28)), target: self, action: #selector(openChip(_:)))
        b.controlSize = .small
        b.style = .neutral
        b.toolTip = url
        b.identifier = NSUserInterfaceItemIdentifier(url)
        return b
    }
    @objc private func openChip(_ b: NSButton) {
        if let s = b.identifier?.rawValue, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    private func actions(for t: SquareTask, uid: String) -> [(String, Selector, Bool)] {
        switch tabs.selectedSegment {
        case 0:
            if t.posterID == uid { return [("我发的 · 取消", #selector(cancelTask(_:)), true)] }
            if !square.canDo(t) { return [("我的模型看不了图", #selector(noop), false)] }
            return [("让小猫解", #selector(take(_:)), true), ("详情", #selector(detail(_:)), true)]
        case 1:
            switch t.status {
            case "open": return [("取消并退回", #selector(cancelTask(_:)), true)]
            case "answered": return [("看回答", #selector(seeAnswer(_:)), true)]
            case "done": return [("看回答", #selector(seeAnswer(_:)), true)]
            default: return []
            }
        default:
            switch t.status {
            case "claimed" where t.solverID == uid:
                return [("继续做", #selector(resolve(_:)), true), ("放弃", #selector(giveUp(_:)), true)]
            case "answered": return [("等对方采纳", #selector(noop), false)]
            case "done": return [("已到账 🐟 \(t.reward)", #selector(noop), false)]
            default: return [("已退回喵副本", #selector(noop), false)]
            }
        }
    }

    private func task(_ b: NSButton) -> SquareTask? { b.tag < items.count ? items[b.tag] : nil }
    @objc private func noop() {}
    @objc private func take(_ b: NSButton) { if let t = task(b) { square.take(t) } }
    @objc private func resolve(_ b: NSButton) { if let t = task(b) { square.solve(t) } }
    @objc private func giveUp(_ b: NSButton) { if let t = task(b) { square.release(t) } }
    @objc private func seeAnswer(_ b: NSButton) { if let t = task(b) { square.showAnswer(t) } }
    @objc private func cancelTask(_ b: NSButton) {
        guard let t = task(b) else { return }
        let a = NSAlert()
        a.messageText = "取消「\(t.title)」？"
        a.informativeText = "还没人接的任务可以取消，\(t.reward) 条小鱼干会退回给你。"
        a.addButton(withTitle: "取消任务")
        a.addButton(withTitle: "不了")
        if a.runModal() == .alertFirstButtonReturn { square.cancel(t) }
    }
    @objc private func detail(_ b: NSButton) {
        guard let t = task(b) else { return }
        var extra = ""
        if !t.links.isEmpty { extra += "\n\n链接：\n" + t.links.map { "🔗 \($0.platform)  \($0.url)" }.joined(separator: "\n") }
        if !t.files.isEmpty { extra += "\n\n附件：\n" + t.files.map { "\($0.icon) \($0.name)" }.joined(separator: "\n") }
        let a = NSAlert()
        a.messageText = t.title
        a.informativeText = "\(t.kind) · \(t.needsText) · 🐟 \(t.reward) · 来自 \(t.posterName.isEmpty ? "一位用户" : t.posterName)\n\n\(String(t.body.prefix(1500)))\(extra)"
        a.addButton(withTitle: "让小猫解")
        a.addButton(withTitle: "关闭")
        let opens = !t.links.isEmpty || !t.files.isEmpty
        if opens { a.addButton(withTitle: "打开链接和附件") }
        let r = a.runModal()
        if r == .alertFirstButtonReturn { square.take(t) }
        else if opens && r == .alertThirdButtonReturn {
            for s in (t.links.map(\.url) + t.files.map(\.url)).prefix(8) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
        }
    }
}

/// The 喵副本 cover: a soft amber wash over the window background, rounded.
final class SquareBanner: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let g = NSGradient(colors: [kAmber.withAlphaComponent(0.26), kAmber.withAlphaComponent(0.10),
                                    NSColor.labelColor.withAlphaComponent(0.04)])
        g?.draw(in: bounds, angle: 0)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
