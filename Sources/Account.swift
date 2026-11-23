// OrdCat — 用户账号.
//
// Local profile (name, username, avatar) always works. Cloud account (email / phone sign-up, subscriptions bound to
// the account, account deletion) runs on Supabase; its address and public anon key come from config/remote.json:
//   "account": { "supabaseURL": "https://xxxx.supabase.co", "anonKey": "sb_publishable_…" }
// Server side lives in supabase/ (tables, storage bucket, delete-account and lemon-webhook functions).

import Cocoa

struct AccountProfile: Codable {
    var userID: String?
    var email: String?
    var phone: String?
    var username: String = ""
    var displayName: String = ""
    var avatarURL: String?
}

private struct AccountSession: Codable {
    var access: String
    var refresh: String
    var expires: Date
}

final class Account {
    static let shared = Account()
    private let d = UserDefaults.standard
    private(set) var profile = AccountProfile()
    private var session: AccountSession?
    private var observers: [() -> Void] = []

    let dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OrdCat")
    var avatarFile: URL { dir.appendingPathComponent("avatar.png") }
    private var profileFile: URL { dir.appendingPathComponent("account.json") }

    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: profileFile), let p = try? JSONDecoder().decode(AccountProfile.self, from: data) {
            profile = p
        }
        if profile.displayName.isEmpty { profile.displayName = NSFullUserName().isEmpty ? "我" : NSFullUserName() }
        let s = Keychain.get(service: "app.ordcat.session")
        if let data = s.data(using: .utf8) { session = try? JSONDecoder().decode(AccountSession.self, from: data) }
    }

    func observe(_ f: @escaping () -> Void) { observers.append(f) }
    private func changed() {
        if let data = try? JSONEncoder().encode(profile) { try? data.write(to: profileFile, options: .atomic) }
        DispatchQueue.main.async { self.observers.forEach { $0() } }
    }

    // MARK: config

    static func applyRemote(_ obj: [String: Any]?) {
        guard let a = obj else { return }
        UserDefaults.standard.set(a["supabaseURL"] as? String ?? "", forKey: "account.url")
        UserDefaults.standard.set(a["anonKey"] as? String ?? "", forKey: "account.anon")
    }
    private var baseURL: String? {
        guard var s = d.string(forKey: "account.url"), !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
    private var anonKey: String? { d.string(forKey: "account.anon").flatMap { $0.isEmpty ? nil : $0 } }
    /// Project address for public storage links.
    var publicBase: String? { baseURL }
    var configured: Bool { baseURL != nil && anonKey != nil }
    var signedIn: Bool { profile.userID != nil && session != nil }
    var accountLine: String {
        guard signedIn else { return configured ? "还没登录" : "账号服务开通中，资料先保存在本机" }
        return "已登录：" + (profile.email ?? profile.phone ?? "")
    }

    // MARK: local profile

    func avatarImage(size: CGFloat = 64) -> NSImage {
        if let img = NSImage(contentsOf: avatarFile) { return img }
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        // Brand graphite (#3d3d3c) circle with the amber capsule eyes.
        NSColor(calibratedRed: 0.24, green: 0.24, blue: 0.235, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        let eyes = ordEyesImage(height: size * 0.34)
        eyes.draw(in: NSRect(x: (size - eyes.size.width) / 2, y: (size - eyes.size.height) / 2,
                             width: eyes.size.width, height: eyes.size.height))
        img.unlockFocus()
        return img
    }

    /// 用户名: 3–20 letters, digits or _ .
    static func validUsername(_ u: String) -> Bool {
        u.range(of: "^[A-Za-z0-9_]{3,20}$", options: .regularExpression) != nil
    }

    func update(displayName: String, username: String, done: @escaping (String?) -> Void) {
        let n = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
        guard !n.isEmpty, n.count <= 30 else { done("名称不能为空，最多 30 个字"); return }
        guard u.isEmpty || Account.validUsername(u) else { done("用户名只能用 3–20 个字母、数字或下划线"); return }
        profile.displayName = n
        profile.username = u
        changed()
        if signedIn { pushProfile(done: done) } else { done(nil) }
    }

    /// Is this 用户名 free? true / false, or nil with a reason when the server can't say (offline, not set up).
    /// Uses the username_available RPC (supabase/account2.sql), which works signed in or not.
    func usernameAvailable(_ u: String, done: @escaping (Bool?, String?) -> Void) {
        guard configured else { done(nil, "格式没问题（账号服务开通后会检查是否被占用）"); return }
        request("POST", "/rest/v1/rpc/username_available", json: ["p_name": u], auth: signedIn) { obj, err in
            if let e = err {
                done(nil, e.contains("username_available") || e.contains("404") || e.contains("PGRST")
                     ? "格式没问题（服务器还没开通用户名检查）" : "格式没问题，暂时连不上服务器确认是否被占用")
                return
            }
            if let b = obj as? Bool { done(b, nil); return }
            if let o = obj as? [String: Any], let b = o["available"] as? Bool { done(b, nil); return }
            done(nil, nil)
        }
    }

    func setAvatar(from url: URL, done: @escaping (String?) -> Void) {
        guard let src = NSImage(contentsOf: url) else { done("这张图片打不开"); return }
        let side: CGFloat = 256
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        let s = src.size
        let scale = max(side / max(s.width, 1), side / max(s.height, 1))
        let w = s.width * scale, h = s.height * scale
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: side, height: side)).addClip()
        src.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { done("头像保存失败"); return }
        try? png.write(to: avatarFile, options: .atomic)
        changed()
        guard signedIn, let base = baseURL, let uid = profile.userID else { done(nil); return }
        request("POST", "/storage/v1/object/avatars/\(uid).png", raw: png, contentType: "image/png",
                headers: ["x-upsert": "true"]) { [weak self] _, err in
            guard let self = self else { return }
            if let e = err { done("头像已保存在本机，上传失败：\(e)"); return }
            self.profile.avatarURL = "\(base)/storage/v1/object/public/avatars/\(uid).png?v=\(Int(Date().timeIntervalSince1970))"
            self.changed()
            self.pushProfile(done: done)
        }
    }

    // MARK: sign up / sign in (one-time code by email or SMS)

    func sendCode(email: String?, phone: String?, done: @escaping (String?) -> Void) {
        guard configured else { done("账号服务还在开通中"); return }
        var body: [String: Any] = ["create_user": true]
        if let e = email { body["email"] = e.trimmingCharacters(in: .whitespaces) }
        if let p = phone { body["phone"] = Account.normalizePhone(p) }
        request("POST", "/auth/v1/otp", json: body, auth: false) { _, err in done(err) }
    }

    func verify(email: String?, phone: String?, code: String, done: @escaping (String?) -> Void) {
        var body: [String: Any] = ["token": code.trimmingCharacters(in: .whitespaces)]
        if let e = email { body["type"] = "email"; body["email"] = e.trimmingCharacters(in: .whitespaces) }
        if let p = phone { body["type"] = "sms"; body["phone"] = Account.normalizePhone(p) }
        request("POST", "/auth/v1/verify", json: body, auth: false) { [weak self] obj, err in
            guard let self = self else { return }
            guard err == nil, let o = obj as? [String: Any], self.takeSession(o) else { done(err ?? "验证码不对或已过期"); return }
            self.pull { done(nil) }
        }
    }

    // MARK: password (Supabase Auth). 忘记密码 = sign in with a one-time code, then set a new password.

    /// Sign in with email / phone + password.
    func signIn(email: String?, phone: String?, password: String, done: @escaping (String?) -> Void) {
        guard configured else { done("账号服务还在开通中"); return }
        var body: [String: Any] = ["password": password]
        if let e = email { body["email"] = e.trimmingCharacters(in: .whitespaces) }
        if let p = phone { body["phone"] = Account.normalizePhone(p) }
        request("POST", "/auth/v1/token?grant_type=password", json: body, auth: false) { [weak self] obj, err in
            guard let self = self else { return }
            guard err == nil, let o = obj as? [String: Any], self.takeSession(o) else {
                let e = (err ?? "").lowercased()
                done(e.contains("invalid") ? "账号或密码不对（没设过密码就用验证码登录）" : (err ?? "登录失败"))
                return
            }
            self.pull { done(nil) }
        }
    }

    /// Set or change the password of the signed-in account. Changing asks for the current one first.
    func setPassword(_ new: String, current: String?, done: @escaping (String?) -> Void) {
        guard signedIn else { done("还没登录"); return }
        guard new.count >= 8 else { done("密码至少 8 位"); return }
        let apply: () -> Void = { [weak self] in
            self?.request("PUT", "/auth/v1/user", json: ["password": new]) { _, err in
                if let e = err, e.lowercased().contains("same") { done("新密码不能和旧密码一样"); return }
                if err == nil { Prefs.d.set(true, forKey: "account.hasPassword") }
                done(err)
            }
        }
        guard let cur = current, !cur.isEmpty else { apply(); return }
        // Check the current password by signing in with it again (same account).
        var body: [String: Any] = ["password": cur]
        if let e = profile.email, !e.isEmpty { body["email"] = e } else if let p = profile.phone, !p.isEmpty { body["phone"] = p }
        request("POST", "/auth/v1/token?grant_type=password", json: body, auth: false) { [weak self] obj, err in
            guard let self = self else { return }
            guard err == nil, let o = obj as? [String: Any], self.takeSession(o) else { done("当前密码不对"); return }
            apply()
        }
    }

    /// Whether this Mac has set a password for the account (Supabase doesn't tell clients).
    var hasPassword: Bool { Prefs.d.bool(forKey: "account.hasPassword") }

    static func normalizePhone(_ p: String) -> String {
        var s = p.filter { $0.isNumber || $0 == "+" }
        if !s.hasPrefix("+") {
            if s.hasPrefix("09") && s.count == 10 { s = "+886" + s.dropFirst() }       // 台湾
            else if s.count == 11 && s.hasPrefix("1") { s = "+86" + s }                // 中国大陆
            else { s = "+" + s }
        }
        return s
    }

    private func takeSession(_ o: [String: Any]) -> Bool {
        guard let a = o["access_token"] as? String, let r = o["refresh_token"] as? String else { return false }
        let exp = Date().addingTimeInterval(Double(o["expires_in"] as? Int ?? 3600) - 60)
        session = AccountSession(access: a, refresh: r, expires: exp)
        if let data = try? JSONEncoder().encode(session!), let s = String(data: data, encoding: .utf8) {
            Keychain.set(s, service: "app.ordcat.session")
        }
        if let u = o["user"] as? [String: Any] {
            profile.userID = u["id"] as? String
            if let e = u["email"] as? String, !e.isEmpty { profile.email = e }
            if let p = u["phone"] as? String, !p.isEmpty { profile.phone = p }
        }
        changed()
        return true
    }

    private func withFreshSession(_ f: @escaping (String?) -> Void) {
        guard let s = session else { f("还没登录"); return }
        if s.expires > Date() { f(nil); return }
        request("POST", "/auth/v1/token?grant_type=refresh_token", json: ["refresh_token": s.refresh], auth: false) { [weak self] obj, err in
            guard let self = self else { return }
            if let o = obj as? [String: Any], self.takeSession(o) { f(nil) }
            else { f(err ?? "登录已过期，请重新登录") }
        }
    }

    // MARK: cloud profile + subscriptions

    /// Load the cloud profile and subscriptions (called after sign-in and on launch).
    func pull(_ done: (() -> Void)? = nil) {
        guard signedIn, let uid = profile.userID else { done?(); return }
        request("GET", "/rest/v1/profiles?id=eq.\(uid)&select=*") { [weak self] obj, _ in
            guard let self = self else { return }
            if let row = (obj as? [[String: Any]])?.first {
                if let n = row["display_name"] as? String, !n.isEmpty { self.profile.displayName = n }
                if let u = row["username"] as? String { self.profile.username = u }
                if let a = row["avatar_url"] as? String, !a.isEmpty, a != self.profile.avatarURL {
                    self.profile.avatarURL = a
                    if let url = URL(string: a), let data = try? Data(contentsOf: url) { try? data.write(to: self.avatarFile) }
                }
                self.changed()
            } else {
                self.pushProfile { _ in }
            }
            self.pullSubscriptions(done)
        }
    }

    private func pullSubscriptions(_ done: (() -> Void)?) {
        guard let uid = profile.userID else { done?(); return }
        request("GET", "/rest/v1/subscriptions?user_id=eq.\(uid)&select=skill,status,renews_at,ends_at,portal_url") { [weak self] obj, _ in
            guard let self = self else { return }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let iso2 = ISO8601DateFormatter()
            for row in (obj as? [[String: Any]]) ?? [] {
                guard let skill = row["skill"] as? String else { continue }
                let status = row["status"] as? String ?? ""
                let dateStr = (row["ends_at"] as? String) ?? (row["renews_at"] as? String) ?? ""
                var until = iso.date(from: dateStr) ?? iso2.date(from: dateStr) ?? Date().addingTimeInterval(32 * 86400)
                if ["expired", "unpaid"].contains(status) { until = .distantPast }
                self.d.set(until, forKey: "account.sub.\(skill)")
                if let p = row["portal_url"] as? String, !p.isEmpty { self.d.set(p, forKey: "account.portal") }
            }
            self.changed()
            done?()
        }
    }

    /// Paid through the account (bound by the Lemon Squeezy webhook).
    func subscribedUntil(_ skill: String) -> Date? {
        guard signedIn else { return nil }
        return d.object(forKey: "account.sub.\(skill)") as? Date
    }
    var portalURL: URL? { d.string(forKey: "account.portal").flatMap(URL.init(string:)) }

    func pushProfile(done: @escaping (String?) -> Void) {
        guard let uid = profile.userID else { done(nil); return }
        var row: [String: Any] = ["id": uid, "display_name": profile.displayName]
        row["username"] = profile.username.isEmpty ? NSNull() : profile.username
        if let a = profile.avatarURL { row["avatar_url"] = a }
        request("POST", "/rest/v1/profiles", json: [row],
                headers: ["Prefer": "resolution=merge-duplicates,return=minimal"]) { _, err in
            if let e = err, e.contains("duplicate") || e.contains("23505") { done("这个用户名已经有人用了"); return }
            done(err)
        }
    }

    /// Checkout link that ties the payment to this account.
    func checkoutURL(_ base: URL) -> URL {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        var q = c.queryItems ?? []
        if let uid = profile.userID { q.append(URLQueryItem(name: "checkout[custom][user_id]", value: uid)) }
        if let e = profile.email { q.append(URLQueryItem(name: "checkout[email]", value: e)) }
        if !profile.displayName.isEmpty { q.append(URLQueryItem(name: "checkout[name]", value: profile.displayName)) }
        c.queryItems = q.isEmpty ? nil : q
        return c.url ?? base
    }

    // MARK: sign out / delete / data

    func signOut() {
        if session != nil { request("POST", "/auth/v1/logout") { _, _ in } }
        session = nil
        Keychain.set("", service: "app.ordcat.session")
        profile.userID = nil; profile.email = nil; profile.phone = nil; profile.avatarURL = nil
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("account.sub.") || k == "account.portal" { d.removeObject(forKey: k) }
        changed()
    }

    /// Delete the cloud account and everything stored for it (profile, avatar, subscription links).
    func deleteAccount(done: @escaping (String?) -> Void) {
        guard signedIn else { done("还没登录"); return }
        request("POST", "/functions/v1/delete-account", json: [:]) { [weak self] _, err in
            if let e = err { done("注销失败：\(e)"); return }
            self?.signOut()
            done(nil)
        }
    }

    /// Zip everything OrdCat keeps on this Mac into ~/Downloads.
    func exportData() -> URL? {
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmm"
        let out = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrdCat-数据-\(df.string(from: Date())).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", dir.path, out.path]
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        return p.terminationStatus == 0 ? out : nil
    }

    /// Remove all local data (chats, memory, X memory, profile, settings). The app restarts afterwards.
    func wipeLocalData() {
        try? FileManager.default.removeItem(at: dir)
        if let id = Bundle.main.bundleIdentifier { d.removePersistentDomain(forName: id) }
        for s in ["app.ordcat.session", "app.ordcat.apikey", "app.ordcat.ttskey", "app.ordcat.visionkey", "app.ordcat.sttkey",
                  "app.ordcat.license.x", "app.ordcat.license.agent"] {
            Keychain.set("", service: s)
        }
    }

    // MARK: HTTP

    /// Supabase REST / storage / functions call with the signed-in session (also used by 猫帮圈).
    func request(_ method: String, _ path: String, json: Any? = nil, raw: Data? = nil, contentType: String? = nil,
                         headers: [String: String] = [:], auth: Bool = true,
                         done: @escaping (Any?, String?) -> Void) {
        guard let base = baseURL, let anon = anonKey, let url = URL(string: base + path) else {
            DispatchQueue.main.async { done(nil, "账号服务还在开通中") }
            return
        }
        let go: () -> Void = { [weak self] in
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.timeoutInterval = 20
            req.setValue(anon, forHTTPHeaderField: "apikey")
            let token = auth ? (self?.session?.access ?? anon) : anon
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            if let j = json {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: j)
            } else if let r = raw {
                req.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
                req.httpBody = r
            }
            URLSession.shared.dataTask(with: req) { data, resp, error in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
                var err: String? = nil
                if let e = error { err = e.localizedDescription }
                else if code >= 300 {
                    let o = obj as? [String: Any]
                    err = (o?["msg"] as? String) ?? (o?["message"] as? String) ?? (o?["error_description"] as? String)
                        ?? (o?["error"] as? String) ?? "服务器返回 \(code)"
                    if let c = o?["code"] as? String, c == "23505" { err = "duplicate 23505" }
                }
                DispatchQueue.main.async { done(obj, err) }
            }.resume()
        }
        if auth && session != nil && !path.hasPrefix("/auth/") {
            withFreshSession { err in
                if let e = err { DispatchQueue.main.async { done(nil, e) } } else { go() }
            }
        } else {
            go()
        }
    }
}
