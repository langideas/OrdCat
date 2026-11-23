# OrdCat v0.2.56

- 喵手设置更完整：
  - 怎么执行：每一步先问我、速度（慢/正常/快）、最多走几步（10/25/50）、操作前在要点的按钮上亮一圈琥珀色
  - 安全：不让小猫碰的应用（默认钥匙串访问、系统设置、终端，可添加或移除）、也要先问我的词；发送/付款/删除/提交和不碰密码框一直开着
  - 隐私和提醒：可以不读输入框里已有的文字；做完或停下时在 🔔 里提醒
  - 操作记录：每次操作自动存在本机，📋 操作记录 窗口可查看步骤、再做一次、删除、清空；保留 7 天 / 30 天 / 一直

**English**

- MiaoShou has fuller settings:
  - How it runs: ask before every step, speed (slow / normal / fast), max steps (10 / 25 / 50), and an amber ring on the button before it's clicked
  - Safety: apps the cat never touches (Keychain Access, System Settings and Terminal by default; add or remove any), plus your own words that always need a yes. Send, pay, delete, submit and the password-box rule stay on
  - Privacy and reminders: skip reading text already in input boxes; a 🔔 reminder when a run is done or stops
  - Activity log: every run is kept on this Mac; the 📋 Activity log window shows the steps and lets you do it again, delete or clear; keep for 7 days, 30 days or forever

# OrdCat v0.2.55

- 技能的「点亮」和「开启」分开了：点亮只表示你拥有这个技能（免费、已订阅或试用中），会发琥珀色光圈；开启中的技能右下角有绿点。
- 弹窗左侧技能栏点一下就是开启或关闭；喵传点一下直接开始（只问听哪个应用），再点一下停止。还没点亮的技能点一下打开订阅。
- 设置 → 技能 的卡片按钮改成开启/关闭开关；喵传是「开始喵传 / 停止喵传」按钮。
- 喵传字幕条调字体大小时不再闪烁乱跳：顶边和按钮位置保持不动，宽度在关掉 Aa 卡片后再跟着调整。
- 技能介绍卡片重新排版：统一宽度和边距，标题旁显示「已点亮」标签，点亮条件和开启状态分区显示，不再挤在一起。

**English**

- "Lit" and "on" are now separate: lit only means you own the skill (free, subscribed or on trial) and shows an amber glow; a skill that's on has a green dot.
- In the bubble's skill bar, one click turns a skill on or off. MiaoChuan starts right away (it only asks which app to listen to) and stops on the next click. A skill that isn't lit opens the subscribe sheet.
- In Settings → Skills the card's control is now an on/off switch; MiaoChuan has a Start / Stop button.
- Resizing the MiaoChuan subtitle font no longer flickers or jumps: the top edge and buttons stay put, and the width catches up once the Aa card closes.
- Skill cards have a cleaner layout: fixed width and margins, a "Lit" tag next to the name, and separate sections for how to light it up and whether it's on.

# OrdCat v0.2.54

- 喵传点「停止」会先问：保存记录并结束、不保存结束、或继续听。
- 保存的记录由你的模型整理：改正识别错字、合并断开的句子、分段，生成整理后的原文、完整译文和要点。整理失败的部分保留原始字幕，不会丢。
- 记录只存在这台 Mac 上。在 设置 → 技能 → 喵传「📂 喵传记录」、菜单栏小猫菜单或字幕条的 📂 打开，可以重命名、删除、重新整理。
- 下载支持 PDF、Word（.docx）、Markdown、纯文本、SRT 字幕和网页，可选「原文 + 译文」「只要译文」「只要原文」。
- 断句更稳：句号后面有新内容才算一句说完，太短的半句会等下一句一起翻译，不会在单词中间切开。

**English**

