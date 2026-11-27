// OrdCat mail template (v0.2.64+): one dark/amber card for every transactional mail, styled like ordcat.de/thanks.html.
// Used by stripe-webhook (order confirmation, renewal receipt, payment failed, cancelled, unpaid-order reminder) and cancel-contract
// (Kündigung / Widerruf receipts). English only. Email-safe: table layout, inline styles + bgcolor, max 600px, no SVG,
// no web fonts required. The same spec renders the plain-text part, so HTML and text never drift apart.
// supabase functions deploy bundles this file with each function that imports it (folders starting with _ are not functions).

// Colours from site/legal.css (dark theme) + thanks.html; rgba() tints pre-mixed onto the card colour for Outlook.
export const C = {
  bg: "#0d0e14",
  card: "#161822",
  line: "#262938",
  fg: "#eceef5",
  mute: "#a4aabd",
  amber: "#f5b53d",
  onAmber: "#18181c",
  saveBg: "#282524",        // rgba(245,181,61,.08) on card
  badgeOk: "#3a3126",       // rgba(245,181,61,.16) on card
  badgeNo: "#2c2f3a",       // rgba(160,166,185,.16) on card
  ghost: "#3a3e52",
};
export const FONT = `-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif`;
const MONO = `ui-monospace,SFMono-Regular,Menlo,Consolas,'Liberation Mono',monospace`;

export const SELLER_NAME = "Axun Conor (OrdCat)";
export const SELLER_ADDR = "Hedemannstraße 74 · 78355 Hohenfels · Germany";
export const SUPPORT = "support@ordcat.de";
export const SELLER_LINE = `${SELLER_NAME} · ${SELLER_ADDR} · ${SUPPORT}`;

export const escH = (s: string) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

/** Escape, then turn bare https URLs and support@ordcat.de into links. */
export const linkify = (s: string, color: string = C.amber) =>
  escH(s)
    .replace(/https:\/\/[^\s<]+[^\s<.,;:)”"]/g, (u) => `<a href="${u}" style="color:${color};text-decoration:underline;word-break:break-word;overflow-wrap:anywhere">${u}</a>`)
    .replace(/(^|[\s(])(support@ordcat\.de)/g, `$1<a href="mailto:$2" style="color:${color};text-decoration:underline">$2</a>`);

// ---------- formatting (English, German time zone) ----------
export const money = (cents: number, cur: string) =>
  new Intl.NumberFormat("en-GB", { style: "currency", currency: (cur || "eur").toUpperCase() }).format(cents / 100);
/** 27 Nov 2026, 14:03 CET */
export const whenEn = (t: number) =>
  new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/Berlin", year: "numeric", month: "long", day: "numeric", hour: "2-digit", minute: "2-digit",
    hour12: false, timeZoneName: "short",
  }).format(new Date(t * 1000));
/** 27 November 2026 */
export const dayEn = (t: number) =>
  new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/Berlin", year: "numeric", month: "long", day: "numeric" })
    .format(new Date(t * 1000));

// ---------- spec ----------
export type Row = { k: string; v: string; sub?: string; mono?: boolean };
export type Button = { label: string; href: string; primary?: boolean };
export type Section = { title?: string; paras: string[]; links?: { label: string; href: string }[] };
export type MailSpec = {
  subject: string;
  preheader: string;                 // inbox preview line
  badge: "ok" | "wait" | "no";       // amber ✓ / amber ! / muted
  icon: string;                      // ✓ ! ✕ …
  title: string;
  subtitle?: string;
  greeting?: string;                 // "Hello,"
  intro?: string[];                  // plain text paragraphs above the amount/table
  amount?: { main: string; per?: string };
  rows?: Row[];
  save?: { html: string; text: string };   // dashed amber box (yearly saving)
  body?: Section[];                  // plain text paragraphs below the table (renewal terms, next steps)
  buttons?: Button[];
  legal?: Section[];                 // small muted section below the card
};

