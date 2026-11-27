// OrdCat · Kündigungsbutton (BGB §312k) und Widerrufsfunktion (BGB §356a) für ordcat.de.
// ordcat.de/kuendigen.html und ordcat.de/widerruf.html rufen ohne Login auf:
//   POST /functions/v1/cancel-contract
//   Kündigung: {"action":"cancel","kind":"ordinary"|"extraordinary","reason":"…","email":"…",
//               "contract":"pro"|"max"|"x"|"agent"|"miao"|"all","date":"YYYY-MM-DD"|null,"lang":"de"|"zh"|"en"}
//   Widerruf:  {"action":"withdraw","name":"…","email":"…","contract":"pro"|…|"fish"|"topup"|"other",
//               "note":"Bestellt am …","lang":"de"|"zh"|"en"}
// Antwort: {"ok":true,"id","received_at","received_utc","received_berlin","summary":{…},"email_sent"}
// Die Seite zeigt die Bestätigung an; die Mail (Resend) geht sofort an die angegebene Adresse.
// Bewusst KEINE Angabe auf der Seite, ob zu der E-Mail ein Konto oder Abo existiert (sonst könnte man Adressen abfragen);
// Ende-Datum und Abo-Details stehen nur in der Mail an diese Adresse.
//
// Kündigung: Stripe-Abos der Person bekommen cancel_at_period_end = true (passender Vertrag, bei "all" alle),
//            mit Fisch bezahlte Mitgliedschaften/Skills bekommen auto_renew = false.
//            Außerordentlich oder Wunschdatum nach Periodenende → zusätzlich status = manual (Lang prüft).
// Widerruf:  wird nur gespeichert und bestätigt (status = manual); Erstattung macht Lang von Hand in Stripe.
//
// Deploy: supabase functions deploy cancel-contract --no-verify-jwt
// Secrets: RESEND_API_KEY=re_… (optional; ohne wird gespeichert und bestätigt, aber keine Mail geschickt)
//          STRIPE_SECRET_KEY, STRIPE_PRICES (schon gesetzt für stripe-checkout / stripe-webhook)
//          CANCEL_MAIL_FROM (optional, Standard "OrdCat <noreply@ordcat.de>"), CANCEL_MAIL_BCC (optional, Kopie an Lang)
// SQL: cancel.sql (nach fish.sql / raids.sql).
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

type Lang = "de" | "zh" | "en";
type Item = "pro" | "max" | "x" | "agent" | "miao";
const ITEMS: Item[] = ["pro", "max", "x", "agent", "miao"];
const CANCEL_CONTRACTS = [...ITEMS, "all"];
const WITHDRAW_CONTRACTS = [...ITEMS, "fish", "topup", "other"];
const LIVE = ["active", "trialing", "past_due", "unpaid"];

const NAMES: Record<string, Record<Lang, string>> = {
  pro: { de: "OrdCat Pro", zh: "OrdCat Pro 会员", en: "OrdCat Pro" },
  max: { de: "OrdCat Max", zh: "OrdCat Max 会员", en: "OrdCat Max" },
  x: { de: "Skill „X Companion“", zh: "技能「喵推」(X Companion)", en: "X Companion skill" },
  agent: { de: "Skill „Mac Agent“", zh: "技能「喵手」(Mac Agent)", en: "Mac Agent skill" },
  miao: { de: "Skill „Live Subtitles“", zh: "技能「喵传」(Live Subtitles)", en: "Live Subtitles skill" },
  all: { de: "Alle Verträge", zh: "全部合同", en: "All contracts" },
  fish: { de: "Trockenfisch-Paket", zh: "小鱼干充值包", en: "Dried Fish pack" },
  topup: { de: "Nachrichten-Aufladung (Top-up)", zh: "加油包", en: "Message top-up" },
  other: { de: "Sonstiges (siehe Angaben)", zh: "其他（见说明）", en: "Other (see details)" },
};

