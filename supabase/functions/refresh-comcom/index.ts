// ============================================================================
// Edge Function : refresh-comcom
// ----------------------------------------------------------------------------
// Rafraichissement MANUEL des donnees Odoo, a la demande depuis le dashboard.
//
// Flux : bouton dashboard -> cette fonction -> Odoo (JSON-RPC) -> Supabase.
// La fonction renvoie AUSSI les donnees fraiches dans la reponse, donc le
// dashboard peut se mettre a jour immediatement, sans attendre.
//
// Remplace l'ancien systeme GitHub Actions (cron toutes les 15 min, mais
// declenche de facon irreguliere par GitHub). Ici c'est instantane et fiable.
//
// SECRETS attendus (a definir via `supabase secrets set ...`) :
//   ODOO_URL, ODOO_DB, ODOO_USERNAME, ODOO_PASSWORD
// Fournis automatiquement par Supabase :
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY
// ============================================================================

const ODOO_URL      = Deno.env.get("ODOO_URL") ?? "";
const ODOO_DB       = Deno.env.get("ODOO_DB") ?? "";
const ODOO_USERNAME = Deno.env.get("ODOO_USERNAME") ?? "";
const ODOO_PASSWORD = Deno.env.get("ODOO_PASSWORD") ?? "";

const SUPABASE_URL         = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const SUPABASE_ANON_KEY    = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// ---------------------------------------------------------------------------
// Petits utilitaires (portage fidele de sync_comcom.py)
// ---------------------------------------------------------------------------
function stripHtml(html: string): string {
  if (!html) return "";
  let t = html.replace(/<br\s*\/?>/gi, "\n");
  t = t.replace(/<[^>]+>/g, "");
  t = t.replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">");
  return t.trim();
}

const pad = (n: number) => String(n).padStart(2, "0");

// Convertit une date UTC Odoo en heure locale (UTC+2, Belgique) — offset fixe
function toLocal(utcStr: unknown, offsetHours = 2): string {
  if (!utcStr) return "";
  const s = String(utcStr).slice(0, 16);
  const m = s.match(/(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})/);
  if (!m) return s;
  const dt = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]));
  dt.setUTCHours(dt.getUTCHours() + offsetHours);
  return `${dt.getUTCFullYear()}-${pad(dt.getUTCMonth() + 1)}-${pad(dt.getUTCDate())} ${pad(dt.getUTCHours())}:${pad(dt.getUTCMinutes())}`;
}

function daysSince(dateStr: unknown): number | null {
  if (!dateStr) return null;
  const m = String(dateStr).slice(0, 10).match(/(\d{4})-(\d{2})-(\d{2})/);
  if (!m) return null;
  const dt = Date.UTC(+m[1], +m[2] - 1, +m[3]);
  return Math.floor((Date.now() - dt) / 86400000);
}

// many2one Odoo -> [id, name] ou false ; renvoie le name (ou "")
function m2oName(v: unknown): string {
  return Array.isArray(v) && v.length > 1 ? String(v[1]) : "";
}
function m2oId(v: unknown): number | null {
  return Array.isArray(v) && v.length > 0 ? (v[0] as number) : null;
}

// ---------------------------------------------------------------------------
// Client Odoo JSON-RPC
// ---------------------------------------------------------------------------
async function odooRpc(service: string, method: string, args: unknown[]): Promise<any> {
  const resp = await fetch(`${ODOO_URL.replace(/\/$/, "")}/jsonrpc`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "call",
      params: { service, method, args },
      id: Math.floor(Math.random() * 1e9),
    }),
  });
  const json = await resp.json();
  if (json.error) {
    throw new Error("Odoo: " + (json.error?.data?.message || json.error?.message || "erreur inconnue"));
  }
  return json.result;
}

let _uid = 0;
async function odooAuth(): Promise<number> {
  const uid = await odooRpc("common", "authenticate", [ODOO_DB, ODOO_USERNAME, ODOO_PASSWORD, {}]);
  if (!uid) throw new Error("Connexion Odoo echouee (verifie ODOO_DB / USERNAME / PASSWORD).");
  _uid = uid as number;
  return _uid;
}
// execute_kw(model, method, argsArray, kwargs)
function execKw(model: string, method: string, argsArray: unknown[], kwargs: Record<string, unknown> = {}) {
  return odooRpc("object", "execute_kw", [ODOO_DB, _uid, ODOO_PASSWORD, model, method, argsArray, kwargs]);
}