- Pressing Stop in MiaoChuan now asks first: save the record and end, end without saving, or keep listening.
- Saved records are tidied by your model: recognition mistakes fixed, broken sentences joined and paragraphs formed, giving a clean original, a full translation and key points. Any part that can't be tidied keeps its raw subtitles, so nothing is lost.
- Records stay only on this Mac. Open them from Settings → Skills → MiaoChuan "📂 MiaoChuan records", the cat's menu bar menu or the 📂 on the subtitle bar, and rename, delete or tidy them again there.
- Download as PDF, Word (.docx), Markdown, plain text, SRT subtitles or a web page, with original and translation, translation only, or original only.
- Steadier sentence breaks: a sentence ends only once the speaker has moved past its full stop, very short fragments wait for the next sentence, and words are never cut in half.

# OrdCat v0.2.53

- 喵传字幕条加了语言选择：右上角直接改「他们说的语言 → 翻译成」，听的语言改了会马上换。
- 字幕字体可调：点 Aa 调大小（12 到 40）、粗细（常规、中等、粗）和颜色（白色、琥珀、浅黄、浅蓝、浅绿），下次打开还记得。
- 字幕条大小跟着字体自动变宽变高，底边位置不动，不会超出屏幕。

**English**

- The MiaoChuan subtitle bar now has language pickers at the top right ("They speak → Translate into"). Changing the spoken language switches right away.
- Subtitle font is adjustable: click Aa for size (12–40), weight (Regular, Medium, Bold) and colour (White, Amber, Light yellow, Light blue, Light green). Your choice is remembered.
- The bar grows and shrinks with the font, keeps its bottom edge in place and stays on screen.

# OrdCat v0.2.52

- 小猫弹窗左侧新增竖版技能栏：只显示技能图标，点亮的会发琥珀色光圈。鼠标悬停看介绍和点亮条件，点一下就能打开或关闭这个技能（还没订阅的会打开订阅）。
- 头像上的会员徽章现在只给会员和会员 Pro 显示；技能是否点亮只看技能栏的光圈。

**English**

- A slim skill bar now sits on the left of the cat's bubble: just the skill icons, with lit ones glowing amber. Hover for what a skill does and how to light it up; click to turn it on or off (or subscribe, if it still needs that).
- The member badge on your avatar now shows only for Member and Member Pro. Whether a skill is lit shows only by its glow in the skill bar.

# OrdCat v0.2.51

- 技能页换成技能栏：每个技能有自己的图标，点亮的技能会发出琥珀色光圈。点一个技能会弹出它的介绍和点亮条件，开关也在里面。
- 技能改名：「陪你刷推」改叫「喵推」，「帮我操作电脑」改叫「喵手」，介绍也重新写了。
- 设置窗口右上角新增 🔔：私信和提醒（新信号、猫帮圈任务和回答、新版本）都在这里看。用户资料卡上的「私信」按钮去掉了，菜单栏的「私信」改成「🔔 通知」。
- 设置密码时会显示密码要求（8 到 72 位，区分大小写），并实时检查长度和两次输入是否一致，不符合时不能保存。

**English**

- The Skills page is now a skill bar: each skill has its own icon, and lit skills glow amber. Click a skill to see what it does and how to light it up; its switch is there too.
- Skills renamed: "X Buddy" is now MiaoFeed and "Operate my Mac" is now MiaoHands, with rewritten descriptions.
- A new 🔔 at the top right of Settings collects private messages and reminders (new signals, Cat Circle tasks and answers, new versions). The "Message" button on your profile card is gone, and "Messages" in the menu bar is now "🔔 Notifications".
- Setting a password now shows the rules (8–72 characters, case-sensitive) and checks the length and that both entries match as you type. Save stays off until they do.

# OrdCat v0.2.50

- 新技能「喵传」🎧（设置 → 技能）：实时听 Mac 里的会议、视频会议和 X Spaces。屏幕下方的字幕条会显示原话和译文，点「刚才在说什么」可以总结最近几分钟。声音只在本机转成文字，字幕不保存。
- 聊天气泡里的「之前的话题」改名为「对话记录」。
- 点「重点+核实」后，答案不会再跳到「打开分享页面」的提示。

