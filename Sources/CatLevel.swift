// OrdCat — 小猫等级（像 QQ 等级，按活跃天数点亮，没有上限）+ 订阅会员徽章。
//
// 陪伴天数 = 在线时长累计（Lang 2026-11-23）：OrdCat 运行满 24 小时算 1 天（可以分多次累计）。
// 本机每分钟记一次；登录后每 5 分钟发一次心跳到云端（supabase/account2.sql → cat_heartbeat），
// 服务器只按两次心跳之间的真实时间累计（每次最多 10 分钟），防止作弊。登录时显示云端的天数。
//
// 升到 Lv N 需要 N*N + 4*N 天（Lv1 = 5 天）。图标：星芒 = 1 级，猫瞳 = 4，猫眼 = 16，猫冠 = 64。
// 例：Lv89 = 1 猫冠 + 1 猫眼 + 2 猫瞳 + 1 星芒。图标照 brand/rank/rank-*.svg 用代码画（64×64，琥珀色 #FFB547，柔光）。

import Cocoa

extension Prefs {
    /// Days on which the user interacted with the cat at least once (this Mac).
    static var catActiveCount: Int { get { d.integer(forKey: "catActiveCount") } set { d.set(newValue, forKey: "catActiveCount") } }
    static var catLastActive: String { get { d.string(forKey: "catLastActive") ?? "" } set { d.set(newValue, forKey: "catLastActive") } }
    /// Last known cloud stats of the signed-in account ("<uid>" → days).
    static var catCloudDays: Int? { get { d.object(forKey: "catCloudDays") as? Int } set { d.set(newValue, forKey: "catCloudDays") } }
    static var catCloudUser: String { get { d.string(forKey: "catCloudUser") ?? "" } set { d.set(newValue, forKey: "catCloudUser") } }
    static var catCloudSynced: String { get { d.string(forKey: "catCloudSynced") ?? "" } set { d.set(newValue, forKey: "catCloudSynced") } }
    /// Seconds OrdCat has been running on this Mac (all sessions added up). -1 = not started yet.
    static var catOnlineSeconds: Int { get { d.object(forKey: "catOnlineSeconds") as? Int ?? -1 } set { d.set(newValue, forKey: "catOnlineSeconds") } }
    /// Online seconds not yet sent to the server.
    static var catPendingSeconds: Int { get { d.integer(forKey: "catPendingSeconds") } set { d.set(newValue, forKey: "catPendingSeconds") } }
    static var catCloudSeconds: Int? { get { d.object(forKey: "catCloudSeconds") as? Int } set { d.set(newValue, forKey: "catCloudSeconds") } }
}

/// Level, 喵友 and membership of one user, as the server sees them.
struct CatStats {
    var userID: String = ""
    var days: Int = 0
    var level: Int = 0
    var followers: Int = 0
    var following: Int = 0
    var member: Bool = false
    var iFollow: Bool = false

    init() {}
    init?(_ o: Any?) {
        guard let r = o as? [String: Any] else { return nil }
        userID = r["user_id"] as? String ?? ""
        days = CatStats.int(r["days"])
        level = r["level"] == nil ? CatLevel.level(days: days) : CatStats.int(r["level"])
        followers = CatStats.int(r["followers"])
        following = CatStats.int(r["following"])
        member = r["member"] as? Bool ?? false
        iFollow = r["i_follow"] as? Bool ?? false
    }
    static func int(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }
}

final class CatLevel {
    static let shared = CatLevel()
    static let changed = Notification.Name("OrdCatLevelChanged")
    /// My own stats from the server (nil until loaded / not signed in).
    private(set) var mine: CatStats?
    private var touching = false

    private var acct: Account { Account.shared }
    private static var today: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: level math

    /// Days needed to reach level n: n*n + 4*n.
    static func daysFor(level n: Int) -> Int { n * n + 4 * n }
    /// Highest level reached with this many active days.
    static func level(days: Int) -> Int {
        guard days > 0 else { return 0 }
        var n = max(Int((Double(days + 4)).squareRoot()) - 2, 0)
        while daysFor(level: n + 1) <= days { n += 1 }
        while n > 0 && daysFor(level: n) > days { n -= 1 }
        return n
    }
    /// Level → icons, biggest first: (猫冠 64, 猫眼 16, 猫瞳 4, 星芒 1). Crowns have no upper limit.
    static func parts(level: Int) -> [(RankIcon, Int)] {
        var left = max(level, 0)
        var out: [(RankIcon, Int)] = []
        for r in RankIcon.allCases {
            let n = left / r.weight
            left -= n * r.weight
            if n > 0 { out.append((r, n)) }
        }
        return out
    }
    /// "1 猫冠 1 猫眼 2 猫瞳 1 星芒" (translated in English).
    static func partsText(level: Int) -> String {
        let p = parts(level: level)
        guard !p.isEmpty else { return L10n.t("还没点亮") }
        return p.map { "\($0.1) \(L10n.t($0.0.name))" }.joined(separator: " ")
    }

