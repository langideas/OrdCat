// OrdCat 托管模型代理（会员额度）。OpenAI 兼容：App 把 Base URL 设成
//   https://<project>.supabase.co/functions/v1/chat-proxy/v1
// 然后照常 POST /chat/completions，带上登录后的 Supabase access token。
// 上游的 Key 只放在这里（supabase secrets），App 里没有。
//
// 部署：supabase functions deploy chat-proxy
// Secrets（例子，按需改模型）：
//   HOSTED_MODELS='{
//     "cn":   {"base":"https://dashscope.aliyuncs.com/compatible-mode/v1","key":"DASHSCOPE_KEY","model":"qwen3.8-flash","in":0.11,"out":0.38,"extra":{"enable_thinking":false}},
//     "intl": {"base":"https://api.openai.com/v1","key":"OPENAI_KEY","model":"gpt-6-luna","in":0.10,"out":0.50},
//     "slow": {"base":"https://open.bigmodel.cn/api/paas/v4","key":"ZHIPU_KEY","model":"glm-4.7-flash","in":0,"out":0,"extra":{"thinking":{"type":"disabled"}}},
//     "premium": {"gpt-6.1-terra":{"base":"https://api.openai.com/v1","key":"OPENAI_KEY","model":"gpt-6.1-terra","mult":10,"in":1,"out":5},
//                 "gemini-3.8-flash":{"base":"https://generativelanguage.googleapis.com/v1beta/openai","key":"GEMINI_KEY","model":"gemini-3.8-flash","mult":15,"in":1.5,"out":7.5},
//                 "claude-sonnet-5-5":{"base":"https://api.anthropic.com/v1","key":"ANTHROPIC_KEY","model":"claude-sonnet-5-5","mult":20,"in":2,"out":10}}
// 高级模型只给Max。
//   }'
//   DASHSCOPE_KEY=… OPENAI_KEY=… ZHIPU_KEY=…   （"key" 写的是 secret 的名字，不是 Key 本身）
// "in"/"out" = 每 1M token 的美元价，只用来记账。
import { createClient } from "npm:@supabase/supabase-js@2";

type Up = { base: string; key: string; model: string; in?: number; out?: number; mult?: number; extra?: Record<string, unknown> };

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-ordcat-region",
};

function err(status: number, code: string, message: string) {
  return new Response(JSON.stringify({ error: { code, message } }), {
    status, headers: { ...cors, "Content-Type": "application/json" },
  });
}

// Context per message (about 3 characters a token): free 16k, Pro 32k, Max 128k tokens.
const LIMITS: Record<string, { ctxChars: number }> = {
  free: { ctxChars: 48_000 }, pro: { ctxChars: 96_000 }, max: { ctxChars: 384_000 },
};

// Keep the system prompt and the newest turns within the plan's context size.
function trim(messages: any[], maxChars: number): any[] {
  const size = (m: any) => typeof m.content === "string" ? m.content.length : JSON.stringify(m.content ?? "").length;
  const sys = messages.filter((m) => m.role === "system");
  const rest = messages.filter((m) => m.role !== "system");
  let total = sys.reduce((a, m) => a + size(m), 0);
  const kept: any[] = [];
  for (let i = rest.length - 1; i >= 0; i--) {
    const s = size(rest[i]);
    if (kept.length > 0 && total + s > maxChars) break;
    kept.unshift(rest[i]);
    total += s;
  }
  // A single huge system prompt (page text) is cut from the end.
  for (const m of sys) if (typeof m.content === "string" && m.content.length > maxChars) m.content = m.content.slice(0, maxChars);
  return [...sys, ...kept];
}