// ---------------------------------------------------------------------------
// Recuperation + transformation des donnees (equivalent fetch_odoo_data())
// ---------------------------------------------------------------------------
function buildEmpty() {
  return {
    movements: [], matrix: [], stages: [], authors: [], valid_stages: [], all_leads: [],
    ordered_stages: [],
    stats: { total: 0, unique_leads: 0, transitions: 0, archived_shown: 0, deleted_stages: 0,
             top: {}, date_from: "", date_to: "", include_archived: false },
  };
}

async function fetchOdooData() {
  await odooAuth();

  // Etapes CRM valides
  const validStagesRaw: any[] = await execKw("crm.stage", "search_read", [[]], {
    fields: ["id", "name", "sequence"], context: { lang: "fr_BE" },
  });
  const validStageNames = new Set<string>(validStagesRaw.map((s) => s.name));
  ["RDV démo planifié", "Nouveau lead", "Contacté", "Offre à Envoyer", "À relancer"]
    .forEach((n) => validStageNames.add(n));

  // Changements d'etape (tracking)
  const domain: unknown[] = [["field_id.name", "=", "stage_id"]];
  const tracking: any[] = await execKw("mail.tracking.value", "search_read", [domain], {
    fields: ["mail_message_id", "old_value_char", "new_value_char", "create_date"],
    limit: 10000, order: "create_date desc",
  });
  if (!tracking.length) return buildEmpty();

  // Messages lies
  const msgIds = [...new Set(tracking.map((t) => m2oId(t.mail_message_id)).filter((x) => x != null))] as number[];
  const messages: any[] = [];
  for (let i = 0; i < msgIds.length; i += 500) {
    const res: any[] = await execKw("mail.message", "search_read",
      [[["id", "in", msgIds.slice(i, i + 500)], ["model", "=", "crm.lead"]]],
      { fields: ["id", "res_id", "author_id", "date"] });
    messages.push(...res);
  }
  const msgMap = new Map<number, any>(messages.map((m) => [m.id, m]));
  const leadIds = [...new Set(messages.map((m) => m.res_id).filter(Boolean))] as number[];

  // Leads (actifs + archives)
  const leadsRaw: any[] = [];
  for (let i = 0; i < leadIds.length; i += 200) {
    const res: any[] = await execKw("crm.lead", "search_read",
      [[["id", "in", leadIds.slice(i, i + 200)]]],
      { fields: ["id", "name", "partner_id", "user_id", "stage_id", "date_last_stage_update",
                 "probability", "activity_user_id", "activity_date_deadline", "activity_type_id",
                 "active", "expected_revenue"],
        context: { active_test: false, lang: "fr_BE" } });
    leadsRaw.push(...res);
  }
  const leadsMap = new Map<number, any>(leadsRaw.map((l) => [l.id, l]));

  // Tous les leads CRM (pour KPIs)
  const allLeadsKpi: any[] = [];
  try {
    let offset = 0;
    while (true) {
      const batch: any[] = await execKw("crm.lead", "search_read",
        [[["type", "=", "opportunity"]]],
        { fields: ["id", "name", "partner_id", "user_id", "stage_id", "create_date", "date_deadline",
                   "probability", "expected_revenue", "active", "write_date", "date_closed", "lost_reason_id"],
          context: { active_test: false, lang: "fr_BE" }, limit: 500, offset });
      if (!batch.length) break;
      allLeadsKpi.push(...batch);
      if (batch.length < 500) break;
      offset += 500;
    }
  } catch (_e) { /* KPI non dispo : on continue */ }

  // Activites
  const actMap = new Map<number, any>();
  try {
    const acts: any[] = await execKw("mail.activity", "search_read",
      [[["res_model", "=", "crm.lead"], ["res_id", "in", leadIds]]],
      { fields: ["res_id", "activity_type_id", "user_id", "date_deadline", "summary", "note"] });
    for (const a of acts) if (!actMap.has(a.res_id)) actMap.set(a.res_id, a);
  } catch (_e) { /* activites non dispo */ }

  // Etapes "sales" a nettoyer
  const dirtyKw = ["!!!", "supprimer", "NE PAS", "Remise dans le flux NE"];
  const isDirty = (s: unknown) => !s || dirtyKw.some((d) => String(s).includes(d));
  const stageStatus = (s: unknown) => {
    if (isDirty(s)) return "dirty";
    if (s && !validStageNames.has(String(s))) return "deleted";
    return "ok";
  };

  // Mouvements
  const movements: any[] = [];
  for (const t of tracking) {
    const msgId = m2oId(t.mail_message_id);
    if (msgId == null || !msgMap.has(msgId)) continue;
    const msg = msgMap.get(msgId);
    const lid = msg.res_id;
    const lead = leadsMap.get(lid) ?? {};
    const act = actMap.get(lid) ?? {};
    const isArchived = !(lead.active ?? true);
    if (isArchived) continue; // include_archived = false

    const de = t.old_value_char || "";
    const vers = t.new_value_char || "";
    const sDe = stageStatus(de);
    const sVers = stageStatus(vers);

    movements.push({
      lead_id: lid,
      opportunite: lead.name || `Lead #${lid}`,
      nom_contact: m2oName(lead.partner_id),
      vendeur: m2oName(lead.user_id),
      etape_actuelle: m2oName(lead.stage_id),
      date_maj_etape: (lead.date_last_stage_update || "").slice(0, 10),
      jours_bloque: daysSince(lead.date_last_stage_update),
      activite_type: m2oName(act.activity_type_id),
      activite_assigne: m2oName(act.user_id),
      activite_echeance: act.date_deadline || "",
      activite_sujet: act.summary || "",
      activite_note: stripHtml(act.note || ""),
      archived: isArchived,
      de, vers, de_status: sDe, vers_status: sVers,
      date: toLocal(t.create_date || ""),
      auteur: m2oName(msg.author_id),
      dirty: sDe !== "ok" || sVers !== "ok",
    });
  }

  // Matrice de flux (etapes valides uniquement)
  const flux = new Map<string, number>();
  for (const m of movements) {
    if (m.de_status === "ok" && m.vers_status === "ok") {
      const k = m.de + " " + m.vers;
      flux.set(k, (flux.get(k) ?? 0) + 1);
    }
  }
  const matrix = [...flux.entries()]
    .map(([k, n]) => { const [de, vers] = k.split(" "); return { de, vers, n }; })
    .sort((a, b) => b.n - a.n);

  const arrivals = new Map<string, number>();
  const departures = new Map<string, number>();
  for (const r of matrix) {
    arrivals.set(r.vers, (arrivals.get(r.vers) ?? 0) + r.n);
    departures.set(r.de, (departures.get(r.de) ?? 0) + r.n);
  }
  const allStages = [...new Set([...arrivals.keys(), ...departures.keys()])].sort();
  const stageStats = allStages.map((s) => ({
    stage: s, in: arrivals.get(s) ?? 0, out: departures.get(s) ?? 0,
    solde: (arrivals.get(s) ?? 0) - (departures.get(s) ?? 0),
  })).sort((a, b) => (b.in + b.out) - (a.in + a.out));

  // Stats par auteur
  type Auth = { total: number; leads: Set<number>; transitions: Map<string, number>;
                stages: Set<string>; last: string };
  const authDetail = new Map<string, Auth>();
  for (const m of movements) {
    if (m.dirty || !m.auteur) continue;
    let a = authDetail.get(m.auteur);
    if (!a) { a = { total: 0, leads: new Set(), transitions: new Map(), stages: new Set(), last: "" }; authDetail.set(m.auteur, a); }
    a.total++;
    a.leads.add(m.lead_id);
    const tk = m.de + " " + m.vers;
    a.transitions.set(tk, (a.transitions.get(tk) ?? 0) + 1);
    a.stages.add(m.de); a.stages.add(m.vers);
    if (m.date > a.last) a.last = m.date;
  }
  const authorStats = [...authDetail.entries()]
    .sort((x, y) => y[1].total - x[1].total)
    .map(([name, d]) => ({
      name, n: d.total, leads: d.leads.size, stages: d.stages.size, last_action: d.last,
      top_trans: [...d.transitions.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5)
        .map(([k, n]) => { const [de, vers] = k.split(" "); return { de, vers, n }; }),
    }));

  return {
    movements, matrix, stages: stageStats, authors: authorStats,
    valid_stages: [...validStageNames].sort(),
    all_leads: allLeadsKpi.map((l) => ({
      id: l.id, name: l.name || "", contact: m2oName(l.partner_id), vendeur: m2oName(l.user_id),
      etape: m2oName(l.stage_id), create_date: toLocal((l.create_date || "").slice(0, 16)),
      active: l.active ?? true, proba: l.probability || 0, revenue: l.expected_revenue || 0,
      write_date: toLocal((l.write_date || "").slice(0, 16)),
      date_closed: toLocal((l.date_closed || l.write_date || "").slice(0, 16)),
      lost_reason: m2oName(l.lost_reason_id),
    })),
    ordered_stages: [...validStagesRaw].sort((a, b) => (a.sequence ?? 99) - (b.sequence ?? 99)).map((s) => s.name),
    stats: {
      total: movements.length,
      unique_leads: new Set(movements.map((m) => m.lead_id)).size,
      transitions: matrix.length,
      archived_shown: movements.filter((m) => m.archived).length,
      deleted_stages: new Set([
        ...movements.filter((m) => m.de_status === "deleted").map((m) => m.de),
        ...movements.filter((m) => m.vers_status === "deleted").map((m) => m.vers),
      ]).size,
      top: matrix[0] ?? {},
      date_from: "", date_to: "", include_archived: false,
    },
  };
}

