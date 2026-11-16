// OrdCat — 技能「帮我操作电脑」.
//
// The user says what to do ("帮我在备忘录里新建一条：明天买猫粮"). Each round the cat reads the target app's
// clickable/typeable elements through Accessibility, asks the model for ONE next action as JSON, shows it,
// and acts only after the user agrees (or in auto mode, except risky steps which always ask).
// Never: password fields, payments, sending messages on its own. Esc stops at any time.

import Cocoa

extension Prefs {
    static var agentOn: Bool { get { d.object(forKey: "agentOn") as? Bool ?? false } set { d.set(newValue, forKey: "agentOn") } }
    /// Ask before every step (default). Off = run safe steps automatically.
    static var agentConfirm: Bool { get { d.object(forKey: "agentConfirm") as? Bool ?? true } set { d.set(newValue, forKey: "agentConfirm") } }
}

final class DesktopAgent {
    struct Target { let id: Int; let el: AXUIElement; let role: String; let label: String; let rect: CGRect }
    struct Action {
        var kind: String
        var id: Int?
        var text: String?
        var keys: String?
        var app: String?
        var url: String?
        var dir: String?
        var say: String
    }

    /// Show a message with buttons next to the cat.
    var present: ((String, [(String, () -> Void)]) -> Void)?
    /// Called when a run ends, with a short log for the chat history.
    var onFinish: ((String) -> Void)?