// ---------- small helpers ----------
const clip = (v: unknown, n: number) => String(v ?? "").trim().slice(0, n);
const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
const EMAIL_RE = /^[^\s@<>()",;:]{1,64}@[^\s@<>()",;:]+\.[^\s@<>()",;:]{2,}$/;

async function sha256(s: string) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function fmt(d: Date, tz: string, lang: Lang) {
  const loc = lang === "zh" ? "zh-CN" : lang === "en" ? "en-GB" : "de-DE";
  return new Intl.DateTimeFormat(loc, {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
    hour12: false, timeZoneName: "short",
  }).format(d);
}
function fmtDate(d: Date, lang: Lang) {
  const loc = lang === "zh" ? "zh-CN" : lang === "en" ? "en-GB" : "de-DE";
  return new Intl.DateTimeFormat(loc, { timeZone: "Europe/Berlin", year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}

// In-memory limiter (per isolate) in front of the DB check.
const hits = new Map<string, number[]>();
function memLimited(key: string, max: number, windowMs: number) {
  const now = Date.now();
  const arr = (hits.get(key) ?? []).filter((t) => now - t < windowMs);
  arr.push(now);
  hits.set(key, arr);
  if (hits.size > 5000) hits.clear();
  return arr.length > max;
}

async function stripe(method: "GET" | "POST", path: string, params?: Record<string, string>) {
  const key = Deno.env.get("STRIPE_SECRET_KEY");
  if (!key) throw new Error("STRIPE_SECRET_KEY missing");
  const r = await fetch("https://api.stripe.com/v1/" + path, {
    method,
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/x-www-form-urlencoded" },
    body: method === "POST" ? new URLSearchParams(params ?? {}) : undefined,
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j?.error?.message ?? `Stripe ${r.status}`);
  return j;
}

type Hit = { id: string; item: string; provider: string; ends_at: string | null; action: string };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ ok: false, error: "method" }, 405);

  let b: any = {};
  try { b = await req.json(); } catch { return json({ ok: false, error: "bad_json" }, 400); }

  // ---------- validate ----------
  const lang: Lang = b.lang === "zh" ? "zh" : b.lang === "en" ? "en" : "de";
  const action = b.action === "withdraw" ? "withdraw" : "cancel";
  const email = clip(b.email, 254).toLowerCase();
  const contract = clip(b.contract, 10);
  const kind = action === "cancel" && b.kind === "extraordinary" ? "extraordinary" : "ordinary";
  const reason = clip(b.reason, 2000) || null;
  const name = clip(b.name, 200) || null;
  const note = clip(b.note, 500) || null;
  let date: string | null = null;
  const errs: string[] = [];
  if (clip(b.website, 200)) errs.push("spam");                                   // honeypot field
  if (!EMAIL_RE.test(email)) errs.push("email");
  if (!(action === "cancel" ? CANCEL_CONTRACTS : WITHDRAW_CONTRACTS).includes(contract)) errs.push("contract");
  if (action === "cancel" && kind === "extraordinary" && !reason) errs.push("reason");
  if (action === "withdraw" && !name) errs.push("name");
  if (action === "cancel" && b.date) {
    const s = clip(b.date, 10);
    const d = new Date(s + "T00:00:00Z");
    if (!/^\d{4}-\d{2}-\d{2}$/.test(s) || isNaN(d.getTime())) errs.push("date");
    else if (d.getTime() > Date.now() + 5 * 366 * 86400e3) errs.push("date");
    else if (d.getTime() >= Date.now() - 86400e3) date = s;                    // a past date = earliest possible
  }
  if (errs.length) return json({ ok: false, error: "invalid", fields: errs }, 400);

  // ---------- rate limit ----------
  const ip = (req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for") ?? req.headers.get("x-real-ip") ?? "")
    .split(",")[0].trim();
  const ipHash = await sha256("ordcat-cancel:" + ip);
  if (memLimited(ipHash, 8, 3600e3)) return json({ ok: false, error: "rate_limited" }, 429);

  const url = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: recent } = await admin.rpc("cancel_recent", { p_ip_hash: ipHash, p_email: email });
  if (recent && (Number(recent.ip) >= 8 || Number(recent.email) >= 5)) return json({ ok: false, error: "rate_limited" }, 429);

  // ---------- store first (the declaration counts from here) ----------
  const { data: row, error: insErr } = await admin.from("cancel_requests").insert({
    action, kind, reason, email, name, contract, contract_note: note, requested_date: date, lang, ip_hash: ipHash,
  }).select("id, received_at").single();
  if (insErr || !row) return json({ ok: false, error: "store_failed" }, 500);
  const received = new Date(row.received_at);

  // ---------- act on subscriptions (Kündigung only) ----------
  const hitsOut: Hit[] = [];
  let status: "done" | "manual" | "no_match" | "error" = action === "withdraw" ? "manual" : "no_match";
  let userId: string | null = null;
  try {
    const { data: uid } = await admin.rpc("cancel_find_user", { p_email: email });
    userId = (uid as string | null) ?? null;
    if (action === "cancel") {
      const want = (item: string) => contract === "all" || item === contract;
      const wantDate = date ? new Date(date + "T23:59:59Z") : null;
      const prices: Record<string, string> = JSON.parse(Deno.env.get("STRIPE_PRICES") ?? "{}");
      const itemOfPrice = (id: string) => Object.entries(prices).find(([, v]) => v === id)?.[0]?.split(".")[0];
      const seen = new Set<string>();
      let manual = kind === "extraordinary";
      let failed = false;

      // Stripe subscriptions: those saved for this account + those of Stripe customers with this email.
      const stripeIds = new Set<string>();
      if (userId) {
        const { data: subs } = await admin.from("subscriptions").select("id, skill, status, provider, ends_at, renews_at, auto_renew")
          .eq("user_id", userId);
        for (const s of subs ?? []) {
          if (!want(String(s.skill)) || !ITEMS.includes(s.skill as Item)) continue;
          if (s.provider === "stripe" && LIVE.includes(String(s.status))) stripeIds.add(String(s.id));
          if (s.provider === "fish" && (s.auto_renew || (s.ends_at && new Date(s.ends_at) > new Date()))) {
            seen.add(String(s.id));
            if (s.auto_renew) {
              const { error } = await admin.from("subscriptions")
                .update({ auto_renew: false, renews_at: null, updated_at: new Date().toISOString() }).eq("id", s.id);
              if (error) failed = true;
            }
            if (wantDate && s.ends_at && wantDate > new Date(s.ends_at)) manual = true;
            hitsOut.push({ id: String(s.id), item: String(s.skill), provider: "fish", ends_at: s.ends_at ?? null, action: "auto_renew_off" });
          }
        }
      }
      if (Deno.env.get("STRIPE_SECRET_KEY")) {
        try {
          const cs = await stripe("GET", `customers?email=${encodeURIComponent(email)}&limit=10`);
          for (const c of cs.data ?? []) {
            const ss = await stripe("GET", `subscriptions?customer=${encodeURIComponent(c.id)}&status=all&limit=100`);
            for (const s of ss.data ?? []) if (LIVE.includes(s.status)) stripeIds.add(s.id);
          }
        } catch (_) { failed = true; }
        for (const id of stripeIds) {
          if (seen.has(id)) continue;
          seen.add(id);
          try {
            let sub = await stripe("GET", `subscriptions/${encodeURIComponent(id)}`);
            const it = sub.items?.data?.[0];
            const item = String(sub.metadata?.item ?? itemOfPrice(it?.price?.id ?? "") ?? "");
            if (!want(item) || !LIVE.includes(sub.status)) continue;
            const end = sub.current_period_end ?? it?.current_period_end ?? null;
            const endDate = end ? new Date(end * 1000) : null;
            let act = "already_cancelling";
            if (wantDate && endDate && wantDate > endDate) {
              // Wunschtermin liegt nach dem laufenden Zeitraum: nicht automatisch, Lang setzt cancel_at von Hand.
              manual = true;
              act = "manual_later_date";
            } else if (!sub.cancel_at_period_end && !sub.cancel_at) {
              sub = await stripe("POST", `subscriptions/${encodeURIComponent(id)}`, {
                cancel_at_period_end: "true",
                "metadata[cancel_request]": row.id,
              });
              act = "cancel_at_period_end";
            }
            const endsAt = sub.cancel_at ? new Date(sub.cancel_at * 1000) : endDate;
            hitsOut.push({ id, item, provider: "stripe", ends_at: endsAt ? endsAt.toISOString() : null, action: act });
          } catch (_) { failed = true; }
        }
      } else if (stripeIds.size) {
        failed = true;
      }
      status = failed ? "error" : hitsOut.length === 0 ? "no_match" : manual ? "manual" : "done";
    }
  } catch (_) {
    status = "error";
  }

  const ends = hitsOut.map((h) => h.ends_at).filter(Boolean).sort() as string[];
  const effectiveAt = ends.length ? ends[ends.length - 1] : null;

  // ---------- confirmation e-mail ----------
  const receivedUtc = fmt(received, "UTC", lang);
  const receivedBerlin = fmt(received, "Europe/Berlin", lang);
  const summary = {
    action, kind, reason, email, name, contract, contract_name: NAMES[contract]?.[lang] ?? contract, note,
    date: date ?? null,
  };
  let emailSent = false;
  let emailError: string | null = null;
  const key = Deno.env.get("RESEND_API_KEY");
  if (key) {
    try {
      const m = mail(lang, { ...summary, id: row.id, received, hits: hitsOut, status });
      const bcc = Deno.env.get("CANCEL_MAIL_BCC");
      const r = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          from: Deno.env.get("CANCEL_MAIL_FROM") ?? "OrdCat <noreply@ordcat.de>",
          to: [email], ...(bcc ? { bcc: [bcc] } : {}), reply_to: "support@ordcat.de",
          subject: m.subject, html: m.html, text: m.text,
        }),
      });
      emailSent = r.ok;
      if (!r.ok) emailError = clip(await r.text(), 300);
    } catch (e) { emailError = clip((e as Error).message, 300); }
  } else emailError = "RESEND_API_KEY missing";

  await admin.from("cancel_requests").update({
    user_id: userId, status, matched: hitsOut, effective_at: effectiveAt, email_sent: emailSent, email_error: emailError,
  }).eq("id", row.id);

  return json({
    ok: true, id: row.id, received_at: received.toISOString(), received_utc: receivedUtc, received_berlin: receivedBerlin,
    summary, email_sent: emailSent,
  });
});

