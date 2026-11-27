// In-memory stand-in for npm:@supabase/supabase-js@2 (tests only; mapped in tests/import_map.json).
// Enough of the query builder for the Edge Functions: select / eq / not / limit / single, insert, upsert, update, rpc.

type Row = Record<string, any>;
export const db = {
  tables: new Map<string, Row[]>(),
  rpcCalls: [] as { name: string; args: any }[],
  rpc: new Map<string, (args: any) => any>(),
  users: new Map<string, { id: string; email: string }>(),       // token → user
  // Hooks to simulate missing schema: table → error message; or columns a table doesn't have.
  missingTable: new Set<string>(),
  missingColumns: new Map<string, string[]>(),
  failUpsert: new Map<string, string>(),
  reset() {
    this.tables.clear(); this.rpcCalls = []; this.rpc.clear(); this.users.clear();
    this.missingTable.clear(); this.missingColumns.clear(); this.failUpsert.clear();
  },
  t(name: string) { if (!this.tables.has(name)) this.tables.set(name, []); return this.tables.get(name)!; },
};

class Q {
  private filters: ((r: Row) => boolean)[] = [];
  private op: "select" | "insert" | "upsert" | "update" = "select";
  private payload: any = null;
  private opts: any = {};
  private wantRows = false;
  private one = false;
  private lim = Infinity;
  constructor(private table: string) {}
  select(_cols?: string) { this.wantRows = true; return this; }
  eq(c: string, v: any) { this.filters.push((r) => r[c] === v); return this; }
  not(c: string, op: string, v: any) {
    if (op === "is" && v === null) this.filters.push((r) => r[c] !== null && r[c] !== undefined);
    return this;
  }
  limit(n: number) { this.lim = n; return this; }
  single() { this.one = true; this.wantRows = true; return this; }
  insert(p: any) { this.op = "insert"; this.payload = p; return this; }
  upsert(p: any, o: any = {}) { this.op = "upsert"; this.payload = p; this.opts = o; return this; }
  update(p: any) { this.op = "update"; this.payload = p; return this; }
  private err(message: string) { return { data: null, error: { message } }; }
  private checkCols(row: Row) {
    const miss = db.missingColumns.get(this.table) ?? [];
    const bad = Object.keys(row).find((k) => miss.includes(k));
    return bad ? `Could not find the '${bad}' column of '${this.table}' in the schema cache` : null;
  }
  run(): { data: any; error: any } {
    if (db.missingTable.has(this.table)) return this.err(`relation "public.${this.table}" does not exist`);
    const rows = db.t(this.table);
    if (this.op === "select") {
      const out = rows.filter((r) => this.filters.every((f) => f(r))).slice(0, this.lim);
      return { data: this.one ? out[0] ?? null : out, error: null };
    }
    if (this.op === "insert") {
      const list = Array.isArray(this.payload) ? this.payload : [this.payload];
      const made = list.map((p: Row) => ({ id: crypto.randomUUID(), received_at: new Date().toISOString(), ...p }));
      rows.push(...made);
      return { data: this.one ? made[0] : (this.wantRows ? made : null), error: null };
    }
    if (this.op === "upsert") {
      const f = db.failUpsert.get(this.table);
      if (f) return this.err(f);
      const list = Array.isArray(this.payload) ? this.payload : [this.payload];
      const out: Row[] = [];
      for (const p of list) {
        const bad = this.checkCols(p);
        if (bad) return this.err(bad);
        const key = this.opts.onConflict ?? "id";
        const i = rows.findIndex((r) => r[key] === p[key]);
        if (i >= 0) {
          if (this.opts.ignoreDuplicates) continue;
          rows[i] = { ...rows[i], ...p };
          out.push(rows[i]);
        } else { rows.push({ ...p }); out.push(p); }
      }
      return { data: this.wantRows ? out : null, error: null };
    }
    // update
    const bad = this.checkCols(this.payload);
    if (bad) return this.err(bad);
    const hit = rows.filter((r) => this.filters.every((f) => f(r)));
    for (const r of hit) Object.assign(r, this.payload);
    return { data: this.wantRows ? hit : null, error: null };
  }
  then(res: (v: any) => any, rej?: (e: any) => any) {
    try { return Promise.resolve(this.run()).then(res, rej); } catch (e) { return Promise.reject(e).then(res, rej); }
  }
}

export function createClient(_url: string, _key: string) {
  return {
    auth: {
      getUser: async (token: string) => {
        const u = db.users.get(token);
        return { data: { user: u ?? null }, error: u ? null : { message: "bad token" } };
      },
    },
    from: (t: string) => new Q(t),
    rpc: async (name: string, args: any) => {
      db.rpcCalls.push({ name, args });
      const h = db.rpc.get(name);
      if (!h) return { data: null, error: null };
      try { return { data: await h(args), error: null }; } catch (e) { return { data: null, error: { message: String((e as Error).message) } }; }
    },
  };
}