    // MARK: my days

    /// Days on this Mac: every full 24 hours OrdCat has been running.
    var localDays: Int { max(0, Prefs.catOnlineSeconds) / 86400 }
    /// What the app shows: the cloud count when signed in (that is what 信号站 checks), else this Mac's.
    var days: Int {
        if acct.signedIn, let uid = acct.profile.userID, Prefs.catCloudUser == uid, let c = Prefs.catCloudDays { return c }
        return localDays
    }
    /// Online seconds behind `days` (cloud when signed in).
    var onlineSeconds: Int {
        if acct.signedIn, let uid = acct.profile.userID, Prefs.catCloudUser == uid, let c = Prefs.catCloudSeconds { return c }
        return max(0, Prefs.catOnlineSeconds)
    }
    var level: Int { CatLevel.level(days: days) }
    var followers: Int { mine?.followers ?? 0 }

    /// Days still needed for the next level.
    var daysToNext: Int { max(0, CatLevel.daysFor(level: level + 1) - days) }
    /// Hours still needed to finish the current day.
    var hoursToNextDay: Int { Int(ceil(Double(86400 - onlineSeconds % 86400) / 3600)) }

    /// Any active subscription (account-bound or license key) → 订阅会员.
    /// 徽章只看会员 / 会员 Pro；技能只在技能栏用光圈区分点亮（Lang 2026-11-23）
    static var isMember: Bool { ["member", "pro"].contains { Billing.isSubscribed($0) } }

    // MARK: online clock

    private var clock: Timer?
    private var lastTick = Date()
    private var beating = false

    /// Start counting online time (once, at launch). Days from the old "active day" rule are kept.
    func startClock() {
        guard clock == nil else { return }
        if Prefs.catOnlineSeconds < 0 { Prefs.catOnlineSeconds = Prefs.catActiveCount * 86400 }
        lastTick = Date()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        clock = t
        // Sleep / wake: never count the time the Mac was asleep.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lastTick = Date()
        }
        beat()
    }

    private func tick() {
        let now = Date()
        let add = Int(min(max(now.timeIntervalSince(lastTick), 0), 90))   // a long gap = sleep, not online
        lastTick = now
        guard add > 0 else { return }
        let before = localDays
        Prefs.catOnlineSeconds = max(0, Prefs.catOnlineSeconds) + add
        Prefs.catPendingSeconds += add
        if localDays != before { NotificationCenter.default.post(name: CatLevel.changed, object: nil) }
        if Prefs.catPendingSeconds >= 300 { beat() }
    }

    /// Send the online time to the server (cat_heartbeat). Falls back quietly when the server isn't updated yet.
    private func beat() {
        guard acct.configured, acct.signedIn, let uid = acct.profile.userID, !beating else { return }
        beating = true
        let pending = min(Prefs.catPendingSeconds, 600)
        acct.request("POST", "/rest/v1/rpc/cat_heartbeat",
                     json: ["p_seconds": pending, "p_local_seconds": max(0, Prefs.catOnlineSeconds)]) { [weak self] obj, err in
            guard let self = self else { return }
            self.beating = false
            guard err == nil, let o = obj as? [String: Any] else { return }
            Prefs.catPendingSeconds = max(0, Prefs.catPendingSeconds - pending)
            let before = self.days
            Prefs.catCloudUser = uid
            Prefs.catCloudDays = CatStats.int(o["days"])
            Prefs.catCloudSeconds = CatStats.int(o["online_seconds"])
            if self.days != before { self.refresh() }
        }
    }

    /// Kept for callers from the old rule: interacting no longer adds days, it only makes sure the clock runs.
    func touch() { startClock() }

    /// Load my level / 喵友 / membership from the server (on launch and after sign-in).
    func refresh(_ done: (() -> Void)? = nil) {
        guard acct.configured, acct.signedIn, let uid = acct.profile.userID else {
            mine = nil
            NotificationCenter.default.post(name: CatLevel.changed, object: nil)
            done?(); return
        }
        beat()
        stats(of: nil) { [weak self] s, _ in
            if let s = s {
                self?.mine = s
                Prefs.catCloudUser = uid
                Prefs.catCloudDays = s.days
            }
            NotificationCenter.default.post(name: CatLevel.changed, object: nil)
            done?()
        }
    }

    func stats(of user: String?, done: @escaping (CatStats?, String?) -> Void) {
        var args: [String: Any] = [:]
        args["p_user"] = user ?? NSNull()
        acct.request("POST", "/rest/v1/rpc/cat_stats", json: args) { obj, err in
            done(CatStats(obj), err.map(SignalStation.friendly))
        }
    }
}

