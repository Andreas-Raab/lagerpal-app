// Supabase Edge Function: lagerpal-backup
//
// Exportiert täglich alle LagerPal-Tabellen (artikel, bestaende, lagerplaetze,
// buchungen, leermeldungen, paletten, mengen_abweichungen) als eine JSON-Datei, packt sie mit gzip und lädt
// sie in den Dropbox-Ordner DROPBOX_FOLDER hoch. Danach wird die Aufbewahrung
// bereinigt: Backups älter als 30 Tage werden gelöscht, AUSSER dem jeweils
// letzten Backup jedes Kalendermonats — das wird dauerhaft behalten.
//
// Im selben Lauf (täglich 03:00 Uhr nachts) wird außerdem der JTL-Lagerbestands-
// kommentar als CSV nach JTL_FOLDER geschrieben (Datei "Lagerbestandskommentar.csv",
// gleiches Format wie der Knopf "Lagerbestandskommentar (JTL)" in der App). Die
// Datei vom Vortag wird vorher nach JTL_FOLDER/Archiv/Lagerbestandskommentar_<Datum>.csv
// verschoben. Backup und JTL-Export laufen unabhängig: scheitert einer, läuft
// der andere trotzdem; der Healthcheck meldet dann einen Fehler.
//
// Benötigte Secrets (Supabase Dashboard → Edge Functions → Secrets):
//   DROPBOX_APP_KEY
//   DROPBOX_APP_SECRET
//   DROPBOX_REFRESH_TOKEN
//   DROPBOX_FOLDER   (z.B. "/1. SILENTMONSTERS/BACKUPS/LagerPal")
//   HEALTHCHECK_URL  (optional, z.B. https://hc-ping.com/<uuid>) — wird nach
//                    jedem erfolgreichen Lauf aufgerufen, bei Fehler <url>/fail.
//                    Bleibt der Ping aus, schickt healthchecks.io eine E-Mail.
//                    Nicht gesetzt → es passiert einfach nichts.
//   JTL_FOLDER       (optional, Standard "/ScannerPro/LagerPal/JTL_lagerbestandskommentare_ex_import")
// SUPABASE_URL und SUPABASE_SERVICE_ROLE_KEY sind bei Edge Functions bereits
// automatisch vorhanden, die müssen NICHT gesetzt werden.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DROPBOX_APP_KEY = Deno.env.get("DROPBOX_APP_KEY")!;
const DROPBOX_APP_SECRET = Deno.env.get("DROPBOX_APP_SECRET")!;
const DROPBOX_REFRESH_TOKEN = Deno.env.get("DROPBOX_REFRESH_TOKEN")!;
const DROPBOX_FOLDER = Deno.env.get("DROPBOX_FOLDER") || "/1. SILENTMONSTERS/BACKUPS/LagerPal";
const HEALTHCHECK_URL = (Deno.env.get("HEALTHCHECK_URL") || "").replace(/\/+$/, "");
const JTL_FOLDER = (Deno.env.get("JTL_FOLDER") || "/ScannerPro/LagerPal/JTL_lagerbestandskommentare_ex_import").replace(/\/+$/, "");
const JTL_DATEI = "Lagerbestandskommentar.csv";

const TABLES = ["artikel", "bestaende", "lagerplaetze", "buchungen", "leermeldungen", "paletten", "mengen_abweichungen"];
const RETENTION_DAYS = 30;

// Primärschlüssel je Tabelle - fürs stabile Paginieren zwingend nötig. Ohne
// explizite Sortierung ist die Reihenfolge zwischen zwei .range()-Aufrufen
// nicht garantiert; Zeilen könnten zwischen Seiten doppelt landen oder fehlen.
const ORDER_COLS: Record<string, string[]> = {
  artikel: ["artikelnummer"],
  bestaende: ["artikelnummer", "lagerplatz"],
  lagerplaetze: ["name"],
  buchungen: ["id"],
  leermeldungen: ["id"],
  paletten: ["name"],
  mengen_abweichungen: ["id"],
};

async function fetchAllRows(supabase: ReturnType<typeof createClient>, table: string) {
  const pageSize = 1000;
  let from = 0;
  let all: unknown[] = [];
  const orderCols = ORDER_COLS[table] || [];
  for (;;) {
    let q = supabase.from(table).select("*").range(from, from + pageSize - 1);
    for (const col of orderCols) q = q.order(col, { ascending: true });
    const { data, error } = await q;
    if (error) throw new Error(`Fehler beim Lesen von ${table}: ${error.message}`);
    if (!data || data.length === 0) break;
    all = all.concat(data);
    if (data.length < pageSize) break;
    from += pageSize;
  }
  return all;
}

