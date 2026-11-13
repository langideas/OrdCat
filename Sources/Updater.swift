// OrdCat — in-app updates and remote config.
//
// Updater: checks GitHub Releases (langideas/OrdCat), downloads OrdCat-macOS.zip, swaps the app bundle in place
//          after OrdCat quits, then relaunches. No re-download from the browser needed.
// RemoteConfig: config/remote.json on the main branch can change the cat's system prompt and push an
//          announcement without shipping a new build at all.

import Cocoa

final class Updater {
    static let shared = Updater()
    static let repo = "langideas/OrdCat"

    let current: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    private(set) var latestVersion: String?
    private(set) var latestNotes = ""
    private(set) var lastChecked: Date?
    private var zipURL: URL?
    private var timer: Timer?
    var onUpdateAvailable: ((String) -> Void)?

    var hasUpdate: Bool {
        guard let v = latestVersion, zipURL != nil else { return false }
        return Updater.isNewer(v, than: current)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func startAutoCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 600
    }

    func check(completion: ((String?) -> Void)? = nil) {
        guard let url = URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { return }
            var problem: String?
            if let d = data, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let tag = obj["tag_name"] as? String {
                let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let assets = obj["assets"] as? [[String: Any]] ?? []
                let zip = assets.first(where: { ($0["name"] as? String) == "OrdCat-macOS.zip" })?["browser_download_url"] as? String
                DispatchQueue.main.async {
                    self.latestVersion = v
                    self.latestNotes = obj["body"] as? String ?? ""
                    self.zipURL = zip.flatMap { URL(string: $0) }
                    self.lastChecked = Date()
                    if self.hasUpdate { self.onUpdateAvailable?(v) }
                    completion?(nil)
                }
                return
            }
            problem = err?.localizedDescription ?? "没拿到版本信息"
            DispatchQueue.main.async { completion?(problem) }
        }.resume()
    }

    /// After we quit: put `newApp` at `target` (keeping the old copy until the new one is in place) and open it.
    static func swapAndRelaunch(target: URL, newApp: URL) -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "$1.old"
        if [ -e "$1" ]; then
          if mv "$1" "$1.old" && mv "$2" "$1"; then rm -rf "$1.old"; else mv "$1.old" "$1"; fi
        else
          mv "$2" "$1"
        fi
        xattr -cr "$1" 2>/dev/null
        open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "ordcat-update", target.path, newApp.path]
        do { try p.run(); return true } catch { return false }
    }

    /// First launch of a version: move out of Downloads / App Translocation into /Applications,
    /// and replace the ad-hoc signature with this Mac's stable one. Returns true when we are
    /// about to quit and relaunch. Runs off the main thread.
    func selfInstallIfNeeded() -> Bool {
        let ud = UserDefaults.standard
        let key = "selfInstall-\(current)"
        if ud.bool(forKey: key) { return false }
        ud.set(true, forKey: key)
        let fm = FileManager.default
        let cur = Bundle.main.bundleURL
        let apps = URL(fileURLWithPath: "/Applications/OrdCat.app")
        let misplaced = cur.path.contains("AppTranslocation") || cur.path.contains("/Downloads/")
            || !fm.isWritableFile(atPath: cur.deletingLastPathComponent().path)
        let target = misplaced ? apps : cur
        if misplaced, let v = Bundle(url: apps)?.infoDictionary?["CFBundleShortVersionString"] as? String,
           v == current || Updater.isNewer(v, than: current),
           v != current || !LocalSigner.isAdhoc(apps) {
            // A same-or-newer, properly signed copy already lives in /Applications: use that one.
            let o = Process()
            o.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            o.arguments = [apps.path]
            if (try? o.run()) != nil { return true }
        }
        let adhoc = LocalSigner.isAdhoc(cur)
        if !misplaced && !adhoc { return false }
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else { return false }
        let work = fm.temporaryDirectory.appendingPathComponent("OrdCatInstall-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let copy = work.appendingPathComponent("OrdCat.app")
        let d = Process()
        d.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        d.arguments = [cur.path, copy.path]
        guard (try? d.run()) != nil else { return false }
        d.waitUntilExit()
        guard d.terminationStatus == 0 else { return false }
        let signed = adhoc ? LocalSigner.sign(copy) : true
        if !misplaced && !signed { return false }
        return Updater.swapAndRelaunch(target: target, newApp: copy)
    }

    /// Download, unpack, and swap the bundle after we quit. `status` receives Chinese progress lines.
    func install(status: @escaping (String) -> Void) {
        guard let zip = zipURL else { status("还没有可用的更新"); return }
        // Where the new version goes: in place when we already live in a writable folder;
        // otherwise (opened straight from Downloads, macOS "App Translocation", read-only folder)
        // install into /Applications so future updates work in place.
        var bundle = Bundle.main.bundleURL
        let fm0 = FileManager.default
        let translocated = bundle.path.contains("AppTranslocation")
        if translocated || !fm0.isWritableFile(atPath: bundle.deletingLastPathComponent().path) {
            bundle = URL(fileURLWithPath: "/Applications/OrdCat.app")
        }
        guard fm0.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            status("没有权限写入「应用程序」文件夹，请用管理员账户登录后再试。")
            return
        }
        status("正在下载新版本…")
        URLSession.shared.downloadTask(with: zip) { tmp, _, err in
            guard let tmp = tmp else {
                DispatchQueue.main.async { status("下载失败：\(err?.localizedDescription ?? "未知错误")") }
                return
            }
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("OrdCatUpdate-\(UUID().uuidString)")
            try? fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zipPath = work.appendingPathComponent("update.zip")
            try? fm.moveItem(at: tmp, to: zipPath)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zipPath.path, work.path]
            try? unzip.run()
            unzip.waitUntilExit()
            let newApp = work.appendingPathComponent("OrdCat.app")
            guard fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/OrdCat").path) else {
                DispatchQueue.main.async { status("解压失败，稍后再试试") }
                return
            }
            // Sign with this Mac's own stable identity so permissions survive the update.
            let signed = LocalSigner.sign(newApp)
            NSLog("OrdCat update: local signing \(signed ? "ok" : "failed, keeping ad-hoc")")
            let ok = Updater.swapAndRelaunch(target: bundle, newApp: newApp)
            DispatchQueue.main.async {
                guard ok else { status("更新启动失败，稍后再试试"); return }
                status("更新好啦，小猫马上重启～")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
            }
        }.resume()
    }
}