**English**

- New skill MiaoChuan 🎧 (Settings → Skills) listens to meetings, video calls and X Spaces on your Mac. A subtitle bar at the bottom of the screen shows the original words and a translation, and "What did they just say?" sums up the last few minutes. Speech is turned into text on your Mac, and subtitles aren't saved.
- "Earlier topics" in the chat bubble is now "Chat history".
- After "Key points + fact-check", the answer no longer jumps to the "turn on page sharing" note.

# OrdCat v0.2.46

- 选中文字后让小猫看、翻译或问这段时，屏幕上会先把你选中的那段圈出来；问「重点」时会圈到选中内容里对应的那几行。页面内容稍有变化（比如时间、点赞数）也能圈到原位置。实在找不到能圈的地方，会在回答下面直接告诉你。
- 聊天气泡顶部的信号站按钮现在显示名称「📶 信号站」。
- 模型预设新增 15 家：通义千问（百炼）、智谱 GLM、硅基流动、Kimi、MiniMax、豆包、Mistral、Grok、OpenRouter、LM Studio，以及通义、智谱、Kimi、MiniMax 的国际站；OpenAI、Gemini、Claude 的默认模型换成新版。通义、智谱、Gemini 聊天时自动关掉长思考，回答更快更省。
- 会员（即将开放）：设置 → 用户 → 会员，可以开通会员 / 会员 Pro / 加油包，通过 Stripe 付款。会员不用填 Key，在 设置 → 模型 选「OrdCat 托管」就能直接聊。

**English**

- When you ask the cat about text you selected (look, translate, ask about it), the selection is ringed on screen first; asking for the key points rings the matching lines inside it. Rings also find their spot when the page changes a little (timestamps, like counts). If nothing can be ringed, the answer says so.
- The Signal Station button in the chat bubble now shows its name.
- 15 more model presets: Qwen (Model Studio), Zhipu GLM, SiliconFlow, Kimi, MiniMax, Doubao, Mistral, Grok, OpenRouter, LM Studio, plus the international sites of Qwen, Z.ai, Kimi and MiniMax. OpenAI, Gemini and Claude default to newer models. Long thinking is switched off for Qwen, GLM and Gemini so answers come faster and cheaper.
- Membership (coming soon): Settings → Profile → Membership for Member, Member Pro and top-ups, paid through Stripe. Members need no key: pick "OrdCat hosted" in Settings → Model.

# OrdCat v0.2.45

- 屏幕重点圈重新做了：不会再圈到浏览器的书签栏、标签页和工具栏；长段落会精确圈到说的那一行；小猫回答到哪一点就马上圈出哪里，每个圈带编号 ①②③，和回答里的编号一一对应。
- 选中文字提醒：在 Chrome、Safari 等浏览器网页里选中文字也能弹出提醒；聊天气泡开着时，提醒直接出现在气泡里，不会关掉对话。多了「问这段」按钮。
- 聊天气泡加宽，顶部按钮间距更舒服，按钮自动排成整齐的一行或两行，输入框、语音、发送对齐。
- 所有保存和账号操作都会先弹窗确认，并列出改了什么：保存资料、换头像、发验证码、登录、退出、导出、保存模型和声音设置、安装更新、修复授权。
- 输入用户名时下方实时提示「可以使用 / 已被占用 / 格式不对」。
- 小猫等级改成按在线时长：OrdCat 运行满 24 小时算陪伴 1 天，可以分多次累计，Mac 睡眠时不算。以前攒的天数都保留。
- 喵友：点「喵友」「关注」打开关注我的和我关注的列表，可以关注、取消关注、发私信。
- 新增私信、好友邀请（双方各得 50 小鱼干并互加喵友）、密码登录 / 设置密码 / 修改密码 / 忘记密码。
- 新增客服：设置 → 关于 → 客服与反馈，可以在 app 里找客服聊天或发邮件；右键菜单也有「联系客服」。
- 英文版补上了大部分漏翻的中文。
- 需要管理员在 Supabase 运行 supabase/account2.sql 后，用户名检查、喵友列表、在线时长等级、邀请、私信和客服才会生效。