async function gzip(bytes: Uint8Array): Promise<Uint8Array> {
  const cs = new CompressionStream("gzip");
  const writer = cs.writable.getWriter();
  writer.write(bytes);
  writer.close();
  const chunks: Uint8Array[] = [];
  const reader = cs.readable.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }
  const total = chunks.reduce((n, c) => n + c.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    out.set(c, offset);
    offset += c.length;
  }
  return out;
}

async function getDropboxAccessToken(): Promise<string> {
  const res = await fetch("https://api.dropboxapi.com/oauth2/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: DROPBOX_REFRESH_TOKEN,
      client_id: DROPBOX_APP_KEY,
      client_secret: DROPBOX_APP_SECRET,
    }),
  });
  if (!res.ok) throw new Error(`Dropbox-Token-Refresh fehlgeschlagen: ${res.status} ${await res.text()}`);
  const json = await res.json();
  return json.access_token as string;
}

async function dropboxUpload(accessToken: string, path: string, bytes: Uint8Array) {
  const res = await fetch("https://content.dropboxapi.com/2/files/upload", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/octet-stream",
      "Dropbox-API-Arg": JSON.stringify({
        path,
        // overwrite: ein zweiter Lauf am selben Tag (z. B. an den Tagen der
        // Zeitumstellung, wo beide Cron-Jobs greifen, oder ein manueller Test)
        // ersetzt die Tagesdatei. Vorher entstand "… (1).json.gz", das von der
        // Aufbewahrungsregel nie erfasst und nie gelöscht wurde.
        mode: "overwrite",
        autorename: false,
        mute: true,
      }),
    },
    body: bytes,
  });
  if (!res.ok) throw new Error(`Dropbox-Upload fehlgeschlagen: ${res.status} ${await res.text()}`);
  return await res.json();
}

async function dropboxListFolder(accessToken: string, path: string) {
  let entries: any[] = [];
  let res = await fetch("https://api.dropboxapi.com/2/files/list_folder", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ path, recursive: false }),
  });
  if (!res.ok) {
    // Ordner existiert evtl. noch nicht -> beim ersten Lauf einfach leere Liste
    if (res.status === 409) return [];
    throw new Error(`Dropbox list_folder fehlgeschlagen: ${res.status} ${await res.text()}`);
  }
  let json = await res.json();
  entries = entries.concat(json.entries || []);
  while (json.has_more) {
    res = await fetch("https://api.dropboxapi.com/2/files/list_folder/continue", {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ cursor: json.cursor }),
    });
    if (!res.ok) throw new Error(`Dropbox list_folder/continue fehlgeschlagen: ${res.status} ${await res.text()}`);
    json = await res.json();
    entries = entries.concat(json.entries || []);
  }
  return entries.filter((e: any) => e[".tag"] === "file");
}

async function dropboxDelete(accessToken: string, path: string) {
  const res = await fetch("https://api.dropboxapi.com/2/files/delete_v2", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ path }),
  });
  if (!res.ok) {
    console.error(`Löschen fehlgeschlagen für ${path}: ${res.status} ${await res.text()}`);
  }
}

function parseBackupDate(filename: string): Date | null {
  // erkennt auch alte Dubletten wie "lagerpal_backup_2026-09-01 (1).json.gz"
  // bzw. "…json (1).gz", damit die Aufbewahrung sie ebenfalls aufräumt
  const m = filename.match(/^lagerpal_backup_(\d{4})-(\d{2})-(\d{2})(?: \(\d+\))?\.json(?: \(\d+\))?\.gz$/);
  if (!m) return null;
  return new Date(Date.UTC(parseInt(m[1]), parseInt(m[2]) - 1, parseInt(m[3])));
}

// Heutiges Datum nach deutscher Zeit (YYYY-MM-DD). Vorher UTC: ein Lauf vor
// 02:00 Uhr (Sommerzeit) bekam das Datum des Vortags.
function heuteBerlin(): string {
  return new Intl.DateTimeFormat("sv-SE", { timeZone: "Europe/Berlin" }).format(new Date());
}

async function healthcheck(ok: boolean, info: string) {
  if (!HEALTHCHECK_URL) return;
  try {
    await fetch(HEALTHCHECK_URL + (ok ? "" : "/fail"), {
      method: "POST",
      body: info.slice(0, 10000),
      signal: AbortSignal.timeout(10000),
    });
  } catch (e) {
    // Monitoring darf das Backup nie scheitern lassen
    console.error("Healthcheck-Ping fehlgeschlagen:", e);
  }
}

