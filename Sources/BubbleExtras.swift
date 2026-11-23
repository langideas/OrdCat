// BubbleExtras.swift — 小猫弹窗的两个小功能 (v0.2.57)
//   • ➕：给小猫发图片、文件，或剪贴板里的图片。
//   • 🎧 正在收听：把喵传听到的内容（刚才 5 分钟 / 整场）或一条喵传记录带进对话。

import AppKit
import PDFKit
import UniformTypeIdentifiers

/// A menu item that runs a closure.
final class BlockMenuItem: NSMenuItem {
    private let block: () -> Void
    init(_ title: String, on: Bool = false, block: @escaping () -> Void) {
        self.block = block
        super.init(title: L10n.t(title), action: #selector(run), keyEquivalent: "")
        target = self
        state = on ? .on : .off
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { block() }
}

enum BubbleAttach {
    static let types: [UTType] = [.image, .pdf, .plainText, .text, .sourceCode, .json, .commaSeparatedText, .xml, .html]

    /// Images become JPEG data; PDFs and text files become text (at most 20,000 characters each).
    static func read(_ urls: [URL]) -> (images: [Data], files: [PendingFile], failed: Int) {
        var imgs: [Data] = [], files: [PendingFile] = [], failed = 0
        for u in urls {
            let type = UTType(filenameExtension: u.pathExtension) ?? .data
            if type.conforms(to: .image) {
                if let d = jpegData(from: u) { imgs.append(d) } else { failed += 1 }
            } else if type.conforms(to: .pdf) {
                let t = PDFDocument(url: u)?.string ?? ""
                if t.isEmpty { failed += 1 } else { files.append(PendingFile(name: u.lastPathComponent, text: String(t.prefix(20000)))) }
            } else if let t = try? String(contentsOf: u, encoding: .utf8) {
                files.append(PendingFile(name: u.lastPathComponent, text: String(t.prefix(20000))))
            } else {
                failed += 1
            }
        }
        return (imgs, files, failed)
    }

    static var pasteboardHasImage: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    static func pasteboardImage() -> Data? {
        guard let img = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage else { return nil }
        var r = CGRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return nil }
        return jpegData(cgImage: cg)
    }
}

/// What the 🎧 chip brings into the chat.
enum ListenPick: Equatable {
    case live(Double?)              // minutes; nil = 整场
    case record(String, String)     // id, title

    var isLive: Bool { if case .live = self { return true }; return false }
}

enum ListenContext {
    static func text(for pick: ListenPick) -> String? {
        switch pick {
        case .live(let mins):
            let m = MiaoChuan.shared
            guard m.running else { return nil }
            let body = m.transcript(lastMinutes: mins)
            let span = mins.map { "最近 \(Int($0)) 分钟" } ?? "这一整场"
            if body.isEmpty {
                return "## 用户正在用喵传收听「\(m.listeningApp)」\n（\(span)还没听到说话。请如实告诉用户。）"
            }
            return """
            ## 用户正在用喵传收听「\(m.listeningApp)」（\(span)的字幕）
            用户说「刚才」「他说的」「这段」时，指的就是下面这些内容。请根据字幕回答，不要编造没听到的内容；语音识别可能有错字，按上下文理解。
            \(body)
            """
        case .record(let id, _):
            guard let r = MiaoRecords.load(id) else { return nil }
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
            var s = "## 用户选了一条喵传记录来聊：「\(r.title)」\n收听：\(r.app) · \(df.string(from: r.start)) · 约 \(r.minutes) 分钟\n用户说「这段」「他们说的」时，指的就是这条记录。请根据记录回答，不要编造记录里没有的内容。"
            if !r.summary.isEmpty { s += "\n\n### 总结\n" + r.summary }
            let tr = r.bestTr, orig = r.bestOrig
            let room = 16000
            if !tr.isEmpty {
                s += "\n\n### 译文\n" + String(tr.prefix(room / 2))
                s += "\n\n### 原文\n" + String(orig.prefix(room / 2))
            } else {
                s += "\n\n### 原文\n" + String(orig.prefix(room))
            }
            return s
        }
    }
}