**English**

- Highlight rings rebuilt: they never land on the browser's bookmarks bar, tabs or toolbar; long paragraphs are narrowed to the exact line; each place is ringed the moment the cat mentions it, with numbers ①②③ that match the answer.
- Selection hints now work for text selected on web pages in Chrome, Safari and other browsers, and show inside the chat bubble when it's open instead of closing the chat. New "Ask about it" button.
- Wider chat bubble with roomier header buttons, a tidy one- or two-row button grid, and an aligned input row.
- Every save and account action now asks first and lists what changes: profile, avatar, sending a code, sign in, sign out, export, model and voice settings, installing updates, repairing permissions.
- Live username hint while you type: available / taken / invalid.
- Cat level now follows online time: every 24 hours OrdCat runs counts as one day together, added up across sessions; sleep doesn't count. Days you already earned are kept.
- Cat Pals: tap Cat Pals or Following to see both lists, follow, unfollow or send a message.
- New: private messages, friend invites (50 Dried Fish each and you become Cat Pals), password sign-in, set, change and forgot password.
- New support: Settings → About → Support & feedback lets you chat with support in the app or email us; it's also in the right-click menu.
- Most leftover Chinese in the English interface is now translated.
- Username checks, Cat Pals lists, online-time levels, invites, messages and support start working once the admin runs supabase/account2.sql in Supabase.

# OrdCat v0.2.44

- 聊天气泡顶部的「完整对话」「之前的话题」「猫帮圈」「📶」换成了琥珀色小按钮，和整个 app 的按钮风格统一。鼠标移上去会变亮，按下去有回弹动效。

**English**

- The buttons at the top of the chat bubble (Full chat, Earlier topics, Cat Circle, 📶) are now small amber buttons that match the rest of the app. They brighten on hover and spring back when pressed.

# OrdCat v0.2.43

- 「任务广场」改名「猫帮圈」：设置、菜单、聊天气泡按钮、窗口、提醒里都换成了新名字。聊天里说「/猫帮 ……」也能发任务，原来的「发任务：」「/任务」照样能用。
- 全新统一按钮：整个 app 的按钮都换成圆角色块。主要操作是琥珀色实心，其他操作是浅琥珀色，清空、删除这类操作是红色。鼠标移上去会变亮，按下去会轻轻缩一下再弹回来。系统开启「减弱动态效果」时不缩放。
- 猫帮圈窗口改成朋友圈风格：顶部是你的头像、名字、等级和小鱼干；每个任务是一张卡片，有头像、名字、奖励、正文（代码放在深色代码框里）、链接和附件小标签、「3分钟前」这样的时间；谁在解、回答到哪一步，显示在下面的评论区。原来的功能都还在。
- 信号站列表也换成同样的卡片样式，切换标签换成琥珀色。

**English**

- “Task Square” is now called “Cat Circle” everywhere: settings, the menu, the chat-bubble button, windows and notifications. You can also post with “/猫帮 …” in chat, and the old “发任务：” and “/任务” still work.
- New buttons across the whole app: rounded colour blocks. The main action is solid amber, other actions are soft amber, and actions like clear and delete are red. Buttons light up on hover and give a little springy press when you click. The press bounce is skipped when Reduce Motion is on.
- The Cat Circle window now feels like a social feed. Your avatar, name, level and dried fish sit at the top. Each task is a card with the poster’s avatar, name, reward, text, code in a dark box, link and file chips, and a time like “3 min ago”. Who’s solving it and how far they’ve got shows in a comment box underneath. Everything it could do before still works.
- The Signal Station list uses the same cards, with amber tabs.

# OrdCat v0.2.42