// ---------- mail text (DE always, plus zh / en) ----------
type MailIn = {
  action: string; kind: string; reason: string | null; email: string; name: string | null; contract: string;
  note: string | null; date: string | null; id: string; received: Date; hits: Hit[]; status: string;
};

function block(l: Lang, m: MailIn): string[] {
  const W = m.action === "withdraw";
  const T = {
    de: {
      head: W ? "Eingangsbestätigung Ihres Widerrufs" : "Eingangsbestätigung Ihrer Kündigung",
      intro: W
        ? "wir haben Ihre Widerrufserklärung erhalten. Inhalt Ihrer Erklärung:"
        : "wir haben Ihre Kündigung erhalten. Inhalt Ihrer Kündigung:",
      type: "Art", ord: "ordentliche Kündigung", ext: "außerordentliche Kündigung", wd: "Widerruf",
      reason: "Grund", name: "Name", mail: "E-Mail-Adresse", contract: "Vertrag", note: "Angaben zum Vertrag",
      when: "Gewünschter Zeitpunkt", earliest: "zum nächstmöglichen Zeitpunkt", recv: "Eingang", ref: "Vorgangsnummer",
      end: (n: string, d: string) => `${n}: endet zum ${d}. Bis dahin können Sie den Vertrag weiter nutzen; es erfolgt keine weitere Verlängerung.`,
      endFish: (n: string, d: string) => `${n} (mit Trockenfisch bezahlt): automatische Verlängerung ist ausgeschaltet, läuft bis ${d}.`,
      later: (n: string) => `${n}: Ihr Wunschtermin liegt nach dem Ende des laufenden Zeitraums; wir setzen die Kündigung zu diesem Termin manuell und bestätigen sie gesondert.`,
      ext2: "Ihre außerordentliche Kündigung prüfen wir und melden uns zeitnah. Eine weitere Verlängerung ist bereits gestoppt.",
      none: "Zu dieser E-Mail-Adresse haben wir automatisch keinen laufenden Vertrag gefunden. Wir prüfen Ihre Kündigung manuell und melden uns. Falls Sie mit einer anderen E-Mail-Adresse bezahlt haben, antworten Sie bitte auf diese E-Mail.",
      err: "Bei der automatischen Verarbeitung ist ein Fehler aufgetreten. Ihre Kündigung ist trotzdem wirksam eingegangen; wir bearbeiten sie manuell und bestätigen das Vertragsende gesondert.",
      wd2: "Wir bearbeiten Ihren Widerruf und erstatten Zahlungen gemäß unserer Widerrufsbelehrung (https://ordcat.de/widerruf.html) über dasselbe Zahlungsmittel. Bei bereits begonnenen Dienstleistungen ist ggf. ein anteiliger Betrag für die genutzte Zeit zu zahlen.",
      undo: "Sie haben das nicht veranlasst? Dann antworten Sie bitte auf diese E-Mail.",
    },
    zh: {
      head: W ? "撤回申请已收到" : "取消合同申请已收到",
      intro: W ? "我们已经收到你的撤回声明，内容如下：" : "我们已经收到你的取消申请，内容如下：",
      type: "类型", ord: "正常取消（ordentlich）", ext: "特别解约（außerordentlich）", wd: "撤回（Widerruf）",
      reason: "理由", name: "姓名", mail: "邮箱", contract: "合同", note: "合同说明",
      when: "希望生效时间", earliest: "最早可生效的时间", recv: "收到时间", ref: "编号",
      end: (n: string, d: string) => `${n}：将于 ${d} 结束，在此之前照常使用，不会再自动续费。`,
      endFish: (n: string, d: string) => `${n}（小鱼干开通）：已关闭自动续费，可用到 ${d}。`,
      later: (n: string) => `${n}：你选的日期在当前周期结束之后，我们会手动按这个日期取消，并另行确认。`,
      ext2: "特别解约我们会人工审核并尽快回复；自动续费已经停止。",
      none: "这个邮箱下我们没有自动找到正在生效的合同。我们会人工核实并回复你。如果付款时用的是别的邮箱，请直接回复这封邮件。",
      err: "自动处理时出了点问题，但你的取消申请已经有效送达；我们会人工处理，并另行确认合同结束日期。",
      wd2: "我们会处理你的撤回，并按撤回说明（https://ordcat.de/widerruf.html）原路退款。已开始提供的服务，可能需要按已使用天数支付相应费用。",
      undo: "如果不是你本人操作，请直接回复这封邮件。",
    },
    en: {
      head: W ? "We received your withdrawal" : "We received your cancellation",
      intro: W ? "we have received your notice of withdrawal. Its content:" : "we have received your cancellation. Its content:",
      type: "Type", ord: "ordinary cancellation", ext: "extraordinary termination", wd: "withdrawal",
      reason: "Reason", name: "Name", mail: "Email", contract: "Contract", note: "Contract details",
      when: "Requested date", earliest: "earliest possible date", recv: "Received", ref: "Reference",
      end: (n: string, d: string) => `${n}: ends on ${d}. You can keep using it until then; it will not renew.`,
      endFish: (n: string, d: string) => `${n} (paid with Dried Fish): auto-renewal is off, runs until ${d}.`,
      later: (n: string) => `${n}: your requested date is after the current period ends; we will set the cancellation for that date manually and confirm separately.`,
      ext2: "We will review your extraordinary termination and get back to you shortly. Renewal has already been stopped.",
      none: "We could not automatically find an active contract for this email address. We will check your cancellation manually and get back to you. If you paid with a different email address, please reply to this email.",
      err: "Something went wrong while processing automatically. Your cancellation has still been received; we will handle it manually and confirm the end date separately.",
      wd2: "We will process your withdrawal and refund payments to the original payment method as described in our withdrawal information (https://ordcat.de/widerruf.html). For services that had already started, a pro-rata amount for the time used may be due.",
      undo: "Didn't request this? Please reply to this email.",
    },
  }[l];
  const nm = (c: string) => NAMES[c]?.[l] ?? c;
  const out: string[] = [T.head, "", T.intro];
  out.push(`${T.type}: ${W ? T.wd : m.kind === "extraordinary" ? T.ext : T.ord}`);
  if (m.reason) out.push(`${T.reason}: ${m.reason}`);
  if (m.name) out.push(`${T.name}: ${m.name}`);
  out.push(`${T.mail}: ${m.email}`);
  out.push(`${T.contract}: ${nm(m.contract)}`);
  if (m.note) out.push(`${T.note}: ${m.note}`);
  if (!W) out.push(`${T.when}: ${m.date ? fmtDate(new Date(m.date + "T12:00:00Z"), l) : T.earliest}`);
  out.push(`${T.recv}: ${fmt(m.received, "Europe/Berlin", l)} (Europe/Berlin) · ${fmt(m.received, "UTC", l)}`);
  out.push(`${T.ref}: ${m.id}`, "");
  if (W) out.push(T.wd2);
  else if (m.status === "error") out.push(T.err);
  else if (!m.hits.length) out.push(T.none);
  else {
    for (const h of m.hits) {
      const d = h.ends_at ? fmtDate(new Date(h.ends_at), l) : "—";
      if (h.action === "manual_later_date") out.push(T.later(nm(h.item)));
      else if (h.provider === "fish") out.push(T.endFish(nm(h.item), d));
      else out.push(T.end(nm(h.item), d));
    }
    if (m.kind === "extraordinary") out.push(T.ext2);
  }
  out.push("", T.undo);
  return out;
}