final class RemoteConfig {
    static let shared = RemoteConfig()
    static let url = URL(string: "https://raw.githubusercontent.com/\(Updater.repo)/main/config/remote.json")!

    var systemPrompt: String? {
        let s = UserDefaults.standard.string(forKey: "remoteSystemPrompt")
        return (s?.isEmpty ?? true) ? nil : s
    }

    func fetch(onAnnouncement: @escaping (String) -> Void) {
        var req = URLRequest(url: RemoteConfig.url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let d = data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            DispatchQueue.main.async {
                let ud = UserDefaults.standard
                ud.set(obj["systemPrompt"] as? String ?? "", forKey: "remoteSystemPrompt")
                if let a = obj["announcement"] as? [String: Any], let id = a["id"] as? String,
                   let text = a["text"] as? String, !text.isEmpty, ud.string(forKey: "lastAnnouncement") != id {
                    ud.set(id, forKey: "lastAnnouncement")
                    onAnnouncement(text)
                }
            }
        }.resume()
    }
}

/// Signs OrdCat with a self-signed identity created on this Mac (Resources/localsign.sh), so
/// macOS keeps Accessibility / Screen Recording grants across updates.
enum LocalSigner {
    static func run(_ exe: String, _ args: [String], timeout: Double = 60) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "") }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return (-1, "timeout") }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out)
    }

    static func isAdhoc(_ app: URL) -> Bool {
        let (_, out) = run("/usr/bin/codesign", ["-dv", app.path], timeout: 10)
        return out.contains("Signature=adhoc") || out.contains("not signed")
    }

    static func sign(_ app: URL) -> Bool {
        let mine = Bundle.main.path(forResource: "localsign", ofType: "sh")
        let theirs = app.appendingPathComponent("Contents/Resources/localsign.sh").path
        guard let script = [mine, theirs].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0) })
        else { return false }
        let (code, out) = run("/bin/sh", [script, app.path])
        NSLog("OrdCat localsign: \(code) \(out)")
        return code == 0
    }
}