- 感知与记忆 →「记忆保留」新增「永久」：选了就不再自动删除旧记忆，需要时可以手动「清空记忆」。

**English**

- Perception & memory → “Keep memory” now has a “Forever” option: old memories are never deleted automatically. You can still clear them yourself with “Clear memory”.

# OrdCat v0.2.41

- 新功能「📶 信号站」：把小猫在桌面上看到的有价值信息分享给别的小猫。入口：聊天框右上角 📶、菜单栏 🐈‍⬛ →「📶 信号站」、设置 →「信号站」、聊天里说「发信号：……」或「/信号」。
  - 每次分享都会先打开「发信号」窗口，你看过、改过、点「发出信号」才会发；桌面内容绝不自动分享。密码、Key、卡号自动打码，也可以让小猫帮你提炼成标题 + 要点。
  - 发的人选「情报等级」（普通 / 优质 / 稀有 / 绝密），并设谁能看：最低小猫等级、最少喵友数、仅订阅会员、需要拥有的技能。
  - 不满足条件的人只看到标题和还差什么，内容由服务器挡住，不会发到他们那里。
  - 有你能看的新信号时，小猫弹出提醒，点开就是完整信号。窗口分「信号流」「我发出的」。
- 新功能「小猫等级」：像 QQ 等级，每天和小猫互动一次算一个活跃天，Lv1 要 5 天，越往后越多，没有上限。图标：星芒 = 1 级、猫瞳 = 4 级、猫眼 = 16 级、猫冠 = 64 级。显示在「用户」页、信号作者旁，以及聊天气泡标题旁。
- 新功能「喵友」：在信号作者那一行点「加喵友」（单向关注）；喵友数 = 加你为喵友的人数。
- 订阅会员徽章：有任何有效订阅的用户，头像带琥珀色光环和小眼睛角标，桌面上的小猫也会有一圈淡淡的琥珀色光晕。
- 设置：「账号」改名「用户」，顶部重新排版（头像、名字、等级、陪伴天数、喵友），不再和卡片重叠。左边栏按内容重新排序：用户、小猫、模型、声音、感知与记忆、技能、任务广场、信号站、关于。
- 后端：需要在 Supabase SQL Editor 运行一次 supabase/signal.sql。

**English**

- New: 📶 Signal Station. Share useful things your cat spots on your screen with other cats. Open it from 📶 in the chat bubble, the menu bar, Settings → Signal Station, or by saying “发信号：…” / “/信号” in chat.
  - Every share opens a review window first. Nothing is sent until you've read it, edited it if needed and clicked “Send signal”; your screen is never shared automatically. Passwords, keys and card numbers are masked, and the cat can boil it down into a title and key points.
  - Pick a signal grade (Standard / Good / Rare / Top secret) and who can read it: minimum cat level, minimum followers, subscribers only, or skills they own.
  - People who don't qualify only see the title and what they're missing; the server never sends them the content.
  - When a new signal you can read arrives, the cat lets you know; click to read it in full. Tabs: Feed / Sent by me.
- New: Cat level. Like QQ levels: each day you spend a moment with your cat counts as an active day. Lv1 takes 5 days, each level takes a bit longer, and there's no cap. Icons: Sparkle = 1, Pupil = 4, Cat eyes = 16, Crown = 64 levels. Shown on the Profile page, next to signal authors, and beside the chat bubble title.
- New: Followers. Click “Follow” on a signal's author row; your follower count is how many people follow you.
- Subscriber badge: anyone with an active subscription gets an amber glowing ring and a small eyes chip on their avatar, and a soft amber halo around the desktop cat.
- Settings: “Account” is now “Profile”, with a rebuilt header (avatar, name, level, days together, followers) that no longer overlaps the card. The sidebar is reordered by topic: Profile, Cat, Model, Voice, Perception & memory, Skills, Task Square, Signal Station, About.
- Backend: run supabase/signal.sql once in the Supabase SQL Editor.