// Bulletproof-ish button: the colour sits on a bgcolor cell (Outlook drops <a> backgrounds); tables float left so they wrap on phones.
const btn = (b: Button) => {
  const bg = b.primary ? C.amber : C.card, bd = b.primary ? C.amber : C.ghost, fg = b.primary ? C.onAmber : C.fg;
  return `<table role="presentation" align="left" cellpadding="0" cellspacing="0" border="0" style="margin:0 8px 10px 0;border-collapse:separate"><tr>` +
    `<td bgcolor="${bg}" style="background:${bg};border:1px solid ${bd};border-radius:11px">` +
    `<a href="${escH(b.href)}" target="_blank" style="display:inline-block;padding:${b.primary ? "11px 20px" : "11px 18px"};color:${fg};font:${b.primary ? 700 : 600} 15px/1.25 ${FONT};text-decoration:none;border-radius:11px">${escH(b.label)}</a>` +
    `</td></tr></table>`;
};

const para = (s: string, size = 15, color = C.fg, mb = 12) =>
  `<p style="margin:0 0 ${mb}px;font:${size}px/1.6 ${FONT};color:${color}">${linkify(s)}</p>`;

function rowsHtml(rows: Row[]) {
  return rows.map((r, i) => {
    const v = r.mono
      ? `<span style="font:12px/1.5 ${MONO};color:${C.fg};word-break:break-all">${escH(r.v)}</span>`
      : `<span style="color:${C.fg}">${linkify(r.v, C.fg)}</span>`;
    const sub = r.sub ? `<br><span style="font-size:12.5px;color:${C.mute}">${escH(r.sub)}</span>` : "";
    const bt = i === 0 ? `border-top:1px solid ${C.line};` : "";
    return `<tr>
<td valign="top" width="38%" style="${bt}border-bottom:1px solid ${C.line};padding:10px 12px 10px 0;font:14px/1.5 ${FONT};color:${C.mute}">${escH(r.k)}</td>
<td valign="top" align="right" style="${bt}border-bottom:1px solid ${C.line};padding:10px 0;font:14.5px/1.5 ${FONT};color:${C.fg};text-align:right;word-break:break-word;overflow-wrap:anywhere">${v}${sub}</td>
</tr>`;
  }).join("\n");
}

function sectionHtml(s: Section, small: boolean) {
  const size = small ? 12.5 : 14.5, color = small ? C.mute : C.fg;
  const t = s.title
    ? `<p style="margin:0 0 6px;font:700 ${small ? 13 : 14.5}px/1.5 ${FONT};color:${small ? C.fg : C.amber}">${escH(s.title)}</p>`
    : "";
  const links = s.links?.length
    ? `<p style="margin:0 0 12px;font:${size}px/1.8 ${FONT};color:${color}">${
      s.links.map((l) => `<a href="${escH(l.href)}" target="_blank" style="color:${C.amber};text-decoration:underline">${escH(l.label)}</a>`).join(" &nbsp;·&nbsp; ")
    }</p>`
    : "";
  return t + s.paras.map((p) => para(p, size, color, small ? 8 : 12)).join("") + links;
}