// ---------------------------------------------------------------------------
// Verifie que l'appelant est bien un admin autorise, en reutilisant la
// fonction get_comcom_data existante (meme controle que le login).
// ---------------------------------------------------------------------------
async function verifyAdmin(email: string, passwordHash: string): Promise<boolean> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_comcom_data`, {
    method: "POST",
    headers: {
      "apikey": SUPABASE_ANON_KEY,
      "Authorization": "Bearer " + SUPABASE_ANON_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ p_email: email, p_password_hash: passwordHash }),
  });
  return r.ok;
}

// ---------------------------------------------------------------------------
// Ecrit la ligne unique de comcom_data (id=1)
// ---------------------------------------------------------------------------
async function pushToSupabase(payload: unknown, updatedAt: string) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/comcom_data`, {
    method: "POST",
    headers: {
      "apikey": SUPABASE_SERVICE_KEY,
      "Authorization": "Bearer " + SUPABASE_SERVICE_KEY,
      "Content-Type": "application/json",
      "Prefer": "resolution=merge-duplicates",
    },
    body: JSON.stringify([{ id: 1, payload, updated_at: updatedAt }]),
  });
  if (!r.ok) throw new Error("Ecriture Supabase echouee: " + (await r.text()));
}

// ---------------------------------------------------------------------------
// Handler HTTP
// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const { p_email, p_password_hash } = await req.json().catch(() => ({}));
    if (!p_email || !p_password_hash) {
      return json({ ok: false, error: "email / mot de passe manquant" }, 400);
    }

    // 1) Controle d'acces (meme regle que le login du dashboard)
    if (!(await verifyAdmin(p_email, p_password_hash))) {
      return json({ ok: false, error: "Acces refuse." }, 403);
    }

    // 2) Recuperation Odoo
    const payload = await fetchOdooData();
    const updatedAt = new Date().toISOString();

    // 3) Sauvegarde dans Supabase
    await pushToSupabase(payload, updatedAt);

    // 4) On renvoie les donnees fraiches -> le dashboard se met a jour direct
    return json({ ok: true, updated_at: updatedAt, payload });
  } catch (err) {
    return json({ ok: false, error: String((err as Error).message || err) }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}
