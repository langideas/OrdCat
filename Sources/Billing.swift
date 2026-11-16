// OrdCat — 订阅.
//
// Basic features (chat, voice, page share, desktop perception, memory) are free.
// Skills (设置 → 技能) are opened by subscription. Pricing and the checkout page come from config/remote.json:
//
//   "billing": {
//     "enabled": false,                       // false = 公测期: every skill is free
//     "trialDays": 7,
//     "skills": { "x": { "price": "¥39/月", "checkout": "https://…" } },
//     "validate": "https://api.lemonsqueezy.com/v1/licenses/validate"
//   }
//
// After paying, the buyer gets a 订阅码 (license key) by email and pastes it in 设置 → 技能.
// The key is checked against the validate endpoint (Lemon Squeezy's public license API by default),
// cached for offline use (3-day grace), and kept in the Keychain.

import Cocoa

enum Billing {
    private static let d = UserDefaults.standard
    static let defaultPrice = "¥39/月"

    // MARK: remote settings

    static func applyRemote(_ obj: [String: Any]?) {
        guard let b = obj else { return }
        d.set(b["enabled"] as? Bool ?? false, forKey: "billing.enabled")
        d.set(b["trialDays"] as? Int ?? 7, forKey: "billing.trialDays")
        if let v = b["validate"] as? String { d.set(v, forKey: "billing.validate") }
        if let skills = b["skills"] as? [String: [String: Any]] {
            for (id, s) in skills {
                if let p = s["price"] as? String { d.set(p, forKey: "billing.price.\(id)") }
                if let c = s["checkout"] as? String, !c.isEmpty { d.set(c, forKey: "billing.checkout.\(id)") }
                else { d.removeObject(forKey: "billing.checkout.\(id)") }
            }
        }
    }

    static var enabled: Bool { d.bool(forKey: "billing.enabled") }
    static var trialDays: Int { (d.object(forKey: "billing.trialDays") as? Int) ?? 7 }
    static func price(_ id: String) -> String { d.string(forKey: "billing.price.\(id)") ?? defaultPrice }
    static func checkoutURL(_ id: String) -> URL? { d.string(forKey: "billing.checkout.\(id)").flatMap(URL.init(string:)) }
    private static var validateURL: URL {
        URL(string: d.string(forKey: "billing.validate") ?? "https://api.lemonsqueezy.com/v1/licenses/validate")!
    }

    // MARK: state

    /// When the free trial of a skill started (set the first time it is switched on while billing is live).
    static func trialStart(_ id: String) -> Date? { d.object(forKey: "billing.trial.\(id)") as? Date }
    static func trialLeft(_ id: String) -> Int {
        guard let s = trialStart(id) else { return trialDays }
        let used = Int(Date().timeIntervalSince(s) / 86400)
        return max(0, trialDays - used)
    }
    static func startTrialIfNeeded(_ id: String) {
        if enabled && trialStart(id) == nil { d.set(Date(), forKey: "billing.trial.\(id)") }
    }

    /// Paid until (from the last successful license check).
    static func paidUntil(_ id: String) -> Date? { d.object(forKey: "billing.paidUntil.\(id)") as? Date }
    static func licenseKey(_ id: String) -> String { Keychain.get(service: "app.ordcat.license.\(id)") }

    static func isSubscribed(_ id: String) -> Bool {
        guard let u = paidUntil(id) else { return false }
        return u > Date()
    }

    /// Can this skill run right now?
    static func isUnlocked(_ id: String) -> Bool {
        if !enabled { return true }                 // 公测期免费
        if isSubscribed(id) { return true }
        if trialStart(id) != nil && trialLeft(id) > 0 { return true }
        return false
    }

    static func statusLine(_ id: String) -> String {
        if !enabled { return "公测期免费（正式开启后 \(price(id))）" }
        if isSubscribed(id) {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            return "✅ 已订阅（有效期到 \(df.string(from: paidUntil(id)!))）"
        }
        if trialStart(id) != nil {
            return trialLeft(id) > 0 ? "免费试用中，还剩 \(trialLeft(id)) 天 · \(price(id))" : "🔒 试用已结束 · \(price(id))"
        }
        return "🔒 \(price(id)) · 可免费试用 \(trialDays) 天"
    }