/** Full HTML document. */
export function renderHtml(m: MailSpec, site = "https://ordcat.de"): string {
  const badgeBg = m.badge === "no" ? C.badgeNo : C.badgeOk;
  const badgeFg = m.badge === "no" ? C.mute : C.amber;
  const amount = m.amount
    ? `<tr><td class="oc-amt" style="padding:18px 0 4px;font:700 36px/1.15 ${FONT};color:${C.fg};letter-spacing:-0.5px">${escH(m.amount.main)}${
      m.amount.per ? `<span style="font:500 15px/1 ${FONT};color:${C.mute};letter-spacing:0"> /${escH(m.amount.per)}</span>` : ""
    }</td></tr>`
    : "";
  const intro = [m.greeting, ...(m.intro ?? [])].filter(Boolean) as string[];
  const introHtml = intro.length ? `<tr><td style="padding:18px 0 2px">${intro.map((p) => para(p, 15, C.fg, 10)).join("")}</td></tr>` : "";
  const rows = m.rows?.length
    ? `<tr><td style="padding:14px 0 4px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;table-layout:fixed">${rowsHtml(m.rows)}</table></td></tr>`
    : "";
  const save = m.save
    ? `<tr><td style="padding:14px 0 0"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate"><tr><td bgcolor="${C.saveBg}" style="background:${C.saveBg};border:1px dashed ${C.amber};border-radius:12px;padding:12px 14px;font:13.5px/1.55 ${FONT};color:${C.fg}">${m.save.html}</td></tr></table></td></tr>`
    : "";
  const body = m.body?.length ? `<tr><td style="padding:18px 0 0">${m.body.map((s) => sectionHtml(s, false)).join("")}</td></tr>` : "";
  const buttons = m.buttons?.length ? `<tr><td style="padding:10px 0 2px">${m.buttons.map(btn).join("\n")}</td></tr>` : "";
  const legal = m.legal?.length
    ? `<tr><td style="padding:22px 28px 4px">${m.legal.map((s) => sectionHtml(s, true)).join(`<div style="height:8px;line-height:8px;font-size:8px">&nbsp;</div>`)}</td></tr>`
    : "";
  const foot = [["Terms", "terms.html"], ["Withdrawal", "widerruf.html"], ["Cancel contracts", "kuendigen.html"], ["Imprint", "impressum.html"]]
    .map(([l, p]) => `<a href="${site}/${p}" target="_blank" style="color:${C.mute};text-decoration:underline">${l}</a>`).join(" &nbsp;·&nbsp; ");

  return `<!doctype html>
<html lang="en" xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="x-apple-disable-message-reformatting">
<meta name="color-scheme" content="dark">
<meta name="supported-color-schemes" content="dark">
<title>${escH(m.subject)}</title>
<style>
:root{color-scheme:dark;supported-color-schemes:dark}
body{margin:0!important;padding:0!important;background:${C.bg}}
a{color:${C.amber}}
@media (max-width:620px){.oc-pad{padding-left:18px!important;padding-right:18px!important}.oc-amt{font-size:30px!important}}
</style>
</head>
<body bgcolor="${C.bg}" style="margin:0;padding:0;background:${C.bg};color:${C.fg};-webkit-text-size-adjust:100%">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;mso-hide:all">${escH(m.preheader)}&#8199;&#847;&#8199;&#847;&#8199;&#847;&#8199;&#847;&#8199;&#847;&#8199;&#847;</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="${C.bg}" style="background:${C.bg}">
<tr><td align="center" style="padding:24px 12px 32px">
<!--[if mso]><table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0"><tr><td><![endif]-->
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;width:100%">
<tr><td class="oc-pad" style="padding:4px 28px 0">
  <a href="${site}/" target="_blank" style="text-decoration:none"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
  <td valign="middle" style="padding:0 10px 0 0"><img src="${site}/icon.png" width="34" height="34" alt="OrdCat" style="display:block;width:34px;height:34px;border:0;border-radius:9px"></td>
  <td valign="middle" style="font:600 23px/1 'Fredoka','Trebuchet MS',${FONT};color:${C.amber}">OrdCat</td>
  </tr></table></a>
</td></tr>
<tr><td style="padding:18px 0 0">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="${C.card}" style="background:${C.card};border:1px solid ${C.line};border-radius:20px;border-collapse:separate">
  <tr><td class="oc-pad" style="padding:28px 28px 22px">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse">
    <tr><td>
      <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
      <td valign="middle" width="44" style="width:44px"><div style="width:44px;height:44px;border-radius:22px;background:${badgeBg};color:${badgeFg};font:700 20px/44px ${FONT};mso-line-height-rule:exactly;text-align:center;overflow:hidden">${escH(m.icon)}</div></td>
      <td valign="middle" style="padding:0 0 0 14px">
        <div style="font:700 24px/1.3 ${FONT};color:${C.fg}">${escH(m.title)}</div>
        ${m.subtitle ? `<div style="font:13.5px/1.45 ${FONT};color:${C.mute};padding-top:2px">${escH(m.subtitle)}</div>` : ""}
      </td></tr></table>
    </td></tr>
    ${introHtml}${amount}${rows}${save}${body}${buttons}
    </table>
  </td></tr>
  </table>
</td></tr>
${legal}
<tr><td class="oc-pad" style="padding:18px 28px 0">
  <div style="border-top:1px solid ${C.line};padding-top:16px;font:12px/1.7 ${FONT};color:${C.mute}">
  ${escH(SELLER_NAME)} · ${escH(SELLER_ADDR)}<br>
  Questions? <a href="mailto:${SUPPORT}" style="color:${C.amber};text-decoration:underline">${SUPPORT}</a> — just reply to this email.<br>
  ${foot}
  </div>
</td></tr>
</table>
<!--[if mso]></td></tr></table><![endif]-->
</td></tr>
</table>
</body>
</html>`;
}

