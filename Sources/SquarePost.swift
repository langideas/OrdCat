// OrdCat — 猫帮圈：发布窗口（模版、链接、代码、文件）+ 设置里的「猫帮圈」页。
//
// 发布：选一个模版（内置 + 自己存的），按提示填；可以贴链接（X 推文、GitHub、YouTube、B站、知乎……会自动识别），
// 插入代码块，附代码 / 文本 / PDF / Word / 图片文件（最多 5 个，每个 10 MB 内）。
// 解题：小猫会读链接内容和附件内容（图片交给看图模型），再用主人自己的模型写答案。

import Cocoa
import PDFKit
import UniformTypeIdentifiers

// MARK: - 模版

struct SquareTemplate: Codable {
    var name: String
    var kind: String
    var title: String
    var body: String
}

enum SquareTemplates {
    static let builtIn: [SquareTemplate] = [
        SquareTemplate(name: "空白", kind: "其他", title: "", body: ""),
        SquareTemplate(name: "🐞 代码报错 / 找 bug", kind: "代码", title: "帮我找一个 bug：",
                       body: "【我在做什么】\n（例如：用 Swift 写一个 macOS 菜单栏小工具）\n\n【出了什么问题】\n（报错信息原样贴上，或描述哪里不对）\n\n【相关代码】\n```swift\n\n```\n\n【我已经试过】\n\n【希望得到】\n（例如：指出原因 + 改好的代码）"),
        SquareTemplate(name: "💻 写一段代码", kind: "代码", title: "帮我写一段代码：",
                       body: "【要实现的功能】\n\n【语言 / 框架 / 版本】\n\n【输入和输出的例子】\n\n【限制】\n（例如：不用第三方库、要能在 macOS 13 上跑）"),
        SquareTemplate(name: "🔗 解读链接（推文 / GitHub / 文章）", kind: "其他", title: "帮我看看这个链接：",
                       body: "【链接】\n（贴在下面的「链接」栏，可以贴多个）\n\n【我想知道】\n（例如：这条推文说的是真的吗？这个仓库怎么跑起来？这篇文章的重点是什么？）"),
        SquareTemplate(name: "✍️ 写作 / 润色", kind: "写作", title: "帮我改一段文字：",
                       body: "【要写 / 要改的内容】\n\n【给谁看、用在哪】\n\n【语气和长度】\n（例如：正式一点，300 字以内）\n\n【其他要求】"),
        SquareTemplate(name: "🌐 翻译", kind: "翻译", title: "帮我翻译：",
                       body: "【原文】\n\n【翻成】\n（例如：英文，美式，口语一点）\n\n【用途】"),
        SquareTemplate(name: "📚 学习答疑", kind: "学习", title: "请教一个问题：",
                       body: "【问题】\n\n【我目前理解到】\n\n【希望讲到什么程度】\n（例如：像给初学者讲，带一个例子）"),
        SquareTemplate(name: "🖼 看图", kind: "看图", title: "帮我看看这张图：",
                       body: "【图是什么】\n（在下面「附件」里加图片）\n\n【我想知道】"),
        SquareTemplate(name: "🏠 生活建议", kind: "生活", title: "想听听建议：",
                       body: "【情况】\n\n【我的考虑】\n\n【想要什么样的建议】")
    ]

    static var custom: [SquareTemplate] {
        get {
            guard let d = UserDefaults.standard.data(forKey: "squareTemplates"),
                  let t = try? JSONDecoder().decode([SquareTemplate].self, from: d) else { return [] }
            return t
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "squareTemplates") }
    }

    /// Built-ins first (a saved template with the same name replaces it), then the user's own.
    static var all: [SquareTemplate] {
        let mine = custom
        var out = builtIn.map { b in mine.first { $0.name == b.name } ?? b }
        out += mine.filter { m in !builtIn.contains { $0.name == m.name } }
        return out
    }
    static func isCustom(_ name: String) -> Bool { custom.contains { $0.name == name } }

    /// What to write, shown under the form for each task kind.
    static func hint(_ kind: String) -> String {
        switch kind {
        case "代码": return "写清语言和版本，报错原样贴，代码放进代码块或作为文件附上。"
        case "写作": return "说清给谁看、用在哪、语气和长度。"
        case "翻译": return "贴原文，写明翻成什么语言、什么风格。"
        case "学习": return "说说你已经懂到哪，想讲多深。"
        case "看图": return "在附件里加图片，要会看图的小猫才能接。"
        case "生活": return "情况说具体一点，别写隐私。"
        default: return "一句话说清要什么结果，越具体越好答。"
        }
    }
}