// ── JTL-Lagerbestandskommentar ─────────────────────────────────────────────
// Muss exakt dem Export im Frontend entsprechen (index.html: exportJtlKommentarCsv):
// Spalten "Artikelnummer;Kommentar", Kommentar = "Platz (Menge), Platz2 (Menge2)"
// in Lagerplatz-Reihenfolge der DB, Artikel nach Artikelnummer sortiert (JS-
// Standardsortierung), Trennzeichen ";", Zeilenende CRLF, UTF-8 mit BOM.
// Artikel OHNE Bestand stehen mit LEEREM Kommentar drin - sonst bliebe in JTL
// nach dem Import der alte Lagerplatz als Kommentar stehen.
function csvZelle(v: unknown): string {
  let s = v == null ? "" : String(v);
  if (/[";\n]/.test(s)) s = '"' + s.replace(/"/g, '""') + '"';
  return s;
}
// Unbekannte Artikel (Platzhalter WE-0-…, unbekannt = 1, Paket A 28.09.2026)
// kennt JTL nicht → bis zur Zuordnung nicht exportieren (gleiche Regel wie
// exportJtlKommentarCsv in index.html).
function jtlKommentarCsv(
  artikelAlle: { artikelnummer: string; unbekannt?: number }[],
  bestaende: { artikelnummer: string; lagerplatz: string; menge: number }[],
): { csv: string; artikel: number; mit_bestand: number } {
  const unb = new Set(artikelAlle.filter((a) => a.unbekannt === 1).map((a) => a.artikelnummer));
  const artikel = artikelAlle.filter((a) => !unb.has(a.artikelnummer));
  const grp: Record<string, string[]> = {};
  for (const r of bestaende) {
    if (!(r.menge > 0) || unb.has(r.artikelnummer)) continue;
    (grp[r.artikelnummer] = grp[r.artikelnummer] || []).push(r.lagerplatz + " (" + r.menge + ")");
  }
  const alle = [...new Set([...artikel.map((a) => a.artikelnummer), ...Object.keys(grp)])].sort();
  const zeilen = [["Artikelnummer", "Kommentar"], ...alle.map((nr) => [nr, (grp[nr] || []).join(", ")])];
  const csv = "\uFEFF" + zeilen.map((z) => z.map(csvZelle).join(";")).join("\r\n");
  return { csv, artikel: alle.length, mit_bestand: Object.keys(grp).length };
}

// Datum (YYYY-MM-DD) eines Zeitpunkts nach deutscher Zeit
function datumBerlin(d: Date): string {
  return new Intl.DateTimeFormat("sv-SE", { timeZone: "Europe/Berlin" }).format(d);
}

async function dropboxMetadata(accessToken: string, path: string): Promise<any | null> {
  const res = await fetch("https://api.dropboxapi.com/2/files/get_metadata", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ path }),
  });
  if (res.status === 409) {
    const txt = await res.text();
    if (txt.includes("not_found")) return null;
    throw new Error(`Dropbox get_metadata fehlgeschlagen: 409 ${txt}`);
  }
  if (!res.ok) throw new Error(`Dropbox get_metadata fehlgeschlagen: ${res.status} ${await res.text()}`);
  return await res.json();
}

async function dropboxOrdnerAnlegen(accessToken: string, path: string) {
  const res = await fetch("https://api.dropboxapi.com/2/files/create_folder_v2", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ path, autorename: false }),
  });
  if (res.ok) return;
  const txt = await res.text();
  if (res.status === 409 && txt.includes("conflict")) return;   // gibt es schon
  throw new Error(`Dropbox create_folder fehlgeschlagen: ${res.status} ${txt}`);
}

async function dropboxVerschieben(accessToken: string, von: string, nach: string): Promise<string> {
  const res = await fetch("https://api.dropboxapi.com/2/files/move_v2", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    // autorename: gibt es die Archivdatei schon (z. B. zweimal am selben Tag
    // archiviert), wird "… (1).csv" angelegt statt etwas zu überschreiben
    body: JSON.stringify({ from_path: von, to_path: nach, autorename: true }),
  });
  if (!res.ok) throw new Error(`Dropbox move fehlgeschlagen: ${res.status} ${await res.text()}`);
  const json = await res.json();
  return json?.metadata?.path_display || nach;
}