    private let llm = LLM()
    private var goal = ""
    private var log: [String] = []
    private var targets: [Target] = []
    private var app: NSRunningApplication?
    private var auto = false
    private(set) var running = false
    private var stepCount = 0
    private let maxSteps = 25
    private var escMonitor: Any?
    private var lastExternalApp: NSRunningApplication?
    private let queue = DispatchQueue(label: "app.ordcat.agent", qos: .userInitiated)

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  a.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.lastExternalApp = a
        }
    }

    /// Does this chat message ask the cat to operate the computer?
    static func isTask(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("/做") || t.hasPrefix("帮我操作") { return true }
        return t.range(of: "^(请)?(帮我|替我|给我)(在|用|打开|点|点击|新建|关闭|切换|输入|填|搜索|操作|把)",
                       options: .regularExpression) != nil
    }

    // MARK: run

    func start(goal raw: String) {
        stop(silent: true)
        var g = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if g.hasPrefix("/做") { g = String(g.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        guard !g.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            present?("🤖 要先在 系统设置 → 隐私与安全性 → 辅助功能 里允许 OrdCat，我才能帮你操作。", [])
            return
        }
        goal = g
        log = []
        stepCount = 0
        auto = !Prefs.agentConfirm
        running = true
        app = lastExternalApp ?? NSWorkspace.shared.frontmostApplication
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { DispatchQueue.main.async { self?.stop() } }   // Esc
        }
        present?("🤖 好，我来试试：\(g)\n（按 Esc 随时停下）", [("停止", { [weak self] in self?.stop() })])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.nextStep() }
    }

    func stop(silent: Bool = false) {
        guard running else { return }
        running = false
        llm.cancel()
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        if !silent {
            present?("🤖 已停下。" + (log.isEmpty ? "" : "做了 \(log.count) 步。"), [])
            onFinish?(summary(done: false))
        }
    }

    private func finish(_ say: String) {
        running = false
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        present?("🤖 " + say, [])
        onFinish?(summary(done: true, say: say))
    }

    private func summary(done: Bool, say: String = "") -> String {
        var s = "🤖 帮你操作：\(goal)\n"
        for (i, l) in log.enumerated() { s += "\(i + 1). \(l)\n" }
        s += done ? (say.isEmpty ? "✅ 完成" : "✅ " + say) : "⏹ 停下了"
        return s
    }

    private func nextStep() {
        guard running else { return }
        stepCount += 1
        guard stepCount <= maxSteps else { finish("步骤太多了，我先停下。你看看现在的样子，要继续就再告诉我。"); return }
        let target = app
        queue.async { [weak self] in
            guard let self = self else { return }
            let snap = self.snapshot(target)
            DispatchQueue.main.async {
                guard self.running else { return }
                self.targets = snap.targets
                self.ask(appName: snap.appName, window: snap.window)
            }
        }
    }

    // MARK: perception (AX)

    private static let actionable: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXTab", "AXComboBox", "AXSearchField", "AXCell", "AXRow",
        "AXDisclosureTriangle", "AXIncrementor", "AXSlider", "AXStaticText"
    ]
    private static let roleName: [String: String] = [
        "AXButton": "按钮", "AXLink": "链接", "AXTextField": "输入框", "AXTextArea": "文本框", "AXCheckBox": "勾选框",
        "AXRadioButton": "单选", "AXPopUpButton": "下拉", "AXMenuButton": "菜单按钮", "AXMenuItem": "菜单项",
        "AXMenuBarItem": "菜单栏", "AXTab": "标签页", "AXComboBox": "组合框", "AXSearchField": "搜索框",
        "AXCell": "格子", "AXRow": "行", "AXDisclosureTriangle": "展开", "AXIncrementor": "加减", "AXSlider": "滑块",
        "AXStaticText": "文字"
    ]

    private func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    private func str(_ el: AXUIElement, _ name: String) -> String? {
        (attr(el, name) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    private func rect(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute as String), let s = attr(el, kAXSizeAttribute as String) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    private func snapshot(_ app: NSRunningApplication?) -> (targets: [Target], appName: String, window: String) {
        guard let app = app else { return ([], "（没有）", "") }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.4)
        AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var roots: [AXUIElement] = []
        var title = ""
        if let w = attr(ax, kAXFocusedWindowAttribute as String) {
            let win = w as! AXUIElement
            roots.append(win)
            title = str(win, kAXTitleAttribute as String) ?? ""
        }
        if let mb = attr(ax, kAXMenuBarAttribute as String) { roots.append(mb as! AXUIElement) }
        if roots.isEmpty { roots = [ax] }
        var out: [Target] = []
        var queue = roots
        var seen = 0
        let started = Date()
        let screen = NSScreen.screens.reduce(CGRect.zero) { $0.union($1.frame) }
        while !queue.isEmpty && seen < 4000 && out.count < 160 && Date().timeIntervalSince(started) < 2.5 {
            let el = queue.removeFirst()
            seen += 1
            let role = str(el, kAXRoleAttribute as String) ?? ""
            if role == "AXSecureTextField" { continue }                     // never touch passwords
            let isMenuBar = role == "AXMenuBarItem"
            if Self.actionable.contains(role), let r = rect(el), r.width > 2, r.height > 2,
               isMenuBar || screen.intersects(r) {
                var label = str(el, kAXTitleAttribute as String) ?? str(el, kAXDescriptionAttribute as String)
                    ?? str(el, "AXPlaceholderValue") ?? str(el, kAXHelpAttribute as String) ?? ""
                if role == "AXStaticText" || role == "AXCell" || role == "AXRow" || role == "AXCheckBox" {
                    if label.isEmpty, let v = attr(el, kAXValueAttribute as String) as? String { label = v }
                }
                if role == "AXTextField" || role == "AXTextArea" || role == "AXSearchField" || role == "AXComboBox" {
                    if let v = attr(el, kAXValueAttribute as String) as? String, !v.isEmpty {
                        label += (label.isEmpty ? "" : " ") + "（现有内容：\(v.prefix(40))）"
                    }
                }
                label = label.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                if !(role == "AXStaticText" && label.isEmpty) && !(role == "AXRow" && label.isEmpty) {
                    out.append(Target(id: out.count + 1, el: el, role: role, label: String(label.prefix(60)), rect: r))
                }
            }
            if isMenuBar { continue }   // don't open menus while reading
            if let kids = attr(el, kAXChildrenAttribute as String) as? [AXUIElement] { queue.append(contentsOf: kids.prefix(80)) }
        }
        return (out, app.localizedName ?? "?", title)
    }

    // MARK: model

    private func ask(appName: String, window: String) {
        var list = ""
        for t in targets { list += "[\(t.id)] \(Self.roleName[t.role] ?? t.role)「\(t.label)」\n" }
        if list.isEmpty { list = "（读不到这个应用的界面元素）\n" }
        let done = log.isEmpty ? "（还没有）" : log.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = """
        你是桌面小猫 OrdCat 的技能「帮我操作电脑」，一次只决定下一步操作。
        用户的目标：\(goal)
        现在最前面的应用：\(appName)　窗口：\(window)
        已经做过的步骤：
        \(done)
        现在界面上能操作的元素（编号）：
        \(list)
        只输出一个 JSON，不要别的文字：
        {"action":"click|type|key|open|scroll|wait|done|ask","id":元素编号,"text":"要输入的文字","keys":"如 cmd+n、enter、tab","app":"要打开的应用名","url":"要打开的网址","dir":"up|down","say":"用一句中文告诉用户这一步要做什么"}
        规则：
        - click 点元素；type 先点中输入框再输入 text（需要 id）；key 按快捷键；open 打开应用或网址；scroll 滚动；wait 等页面加载。
        - 目标需要别的应用时先 open 它。
        - 目标已经完成就 done，并在 say 里说结果；做不到或需要用户自己决定就 ask，并在 say 里说明。
        - 绝不输入密码、绝不付款、绝不替用户点「发送 / 发布 / 购买 / 删除」，到那一步用 ask 让用户自己来。
        """
        present?("🤖 第 \(stepCount) 步：在看「\(appName)」…", [("停止", { [weak self] in self?.stop() })])
        llm.stream([["role": "user", "content": prompt]], onDelta: { _ in }, onDone: { [weak self] t, err in
            guard let self = self, self.running else { return }
            if let e = err { self.finish("模型出错了：\(e)"); return }
            guard let a = Self.parse(t ?? "") else { self.finish("我没想明白下一步，先停下。你可以换个说法再试。"); return }
            self.propose(a)
        })
    }

    static func parse(_ text: String) -> Action? {
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e,
              let data = String(text[s...e]).data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = o["action"] as? String else { return nil }
        var id = o["id"] as? Int
        if id == nil, let sid = o["id"] as? String { id = Int(sid) }
        return Action(kind: kind.lowercased(), id: id, text: o["text"] as? String, keys: o["keys"] as? String,
                      app: o["app"] as? String, url: o["url"] as? String, dir: o["dir"] as? String,
                      say: (o["say"] as? String) ?? "")
    }

    // MARK: confirm + act

    private static let riskyWords = ["发送", "送出", "发布", "發佈", "發送", "回覆", "回复", "send", "post", "reply", "tweet",
                                     "购买", "購買", "付款", "支付", "pay", "buy", "checkout", "下单", "删除", "刪除",
                                     "delete", "remove", "移除", "清空", "确认支付", "转账", "提交", "submit"]
    private static let chatApps: Set<String> = ["com.apple.MobileSMS", "com.tencent.xinWeChat", "ru.keepcoder.Telegram",
                                                "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.mail",
                                                "jp.naver.line.mac", "net.whatsapp.WhatsApp", "com.tencent.qq"]

    private func isRisky(_ a: Action) -> Bool {
        let label = a.id.flatMap { id in targets.first { $0.id == id }?.label.lowercased() } ?? ""
        if a.kind == "click" && Self.riskyWords.contains(where: { label.contains($0) }) { return true }
        if a.kind == "key", let k = a.keys?.lowercased(), k.contains("enter") || k.contains("return") {
            if let b = app?.bundleIdentifier, Self.chatApps.contains(b) { return true }
            if label.contains("回") || (app?.localizedName ?? "").contains("X") { return true }
        }
        if a.kind == "type", let t = a.text, t.contains("\n") { return true }   // a newline may send
        return false
    }

    private func describe(_ a: Action) -> String {
        let t = a.id.flatMap { id in targets.first { $0.id == id } }
        let what = t.map { "\(Self.roleName[$0.role] ?? "")「\($0.label)」" } ?? ""
        switch a.kind {
        case "click": return "点 \(what)"
        case "type": return "在 \(what) 输入「\((a.text ?? "").prefix(40))」"
        case "key": return "按 \(a.keys ?? "")"
        case "open": return "打开 \(a.app ?? a.url ?? "")"
        case "scroll": return "往\(a.dir == "up" ? "上" : "下")滚动"
        case "wait": return "等一下"
        default: return a.say
        }
    }

    private func propose(_ a: Action) {
        switch a.kind {
        case "done": finish(a.say.isEmpty ? "做完啦。" : a.say); return
        case "ask": finish(a.say.isEmpty ? "这一步需要你自己来。" : a.say); return
        default: break
        }
        let step = describe(a)
        let risky = isRisky(a)
        if auto && !risky {
            present?("🤖 第 \(stepCount) 步：\(step)", [("停止", { [weak self] in self?.stop() })])
            execute(a, step: step)
            return
        }
        var text = "🤖 第 \(stepCount) 步：\(a.say.isEmpty ? step : a.say)\n→ \(step)"
        if risky { text += "\n⚠️ 这一步可能会发送、付款或删除东西，确认是你想要的再点。" }
        var acts: [(String, () -> Void)] = [("执行", { [weak self] in self?.execute(a, step: step) })]
        if !risky && !auto { acts.append(("之后都自动", { [weak self] in self?.auto = true; self?.execute(a, step: step) })) }
        acts.append(("跳过", { [weak self] in self?.log.append("（跳过）" + step); self?.nextStep() }))
        acts.append(("停止", { [weak self] in self?.stop() }))
        present?(text, acts)
    }

    private func execute(_ a: Action, step: String) {
        guard running else { return }
        if let target = app, a.kind != "open" { target.activate(options: []) }
        let t = a.id.flatMap { id in targets.first { $0.id == id } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, self.running else { return }
            var ok = true
            switch a.kind {
            case "click":
                guard let t = t else { ok = false; break }
                ok = self.press(t)
            case "type":
                if let t = t {
                    AXUIElementSetAttributeValue(t.el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    if !self.press(t) { self.click(at: CGPoint(x: t.rect.midX, y: t.rect.midY)) }
                }
                usleep(150_000)
                self.typeText(a.text ?? "")
            case "key":
                ok = self.pressKeys(a.keys ?? "")
            case "open":
                ok = self.open(app: a.app, url: a.url)
            case "scroll":
                self.scroll(up: a.dir == "up", at: t.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) })
            default:
                break
            }
            self.log.append(ok ? step : "⚠️ 没成功：" + step)
            let wait: Double = a.kind == "open" ? 1.8 : (a.kind == "wait" ? 1.5 : 0.9)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.nextStep() }
        }
    }

    // MARK: input

    private func press(_ t: Target) -> Bool {
        let r = AXUIElementPerformAction(t.el, kAXPressAction as CFString)
        if r == .success { return true }
        if t.role == "AXMenuBarItem" || t.role == "AXMenuItem" {
            if AXUIElementPerformAction(t.el, "AXPick" as CFString) == .success { return true }
        }
        click(at: CGPoint(x: t.rect.midX, y: t.rect.midY))
        return true
    }

    private func click(at p: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(40_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func typeText(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        let chars = Array(text.replacingOccurrences(of: "\n", with: " ").utf16)
        var i = 0
        while i < chars.count {
            let chunk = Array(chars[i..<min(i + 16, chars.count)])
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up?.post(tap: .cghidEventTap)
            usleep(25_000)
            i += 16
        }
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "enter": 36, "return": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "esc": 53, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "f5": 96
    ]

    private func pressKeys(_ combo: String) -> Bool {
        let parts = combo.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for p in parts {
            switch p {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            default: key = Self.keyCodes[p]
            }
        }
        guard let k = key else { return false }
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
        return true
    }

    private func scroll(up: Bool, at p: CGPoint?) {
        if let p = p { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: up ? 8 : -8, wheel2: 0, wheel3: 0)
        e?.post(tap: .cghidEventTap)
    }

    private func open(app name: String?, url: String?) -> Bool {
        if let u = url, let link = URL(string: u), link.scheme?.hasPrefix("http") == true {
            NSWorkspace.shared.open(link)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.app = NSWorkspace.shared.frontmostApplication
            }
            return true
        }
        guard let n = name, !n.isEmpty else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", n]
        do { try p.run(); p.waitUntilExit() } catch { return false }
        guard p.terminationStatus == 0 else { return false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if let a = NSWorkspace.shared.runningApplications.first(where: {
                ($0.localizedName ?? "").localizedCaseInsensitiveContains(n)
            }) {
                self?.app = a
                a.activate(options: [])
            } else {
                self?.app = NSWorkspace.shared.frontmostApplication
            }
        }
        return true
    }
}
