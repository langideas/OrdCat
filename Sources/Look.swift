import AppKit
import ObjectiveC

// MARK: - Appearance (light / dark), whole app

enum Theme {
    /// 0 = follow system, 1 = light, 2 = dark
    static var mode: Int {
        get { UserDefaults.standard.integer(forKey: "appearanceMode") }
        set { UserDefaults.standard.set(newValue, forKey: "appearanceMode"); apply() }
    }
    static let changed = Notification.Name("OrdCatThemeChanged")
    private static var watch: NSKeyValueObservation?

    static func apply() {
        switch mode {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }
    /// Also follow the system switching between light and dark while we run.
    static func start() {
        apply()
        watch = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
        }
    }
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    /// Text colour inside the cat's bubble.
    static var fg: NSColor { isDark ? .white : NSColor(calibratedWhite: 0.08, alpha: 1) }
    static var bubbleAppearance: NSAppearance? { NSAppearance(named: isDark ? .vibrantDark : .vibrantLight) }
}

// MARK: - Interface language (中文 / English), whole app

enum L10n {
    static let changed = Notification.Name("OrdCatLanguageChanged")
    static var english: Bool {
        get { UserDefaults.standard.string(forKey: "uiLanguage") == "en" }
        set { UserDefaults.standard.set(newValue ? "en" : "zh", forKey: "uiLanguage") }
    }