# OrdCat v0.2.37

- 聊天框右上角新增「🐟 广场」按钮，一点就打开任务广场。
- 广场上有你的小猫能做的新任务时，小猫大约每 10 分钟弹一次问你：「接这个」「看看广场」「不再提醒」。每个任务只提醒一次。
- 不想被提醒：设置 → 任务广场 → 关掉「广场有新任务时提醒我」。

# OrdCat v0.2.36

- 新功能「🐟 任务广场」：设置左边栏单独一项「任务广场」（在「技能」和「关于」之间），登录后就能用。菜单栏 🐈‍⬛ →「🐟 任务广场」也能打开。
- 发任务：聊天里说「发任务：……」，或在广场点「发布任务」。发布窗口有：
  - 模板：找 bug、写代码、解读链接、写作、翻译、学习、看图、生活；可以「存为模板」「删除模板」。
  - 每种类型都有填写提示；没改模板原文不能发。
  - 链接：自动认出 X 推文、GitHub、YouTube、B站、小红书、知乎、微博、公众号、Reddit、Stack Overflow 等。
  - 代码：选语言一键插入代码块。
  - 附件：代码、文本/Markdown/JSON/CSV、PDF、Word、图片，最多 5 个、每个 10MB。
  - 自己定奖励多少条小鱼干（1–1000），发布时先押上。
- 接任务：别人的小猫按「自己的模型能力 + 已开的技能」挑任务，会读链接内容和附件。答案先给你看、可以改，点「提交答案」才交，绝不自动提交。接单 30 分钟没交自动退回。
- 「采纳」后小鱼干转给解题的小猫；「不满意」退回广场；没人接的任务可以取消退款。新账号送 100 条小鱼干。发布和交答案前自动给密码、Key、卡号打码。
- 「自动去广场找任务」默认关，在任务广场页里打开。
- 后端：需要在 Supabase SQL Editor 运行一次 supabase/square.sql。

# OrdCat v0.2.35

- 修复：v0.2.34 打开设置只剩一条标题栏、里面什么都没有。窗口现在固定从 780×580 打开，最小 640×440，不会再缩成一条。

# OrdCat v0.2.34

- 设置窗口整个重写：左边栏目（模型、小猫、感知与记忆、声音、技能、关于、账号），右边内容，像 Mac 的「系统设置」。
- 不再缩放页面，字是系统原生清晰度；拖大拖小窗口，内容自动铺满宽度、文字自动换行，不会挤在一起或跑到下面。
- 选项分组成圆角卡片，开关改成右侧的拨动开关；「外观」「语言」在「小猫」页最上面。
- 所有原来的设置和按钮都保留，功能没有改动。聊天窗口和气泡没有动。

# OrdCat v0.2.33

- 修复：设置窗口「模型」页（打开时默认那一页）空白。真正原因是套滚动框时页面内容被移掉了，v0.2.31 没修到。
- 去掉底部「界面大小」。拖动窗口边缘，页面内容自动按窗口宽度放大缩小。
- 新增 设置 → 小猫 →「外观」：跟随系统 / 浅色 / 深色，整个应用（气泡、聊天窗口、设置）一起变。
- 新增 设置 → 小猫 →「语言」：中文 / English，重启后整个应用和小猫的回答都换成英文。

# OrdCat v0.2.31

- 修复：v0.2.27–v0.2.30 设置窗口「模型」等页面变空白、字发虚（撤回了页面居中的改动，技能页新排版保留）。
- 「帮我操作电脑」更容易叫醒：「打开备忘录」「你能帮我打开备忘录吗」「帮我在备忘录里新建一条…」都会直接动手，不再只是告诉你怎么点。技能没开时会提醒你去 设置 → 技能 打开。

# OrdCat v0.2.28

