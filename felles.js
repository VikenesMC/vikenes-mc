// Felles oppsett for alle sidene i MC Quiz.
// Den publiserbare nøkkelen er laga for å liggje i nettsider. Tryggleiken
// ligg i databasen (Row Level Security + funksjonar), ikkje i denne fila.
const SUPABASE_URL = "https://yrozxcxjqxfwbbdwlwwi.supabase.co";
const SUPABASE_KEY = "sb_publishable_eb4NTorneozNeCZU7GnGFQ_ybS53nn5";

const db = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

// Mappa der sidene ligg (brukast til QR-lenkjer)
const BASE_URL = new URL(".", location.href).href;

function esc(s) {
  return String(s ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function klokkeslett(iso) {
  if (!iso) return "–";
  return new Date(iso).toLocaleTimeString("nb-NO", { hour: "2-digit", minute: "2-digit" });
}

function kartLenke(adresse) {
  return "https://www.google.com/maps/dir/?api=1&travelmode=driving&destination=" +
    encodeURIComponent(adresse || "");
}

function lagre(nokkel, verdi) {
  try { localStorage.setItem(nokkel, verdi); return true; } catch { return false; }
}

function hent(nokkel) {
  try { return localStorage.getItem(nokkel); } catch { return null; }
}

// Kallar ein databasefunksjon og kastar feil med lesbar tekst
async function rpc(namn, args) {
  const { data, error } = await db.rpc(namn, args || {});
  if (error) throw new Error(error.message);
  return data;
}
