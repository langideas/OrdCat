// OrdCat — 功能「任务广场」🐟（设置 → 任务广场；不是技能，登录就能用）
//
// 用户通过小猫把需要解决的问题发到广场，并自己定一份小鱼干奖励（发布时先押上）。
// 别的用户的小猫按「自己的模型能力 + 已开的技能」挑合适的任务来解：小猫用主人自己的模型写出答案，
// 主人看过、改过再交（绝不自动提交）。发布者采纳后，小鱼干转给解题的人；不满意可退回广场，取消会退回小鱼干。
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
        if Prefs.xMode { skills.append("陪你刷推") }
        if Prefs.agentOn { skills.append("帮我操作电脑") }
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
            self.present?("🐟 广场上有「\(first.title)」\(more)（\(first.kind) · \(first.reward) 条小鱼干），要我接吗？",
                          [("接这个", { [weak self] in self?.take(first) }),
                           ("看看广场", { [weak self] in self?.showWindow() }),
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
            return "广场服务器还没开通好（管理员需要在 Supabase 运行 supabase/square.sql）"
        }
        return e
    }

    func refreshBalance(_ done: (() -> Void)? = nil) {
        guard ready else { done?(); return }
        rpc("fish_balance", [:]) { [weak self] obj, _ in
            if let b = obj as? Int { self?.balance = b }
            else if let n = obj as? NSNumber { self?.balance = n.intValue }
            self?.changed()
            done?()
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
                self.present?("📬 你发到广场的「\(t.title)」有小猫回答啦，去看看？",
                              [("看回答", { [weak self] in self?.showAnswer(t) })], 20)
                return
            }
            self.myTaken { [weak self] ts2, _ in
                for t in ts2 where t.status == "done" && !seen.contains("d:" + t.id) {
                    seen.append("d:" + t.id)
                    Prefs.squareSeen = seen
                    self?.refreshBalance()
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
                if manual { self.present?(err.map { "广场没连上：\($0)" } ?? "广场上暂时没有适合我的任务 🐾 晚点我再看看。", [], 6) }
                return
            }
            let lines = cands.enumerated().map { i, t in
                "\(i + 1). [\(t.kind)] \(t.title)｜\(String(t.body.prefix(160)).replacingOccurrences(of: "\n", with: " "))｜奖励 \(t.reward)"
            }.joined(separator: "\n")
            let prompt = """
            下面是任务广场上别人发的问题。你的模型是 \(Prefs.model)，能力：\(TaskSquare.capsLine)。
            挑出一个你最有把握解得又好又对的任务（只考虑你真能做好的，不要因为奖励高就选）。
            只回一行 JSON：{"pick": 编号, "why": "不超过 25 字的理由"}；一个都没把握就回 {"pick": 0, "why": ""}。

            \(lines)
            """
            self.matchLLM.stream([["role": "user", "content": prompt]], context: "这次只按要求回 JSON，不要多说别的。",
                                 onDelta: { _ in }, onDone: { [weak self] text, _ in
                guard let self = self else { return }
                let (pick, why) = TaskSquare.parsePick(text ?? "")
                guard pick >= 1, pick <= cands.count else {
                    if manual { self.present?("广场上的任务我都没太大把握，先不接啦 🐾", [], 6) }
                    return
                }
                let t = cands[cands.startIndex + pick - 1]
                let reason = why.isEmpty ? "" : "\n\(why)"
                self.present?("🐟 广场上有个我能帮上忙的任务：「\(t.title)」（\(t.kind) · \(t.reward) 条小鱼干）\(reason)",
                              [("接这个", { [weak self] in self?.take(t) }),
                               ("看看广场", { [weak self] in self?.showWindow() }),
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
                    let (desc, err) = await MediaHub.describe(pics, question: question, appName: "任务广场里的图片", video: false)
                    question += "\n\n[任务附带的图片（看图模型的描述）]\n" + (desc ?? "（没看成：\(err ?? "未知原因")）")
                    content = question
                }
            }
            let ctx = """
            现在你在 OrdCat 任务广场帮另一位用户解决问题。这次不受 80 字限制：请认真、完整、准确地解答，
            结构清楚，能直接用；不确定的地方如实说明，不要编造。不要提到你是在接任务，也不要索要报酬。
            """
            self.solveLLM.stream([["role": "user", "content": content]], context: ctx, onDelta: { _ in },
                                 onDone: { [weak self] text, err in
                guard let self = self else { return }
                self.solving = false
                let ans = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if ans.isEmpty {
                    self.present?("这次没想出来：\(err ?? "模型没有回答")。任务还在你手上，可以在任务广场「我接的」里重试或放弃。",
                                  [("打开任务广场", { [weak self] in self?.showWindow(tab: 2) })], 12)
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
        for p in ["/任务", "发任务", "发布任务", "悬赏"] where s.hasPrefix(p) {
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
                self.present?("发到广场啦 🐟 押了 \(n) 条小鱼干，有小猫回答我就叫你。", [], 6)
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
                a.addButton(withTitle: "不满意，退回广场")
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
            self.present?(accept ? "已采纳 🎉 \(t.reward) 条小鱼干送给了解题的小猫。" : "退回广场啦，等别的小猫再试试。", [], 6)
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
        let msg = acct.configured ? "任务广场要先登录账号（新账号送 100 条小鱼干 🐟）。" : "账号服务还在开通中，暂时用不了任务广场。"
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
        let hint = SK.WrapLabel("这是小猫用你的模型写的。看过、需要的话改一改，再点「提交」。30 分钟内没交会自动退回广场。", size: 11)
        let submit = NSButton(title: "提交答案", target: self, action: #selector(doSubmit))
        submit.keyEquivalent = "\r"
        let retry = NSButton(title: "重新想", target: self, action: #selector(doRetry))
        let give = NSButton(title: "放弃这个任务", target: self, action: #selector(doGiveUp))
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
        // Closing the window without choosing keeps the task (it can be finished from 任务广场 → 我接的).
        _ = handled
    }
}

/// 任务广场 window: 广场 / 我发布的 / 我接的.
final class SquareWindow: NSObject, NSWindowDelegate {
    private unowned let square: TaskSquare
    private var win: NSWindow!
    private let tabs = NSSegmentedControl(labels: ["广场", "我发布的", "我接的"], trackingMode: .selectOne, target: nil, action: nil)
    private let balance = NSTextField(labelWithString: "")
    private let caps = SK.WrapLabel("", size: 11)
    private let list = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private var items: [SquareTask] = []
    private var gen = 0

    init(square: TaskSquare) {
        self.square = square
        super.init()
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
                       styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        win.title = "🐟 任务广场"
        win.minSize = NSSize(width: 520, height: 380)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.setFrameAutosaveName("OrdCatSquare")
        let root = NSView()
        balance.font = .systemFont(ofSize: 14, weight: .semibold)
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        let post = NSButton(title: "发布任务", target: self, action: #selector(post))
        post.bezelStyle = .rounded
        let find = NSButton(title: "帮我挑一个", target: self, action: #selector(find))
        find.bezelStyle = .rounded
        find.toolTip = "小猫按你的模型和技能，从广场挑一个最适合它解的任务"
        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshNow))
        refresh.bezelStyle = .rounded
        let top = NSStackView(views: [balance, NSView(), find, refresh, post])
        top.spacing = 8
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
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
        for v in [top, tabs, caps, scroll, status] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            caps.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
            caps.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            caps.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            tabs.topAnchor.constraint(equalTo: caps.bottomAnchor, constant: 10),
            tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            status.leadingAnchor.constraint(equalTo: top.leadingAnchor),
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

    func reload(fetch: Bool) {
        guard win.isVisible || fetch else { return }
        balance.stringValue = "🐟 小鱼干：\(square.balance.map(String.init) ?? "—")"
        caps.stringValue = "我的小猫：" + TaskSquare.capsLine
        guard fetch else { return }
        guard square.ready else {
            items = []
            render(empty: Account.shared.configured ? "先登录账号才能用任务广场（设置 → 账号，新账号送 100 条小鱼干）。" : "账号服务还在开通中。")
            return
        }
        gen += 1
        let g = gen
        status.stringValue = "正在加载…"
        let done: ([SquareTask], String?) -> Void = { [weak self] ts, err in
            guard let self = self, g == self.gen else { return }
            self.items = ts
            self.status.stringValue = err.map { "没连上：\($0)" } ?? "共 \(ts.count) 个"
            self.render(empty: ["广场上还没有任务，发一个试试？", "你还没发过任务。", "你还没接过任务。"][self.tabs.selectedSegment])
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
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let title = SK.WrapLabel("\(t.title)", size: 13.5, secondary: false, weight: .semibold)
            let who = t.posterName.isEmpty ? "一位用户" : t.posterName
            var metaText = "\(t.kind) · \(t.needsText) · 🐟 \(t.reward)"
            switch tabs.selectedSegment {
            case 0: metaText += " · \(who)"
            default: metaText += " · \(t.statusText)"
            }
            if !t.extrasText.isEmpty { metaText += " · " + t.extrasText }
            let meta = SK.WrapLabel(metaText, size: 11.5)
            let body = SK.WrapLabel(String(t.body.prefix(220)), size: 12)
            let col = NSStackView(views: [title, meta, body])
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 3
            col.translatesAutoresizingMaskIntoConstraints = false
            for l in [title, meta, body] { l.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
            if t.body.isEmpty { body.isHidden = true }
            let acts = NSStackView()
            acts.orientation = .vertical
            acts.alignment = .trailing
            acts.spacing = 6
            acts.translatesAutoresizingMaskIntoConstraints = false
            acts.setContentHuggingPriority(.required, for: .horizontal)
            acts.setContentCompressionResistancePriority(.required, for: .horizontal)
            for (name, sel, enabled) in actions(for: t, uid: uid) {
                let b = NSButton(title: name, target: self, action: sel)
                b.bezelStyle = .rounded
                b.controlSize = .small
                b.tag = i
                b.isEnabled = enabled
                acts.addArrangedSubview(b)
            }
            row.addSubview(col); row.addSubview(acts)
            let line = NSBox()
            line.boxType = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(line)
            NSLayoutConstraint.activate([
                col.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
                col.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
                col.trailingAnchor.constraint(equalTo: acts.leadingAnchor, constant: -12),
                col.bottomAnchor.constraint(lessThanOrEqualTo: line.topAnchor, constant: -10),
                acts.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
                acts.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
                acts.bottomAnchor.constraint(lessThanOrEqualTo: line.topAnchor, constant: -10),
                line.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                line.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                line.bottomAnchor.constraint(equalTo: row.bottomAnchor)])
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
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
            default: return [("已退回广场", #selector(noop), false)]
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