// MARK: - Rank icons (drawn from brand/rank/rank-*.svg, 64×64 box)

enum RankIcon: CaseIterable {
    case crown, eyes, pupil, star

    var weight: Int {
        switch self { case .crown: return 64; case .eyes: return 16; case .pupil: return 4; case .star: return 1 }
    }
    var name: String {
        switch self { case .crown: return "猫冠"; case .eyes: return "猫眼"; case .pupil: return "猫瞳"; case .star: return "星芒" }
    }

    /// The icon at `size` points, amber with a soft glow.
    func image(size: CGFloat, color: NSColor = kAmber, glow: Bool = true) -> NSImage {
        let kind = self
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let k = size / 64
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * k, y: y * k) }
            func capsule(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
                let r = min(w, h) / 2 * k
                NSBezierPath(roundedRect: NSRect(x: x * k, y: y * k, width: w * k, height: h * k), xRadius: r, yRadius: r).fill()
            }
            func dot(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
                NSBezierPath(ovalIn: NSRect(x: (cx - r) * k, y: (cy - r) * k, width: 2 * r * k, height: 2 * r * k)).fill()
            }
            NSGraphicsContext.current?.saveGraphicsState()
            if glow {
                let sh = NSShadow()
                sh.shadowColor = color.withAlphaComponent(0.8)
                sh.shadowBlurRadius = max(1, 4.4 * k)
                sh.shadowOffset = .zero
                sh.set()
            }
            color.setFill()
            color.setStroke()
            switch kind {
            case .star:
                let s = NSBezierPath()
                s.move(to: p(32, 10))
                s.curve(to: p(54, 32), controlPoint1: p(34, 26), controlPoint2: p(38, 30))
                s.curve(to: p(32, 54), controlPoint1: p(38, 34), controlPoint2: p(34, 38))
                s.curve(to: p(10, 32), controlPoint1: p(30, 38), controlPoint2: p(26, 34))
                s.curve(to: p(32, 10), controlPoint1: p(26, 30), controlPoint2: p(30, 26))
                s.close()
                s.fill()
            case .pupil:
                capsule(24, 12, 16, 40)
            case .eyes:
                capsule(14, 14, 13, 36)
                capsule(37, 14, 13, 36)
            case .crown:
                capsule(17, 24, 11, 30)
                capsule(36, 24, 11, 30)
                // Quadratic arc (10,20) → ctrl (32,2) → (54,20), written as a cubic.
                let a = NSBezierPath()
                a.move(to: p(10, 20))
                a.curve(to: p(54, 20), controlPoint1: p(10 + 2.0 / 3 * 22, 20 - 2.0 / 3 * 18), controlPoint2: p(54 - 2.0 / 3 * 22, 20 - 2.0 / 3 * 18))
                a.lineWidth = 3 * k
                a.lineCapStyle = .round
                a.stroke()
                dot(32, 8.5, 2.6)
                dot(18, 13, 1.8)
                dot(46, 13, 1.8)
            }
            NSGraphicsContext.current?.restoreGraphicsState()
            return true
        }
    }

    /// The whole level as one strip of icons; more than `maxRepeat` of one kind shows as "icon ×N".
    static func strip(level: Int, height h: CGFloat, maxRepeat: Int = 3) -> NSImage {
        let parts = CatLevel.parts(level: level)
        let font = NSFont.systemFont(ofSize: h * 0.62, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: kAmber]
        var items: [(NSImage?, String?)] = []
        if parts.isEmpty {
            items.append((RankIcon.star.image(size: h, color: NSColor.secondaryLabelColor.withAlphaComponent(0.5), glow: false), nil))
        }
        for (r, n) in parts {
            if n > maxRepeat { items.append((r.image(size: h), nil)); items.append((nil, "×\(n)")) }
            else { for _ in 0..<n { items.append((r.image(size: h), nil)) } }
        }
        let gap = h * 0.06
        var w: CGFloat = 0
        for it in items {
            if it.0 != nil { w += h * 0.86 + gap }
            if let s = it.1 { w += ceil((s as NSString).size(withAttributes: attrs).width) + gap * 2 }
        }
        w = max(ceil(w), 1)
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            var x: CGFloat = 0
            for it in items {
                if let img = it.0 {
                    // Icons have some empty margin in their 64 box: overlap them a little so the strip reads as one.
                    img.draw(in: NSRect(x: x - h * 0.07, y: 0, width: h, height: h))
                    x += h * 0.86 + gap
                }
                if let s = it.1 {
                    let sz = (s as NSString).size(withAttributes: attrs)
                    (s as NSString).draw(at: NSPoint(x: x + gap, y: (h - sz.height) / 2), withAttributes: attrs)
                    x += ceil(sz.width) + gap * 2
                }
            }
            return true
        }
    }
}