/** Plain-text part from the same spec. */
export function renderText(m: MailSpec, site = "https://ordcat.de"): string {
  const out: string[] = [m.title];
  if (m.subtitle) out.push(m.subtitle);
  out.push("");
  if (m.greeting) out.push(m.greeting);
  for (const p of m.intro ?? []) out.push(p);
  if (m.greeting || m.intro?.length) out.push("");
  if (m.amount) out.push(m.amount.main + (m.amount.per ? ` /${m.amount.per}` : ""), "");
  for (const r of m.rows ?? []) out.push(`${r.k}: ${r.v}${r.sub ? ` (${r.sub})` : ""}`);
  if (m.rows?.length) out.push("");
  if (m.save) out.push(m.save.text, "");
  const sec = (s: Section) => {
    if (s.title) out.push(s.title);
    for (const p of s.paras) out.push(p);
    for (const l of s.links ?? []) out.push(`${l.label}: ${l.href}`);
    out.push("");
  };
  (m.body ?? []).forEach(sec);
  for (const b of m.buttons ?? []) out.push(`${b.label}: ${b.href}`);
  if (m.buttons?.length) out.push("");
  if (m.legal?.length) { out.push("—".repeat(24), ""); m.legal.forEach(sec); }
  out.push("—".repeat(24), SELLER_LINE, `Terms ${site}/terms.html · Withdrawal ${site}/widerruf.html · Cancel contracts ${site}/kuendigen.html`);
  return out.join("\n").replace(/\n{3,}/g, "\n\n").trim() + "\n";
}

export const render = (m: MailSpec, site?: string) => ({ subject: m.subject, html: renderHtml(m, site), text: renderText(m, site) });

// ---------- sending (Resend), shared by stripe-webhook and stripe-checkout ----------
// receipt_emails.kind (receipts.sql + plan_change.sql CHECK): checkout | renewal | failed | cancel | upgrade | scheduled
export type MailKind = "checkout" | "renewal" | "failed" | "cancel" | "upgrade" | "scheduled" | "unpaid";
export type MailOut = { to: string | null; lang: string; subject: string; html: string; text: string; item: string | null; user_id: string | null; skip?: string };

/** Claim (receipt_emails) → build → send → mark. One mail per id, ever. Never throws. */
export async function sendOnce(admin: any, id: string, kind: MailKind, build: () => Promise<MailOut>) {
  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) return "no_key";                         // nothing claimed, so a later redelivery can still send it
  let claimed = false;
  try {
    const { data, error } = await admin.from("receipt_emails")
      .upsert({ id, kind, status: "sending" }, { onConflict: "id", ignoreDuplicates: true }).select("id");
    if (error) { console.error("receipt_emails claim", error.message); return "no_table"; }   // don't risk duplicates
    if (!data?.length) return "duplicate";
    claimed = true;
    const m = await build();
    let uid: string | null = m.user_id && /^[0-9a-f-]{36}$/i.test(m.user_id) ? m.user_id : null;
    if (!m.to || m.skip) {
      await admin.from("receipt_emails").update({ status: "skipped", item: m.item, lang: m.lang, error: m.skip ?? "no email" }).eq("id", id);
      return "skipped";
    }
    const bcc = Deno.env.get("CANCEL_MAIL_BCC");
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json", "Idempotency-Key": `ordcat-${id}`.slice(0, 256) },
      body: JSON.stringify({
        from: Deno.env.get("CANCEL_MAIL_FROM") ?? "OrdCat <noreply@ordcat.de>",
        to: [m.to], ...(bcc ? { bcc: [bcc] } : {}), reply_to: "support@ordcat.de",
        subject: m.subject, html: m.html, text: m.text,
      }),
    });
    const err = res.ok ? null : (await res.text()).slice(0, 400);
    const upd = { status: res.ok ? "sent" : "failed", item: m.item, lang: m.lang, error: err, sent_at: res.ok ? new Date().toISOString() : null, user_id: uid };
    let { error: e2 } = await admin.from("receipt_emails").update(upd).eq("id", id);
    if (e2 && uid) { uid = null; ({ error: e2 } = await admin.from("receipt_emails").update({ ...upd, user_id: null }).eq("id", id)); }
    if (e2) console.error("receipt_emails update", e2.message);
    return res.ok ? "sent" : "failed";
  } catch (e) {
    console.error("mail", (e as Error).message);
    if (claimed) {
      try { await admin.from("receipt_emails").update({ status: "failed", error: String((e as Error).message).slice(0, 400) }).eq("id", id); } catch (_) { /* ignore */ }
    }
    return "error";
  }
}