async function jtlExport(accessToken: string, snapshot: Record<string, unknown>) {
  const { csv, artikel, mit_bestand } = jtlKommentarCsv(
    snapshot.artikel as { artikelnummer: string; unbekannt?: number }[],
    snapshot.bestaende as { artikelnummer: string; lagerplatz: string; menge: number }[],
  );
  const pfad = `${JTL_FOLDER}/${JTL_DATEI}`;
  const heute = heuteBerlin();
  let archiviert: string | null = null;
  // Datei vom Vortag (oder älter) mit Datum ins Archiv verschieben. Stammt sie
  // von heute (zweiter Lauf am selben Tag, z. B. manueller Test), wird sie
  // einfach überschrieben.
  const alt = await dropboxMetadata(accessToken, pfad);
  if (alt && alt[".tag"] === "file") {
    const altDatum = datumBerlin(new Date(alt.server_modified));
    if (altDatum !== heute) {
      await dropboxOrdnerAnlegen(accessToken, `${JTL_FOLDER}/Archiv`);
      archiviert = await dropboxVerschieben(accessToken, pfad, `${JTL_FOLDER}/Archiv/Lagerbestandskommentar_${altDatum}.csv`);
    }
  }
  await dropboxUpload(accessToken, pfad, new TextEncoder().encode(csv));
  return { pfad, archiviert, artikel, mit_bestand };
}

async function applyRetention(accessToken: string) {
  const files = await dropboxListFolder(accessToken, DROPBOX_FOLDER);
  const parsed = files
    .map((f: any) => ({ name: f.name as string, path: f.path_lower as string, date: parseBackupDate(f.name) }))
    .filter((f): f is { name: string; path: string; date: Date } => f.date !== null);

  const now = new Date();
  const cutoff = new Date(now.getTime() - RETENTION_DAYS * 24 * 60 * 60 * 1000);

  // Letztes Backup je Kalendermonat ermitteln -> dauerhaft behalten
  const lastOfMonth = new Map<string, { name: string; path: string; date: Date }>();
  for (const f of parsed) {
    const key = `${f.date.getUTCFullYear()}-${f.date.getUTCMonth()}`;
    const cur = lastOfMonth.get(key);
    if (!cur || f.date > cur.date) lastOfMonth.set(key, f);
  }
  const keepNames = new Set([...lastOfMonth.values()].map((f) => f.name));

  const toDelete = parsed.filter((f) => f.date < cutoff && !keepNames.has(f.name));
  for (const f of toDelete) {
    await dropboxDelete(accessToken, f.path);
  }
  return { geprueft: parsed.length, geloescht: toDelete.length, dauerhaft_behalten: keepNames.size };
}

Deno.serve(async (_req) => {
  // Backup und JTL-Export laufen unabhängig voneinander: scheitert einer, wird
  // der andere trotzdem versucht. Nur wenn das Lesen der Daten oder die
  // Dropbox-Anmeldung scheitert, fällt beides aus.
  const ergebnis: Record<string, unknown> = { ok: false };
  const fehler: string[] = [];
  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const snapshot: Record<string, unknown> = { erstellt_am: new Date().toISOString() };
    for (const table of TABLES) {
      try {
        snapshot[table] = await fetchAllRows(supabase, table);
      } catch (e) {
        // mengen_abweichungen gibt es erst ab dem Datenbank-Update Paket 2 - fehlt
        // sie noch, läuft das Backup ohne sie weiter statt komplett zu scheitern
        if (table !== "mengen_abweichungen") throw e;
        console.error("Tabelle mengen_abweichungen nicht lesbar, wird ausgelassen:", e);
      }
    }
    ergebnis.zeilen = Object.fromEntries(TABLES.map((t) => [t, ((snapshot[t] as unknown[]) || []).length]));

    const accessToken = await getDropboxAccessToken();

    // ── 1. Backup ──
    try {
      const json = JSON.stringify(snapshot);
      const gzipped = await gzip(new TextEncoder().encode(json));
      const today = heuteBerlin(); // YYYY-MM-DD (deutsche Zeit)
      const dropboxPath = `${DROPBOX_FOLDER}/lagerpal_backup_${today}.json.gz`;
      await dropboxUpload(accessToken, dropboxPath, gzipped);
      ergebnis.pfad = dropboxPath;
      ergebnis.groesse_bytes = gzipped.length;
      ergebnis.retention = await applyRetention(accessToken);
    } catch (e) {
      fehler.push("Backup: " + String((e as Error)?.message || e));
    }

    // ── 2. JTL-Lagerbestandskommentar ──
    try {
      ergebnis.jtl = await jtlExport(accessToken, snapshot);
    } catch (e) {
      fehler.push("JTL-Export: " + String((e as Error)?.message || e));
    }
  } catch (err) {
    fehler.push(String((err as Error)?.message || err));
  }

  ergebnis.ok = fehler.length === 0;
  if (fehler.length) {
    ergebnis.fehler = fehler.join(" | ");
    console.error(ergebnis.fehler);
  }
  const text = JSON.stringify(ergebnis);
  await healthcheck(fehler.length === 0, text);
  return new Response(text, {
    status: fehler.length ? 500 : 200,
    headers: { "Content-Type": "application/json" },
  });
});