    static let en: [String: String] = [
        "外观与语言": "Appearance & language",
        "切换语言后重启 OrdCat 生效。": "Language changes take effect after restarting OrdCat.",
        "说话": "Talking",
        "开启语音对话": "Voice chat",
        "按快捷键或 🎤 和小猫说话": "Talk to the cat with the hotkey or 🎤",
        "打开对话时分享当前页面": "Share the current page when a chat opens",
        "气泡里点 ✕ 就不分享": "Click ✕ in the bubble to stop sharing",
        "陪伴": "Companion",
        "兼容模式": "Compatibility mode",
        "读不到选中内容时，自动复制再还原剪贴板": "If the selection can't be read, copy it and restore the clipboard",
        "权限": "Permissions",
        "需要时看图片和视频画面": "Look at images and video when needed",
        "只在你提问时截这个窗口": "Only captures this window when you ask",
        "看视频时顺便听 6 秒声音": "Listen to 6 seconds of audio for videos",
        "用「听写」转成文字": "Transcribed with Dictation",
        "开启桌面感知": "Desktop perception",
        "回答时参考你屏幕上的内容": "Answers use what's on your screen",
        "读不到文字时用 OCR 识别": "Use OCR when text can't be read",
        "需要「屏幕录制」权限": "Needs Screen Recording permission",
        "提问时附带当前窗口截图": "Attach a screenshot of the current window",
        "需要识图模型": "Needs a vision model",
        "云端声音": "Cloud voice",
        "更新": "Updates",
        "签名与授权": "Signing & permissions",
        "更新内容": "What's new",
        "回复建议：几条、语气、长度、语言、关于我": "Reply ideas: count, tone, length, language, about me",
        "信号": "Signals",
        "刷推记忆": "X memory",
        "有这些情况时弹窗提醒我": "Pop up when",
        "头像和名称会显示在聊天窗口左下角。": "Your avatar and name appear at the bottom left of the chat window.",
        "方式": "Method",
        "个人资料": "Profile",
        "账号与登录": "Account & sign-in",
        "订阅与付款": "Subscription & payment",
        "数据管理": "Data",
        "每一步都先问我（推荐）": "Ask me before every step (recommended)",
        "语速": "Speed",
        "音调": "Pitch",
        "快捷键": "Hotkey",
        "记忆保留": "Keep memory",
        "排除应用": "Excluded apps",
        "关键词": "Keywords",
        "特别关注": "Watch accounts",
        "提醒频率": "Alert frequency",
        " · 设置": " · Settings",
        "名称": "Name",
        "用户名": "Username",
        "6 位验证码": "6-digit code",
        "Bundle ID，用逗号分隔，例如 com.tencent.xinWeChat": "Bundle IDs, comma separated, e.g. com.tencent.xinWeChat",
        "Groq Qwen3.8 看图（可用同一个 Groq Key）": "Groq Qwen3.8 vision (same Groq key works)",
        "Groq Whisper Turbo（可用同一个 Groq Key）": "Groq Whisper Turbo (same Groq key works)",
        "Ollama 本地 qwen2.5vl（离线）": "Ollama local qwen2.5vl (offline)",
        "Ollama（本地离线）": "Ollama (local, offline)",
        "OrdCat 设置 · v": "OrdCat Settings · v",
        "\n\n提示：先切到浏览器打开 x.com，再回到这里点「检查刷推」。": "\n\nTip: switch to the browser and open x.com first, then come back and click “Check X reading”.",
        "· 项目说明": "· Project notes",
        "↗ 完整对话": "↗ Full chat",
        "🐟 广场": "🐟 Square",
        "⌃ Control + ⌥ Option + 空格": "⌃ Control + ⌥ Option + Space",
        "⌘ Command + ⇧ Shift + 空格": "⌘ Command + ⇧ Shift + Space",
        "⌥ Option + 空格": "⌥ Option + Space",
        "▶︎ 系统声音试听中": "▶︎ Previewing system voice",
        "▶︎ 试听": "▶︎ Preview",
        "⚠️ 导出失败": "⚠️ Export failed",
        "⚠️ 检查失败：": "⚠️ Check failed:",
        "⚠️ 还没授权「辅助功能」，选中文字提示暂时用不了": "⚠️ Accessibility not allowed yet, selection hints won't work",
        "⚪️ 未分享当前页面 · 点这里分享": "⚪️ Not sharing this page · click to share",
        "✅ 头像已更新": "✅ Avatar updated",
        "✅ 已保存": "✅ Saved",
        "✅ 已导出到：": "✅ Exported to:",
        "✅ 已经是最新版本（线上最新 v": "✅ Up to date (latest online v",
        "✅ 已获得辅助功能权限": "✅ Accessibility permission granted",
        "✅ 登录成功": "✅ Signed in",
        "✅ 看得到：": "✅ Can see:",
        "✅ 订阅已刷新": "✅ Subscription refreshed",
        "✅ 订阅已开启": "✅ Subscription active",
        "✅ 连接成功：": "✅ Connected:",
        "✏️  发起新对话": "✏️  New chat",
        "「帮我操作电脑」关掉啦。": "“Operate my Mac” is off now.",
        "「帮我操作电脑」开啦 🤖 跟我说「帮我……」试试，每一步我都会先问你。": "“Operate my Mac” is on 🤖 Try saying “Help me…”; I'll ask before every step.",
        "「陪你刷推」关掉啦，我不看 X 了。": "“X Buddy” is off, I won't look at X anymore.",
        "「陪你刷推」开啦 🐾 去 x.com 刷一刷，我在旁边看着。": "“X Buddy” is on 🐾 Go browse x.com, I'm right here.",
        "「陪你刷推」等技能在 设置 → 技能 里开关。": "Skills like “X Buddy” are switched in Settings → Skills.",
        "中文": "中文",
        "久坐 / 熬夜温柔提醒": "Gentle reminders for long sitting / late nights",
        "之前的聊天": "Earlier chats",
        "云端声音的 API Key（只存在本机钥匙串）": "Cloud voice API key (kept only in this Mac's keychain)",
        "云端声音需要对应服务的 API Key；失败时会自动改用系统声音。": "Cloud voices need that service's API key; falls back to the system voice on failure.",
        "云端服务": "Cloud service",
        "云端自然声音（更像真人）": "Natural cloud voice (more human)",
        "付款页面还在准备中": "Payment page isn't ready yet",
        "付款（即将开放）": "Payment (coming soon)",
        "以后": "Later",
        "任何 OpenAI 兼容接口都能用。API Key 只保存在你 Mac 的钥匙串里。聊天模型只懂文字也没关系：图片会交给「看图」模型，声音交给「听写」。": "Any OpenAI-compatible API works. The API key is kept only in your Mac's keychain. Text-only chat models are fine: images go to the Vision model, audio to Dictation.",
        "你在刷 X 呀～要我陪你刷吗？我会记住你关注和互动过的人，帮你讲重点、筛评论、想回复（不替你发）。全部只存在这台 Mac 上，私信不看。": "Browsing X~ want me to keep you company? I'll remember people you follow and interact with, sum up key points, filter replies and suggest replies (never send for you). Everything stays on this Mac; DMs are never read.",
        "例如：@elonmusk, @sama": "e.g. @elonmusk, @sama",
        "例如：AI, 融资, 空投, OpenAI（逗号分隔）": "e.g. AI, funding, airdrop, OpenAI (comma separated)",
        "保存": "Save",
        "修复授权": "Repair permissions",
        "值得看": "Worth reading",
        "先不用": "Not now",
        "先填验证码": "Enter the code first",
        "先登录账号再付款？": "Sign in before paying?",
        "免费试用": "Free trial",
        "全部分类": "All categories",
        "关于": "About",
        "关闭窗口": "Close window",
        "兼容模式：读不到选中内容时，自动复制再还原剪贴板": "Compatibility mode: if selection can't be read, copy it and restore the clipboard",
        "写下这个项目的背景、要求或偏好。在这个项目里的每个对话，小猫都会先看这段说明。": "Write this project's background, requirements or preferences. The cat reads this first in every chat of the project.",
        "几条、语气、长度、语言、关于我": "Count, tone, length, language, about me",
        "分类 ▾": "Category ▾",
        "划选文字": "Selected text",
        "创作": "Creative",
        "删除": "Delete",
        "删除后无法恢复。": "This can't be undone.",
        "删除对话": "Delete chat",
        "删除正在看的这个对话（全部清空在左栏右键或设置里）": "Delete the chat you're viewing (clear all via right-click in the sidebar or Settings)",
        "去「声音」设置": "Go to Voice settings",
        "去付款": "Pay",
        "去修复": "Fix it",
        "发布页": "Releases",
        "发送验证码": "Send code",
        "取消": "Cancel",
        "只删项目": "Delete project only",
        "可拖动窗口边缘调大小，内容放不下时可上下左右滚动": "Drag the window edges to resize",
        "和 OrdCat 聊天 🐈‍⬛": "Chat with OrdCat 🐈‍⬛",
        "和小猫的对话": "Chat with the cat",
        "和小猫聊天": "Chat with the cat",
        "和小猫说点什么…（回车发送）": "Say something to the cat… (Enter to send)",
        "和聊天同一家可留空": "Leave empty if same as chat",
        "喵～想聊点什么？": "Meow~ what shall we talk about?",
        "喵～我能看到你正在看的页面，想问点什么？": "Meow~ I can see the page you're on. What would you like to ask?",
        "回复建议设置": "Reply idea settings",
        "回复建议设置…": "Reply idea settings…",
        "回复设置": "Reply settings",
        "回答里指到的位置，在屏幕上高亮出来": "Highlight on screen the spots the answer points to",
        "在 X 上": "on X",
        "基础功能免费，技能按订阅开启。打开开关就生效，点一行看它的设置。": "Basics are free; skills come with a subscription. Toggle to enable, click a row for its settings.",
        "声音": "Voice",
        "声音来源": "Voice source",
        "复制文字时提示": "Hint when I copy text",
        "复制结果": "Copy result",
        "外观": "Appearance",
        "好～从现在起我陪你刷。命中信号、营销号、水评我会提醒你，点回复时给你回复建议。想改提醒：右键我 → 设置 → 技能。": "OK~ from now on I'll browse with you. I'll alert you to signals, spam and filler replies, and suggest replies when you reply. To change alerts: right-click me → Settings → Skills.",
        "好～我们聊你现在看的这个页面。": "OK~ let's talk about the page you're looking at.",
        "字母、数字或下划线": "Letters, digits or underscores",
        "学习": "Study",
        "小猫": "Cat",
        "小猫会忘掉在 X 上记住的人、互动和兴趣，不能恢复。": "The cat will forget the people, interactions and interests it remembered on X. This can't be undone.",
        "小猫会读这个页面上的文字来回答你（密码框不会读，隐私信息会先打码）": "The cat reads this page's text to answer you (password fields are never read, private info is masked)",
        "小猫怎么称呼你": "What should the cat call you",
        "小猫说话的声音（系统声音或云端自然声音、语速、音调）在「声音」标签里设置。": "The cat's voice (system or natural cloud voice, speed, pitch) is set in the Voice tab.",
        "工作": "Work",
        "已经连续看屏幕 2 小时啦，喝口水、伸个懒腰歇一歇吧 🍵": "You've been looking at the screen for 2 hours. Drink some water and stretch 🍵",
        "已退出登录": "Signed out",
        "帧 / 丢弃重复": "frames / dropped duplicates",
        "帮我操作电脑": "Operate my Mac",
        "开一个新对话（⌘N）": "New chat (⌘N)",
        "开启桌面感知（回答时参考你屏幕上的内容）": "Turn on desktop perception (answers use what's on your screen)",
        "开启语音对话（按快捷键或 🎤 和小猫说话）": "Turn on voice chat (hotkey or 🎤 to talk to the cat)",
        "当前会发给模型的上下文": "Context that will be sent to the model",
        "想在你选中文字时竖起耳朵，需要先授权「辅助功能」哦～": "To perk up when you select text, please allow “Accessibility” first~",
        "想更自然：系统设置 → 辅助功能 → 朗读内容 → 系统声音 → 管理声音，下载带「高级」或「增强」的中文声音（如 Lilian、Tingting 增强版），装好后在上面选。": "For a more natural voice: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices, download a Premium or Enhanced voice, then pick it above.",
        "感知与记忆": "Memory",
        "手机号不对": "Invalid phone number",
        "手机号，例如 0912345678": "Phone number, e.g. 0912345678",
        "打开对话时分享当前页面（气泡里点 ✕ 就不分享）": "Share the current page when a chat opens (click ✕ in the bubble to stop)",
        "打开技能": "Turn on skill",
        "打开独立聊天窗口（聊天记录、发送图片和文件）": "Open the chat window (history, send images and files)",
        "打开聊天窗口": "Open chat window",
        "打开设置": "Open Settings",
        "技能": "Skills",
        "按分类筛选": "Filter by category",
        "授权屏幕录制": "Allow Screen Recording",
        "授权成功啦～小猫重启一下马上生效 🐾": "Permission granted~ the cat will restart to apply it 🐾",
        "授权辅助功能": "Allow Accessibility",
        "接口地址": "API URL",
        "提问时附带当前窗口截图（需要识图模型）": "Attach a screenshot of the current window when asking (needs a vision model)",
        "搜索聊天记录": "Search chats",
        "数据文件夹": "Data folder",
        "新对话": "New chat",
        "新话题开始啦，之前的聊天这次不带上。": "New topic started; earlier chats aren't included.",
        "新项目": "New project",
        "显示 / 隐藏小猫": "Show / hide the cat",
        "显示/隐藏左侧的对话和项目栏": "Show/hide the chats and projects sidebar",
        "显示全部对话": "Show all chats",
        "暂停朗读": "Pause reading",
        "更改分类": "Change category",
        "有新版本 v": "New version v",
        "服务商": "Provider",
        "本地 Ollama 可留空": "Leave empty for local Ollama",
        "本机保存的屏幕卡片、划选记录和实体都会删除，无法恢复。": "Screen cards, selections and entities saved on this Mac will be deleted. This can't be undone.",
        "本机苹果语音识别（离线、免费）": "On-device Apple speech recognition (offline, free)",
        "条帖子。点我：TA 是谁 · 重点+核实 · 筛评论 · 想回复": " posts. Click me: Who's this · Key points + fact-check · Filter replies · Reply ideas",
        "查看当前上下文": "View current context",
        "桌面感知": "Desktop perception",
        "检查刷推": "Check X reading",
        "检查更新": "Check for updates",
        "模型": "Model",
        "模型名称": "Model name",
        "模型（BYOM）": "Model (BYOM)",
        "正在保存…": "Saving…",
        "正在刷新订阅…": "Refreshing subscription…",
        "正在发送…": "Sending…",
        "正在打包…": "Packing…",
        "正在检查…": "Checking…",
        "正在检查签名…": "Checking signature…",
        "正在注销…": "Deleting account…",
        "正在测试…": "Testing…",
        "正在用这台 Mac 的签名重新签…": "Re-signing with this Mac's signature…",
        "正在登录…": "Signing in…",
        "正在请求云端声音…": "Requesting cloud voice…",
        "正在连接…": "Connecting…",
        "比如：我做量化交易，用第一人称，别用 emoji，多给干货": "e.g. I trade quant, first person, no emoji, more substance",
        "没听清呢，再说一次？🐾": "Didn't catch that, say it again? 🐾",
        "没能激活": "Couldn't activate",
        "浅色": "Light",
        "测试听写": "Test dictation",
        "测试看图": "Test vision",
        "测试连接": "Test connection",
        "深色": "Dark",
        "清空": "Clear",
        "清空刷推记忆": "Clear X memory",
        "清空刷推记忆？": "Clear X memory?",
        "清空后无法恢复，小猫也会忘掉之前聊过的内容。": "This can't be undone; the cat will forget what you talked about.",
        "清空所有桌面记忆？": "Clear all desktop memory?",
        "清空所有聊天记录？": "Clear all chat history?",
        "清空聊天记录": "Clear chat history",
        "清空记忆": "Clear memory",
        "激活订阅码": "Activate license key",
        "点击填进 X 的回复框（只填不发）": "Click to fill X's reply box (fills only, never sends)",
        "点击复制": "Click to copy",
        "点回复框或「想回复」时，小猫按这里的要求给你想回复。": "When you click a reply box or “Reply ideas”, the cat follows these settings.",
        "现在是公测期，技能可以免费用。": "Public beta: skills are free for now.",
        "现在没有可以分享的页面，直接聊也可以～": "No page to share right now, we can just chat~",
        "理财": "Finance",
        "生活": "Life",
        "用在两个地方：你对小猫说话（⌃⌥空格 / 🎤），和看视频时听声音。本机识别完全离线；云端 Whisper 更准，会把录音发给你选的服务商。": "Used in two places: when you talk to the cat (⌃⌥Space / 🎤) and when listening to video audio. On-device is fully offline; cloud Whisper is more accurate and sends the recording to your chosen provider.",
        "用语音读出小猫的回复": "Read the cat's replies aloud",
        "登录 / 注册": "Sign in / Sign up",
        "登录后订阅会绑定到你的账号，换电脑也能用。也可以不登录，付款后用邮件里的订阅码激活。": "After signing in, your subscription is tied to your account and works on any Mac. Or skip signing in and activate with the key from your email.",
        "看图模型名称": "Vision model name",
        "看视频时顺便听 6 秒声音（用「听写」转成文字）": "Listen to 6 seconds of audio when watching video (via Dictation)",
        "硅基流动 CosyVoice2（中文最自然）": "SiliconFlow CosyVoice2 (most natural Chinese)",
        "硅基流动 Qwen2.5-VL": "SiliconFlow Qwen2.5-VL",
        "硅基流动 SenseVoice（中文好）": "SiliconFlow SenseVoice (good for Chinese)",
        "移出项目": "Remove from project",
        "移到项目": "Move to project",
        "移除附件": "Remove attachment",
        "立即更新": "Update now",
        "立即重启": "Restart now",
        "粘贴订阅码": "Paste license key",
        "系统声音": "System voice",
        "系统声音（离线、免费）": "System voice (offline, free)",
        "继续付款": "Continue to payment",
        "继续朗读": "Resume reading",
        "编程": "Coding",
        "网页": "Web",
        "聊天记录、记忆和刷推记忆都只存在这台 Mac 上。导出会打包到「下载」文件夹；注销会删除云端账号、头像和订阅绑定（已付的订阅请先在「管理付款方式」里取消）。": "Chats, memory and X memory stay on this Mac only. Export packs them into Downloads; deleting your account removes the cloud account, avatar and subscription link (cancel paid subscriptions in “Manage payment” first).",
        "聊天软件（微信、QQ…）按位置识别谁说了什么": "Chat apps (WeChat, QQ…): tell who said what by position",
        "自动检查更新（每 6 小时）": "Check for updates automatically (every 6 hours)",
        "自动（聊天模型会看图就用它，不会就用同服务商的看图模型）": "Auto (use the chat model if it can see images, otherwise the same provider's vision model)",
        "自动（选最自然的中文声音）": "Auto (most natural voice)",
        "自定义（OpenAI 兼容 /audio/speech）": "Custom (OpenAI-compatible /audio/speech)",
        "自定义（OpenAI 兼容 /audio/transcriptions）": "Custom (OpenAI-compatible /audio/transcriptions)",
        "自定义（OpenAI 兼容）": "Custom (OpenAI-compatible)",
        "订阅、试用或输入订阅码": "Subscribe, start a trial or enter a key",
        "订阅绑定在这个账号上，换一台 Mac 登录同一个账号就能继续用。": "Your subscription is tied to this account; sign in on another Mac to keep using it.",
        "认人、信号提醒、标出营销号和水评、点回复时给建议": "Recognize people, signal alerts, flag spam and filler replies, reply ideas",
        "记住啦 ❤️": "Got it ❤️",
        "记忆": "Memory",
        "设置": "Settings",
        "设置…": "Settings…",
        "语言": "Language",
        "语音对话": "Voice chat",
        "语音对话还没开哦～右键点我 → 小猫 → 开启语音对话。": "Voice chat isn't on~ right-click me → Cat → Turn on voice chat.",
        "语音识别模型名称": "Speech recognition model name",
        "说「帮我……」，小猫一步步替你点、输入、打开应用": "Say “Help me…” and the cat clicks, types and opens apps for you step by step",
        "说点什么…（回车发送，⌥+回车换行）": "Say something… (Enter to send, ⌥+Enter for new line)",
        "读不到文字时用 OCR 识别（需要「屏幕录制」权限）": "Use OCR when text can't be read (needs Screen Recording permission)",
        "账号": "Account",
        "账号与设置": "Account & settings",
        "跟随系统": "System",
        "还没有之前的话题": "No earlier topics yet",
        "还没检查过更新": "Haven't checked for updates yet",
        "这一版没能用本机固定签名，所以每次更新都要重新授权。可以在 设置 → 关于 点「修复授权」再试一次。": "This build couldn't use this Mac's fixed signature, so each update needs permissions again. Try “Repair permissions” in Settings → About.",
        "这个页面": "this page",
        "这次对话不分享这个页面": "Don't share this page in this chat",
        "这页": "this page",
        "连对话一起删": "Delete chats too",
        "退出": "Quit",
        "退出 OrdCat": "Quit OrdCat",
        "退出登录": "Sign out",
        "选中文字提示需要「辅助功能」权限：系统设置 → 隐私与安全性 → 辅助功能，打开 OrdCat。从 v0.2.8 起小猫用这台 Mac 自己的签名，授权一次以后更新不会再丢。如果开关是开着却没用，先用「−」删掉旧的 OrdCat 再重新添加。": "Selection hints need Accessibility: System Settings → Privacy & Security → Accessibility, turn on OrdCat. Since v0.2.8 the cat uses this Mac's own signature, so one grant survives updates. If it's on but not working, remove the old OrdCat with “−” and add it again.",
        "选中文字时竖起耳朵提示": "Perk up ears when I select text",
        "邮箱 / 手机号注册即将开放。现在名称和头像先保存在本机，开通后登录会自动同步。": "Email / phone sign-up coming soon. Name and avatar are saved on this Mac for now and will sync once you sign in.",
        "邮箱格式不对": "Invalid email address",
        "重启后完全生效": "Fully applies after restart",
        "闲聊": "Chit-chat",
        "陪你刷推 · 检查结果": "X Buddy · check result",
        "陪你刷推（X）": "X Buddy (X)",
        "需要时看图片和视频画面（只在你提问时截这个窗口）": "Look at images and video when needed (captures this window only when you ask)",
        "项目": "Projects",
        "项目里没有对话。": "No chats in this project.",
        "默认只参考当前页面；想接着聊以前的内容，在这里选": "Only the current page by default; pick here to continue an earlier topic",
        "＋  新建项目": "＋  New project",
        "＋ 新建项目并移入…": "＋ New project and move…",
        "，点「立即更新」，小猫会自己换新并重启。": ", click “Update now” and the cat will update and restart itself.",
        "🆕 新话题（不带之前的聊天）": "🆕 New topic (without earlier chats)",
        "🎉 有新版本 v": "🎉 New version v",
        "🎙️ 听写": "🎙️ Dictation",
        "🎙️ 我在听…（说完停一下就好，再按一次快捷键结束）": "🎙️ Listening… (pause when done, or press the hotkey again)",
        "🎬 我看几眼画面、听几秒声音…": "🎬 Watching a few frames and listening a few seconds…",
        "👀 桌面感知打开啦，问我问题时我会先看看你的屏幕。": "👀 Desktop perception is on; I'll look at your screen when you ask.",
        "💬 在聊之前的「": "💬 Continuing earlier chat",
        "💬 聊天": "💬 Chat",
        "📄 当前页面（默认）": "📄 Current page (default)",
        "🔊 朗读": "🔊 Read aloud",
        "🖼️ 看图 / 视频": "🖼️ Images / Video",
        "🖼️ 看图模型正在看图…": "🖼️ Vision model is looking…",
        "🗂 之前的话题": "🗂 Earlier topics",
        "🙈 桌面感知已关闭，我不会再看你的屏幕。": "🙈 Desktop perception is off, I won't look at your screen.",
        // 信号站 / 小猫等级 / 喵友 / 用户页 (v0.2.41)
        "用户": "Profile",
        "更换头像": "Change avatar",
        "信号站": "Signal Station",
        "📶 信号站": "📶 Signal Station",
        "📶 信号": "📶 Signal",
        "打开信号站": "Open Signal Station",
        "一只小猫": "A cat",
        "所有人可看": "Everyone",
        "普通情报": "Standard intel",
        "优质情报": "Good intel",
        "稀有情报": "Rare intel",
        "绝密情报": "Top-secret intel",
        "陪你刷推": "X Buddy",
        "小猫等级": "Cat level",
        "喵友": "Followers",
        "订阅会员": "Subscriber",
        "查看信号": "View signal",
        "不再提醒": "Don't remind me",
        "信号站服务器还没开通好（管理员需要在 Supabase 运行 supabase/signal.sql）": "Signal Station isn't set up on the server yet (the admin needs to run supabase/signal.sql in Supabase)",
        "还没登录": "Not signed in",
        "信号发出去啦 📶 满足条件的小猫会收到提醒。": "Signal sent 📶 Cats who meet your conditions will get a heads-up.",
        "信号站要先登录账号。": "Sign in to use Signal Station.",
        "账号服务还在开通中，暂时用不了信号站。": "Accounts aren't open yet, so Signal Station isn't available for now.",
        "去登录": "Sign in",
        "信号流": "Feed",
        "我发出的": "Sent by me",
        "分享当前桌面": "Share my screen",
        "小猫读一下你正在看的窗口，先给你审、改，你点「发出信号」才会发": "The cat reads the window you're looking at. You review and edit it first; nothing goes out until you click “Send signal”.",
        "刷新": "Refresh",
        "满足条件的信号能看全文；不满足的只显示标题和还差什么。": "You can read signals whose conditions you meet; for the rest you'll see the title and what you're missing.",
        "正在加载…": "Loading…",
        "没连上：": "Couldn't connect: ",
        "信号站还没有信号，分享一条试试？": "No signals yet. Why not share the first one?",
        "你还没发过信号。": "You haven't sent any signals yet.",
        "来自": "from",
        "谁能看：": "Who can read: ",
        "还差：": "Still needed: ",
        "查看": "View",
        "看看条件": "See conditions",
        "已是喵友": "Following",
        "加喵友": "Follow",
        "删除后别人就看不到这条信号了。": "Once deleted, nobody else can see this signal.",
        "复制内容": "Copy",
        "关闭": "Close",
        "点一下取消喵友": "Click to unfollow",
        "仅订阅会员": "Subscribers only",
        "发出信号": "Send signal",
        "小猫帮我提炼": "Let the cat boil it down",
        "📶 发信号 · 先审再发": "📶 New signal · review before sending",
        "这些内容来自你的屏幕。小猫已自动给密码、Key、卡号打码，但请你再看一遍，删掉不想公开的部分。只有你点「发出信号」才会发出去。": "This comes from your screen. The cat has already masked passwords, keys and card numbers, but please read it over and remove anything you don't want to share. Nothing is sent until you click “Send signal”.",
        "来源": "Source",
        "重新读取桌面": "Read screen again",
        "标题": "Title",
        "一句话说清这条信号（2–80 字）": "Sum up the signal in one line (2–80 characters)",
        "内容": "Content",
        "用你的模型把读到的内容提炼成标题和几条要点，提炼完你还可以再改": "Uses your model to turn what was read into a title and a few key points. You can still edit it afterwards.",
        "情报等级": "Signal grade",
        "谁能看": "Who can read",
        "小猫等级至少": "Cat level at least",
        "喵友至少": "Followers at least",
        "需要技能：": "Skills needed:",
        "不满足条件的人只能看到标题和还差什么，看不到内容。「需要技能」= 对方的账号订阅了这个技能。": "People who don't meet the conditions only see the title and what they're missing, never the content. “Skills needed” means their account subscribes to that skill.",
        "⌘↩ 发出信号": "⌘↩ Send signal",
        "读不到桌面内容": "Can't read the screen",
        "正在读取你正在看的窗口…": "Reading the window you're looking at…",
        "读好了，看一遍再发；也可以让小猫帮你提炼。": "Done. Read it over before sending, or let the cat boil it down.",
        "（没读到内容）": "(nothing read)",
        "没读到这个窗口的文字：可能是没给「辅助功能」权限，或这个应用被排除了。可以直接自己写。": "Couldn't read any text from this window. Accessibility permission may be off, or this app is excluded. You can write it yourself.",
        "聊天里写的": "Written in chat",
        "先读取桌面或写点内容": "Read the screen or write something first",
        "还没设置聊天模型（设置 → 模型）": "No chat model set up yet (Settings → Model)",
        "小猫正在提炼…": "The cat is boiling it down…",
        "没提炼成：": "Couldn't boil it down: ",
        "提炼好了，看一遍再发。": "All done. Read it over before sending.",
        "标题至少 2 个字": "The title needs at least 2 characters",
        "内容还是空的": "The content is still empty",
        "正在发出…": "Sending…",
        "没发出去：": "Couldn't send: ",
        "把小猫在桌面上看到的有价值信息分享给别的小猫。每次都先给你审、改，你点「发出信号」才会发。你可以设谁能看：小猫等级、喵友数、订阅会员、拥有的技能。": "Share useful things your cat spots on your screen with other cats. You always review and edit first, and nothing goes out until you click “Send signal”. You decide who can read it: cat level, followers, subscribers, or skills they own.",
        "提醒": "Notifications",
        "有我能看的新信号时提醒我": "Notify me about new signals I can read",
        "大约每 10 分钟看一次，每条信号只提醒一次": "Checks about every 10 minutes; each signal is announced once",
        "怎么用": "How it works",
        "• 分享：点「分享当前桌面」，或在聊天里说「发信号：……」/「/信号」。小猫读一下你正在看的窗口，打开发信号窗口让你审、改；可以让小猫帮你提炼。\n• 情报等级：普通 / 优质 / 稀有 / 绝密，告诉大家这条有多重要。\n• 谁能看：不满足条件的人只看到标题和还差什么，内容不会发到他们那里。\n• 小猫等级：每天和小猫互动一次算一个活跃天，Lv1 要 5 天，越往后越多，没有上限。等级显示在「用户」页。\n• 喵友：在信号作者那一行点「加喵友」；喵友数 = 加你为喵友的人数。": "• Share: click “Share my screen”, or say “发信号：…” / “/信号” in chat. The cat reads the window you're looking at and opens the signal window so you can review and edit it first; it can also boil it down for you.\n• Signal grade: Standard / Good / Rare / Top secret — how important it is.\n• Who can read: people who don't meet the conditions only see the title and what they're missing; the content never reaches them.\n• Cat level: each day you spend a moment with your cat counts as one active day. Lv1 takes 5 days, each level takes a little longer, and there's no cap. Your level shows on the Profile page.\n• Followers: click “Follow” on a signal's author row; your follower count is how many people follow you.",
        "📶 已登录，可以分享和接收信号": "📶 Signed in, ready to share and receive signals",
        "📶 先登录账号（设置 → 用户）才能用信号站": "📶 Sign in first (Settings → Profile) to use Signal Station",
        "📶 账号服务还在开通中": "📶 Accounts aren't open yet",
        "还没点亮": "Not lit yet",
        "猫冠": "Crown",
        "猫眼": "Cat eyes",
        "猫瞳": "Pupil",
        "星芒": "Sparkle",
    ]
    /// Longer pieces first so whole phrases win over the words inside them.
    private static let pieces: [String] = en.keys.filter { cjkCount($0) >= 2 }.sorted { $0.count > $1.count }