const GREET: Record<Lang, string> = { de: "Guten Tag,", zh: "你好，", en: "Hello," };

function mail(lang: Lang, m: MailIn) {
  const de = block("de", m);
  const other = lang === "de" ? [] : block(lang, m);
  const foot = [
    "OrdCat · Axun Conor · Hedemannstraße 74 · 78355 Hohenfels · Deutschland · support@ordcat.de",
  ];
  const textParts = lang === "de"
    ? [["Guten Tag,", ...de.slice(2)].join("\n")]
    : [[GREET[lang], ...other.slice(2)].join("\n"), "— Deutsche Fassung (maßgeblich) —\n" + ["Guten Tag,", ...de.slice(2)].join("\n")];
  const text = textParts.join("\n\n") + "\n\n" + foot.join("\n");
  const para = (lines: string[]) =>
    `<p style="margin:0 0 14px">${lines.map(esc).join("<br>").replace(/(<br>){2,}/g, "</p><p style=\"margin:0 0 14px\">")}</p>`;
  const html = `<!doctype html><html><body style="font:15px/1.6 -apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif;color:#18181c;max-width:620px;margin:0 auto;padding:24px">
<h2 style="margin:0 0 16px;color:#c98400">${esc(lang === "de" ? de[0] : other[0])}</h2>
${lang === "de" ? para(["Guten Tag,", ...de.slice(2)]) : para([GREET[lang], ...other.slice(2)]) + `<hr style="border:0;border-top:1px solid #e6e3dc;margin:24px 0"><h3 style="margin:0 0 12px">${esc(de[0])} (Deutsche Fassung, maßgeblich)</h3>` + para(["Guten Tag,", ...de.slice(2)])}
<p style="color:#5f6270;font-size:12px;margin-top:28px">${esc(foot[0])}</p></body></html>`;
  const subject = lang === "de" ? `${de[0]} · OrdCat` : `${other[0]} · ${de[0]} · OrdCat`;
  return { subject, html, text };
}
