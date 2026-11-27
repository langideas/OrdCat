#!/usr/bin/env python3
"""Browser check of the payment pages (thanks / pricing / kuendigen) with a stubbed checkout-receipt.

  pip install playwright && python3 -m playwright install chromium
  python3 app/OrdCat/supabase/tests/site_check.py <path to site/> <out dir>

Serves site/ locally, answers the checkout-receipt Edge Function from fixtures (no network), screenshots each state
in zh / en and dark / light, and fails on JS errors or missing texts.
"""
import functools, http.server, json, sys, threading, time
from pathlib import Path
from playwright.sync_api import sync_playwright

site, out = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 8765), functools.partial(Quiet, directory=str(site)))
threading.Thread(target=srv.serve_forever, daemon=True).start()
B = "http://127.0.0.1:8765/"
now = int(time.time())

FIX = {
    "cs_test_paidYearly0001": {"ok": True, "state": "complete", "receipt": {
        "id": "cs_test_paidYearly0001", "mode": "subscription", "item": "max", "currency": "eur", "amount_total": 56600,
        "amount_tax": 9037, "items": [{"name": "OrdCat Max", "interval": "year"}], "created": now, "fish": None,
        "yearly": {"monthly": 5900, "regular": 70800, "discount": 14200, "paid": 56600},
        "payment_method": {"type": "card", "brand": "visa", "last4": "4242", "wallet": None}, "email": "m***@langgo.de",
        "renews_at": now + 365 * 86400, "receipt_url": "https://pay.stripe.com/receipts/x", "invoice_pdf": "https://pay.stripe.com/invoice/x/pdf",
        "invoice_number": "ORD-0001", "processing": False}},
    "cs_test_paidFish000001": {"ok": True, "state": "complete", "receipt": {
        "id": "cs_test_paidFish000001", "mode": "payment", "item": "fish", "currency": "eur", "amount_total": 1000, "amount_tax": None,
        "items": [{"name": "OrdCat Dried Fish", "interval": None}], "created": now, "fish": 1050, "yearly": None,
        "payment_method": {"type": "card", "brand": "mastercard", "last4": "4444", "wallet": "apple_pay"}, "email": "m***@langgo.de",
        "renews_at": None, "receipt_url": "https://pay.stripe.com/receipts/y", "processing": False}},
    "cs_test_processing0001": {"ok": True, "state": "complete", "receipt": {
        "id": "cs_test_processing0001", "item": "fish", "currency": "eur", "amount_total": 500, "items": [{"name": "OrdCat Dried Fish"}],
        "fish": 500, "created": now, "processing": True, "payment_method": {"type": "sepa_debit", "brand": "sepa_debit", "last4": "3000"}}},
    "cs_test_abandoned00001": {"ok": True, "state": "open", "receipt": {
        "id": "cs_test_abandoned00001", "item": "pro", "currency": "eur", "amount_total": 9500, "items": [{"name": "OrdCat Pro", "interval": "year"}],
        "yearly": {"monthly": 990, "regular": 11880, "discount": 2380, "paid": 9500}}},
}
CASES = [
    ("thanks-paid-yearly", "thanks.html?session_id=cs_test_paidYearly0001", ["付款成功", "€566", "原价", "下次续费", "Visa •••• 4242", "m***@langgo.de"], ["Payment successful", "Regular price", "Renews on"]),
    ("thanks-paid-fish", "thanks.html?session_id=cs_test_paidFish000001", ["付款成功", "1050 条小鱼干", "已含增值税"], ["1050 Dried Fish", "Apple Pay"]),
    ("thanks-processing", "thanks.html?session_id=cs_test_processing0001", ["付款处理中"], ["Payment processing"]),
    ("thanks-cancelled-session", "thanks.html?session_id=cs_test_abandoned00001&cancelled=1", ["订单未完成，没有扣款", "OrdCat Pro", "原价"], ["Order not completed"]),
    ("thanks-cancelled-literal", "thanks.html?session_id={CHECKOUT_SESSION_ID}&cancelled=1", ["订单未完成，没有扣款"], ["You were not charged"]),
    ("thanks-invalid", "thanks.html", ["没有找到这笔付款"], ["couldn't find this payment"]),
    ("thanks-unknown", "thanks.html?session_id=cs_test_unknown0000001", ["没有找到这笔付款"], ["couldn't find"]),
    ("thanks-error", "thanks.html?session_id=cs_test_servererror001", ["暂时读不到付款详情"], ["can't load the payment details"]),
    ("thanks-updated", "thanks.html?updated=1", ["方案已更新"], ["Plan updated"]),
    ("thanks-demo", "thanks.html?demo=1", ["示例", "付款成功"], ["Sample"]),
    ("pricing", "pricing.html", ["原价", "€47.17", "怎么升级或降级", "能退款吗"], ["Regular", "How do I upgrade or downgrade"]),
    ("pricing-paid0-redirect", "pricing.html?paid=0", ["订单未完成，没有扣款"], ["Order not completed"]),
    ("pricing-paid1-redirect", "pricing.html?paid=1&session_id=cs_test_paidFish000001", ["付款成功"], ["Payment successful"]),
    ("kuendigen", "kuendigen.html", ["jetzt kündigen"], ["jetzt kündigen"]),
]

def route(r):
    from urllib.parse import urlparse, parse_qs
    sid = parse_qs(urlparse(r.request.url).query).get("session_id", [""])[0]
    if sid == "cs_test_servererror001":
        return r.fulfill(status=500, content_type="application/json", body=json.dumps({"ok": False, "error": "error"}))
    body = FIX.get(sid)
    if body is None:
        return r.fulfill(status=404, content_type="application/json", body=json.dumps({"ok": False, "error": "not_found"}))
    r.fulfill(status=200, content_type="application/json", body=json.dumps(body), headers={"Access-Control-Allow-Origin": "*"})

fails = []
with sync_playwright() as p:
    br = p.chromium.launch()
    for lang in ("zh", "en"):
        for theme in ("dark", "light"):
            ctx = br.new_context(viewport={"width": 760, "height": 1100}, locale="zh-CN" if lang == "zh" else "en-GB")
            ctx.add_init_script(f"localStorage.setItem('oc-lang','{lang}');localStorage.setItem('oc-theme','{theme}');")
            ctx.route("**/functions/v1/checkout-receipt**", route)
            for name, path, zh, en in CASES:
                pg = ctx.new_page()
                errs = []
                pg.on("pageerror", lambda e, errs=errs: errs.append(str(e)))
                pg.goto(B + path)
                pg.wait_for_timeout(700)
                text = pg.inner_text("body")
                for want in (zh if lang == "zh" else en):
                    if want not in text:
                        fails.append(f"{name} [{lang}/{theme}]: missing «{want}»")
                if errs:
                    fails.append(f"{name} [{lang}/{theme}]: JS error {errs}")
                if theme == "dark" or name.startswith("thanks-paid-yearly"):
                    pg.screenshot(path=str(out / f"{name}-{lang}-{theme}.png"), full_page=name != "pricing")
                pg.close()
            ctx.close()
    br.close()
srv.shutdown()
print("\n".join(fails) if fails else f"site check OK: {len(CASES)} pages × zh/en × dark/light")
sys.exit(1 if fails else 0)