// MARK: - Avatars with the 订阅会员 badge

/// A round avatar. Members get an amber glowing ring and a small eyes chip (graphite circle, two amber capsules)
/// at the bottom-right. The result is drawn inside its own square, so don't round-clip the image view.
func memberAvatar(_ src: NSImage, member: Bool, size s: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let ring = member ? max(1.5, s * 0.045) : 0
        let inset = member ? ring + max(1.5, s * 0.04) : 0
        let face = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(ovalIn: face).addClip()
        let sz = src.size
        let scale = max(face.width / max(sz.width, 1), face.height / max(sz.height, 1))
        let w = sz.width * scale, h = sz.height * scale
        src.draw(in: NSRect(x: face.midX - w / 2, y: face.midY - h / 2, width: w, height: h))
        NSGraphicsContext.current?.restoreGraphicsState()
        guard member else { return true }
        NSGraphicsContext.current?.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = kAmber.withAlphaComponent(0.85)
        sh.shadowBlurRadius = max(2, s * 0.08)
        sh.shadowOffset = .zero
        sh.set()
        kAmber.setStroke()
        let r = NSBezierPath(ovalIn: NSRect(x: ring / 2 + 0.5, y: ring / 2 + 0.5, width: s - ring - 1, height: s - ring - 1))
        r.lineWidth = ring
        r.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
        // Eyes chip, bottom-right.
        let c = s * 0.34
        let chip = NSRect(x: s - c, y: 0, width: c, height: c)
        NSColor(calibratedRed: 0.24, green: 0.24, blue: 0.235, alpha: 1).setFill()
        NSBezierPath(ovalIn: chip).fill()
        NSColor.windowBackgroundColor.withAlphaComponent(0.9).setStroke()
        let edge = NSBezierPath(ovalIn: chip.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = max(1, s * 0.02)
        edge.stroke()
        kAmber.setFill()
        let ew = c * 0.16, eh = c * 0.40, gap = c * 0.14
        for x in [chip.midX - gap / 2 - ew, chip.midX + gap / 2] {
            NSBezierPath(roundedRect: NSRect(x: x, y: chip.midY - eh / 2, width: ew, height: eh), xRadius: ew / 2, yRadius: ew / 2).fill()
        }
        return true
    }
}

/// Small in-memory cache for other users' avatars (public storage links).
final class AvatarCache {
    static let shared = AvatarCache()
    private var cache: [String: NSImage] = [:]
    private var waiting: [String: [(NSImage?) -> Void]] = [:]

    /// The brand placeholder: graphite circle with the amber eyes.
    static func placeholder(_ size: CGFloat = 64) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSColor(calibratedRed: 0.24, green: 0.24, blue: 0.235, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
            let eyes = ordEyesImage(height: size * 0.34)
            eyes.draw(in: NSRect(x: (size - eyes.size.width) / 2, y: (size - eyes.size.height) / 2,
                                 width: eyes.size.width, height: eyes.size.height))
            return true
        }
    }

    func load(_ url: String?, done: @escaping (NSImage?) -> Void) {
        guard let s = url, !s.isEmpty, let u = URL(string: s) else { done(nil); return }
        if let img = cache[s] { done(img); return }
        if waiting[s] != nil { waiting[s]?.append(done); return }
        waiting[s] = [done]
        URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
            let img = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let i = img { self.cache[s] = i }
                let cbs = self.waiting.removeValue(forKey: s) ?? []
                cbs.forEach { $0(img) }
            }
        }.resume()
    }
}
