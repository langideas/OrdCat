// OrdCat · 小鱼干自定义金额（v0.2.64+）。stripe-checkout 和 stripe-webhook 共用，服务器说了算，不信 App 传来的数量。
//   1 € = 100 条；≥ €10 多送 5%，≥ €30 多送 10%，≥ €100 多送 15%（向下取整）。整欧元 €5 – €500。
//   和固定档位一致：€5 = 500、€10 = 1050、€30 = 3300、€100 = 11500。

export const FISH_CUSTOM_MIN = 5;
export const FISH_CUSTOM_MAX = 500;

/** Bonus percent for a whole-euro amount. */
export function fishBonusPct(eur: number): number {
  return eur >= 100 ? 15 : eur >= 30 ? 10 : eur >= 10 ? 5 : 0;
}

/** Dried Fish for a whole-euro amount (base 100 per €, plus the tier bonus, floored). */
export function fishForEur(eur: number): number {
  return Math.floor((eur * 100 * (100 + fishBonusPct(eur))) / 100);
}

/** A valid custom amount (whole euros, 5 … 500), else null. Accepts a number or a numeric string, never 7.5. */
export function customEur(v: unknown): number | null {
  const n = typeof v === "number" ? v : typeof v === "string" && /^\s*\d+\s*$/.test(v) ? Number(v) : NaN;
  if (!Number.isInteger(n) || n < FISH_CUSTOM_MIN || n > FISH_CUSTOM_MAX) return null;
  return n;
}