// MARK: - 链接

struct SquareLink {
    let url: String
    let platform: String

    static func platform(of s: String) -> String {
        guard let h = URL(string: s)?.host?.lowercased() else { return "网页" }
        func on(_ d: String) -> Bool { h == d || h.hasSuffix("." + d) }
        if on("x.com") || on("twitter.com") { return "X 推文" }
        if on("gist.github.com") { return "GitHub Gist" }
        if on("github.com") || on("raw.githubusercontent.com") { return "GitHub" }
        if on("gitlab.com") { return "GitLab" }
        if on("youtube.com") || on("youtu.be") { return "YouTube" }
        if on("bilibili.com") || on("b23.tv") { return "B站" }
        if on("xiaohongshu.com") || on("xhslink.com") { return "小红书" }
        if on("zhihu.com") { return "知乎" }
        if on("weibo.com") || on("weibo.cn") { return "微博" }
        if on("mp.weixin.qq.com") { return "公众号文章" }
        if on("douyin.com") { return "抖音" }
        if on("reddit.com") { return "Reddit" }
        if on("stackoverflow.com") || on("stackexchange.com") { return "Stack Overflow" }
        if on("huggingface.co") { return "Hugging Face" }
        if on("notion.so") || on("notion.site") { return "Notion" }
        if on("docs.google.com") || on("drive.google.com") { return "Google 文档" }
        if on("feishu.cn") || on("larksuite.com") { return "飞书文档" }
        if on("medium.com") { return "Medium" }
        if on("arxiv.org") { return "arXiv 论文" }
        return "网页"
    }