function countImages(messages: any[]): number {
  let n = 0;
  for (const m of messages) if (Array.isArray(m.content)) n += m.content.filter((p: any) => p?.type === "image_url").length;
  return n;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const url = new URL(req.url);
  if (url.pathname.endsWith("/models")) {
    return new Response(JSON.stringify({ data: [{ id: "ordcat", object: "model" }] }), { headers: { ...cors, "Content-Type": "application/json" } });
  }
  if (!url.pathname.endsWith("/chat/completions") || req.method !== "POST") return err(404, "not_found", "Only /chat/completions");

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: u, error: authErr } = await admin.auth.getUser(token);
  if (authErr || !u?.user) return err(401, "sign_in", "请先登录 OrdCat 账号（设置 → 用户）");
  const uid = u.user.id;

  const { data: admit, error: admitErr } = await admin.rpc("proxy_admit", { p_user: uid });
  if (admitErr) return err(500, "server", admitErr.message);
  if (!admit?.ok) {
    const msg = admit?.reason === "too_fast" ? "发得太快啦，歇一分钟再聊～"
      : "今天的额度用完了：可以在 设置 → 用户 → 会员 升级方案，或者填自己的模型 Key。";
    return err(429, admit?.reason ?? "quota", msg);
  }

  let body: any;
  try { body = await req.json(); } catch { return err(400, "bad_json", "bad json"); }
  const cfg = JSON.parse(Deno.env.get("HOSTED_MODELS") ?? "{}");
  const plan: string = admit.plan ?? "free";
  const tier: string = admit.tier;
  const region = (req.headers.get("x-ordcat-region") ?? "intl").toLowerCase() === "cn" ? "cn" : "intl";
  let up: Up | undefined;
  let mult = 1;
  const asked = String(body.model ?? "ordcat");
  if (tier === "slow") up = cfg.slow;
  else if (plan === "max" && cfg.premium?.[asked]) { up = cfg.premium[asked]; mult = up!.mult ?? 1; }
  else up = cfg[region] ?? cfg.intl ?? cfg.cn;
  if (!up) return err(503, "not_configured", "托管模型还没配置好");
  const key = Deno.env.get(up.key) ?? "";

  const messages = trim(Array.isArray(body.messages) ? body.messages : [], (LIMITS[plan] ?? LIMITS.free).ctxChars);
  const images = Math.min(countImages(messages), 4);
  const stream = body.stream !== false;
  const out: Record<string, unknown> = {
    ...(up.extra ?? {}),
    model: up.model,
    messages,
    stream,
    max_tokens: Math.min(Number(body.max_tokens ?? 1500), 1500),
  };
  if (body.temperature !== undefined) out.temperature = body.temperature;
  if (stream) out.stream_options = { include_usage: true };

  const r = await fetch(up.base.replace(/\/$/, "") + "/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
    body: JSON.stringify(out),
  });
  if (!r.ok || !r.body) {
    const t = await r.text();
    return err(r.status || 502, "upstream", `模型服务暂时不可用（${r.status}）${t.slice(0, 200)}`);
  }

  // Credits: 1 per message, +1 with a picture, +1 for a long context, × model multiplier.
  const charge = async (pt: number, ct: number) => {
    const credits = tier === "slow" ? 0 : (1 + (images > 0 ? 1 : 0) + (pt > 8000 ? 1 : 0)) * mult;
    const cost = (pt * (up!.in ?? 0) + ct * (up!.out ?? 0)) / 1e6;
    await admin.rpc("consume_credits", {
      p_user: uid, p_tier: tier, p_credits: credits, p_model: up!.model,
      p_prompt: pt, p_completion: ct, p_cost: cost,
    });
  };

  const headers = { ...cors, "x-ordcat-tier": tier, "x-ordcat-plan": plan };
  if (!stream) {
    const j = await r.json();
    await charge(j?.usage?.prompt_tokens ?? 0, j?.usage?.completion_tokens ?? 0);
    return new Response(JSON.stringify(j), { headers: { ...headers, "Content-Type": "application/json" } });
  }

  // Pass the stream through unchanged while reading the usage chunk at the end.
  let pt = 0, ct = 0, chars = 0, buf = "";
  const dec = new TextDecoder();
  const tap = new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, ctl) {
      ctl.enqueue(chunk);
      buf += dec.decode(chunk, { stream: true });
      let i: number;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (!line.startsWith("data:")) continue;
        const d = line.slice(5).trim();
        if (d === "[DONE]") continue;
        try {
          const j = JSON.parse(d);
          if (j.usage) { pt = j.usage.prompt_tokens ?? pt; ct = j.usage.completion_tokens ?? ct; }
          chars += (j.choices?.[0]?.delta?.content ?? "").length;
        } catch { /* partial line */ }
      }
    },
    async flush() {
      // No usage chunk from this provider: estimate.
      if (pt === 0) pt = Math.ceil(JSON.stringify(messages).length / 3);
      if (ct === 0) ct = Math.ceil(chars / 2);
      await charge(pt, ct);
    },
  });
  return new Response(r.body.pipeThrough(tap), {
    headers: { ...headers, "Content-Type": "text/event-stream", "Cache-Control": "no-cache" },
  });
});
