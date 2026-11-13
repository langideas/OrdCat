# OrdCat 🐈‍⬛

**A cozy cat in your island & desktop. Less burden, low power, always with you.**
窝在灵动岛与桌面角落的小黑猫：低能耗、零负担，安静陪你每一天。

## v0.1（macOS 桌面端 · Phase 1 子集）

- 从屏幕**右侧边探头**的小黑猫，一只爪子扒在屏幕边缘，可上下拖动位置
- **眼睛跟着鼠标转**（仅在鼠标移动时刷新，静止时零重绘）
- **复制文字 → 竖起耳朵 + “!”** 并弹出气泡，可一键让小猫帮你看看（报错 / 代码 / 普通文字）
- 气泡窗口**不抢焦点**（non-activating），点击小猫即可聊天，Esc 收起
- **BYOM**：本地 Ollama、DeepSeek、OpenAI、Gemini、Claude 或任意 OpenAI 兼容接口；API Key 存在系统钥匙串
- 系统语音播报（可关）、连续用屏 2 小时 / 凌晨熬夜温柔提醒、陪伴天数记录
- 隐私：不截屏、不录音；忽略密码管理器写入剪贴板的内容

## 安装

到 [Releases](../../releases/latest) 下载 `OrdCat-macOS.zip`，安装说明见发布页。

## 自己编译

```bash
./build.sh   # 需要 macOS + Xcode Command Line Tools
open build/OrdCat.app
```

## Roadmap

- v0.2：单窗口陪看（ScreenCaptureKit + 1~2fps 差分抽帧）、语音输入与 150ms 打断（Silero-VAD + AEC）
- v0.3：iOS 灵动岛（Live Activities）
- Phase 2：社交广场、助手串门、装扮家园、陪伴等级、Pro 徽章

产品需求见 `docs/OrdCat_PRD_v4.0.pdf`。