    // MARK: license

    /// Check a 订阅码. Calls back on the main thread with an error message, or nil when it is valid.
    static func activate(_ id: String, key raw: String, done: @escaping (String?) -> Void) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { done("订阅码是空的"); return }
        validate(key) { ok, until, err in
            if ok {
                Keychain.set(key, service: "app.ordcat.license.\(id)")
                d.set(until, forKey: "billing.paidUntil.\(id)")
                done(nil)
            } else {
                done(err ?? "这个订阅码无效或已过期")
            }
        }
    }

    /// Re-check a saved key (once a day). Keeps a 3-day grace period when offline.
    static func refresh(_ id: String) {
        let key = licenseKey(id)
        guard !key.isEmpty else { return }
        let last = d.object(forKey: "billing.checked.\(id)") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86400 else { return }
        validate(key) { ok, until, err in
            if ok { d.set(until, forKey: "billing.paidUntil.\(id)"); d.set(Date(), forKey: "billing.checked.\(id)") }
            else if err == nil { d.removeObject(forKey: "billing.paidUntil.\(id)") }   // the shop says: not valid any more
        }
    }

    private static func validate(_ key: String, done: @escaping (Bool, Date, String?) -> Void) {
        var req = URLRequest(url: validateURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let enc = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        req.httpBody = "license_key=\(enc)".data(using: .utf8)
        URLSession.shared.dataTask(with: req) { data, resp, error in
            let grace = Date().addingTimeInterval(3 * 86400)
            guard error == nil, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { done(false, grace, "连不上订阅服务器，稍后再试") }
                return
            }
            let valid = obj["valid"] as? Bool ?? false
            let lk = obj["license_key"] as? [String: Any]
            let status = lk?["status"] as? String ?? ""
            var until = Date().addingTimeInterval(32 * 86400)
            if let e = lk?["expires_at"] as? String, let dt = ISO8601DateFormatter().date(from: e) { until = dt }
            let ok = valid && status != "expired" && status != "disabled"
            let msg: String? = ok ? nil : (obj["error"] as? String).map { "订阅码无效：\($0)" }
            DispatchQueue.main.async { done(ok, until, msg) }
        }.resume()
    }

    // MARK: UI

    /// The subscribe sheet: trial / pay / paste a code.
    static func showSubscribe(_ id: String, name: String, onChange: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = "订阅「\(name)」· \(price(id))"
        var info = "基础功能（聊天、语音、分享页面、桌面感知、记忆）一直免费；技能按订阅开启。\n\n"
        info += statusLine(id)
        info += "\n\n付款后你会收到一个订阅码，粘贴到下面就能开启。"
        a.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "粘贴订阅码"
        field.stringValue = licenseKey(id)
        a.accessoryView = field
        a.addButton(withTitle: "激活订阅码")
        a.addButton(withTitle: checkoutURL(id) == nil ? "付款（即将开放）" : "去付款")
        let canTrial = trialStart(id) == nil
        if canTrial { a.addButton(withTitle: "免费试用 \(trialDays) 天") }
        a.addButton(withTitle: "取消")
        let r = a.runModal()
        switch r {
        case .alertFirstButtonReturn:
            activate(id, key: field.stringValue) { err in
                let b = NSAlert()
                b.messageText = err == nil ? "✅ 订阅已开启" : "没能激活"
                b.informativeText = err ?? statusLine(id)
                b.runModal()
                onChange()
            }
        case .alertSecondButtonReturn:
            if let u = checkoutURL(id) { NSWorkspace.shared.open(u) }
            else {
                let b = NSAlert()
                b.messageText = "付款页面还在准备中"
                b.informativeText = "现在是公测期，技能可以免费用。"
                b.runModal()
            }
        case .alertThirdButtonReturn where canTrial:
            d.set(Date(), forKey: "billing.trial.\(id)")
            onChange()
        default: break
        }
    }
}