    static func cjkCount(_ s: String) -> Int {
        s.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
    }
    static func hasCJK(_ s: String) -> Bool { cjkCount(s) > 0 }

    /// Chinese UI text → English when English is on. Non-Chinese text is left alone.
    static func t(_ s: String) -> String {
        guard english, hasCJK(s) else { return s }
        if let x = en[s] { return x }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let x = en[trimmed] { return x }
        guard s.count <= 400 else { return s }
        var out = s
        for k in pieces where out.contains(k) {
            out = out.replacingOccurrences(of: k, with: en[k]!)
            if !hasCJK(out) { return out }
        }
        // Only partly known (e.g. a chat title you wrote): keep the original rather than mix languages.
        return s
    }

    // MARK: install: translate controls as they are created, titled or added
    private static var installed = false
    static func install() {
        guard english, !installed else { return }
        installed = true
        swap(NSControl.self, #selector(setter: NSControl.stringValue), #selector(NSControl.ord_setStringValue(_:)))
        swap(NSButton.self, #selector(setter: NSButton.title), #selector(NSButton.ord_setTitle(_:)))
        swap(NSWindow.self, #selector(setter: NSWindow.title), #selector(NSWindow.ord_setTitle(_:)))
        swap(NSMenuItem.self, #selector(setter: NSMenuItem.title), #selector(NSMenuItem.ord_setTitle(_:)))
        swap(NSMenu.self, #selector(NSMenu.addItem(_:)), #selector(NSMenu.ord_addItem(_:)))
        swap(NSMenu.self, #selector(NSMenu.insertItem(_:at:)), #selector(NSMenu.ord_insertItem(_:at:)))
        swap(NSSegmentedControl.self, #selector(NSSegmentedControl.setLabel(_:forSegment:)), #selector(NSSegmentedControl.ord_setLabel(_:forSegment:)))
        swap(NSView.self, #selector(NSView.addSubview(_:)), #selector(NSView.ord_addSubview(_:)))
        swap(NSAlert.self, #selector(setter: NSAlert.messageText), #selector(NSAlert.ord_setMessageText(_:)))
        swap(NSAlert.self, #selector(setter: NSAlert.informativeText), #selector(NSAlert.ord_setInformativeText(_:)))
        swap(NSAlert.self, #selector(NSAlert.addButton(withTitle:)), #selector(NSAlert.ord_addButton(withTitle:)))
        NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow, !walked.contains(ObjectIdentifier(w)) else { return }
            walked.insert(ObjectIdentifier(w))
            translate(window: w)
        }
    }
    private static var walked = Set<ObjectIdentifier>()

    private static func swap(_ cls: AnyClass, _ a: Selector, _ b: Selector) {
        guard let m1 = class_getInstanceMethod(cls, a), let m2 = class_getInstanceMethod(cls, b) else { return }
        // Only exchange on this class itself so subclasses keep working.
        if class_addMethod(cls, a, method_getImplementation(m2), method_getTypeEncoding(m2)) {
            class_replaceMethod(cls, b, method_getImplementation(m1), method_getTypeEncoding(m1))
        } else {
            method_exchangeImplementations(m1, m2)
        }
    }

    static func translate(window w: NSWindow) {
        if hasCJK(w.title) { w.title = w.title }
        if let v = w.contentView { translate(view: v) }
    }

    /// Labels, buttons, menus and placeholders only. Text you type or chat text is never touched.
    static func translate(view v: NSView) {
        guard english else { return }
        if let seg = v as? NSSegmentedControl {
            for i in 0..<seg.segmentCount { if let l = seg.label(forSegment: i), hasCJK(l) { seg.setLabel(t(l), forSegment: i) } }
            for i in 0..<seg.segmentCount { if let tip = seg.toolTip(forSegment: i), hasCJK(tip) { seg.setToolTip(t(tip), forSegment: i) } }
        } else if let pop = v as? NSPopUpButton {
            for item in pop.itemArray where hasCJK(item.title) { item.title = t(item.title) }
            pop.synchronizeTitleAndSelectedItem()
        } else if let b = v as? NSButton {
            let at = b.attributedTitle
            if hasCJK(at.string) {
                let attrs = at.length > 0 ? at.attributes(at: 0, effectiveRange: nil) : [:]
                b.attributedTitle = NSAttributedString(string: t(at.string), attributes: attrs)
            }
        } else if let f = v as? NSTextField {
            if isLabel(f), hasCJK(f.stringValue) { f.stringValue = f.stringValue }
            if let p = f.placeholderString, hasCJK(p) { f.placeholderString = t(p) }
        }
        if let tip = v.toolTip, hasCJK(tip) { v.toolTip = t(tip) }
        if let m = v.menu { translate(menu: m) }
        for s in v.subviews { translate(view: s) }
    }
    static func translate(menu m: NSMenu) {
        for item in m.items {
            if hasCJK(item.title) { item.title = item.title }
            if let sub = item.submenu { translate(menu: sub) }
        }
    }
    static func isLabel(_ f: NSTextField) -> Bool { !f.isEditable && !f.isSelectable }
}

extension NSControl {
    @objc func ord_setStringValue(_ s: String) {
        if let f = self as? NSTextField, L10n.isLabel(f) { ord_setStringValue(L10n.t(s)) } else { ord_setStringValue(s) }
    }
}
extension NSButton {
    @objc func ord_setTitle(_ s: String) { ord_setTitle(L10n.t(s)) }
}
extension NSWindow {
    @objc func ord_setTitle(_ s: String) { ord_setTitle(L10n.t(s)) }
}
extension NSMenuItem {
    @objc func ord_setTitle(_ s: String) { ord_setTitle(L10n.t(s)) }
}
extension NSMenu {
    @objc func ord_addItem(_ item: NSMenuItem) {
        if L10n.hasCJK(item.title) { item.title = L10n.t(item.title) }
        ord_addItem(item)
    }
    @objc func ord_insertItem(_ item: NSMenuItem, at i: Int) {
        if L10n.hasCJK(item.title) { item.title = L10n.t(item.title) }
        ord_insertItem(item, at: i)
    }
}
extension NSSegmentedControl {
    @objc func ord_setLabel(_ s: String, forSegment i: Int) { ord_setLabel(L10n.t(s), forSegment: i) }
}
extension NSView {
    @objc func ord_addSubview(_ v: NSView) {
        ord_addSubview(v)
        L10n.translate(view: v)
    }
}
extension NSAlert {
    @objc func ord_setMessageText(_ s: String) { ord_setMessageText(L10n.t(s)) }
    @objc func ord_setInformativeText(_ s: String) { ord_setInformativeText(L10n.t(s)) }
    @objc func ord_addButton(withTitle s: String) -> NSButton { ord_addButton(withTitle: L10n.t(s)) }
}