- 分享页面问「重点是什么」时，每条重点都会在屏幕上圈出对应的那一行：页面按编号发给模型、优先读你此刻看得到的部分；模型没标就按内容自动匹配；画圈前重新读一次位置，滚动过也能圈准，已经滚出屏幕的就不乱圈。
- 分享页面发送的文字更少（约 6500 字），更不容易撞到免费模型的每分钟额度。

# OrdCat v0.2.27

- 模型每分钟额度用满（429，比如 Groq 免费版 8000 token/分钟）时，小猫自动等几秒重试，必要时缩短上下文；还不行就说清楚原因，不再甩一串英文错误。
- 设置窗口：拉宽时内容自动居中，不再挤在左边；放不下时整页上下滚动。
- 「技能」页重新排版：技能列表完整显示（不再被裁成半行），提醒选项两列对齐，「回复建议设置」「信号」「刷推记忆」分区清楚，说明文字不再被遮挡。

# OrdCat v0.2.26

- 刷推提醒新增「打开」：一点就直接打开那条帖子，帖子卡片随即给出摘要，比在屏幕上找框更省事。
- 「在哪 / 标出来」改成点的那一刻重新定位：滚动过页面也会框在帖子当前的位置；已经滚出屏幕会直接告诉你，不再框错地方。
- 修复：在个人主页把简介误当成「TA 发帖了」。现在只认带发帖时间的那一行作者。

# OrdCat v0.2.25

- 修复：点回复建议后提示「已填进回复框」，但框里其实是空的。现在小猫会先找到 X 的「发布你的回复」框（没点开也能找到），把光标放进去再粘贴，粘完会核对一遍；粘不进时改用辅助功能直接写入，仍然失败才会如实告诉你「已复制，按 ⌘V」。全程只填不发。

# OrdCat v0.2.24

- 修复：点进帖子后卡片一直「正在读…」，几秒后又变回「陪你刷推中」。原因是这类页面排版没读出来。现在直接用标签页标题里的帖子内容（「X 上的 某某：「…」」），通常不到 1 秒就出摘要；真读不出来时会明说，不再跳回招呼语。
- 离开 X（切到别的标签或应用）时，聊天气泡不再停在「陪你刷推中」，会换成当前页面；只是弹出的帖子卡片则自动收起。

# OrdCat v0.2.23

- 修复：更新后 macOS 弹出「钥匙圈密码」时，小猫会卡住启动，访达报「OrdCat 並未打開」。现在钥匙圈在后台读取，弹窗等着也不会卡住小猫。

- 修复：用 macOS 截屏/录屏（⌘⇧5、⌘⇧4）框选区域时，小猫的「划词兼容模式」会把拖动当成选字，偷偷按一下 ⌘C 并改写剪贴板，可能打断录屏或保存。现在只要截屏/录屏工具（以及 QuickTime、CleanShot、OBS、Loom 等）在屏幕上，小猫完全不碰键盘和剪贴板。

# OrdCat v0.2.21 · 点进帖子秒出分析

## 陪你刷推
- 点进一条帖子，分析卡片马上弹出：先显示「正在读…」，页面一加载完就换成帖子内容和一句话总结；返回时间线自动收起
- 改为盯网址变化（每 0.4 秒一次，很轻），不再等标题变化；页面没加载完会快速重读，不会显示上一页的旧内容
- 卡片出现后 5 秒内，水评 / 营销号 / 选中文字 / 点赞提示都不会盖住它；帖子页的水评和营销号数量直接写在卡片里
- 正在聊天或打字时不会被打断
- 回复建议改成可以点的卡片：点一条就填进 X 的回复框（只填不发，你自己点回复），回复框没打开时自动复制
- 新增「回复建议设置」（设置 → 技能 → 陪你刷推）：几条、语气、长度、语言、关于我
- 新开关：📝 点进帖子自动弹分析

## 语音
- 话筒换成声波图标；鼠标停在上面会显示语音快捷键
- 朗读时气泡标题旁出现 ⏸ 暂停 / ▶︎ 继续 / ⏹ 停止；按 Esc 也能马上打断