    /// Every http(s) link in a piece of text, in order, without duplicates (max 10).
    static func find(in text: String) -> [SquareLink] {
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        var out: [SquareLink] = []
        for m in det.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let u = m.url, let sch = u.scheme?.lowercased(), sch == "http" || sch == "https" else { continue }
            let s = u.absoluteString
            if seen.insert(s).inserted { out.append(SquareLink(url: s, platform: platform(of: s))) }
            if out.count >= 10 { break }
        }
        return out
    }

    var json: [String: Any] { ["url": url, "platform": platform] }
    init(url: String, platform: String) { self.url = url; self.platform = platform }
    init?(_ o: Any) {
        guard let d = o as? [String: Any], let u = d["url"] as? String else { return nil }
        url = u
        platform = d["platform"] as? String ?? SquareLink.platform(of: u)
    }

    /// Readable text behind the link, for the solving cat (best effort, capped).
    func fetchText() async -> String {
        guard let u = URL(string: url) else { return "（链接打不开）" }
        let host = u.host?.lowercased() ?? ""
        let parts = u.pathComponents.filter { $0 != "/" }
        // X / Twitter: the public oEmbed endpoint gives the post text without signing in.
        if platform == "X 推文" {
            var c = URLComponents(string: "https://publish.twitter.com/oembed")!
            c.queryItems = [URLQueryItem(name: "url", value: url), URLQueryItem(name: "omit_script", value: "1")]
            if let j = await SquareLink.getJSON(c.url!) as? [String: Any], let html = j["html"] as? String {
                let who = j["author_name"] as? String ?? ""
                return "推文（\(who)）：" + SquareLink.plain(html)
            }
            return "（推文读不到，可能是私密或已删除）"
        }
        // GitHub: repo → README, blob → raw file, issue / PR → title + body.
        if platform == "GitHub" && host.hasSuffix("github.com") && host != "raw.githubusercontent.com" && parts.count >= 2 {
            let o = parts[0], r = parts[1]
            if parts.count >= 4 && (parts[2] == "issues" || parts[2] == "pull"),
               let api = URL(string: "https://api.github.com/repos/\(o)/\(r)/issues/\(parts[3])"),
               let j = await SquareLink.getJSON(api) as? [String: Any] {
                return "GitHub \(parts[2] == "pull" ? "PR" : "Issue")：\(j["title"] as? String ?? "")\n\(j["body"] as? String ?? "")"
            }
            if parts.count >= 5 && parts[2] == "blob" {
                // parts[3] is the branch; the rest is the file path.
                let path = parts[4...].joined(separator: "/")
                if let rawURL = URL(string: "https://raw.githubusercontent.com/\(o)/\(r)/\(parts[3])/\(path)"),
                   let t = await SquareLink.getText(rawURL) { return "GitHub 文件 \(path)：\n" + t }
            }
            if parts.count == 2, let api = URL(string: "https://api.github.com/repos/\(o)/\(r)/readme"),
               let t = await SquareLink.getText(api, accept: "application/vnd.github.raw") {
                return "GitHub 仓库 \(o)/\(r) 的 README：\n" + t
            }
        }
        if let t = await SquareLink.getText(u) { return t }
        return "（这个链接打不开，或需要登录）"
    }

    private static func get(_ u: URL, accept: String? = nil) async -> (Data, String)? {
        var req = URLRequest(url: u)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        if let a = accept { req.setValue(a, forHTTPHeaderField: "Accept") }
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              let h = r as? HTTPURLResponse, (200..<300).contains(h.statusCode) else { return nil }
        return (d, (h.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased())
    }
    private static func getJSON(_ u: URL) async -> Any? {
        guard let (d, _) = await get(u, accept: "application/json") else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }
    private static func getText(_ u: URL, accept: String? = nil) async -> String? {
        guard let (d, type) = await get(u, accept: accept) else { return nil }
        if type.contains("pdf") { return PDFDocument(data: d)?.string.map { String($0.prefix(8000)) } }
        let s = String(decoding: d, as: UTF8.self)
        let t = type.contains("html") || s.prefix(400).lowercased().contains("<html") ? plain(s) : s
        let out = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : String(out.prefix(8000))
    }

    /// HTML → plain text: title + visible text, scripts and styles dropped.
    static func plain(_ html: String) -> String {
        var s = html
        var title = ""
        if let r = s.range(of: "<title[^>]*>([\\s\\S]*?)</title>", options: [.regularExpression, .caseInsensitive]) {
            title = String(s[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        for p in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<noscript[\\s\\S]*?</noscript>", "<svg[\\s\\S]*?</svg>"] {
            s = s.replacingOccurrences(of: p, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&mdash;", "—")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        let body = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? body : "【\(t)】\n" + body
    }
}

// MARK: - 附件

struct SquareFile {
    let name: String
    let url: String
    let kind: String   // image | code | text | pdf | doc
    let size: Int

    static let codeExt: Set<String> = ["swift", "py", "js", "mjs", "ts", "tsx", "jsx", "java", "kt", "kts", "go", "rs", "c", "h",
                                       "cpp", "hpp", "cc", "m", "mm", "cs", "rb", "php", "sh", "zsh", "bash", "ps1", "sql", "r",
                                       "lua", "dart", "scala", "vue", "svelte", "html", "htm", "css", "scss", "less", "ipynb",
                                       "gradle", "cmake", "makefile", "dockerfile"]
    static let textExt: Set<String> = ["txt", "md", "markdown", "json", "jsonl", "yaml", "yml", "toml", "xml", "csv", "tsv",
                                       "log", "ini", "conf", "cfg", "plist", "srt", "tex"]
    static let docExt: Set<String> = ["docx", "doc", "rtf"]
    static let imageExt: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp"]
    static let maxBytes = 10 * 1024 * 1024
    static let maxCount = 5

    static func kind(of name: String) -> String? {
        let n = (name as NSString).lastPathComponent.lowercased()
        let e = (n as NSString).pathExtension
        if imageExt.contains(e) { return "image" }
        if e == "pdf" { return "pdf" }
        if docExt.contains(e) { return "doc" }
        if codeExt.contains(e) || codeExt.contains(n) { return "code" }
        if textExt.contains(e) { return "text" }
        return nil
    }
    static var allowedTypes: [UTType] {
        (imageExt.union(codeExt).union(textExt).union(docExt).union(["pdf"])).compactMap { UTType(filenameExtension: $0) }
    }

    var icon: String { ["image": "🖼", "code": "💻", "pdf": "📕", "doc": "📄"][kind] ?? "📝" }
    var json: [String: Any] { ["name": name, "url": url, "kind": kind, "size": size] }
    init(name: String, url: String, kind: String, size: Int) { self.name = name; self.url = url; self.kind = kind; self.size = size }
    init?(_ o: Any) {
        guard let d = o as? [String: Any], let u = d["url"] as? String else { return nil }
        url = u
        name = d["name"] as? String ?? (u as NSString).lastPathComponent
        kind = d["kind"] as? String ?? SquareFile.kind(of: name) ?? "text"
        size = d["size"] as? Int ?? 0
    }

    /// Text inside a non-image file (code, text, PDF, Word), capped.
    static func text(of data: Data, kind: String, name: String) -> String {
        var s: String
        switch kind {
        case "pdf": s = PDFDocument(data: data)?.string ?? "（PDF 读不出文字，可能是扫描件）"
        case "doc":
            let e = (name as NSString).pathExtension.lowercased()
            let type: NSAttributedString.DocumentType = e == "docx" ? .officeOpenXML : (e == "doc" ? .docFormat : .rtf)
            s = (try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil))?.string
                ?? "（文档读不出来）"
        default: s = String(decoding: data, as: UTF8.self)
        }
        return String(s.prefix(15000))
    }

    /// Reads a local file and gets it ready to upload: images shrink to JPEG, text files are de-secreted.
    static func prepare(_ file: URL) -> (data: Data, kind: String, mime: String, ext: String)? {
        guard let k = kind(of: file.lastPathComponent) else { return nil }
        if k == "image" {
            guard let src = NSImage(contentsOf: file) else { return nil }
            let maxSide: CGFloat = 1600
            let s = src.size
            let scale = min(1, maxSide / max(s.width, s.height, 1))
            let out = NSImage(size: NSSize(width: s.width * scale, height: s.height * scale))
            out.lockFocus()
            src.draw(in: NSRect(origin: .zero, size: out.size))
            out.unlockFocus()
            guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
            return (jpg, k, "image/jpeg", "jpg")
        }
        guard let d = try? Data(contentsOf: file) else { return nil }
        let e = file.pathExtension.lowercased()
        if k == "code" || k == "text" {
            let clean = Redactor.clean(String(decoding: d, as: UTF8.self))
            return (Data(clean.utf8), k, "text/plain;charset=UTF-8", e.isEmpty ? "txt" : e)
        }
        let mime = UTType(filenameExtension: e)?.preferredMIMEType ?? "application/octet-stream"
        return (d, k, mime, e)
    }
}

// MARK: - 发布窗口

final class SquarePostWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    /// title, body, kind, reward, links, local files
    var onPost: ((String, String, String, Int, [SquareLink], [URL]) -> Void)?

    private var win: NSWindow!
    private let templatePop = NSPopUpButton()
    private let deleteTpl = OCButton(title: "删除模版", target: nil, action: nil)
    private let title = NSTextField()
    private let kind = NSPopUpButton()
    private let kindHint = NSTextField(labelWithString: "")
    private let body = NSTextView()
    private let langPop = NSPopUpButton()
    private let links = NSTextField()
    private let linkInfo = NSTextField(labelWithString: "")
    private let fileInfo = NSTextField(wrappingLabelWithString: "")
    private let reward = NSComboBox()
    private let postButton = OCButton(title: "发布", target: nil, action: nil)
    private var files: [URL] = []
    private static let langs = ["swift", "python", "javascript", "typescript", "java", "go", "rust", "c", "cpp", "csharp",
                                "kotlin", "ruby", "php", "bash", "sql", "html", "css", "json", "yaml", "markdown", "text"]

    init(prefill: String, balance: Int?) {
        super.init()
        let W: CGFloat = 620, H: CGFloat = 690
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H), styleMask: [.titled, .closable],
                       backing: .buffered, defer: false)
        win.title = "🐟 发布任务到猫帮圈"
        win.isReleasedWhenClosed = false
        win.delegate = self
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        let fx: CGFloat = 92, fw: CGFloat = W - fx - 20

        func lab(_ t: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: t)
            l.alignment = .right
            l.frame = NSRect(x: 10, y: y + 4, width: fx - 18, height: 18)
            v.addSubview(l)
        }
        func small(_ l: NSTextField, _ r: NSRect) {
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.frame = r
            v.addSubview(l)
        }

        let info = NSTextField(wrappingLabelWithString: "猫帮圈上所有登录的用户都能看到标题、说明、链接和附件。别写密码、手机号这类隐私（小猫也会自动打码）。")
        small(info, NSRect(x: 20, y: H - 46, width: W - 40, height: 32))

        // 模版
        lab("模版", H - 84)
        templatePop.frame = NSRect(x: fx, y: H - 86, width: 280, height: 26)
        templatePop.target = self
        templatePop.action = #selector(templateChosen)
        v.addSubview(templatePop)
        let save = OCButton(title: "存为模版…", target: self, action: #selector(saveTemplate))
        save.bezelStyle = .rounded
        save.frame = NSRect(x: fx + 286, y: H - 87, width: 110, height: 28)
        v.addSubview(save)
        deleteTpl.bezelStyle = .rounded
        deleteTpl.target = self
        deleteTpl.action = #selector(deleteTemplate)
        deleteTpl.frame = NSRect(x: fx + 400, y: H - 87, width: 100, height: 28)
        v.addSubview(deleteTpl)

        // 标题
        lab("标题", H - 120)
        title.frame = NSRect(x: fx, y: H - 120, width: fw, height: 24)
        title.placeholderString = "一句话说清要解决什么（2–80 字）"
        v.addSubview(title)

        // 类型
        lab("类型", H - 154)
        kind.frame = NSRect(x: fx, y: H - 156, width: 120, height: 26)
        kind.addItems(withTitles: TaskSquare.kinds)
        kind.selectItem(withTitle: "其他")
        kind.target = self
        kind.action = #selector(kindChanged)
        v.addSubview(kind)
        small(kindHint, NSRect(x: fx + 128, y: H - 150, width: fw - 128, height: 16))

        // 说明
        lab("说明", H - 188)
        let scroll = NSScrollView(frame: NSRect(x: fx, y: H - 440, width: fw, height: 256))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        body.frame = NSRect(x: 0, y: 0, width: fw - 18, height: 256)
        body.isRichText = false
        body.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        body.isAutomaticQuoteSubstitutionEnabled = false
        body.isAutomaticDashSubstitutionEnabled = false
        body.isAutomaticTextReplacementEnabled = false
        body.autoresizingMask = [.width]
        body.isVerticallyResizable = true
        body.textContainer?.widthTracksTextView = true
        scroll.documentView = body
        v.addSubview(scroll)

        // 代码块
        lab("代码", H - 476)
        langPop.frame = NSRect(x: fx, y: H - 478, width: 130, height: 26)
        langPop.addItems(withTitles: SquarePostWindow.langs)
        v.addSubview(langPop)
        let insert = OCButton(title: "插入代码块", target: self, action: #selector(insertCode))
        insert.bezelStyle = .rounded
        insert.frame = NSRect(x: fx + 136, y: H - 479, width: 110, height: 28)
        v.addSubview(insert)
        let codeTip = NSTextField(labelWithString: "代码放在 ``` 之间，排版不会乱；也可以直接附代码文件")
        small(codeTip, NSRect(x: fx + 252, y: H - 472, width: fw - 252, height: 16))

        // 链接
        lab("链接", H - 512)
        links.frame = NSRect(x: fx, y: H - 512, width: fw, height: 24)
        links.placeholderString = "X 推文、GitHub、YouTube、B站、知乎、公众号、文章…（多个用空格隔开）"
        links.delegate = self
        v.addSubview(links)
        small(linkInfo, NSRect(x: fx, y: H - 532, width: fw, height: 16))

        // 附件
        lab("附件", H - 566)
        let add = OCButton(title: "添加文件…", target: self, action: #selector(addFiles))
        add.bezelStyle = .rounded
        add.frame = NSRect(x: fx - 4, y: H - 569, width: 110, height: 28)
        v.addSubview(add)
        let clear = OCButton(title: "清空", target: self, action: #selector(clearFiles))
        clear.bezelStyle = .rounded
        clear.frame = NSRect(x: fx + 108, y: H - 569, width: 70, height: 28)
        v.addSubview(clear)
        fileInfo.font = .systemFont(ofSize: 11.5)
        fileInfo.frame = NSRect(x: fx + 186, y: H - 580, width: fw - 186, height: 34)
        v.addSubview(fileInfo)
        let fileTip = NSTextField(labelWithString: "支持代码、文本 / Markdown / JSON / CSV、PDF、Word、图片；最多 5 个，每个 10 MB 内")
        small(fileTip, NSRect(x: fx, y: H - 600, width: fw, height: 16))

        // 奖励
        lab("奖励 🐟", H - 638)
        reward.frame = NSRect(x: fx, y: H - 640, width: 90, height: 26)
        reward.addItems(withObjectValues: TaskSquare.rewards)
        reward.stringValue = "10"
        reward.completes = false
        v.addSubview(reward)
        let unit = NSTextField(labelWithString: "条")
        unit.frame = NSRect(x: fx + 96, y: H - 634, width: 24, height: 18)
        v.addSubview(unit)
        let bal = NSTextField(wrappingLabelWithString: "你有 \(balance.map(String.init) ?? "…") 条小鱼干。发布时先押上，采纳后给解题的小猫；没人接可以取消退回。")
        small(bal, NSRect(x: fx + 124, y: H - 644, width: fw - 124, height: 30))

        // 按钮
        let cancel = OCButton(title: "取消", target: self, action: #selector(doCancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: W - 220, y: 12, width: 100, height: 30)
        v.addSubview(cancel)
        postButton.bezelStyle = .rounded
        postButton.keyEquivalent = "\r"
        postButton.keyEquivalentModifierMask = [.command]
        postButton.target = self
        postButton.action = #selector(doPost)
        postButton.frame = NSRect(x: W - 116, y: 12, width: 100, height: 30)
        v.addSubview(postButton)
        let keyTip = NSTextField(labelWithString: "⌘↩ 发布")
        small(keyTip, NSRect(x: 20, y: 20, width: 200, height: 16))

        win.contentView = v
        reloadTemplates(select: "空白")
        if !prefill.isEmpty {
            let first = prefill.split(separator: "\n").first.map(String.init) ?? ""
            title.stringValue = String(first.prefix(80))
            body.string = prefill
            let found = SquareLink.find(in: prefill)
            if !found.isEmpty { links.stringValue = found.map(\.url).joined(separator: " ") }
        }
        kindChanged()
        updateLinks()
        updateFiles()
        win.initialFirstResponder = title
    }

    func show() {
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // MARK: templates

    private func reloadTemplates(select name: String) {
        templatePop.removeAllItems()
        let all = SquareTemplates.all
        templatePop.addItems(withTitles: all.map { $0.name + (SquareTemplates.isCustom($0.name) ? " ★" : "") })
        if let i = all.firstIndex(where: { $0.name == name }) { templatePop.selectItem(at: i) }
        updateDelete()
    }
    private var chosenTemplate: SquareTemplate? {
        let all = SquareTemplates.all
        let i = templatePop.indexOfSelectedItem
        return i >= 0 && i < all.count ? all[i] : nil
    }
    private func updateDelete() { deleteTpl.isEnabled = chosenTemplate.map { SquareTemplates.isCustom($0.name) } ?? false }

    @objc private func templateChosen() {
        updateDelete()
        guard let t = chosenTemplate else { return }
        let typed = body.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let isTemplateText = typed.isEmpty || SquareTemplates.all.contains { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) == typed }
        if !isTemplateText {
            let a = NSAlert()
            a.messageText = "换成「\(t.name)」模版？"
            a.informativeText = "说明里已经写了内容，换模版会替换掉。"
            a.addButton(withTitle: "替换")
            a.addButton(withTitle: "不换")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        if !t.title.isEmpty || title.stringValue.isEmpty { title.stringValue = t.title }
        body.string = t.body
        kind.selectItem(withTitle: TaskSquare.kinds.contains(t.kind) ? t.kind : "其他")
        kindChanged()
        win.makeFirstResponder(title)
        if let ed = title.currentEditor() { ed.selectedRange = NSRange(location: (title.stringValue as NSString).length, length: 0) }
    }

    @objc private func saveTemplate() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "模版名字"
        if let t = chosenTemplate, t.name != "空白" { field.stringValue = t.name }
        let a = NSAlert()
        a.messageText = "存为模版"
        a.informativeText = "把现在的标题、类型和说明存成模版，下次直接选。名字和已有模版相同会覆盖它。"
        a.accessoryView = field
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "取消")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "空白" else { return }
        var mine = SquareTemplates.custom.filter { $0.name != name }
        mine.append(SquareTemplate(name: name, kind: kind.titleOfSelectedItem ?? "其他",
                                   title: title.stringValue, body: body.string))
        SquareTemplates.custom = mine
        reloadTemplates(select: name)
    }

    @objc private func deleteTemplate() {
        guard let t = chosenTemplate, SquareTemplates.isCustom(t.name) else { return }
        let builtIn = SquareTemplates.builtIn.contains { $0.name == t.name }
        let a = NSAlert()
        a.messageText = builtIn ? "恢复「\(t.name)」为默认？" : "删除模版「\(t.name)」？"
        a.addButton(withTitle: builtIn ? "恢复默认" : "删除")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        SquareTemplates.custom = SquareTemplates.custom.filter { $0.name != t.name }
        reloadTemplates(select: builtIn ? t.name : "空白")
    }

    // MARK: form helpers

    @objc private func kindChanged() {
        kindHint.stringValue = SquareTemplates.hint(kind.titleOfSelectedItem ?? "其他")
    }

    @objc private func insertCode() {
        let lang = langPop.titleOfSelectedItem ?? ""
        let block = "\n```\(lang)\n\n```\n"
        let r = body.selectedRange()
        body.insertText(block, replacementRange: r)
        // Put the cursor on the empty line inside the block.
        let caret = r.location + ("\n```\(lang)\n" as NSString).length
        body.setSelectedRange(NSRange(location: caret, length: 0))
        win.makeFirstResponder(body)
    }

    func controlTextDidChange(_ obj: Notification) { updateLinks() }

    private var parsedLinks: [SquareLink] { SquareLink.find(in: links.stringValue) }
    private func updateLinks() {
        let ls = parsedLinks
        linkInfo.stringValue = ls.isEmpty ? "可以不填。贴了链接，小猫解题时会去读链接里的内容。"
            : "识别到：" + ls.map { "🔗 " + $0.platform }.joined(separator: "  ")
    }

    @objc private func addFiles() {
        let p = NSOpenPanel()
        p.allowedContentTypes = SquareFile.allowedTypes
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        guard p.runModal() == .OK else { return }
        var skipped: [String] = []
        for u in p.urls {
            guard files.count < SquareFile.maxCount else { skipped.append("\(u.lastPathComponent)（最多 5 个）"); continue }
            guard SquareFile.kind(of: u.lastPathComponent) != nil else { skipped.append("\(u.lastPathComponent)（格式不支持）"); continue }
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let isImage = SquareFile.kind(of: u.lastPathComponent) == "image"
            if !isImage && size > SquareFile.maxBytes { skipped.append("\(u.lastPathComponent)（超过 10 MB）"); continue }
            if !files.contains(u) { files.append(u) }
        }
        updateFiles()
        if files.contains(where: { SquareFile.kind(of: $0.lastPathComponent) == "image" }) && kind.titleOfSelectedItem == "其他" {
            kind.selectItem(withTitle: "看图"); kindChanged()
        }
        if !skipped.isEmpty {
            let a = NSAlert()
            a.messageText = "有文件没加上"
            a.informativeText = skipped.joined(separator: "\n")
            a.runModal()
        }
    }
    @objc private func clearFiles() { files = []; updateFiles() }
    private func updateFiles() {
        fileInfo.stringValue = files.isEmpty ? "还没有附件"
            : files.map { u in
                let k = SquareFile.kind(of: u.lastPathComponent) ?? "text"
                return (["image": "🖼", "code": "💻", "pdf": "📕", "doc": "📄"][k] ?? "📝") + " " + u.lastPathComponent
            }.joined(separator: "   ")
    }

    // MARK: actions

    @objc private func doCancel() { win.close() }

    @objc private func doPost() {
        let tt = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let bb = body.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = Int(reward.stringValue.filter(\.isNumber)) ?? 0
        func warn(_ s: String) { let a = NSAlert(); a.messageText = s; a.runModal() }
        guard tt.count >= 2 else { warn("标题至少写两个字哦。"); return }
        guard tt.count <= 80 else { warn("标题最多 80 字，细节写到说明里。"); return }
        guard bb.count <= 8000 else { warn("说明最多 8000 字。长代码可以作为文件附上。"); return }
        guard n >= 1 && n <= 1000 else { warn("奖励要在 1 到 1000 条小鱼干之间。"); return }
        let template = SquareTemplates.all.contains { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) == bb && !bb.isEmpty }
        if template { warn("说明还是模版原文，按提示填一下再发吧。"); return }
        let k = kind.titleOfSelectedItem ?? "其他"
        win.close()
        onPost?(tt, bb, k, n, parsedLinks, files)
    }
}

// MARK: - 设置 → 猫帮圈

final class SquarePane: NSObject {
    private let balance = SK.WrapLabel("", size: 13, secondary: false)
    private let caps = SK.WrapLabel("", size: 12)
    private let auto = NSSwitch()
    private let notify = NSSwitch()
    private var kindBoxes: [NSButton] = []

    func build(into p: SK.Page) {
        p.hint("把问题发到猫帮圈，自己定小鱼干奖励；也可以让小猫用你的模型帮别人解题，赚小鱼干。需要登录账号，新账号送 100 条。")

        p.header("我的小猫")
        let g0 = SK.Group()
        g0.add(SK.info(balance))
        g0.add(SK.info(caps))
        p.add(g0)
        p.add(SK.buttons([SK.button("打开猫帮圈", self, #selector(openSquare)),
                          SK.button("发布任务", self, #selector(postSquare)),
                          SK.button("帮我挑一个", self, #selector(findOne))]))

        p.header("自动找任务")
        auto.target = self
        auto.action = #selector(autoToggled(_:))
        notify.target = self
        notify.action = #selector(notifyToggled(_:))
        let g = SK.Group()
        g.add(SK.toggle("猫帮圈有新任务时提醒我", notify, sub: "大约每 10 分钟看一次，有你的小猫能做的新任务就弹出来问你"))
        g.add(SK.toggle("小猫自己去猫帮圈找适合它的任务", auto, sub: "大约每 15 分钟看一次，找到会先问你，接不接你说了算"))
        p.add(g)

        p.header("我想接的类型（都不勾 = 全部）")
        let kinds = NSStackView()
        kinds.orientation = .horizontal
        kinds.spacing = 10
        for k in TaskSquare.kinds {
            let b = NSButton(checkboxWithTitle: k, target: self, action: #selector(kindToggled(_:)))
            kindBoxes.append(b)
            kinds.addArrangedSubview(b)
        }
        p.add(kinds, full: false)

        p.header("怎么用")
        p.hint("""
        • 发任务：点「发布任务」，或在聊天里说「发任务：……」。可以选模版、贴链接（X 推文、GitHub 等）、插入代码块、附代码 / PDF / Word / 图片文件。
        • 接任务：小猫只挑你的模型做得了的（要看图的任务需要会看图的模型），会读链接和附件，用你自己的模型写答案；你看过、改过才会交，绝不自动提交。
        • 猫帮圈上大家都能看到任务内容和附件，别放隐私（文字和代码里的密钥、密码会自动打码）。
        """)
        refresh()
        TaskSquare.shared.observe { [weak self] in self?.refresh() }
    }

    func refresh() {
        let sq = TaskSquare.shared
        balance.stringValue = sq.ready ? "🐟 小鱼干：\(sq.balance.map(String.init) ?? "…")"
            : (Account.shared.configured ? "🐟 先登录账号（设置 → 账号）才能用猫帮圈" : "🐟 账号服务还在开通中")
        caps.stringValue = TaskSquare.capsLine
        auto.state = Prefs.squareAuto ? .on : .off
        notify.state = Prefs.squareNotify ? .on : .off
        let chosen = Set(Prefs.squareKinds)
        for b in kindBoxes { b.state = chosen.contains(b.title) ? .on : .off }
        if sq.ready && sq.balance == nil { sq.refreshBalance() }
    }

    @objc private func autoToggled(_ s: NSSwitch) { Prefs.squareAuto = s.state == .on }
    @objc private func notifyToggled(_ s: NSSwitch) { Prefs.squareNotify = s.state == .on }
    @objc private func kindToggled(_ b: NSButton) {
        var k = Prefs.squareKinds.filter { $0 != b.title }
        if b.state == .on { k.append(b.title) }
        Prefs.squareKinds = k
    }
    @objc private func openSquare() { TaskSquare.shared.showWindow() }
    @objc private func postSquare() { TaskSquare.shared.postDialog() }
    @objc private func findOne() { TaskSquare.shared.autoMatch(manual: true) }
}
