// Edge-funksjon «chat-push» – sender push-varsel når nokon skriv i medlemschatten.
// Deploy: Supabase → Edge Functions → chat-push (kode limt inn her frå).
//
// action "key"  → gir den offentlege VAPID-nøkkelen (lagar nøklane første gong)
// action "send" → sender varsel om melding <message_id> til alle andre medlemmer
// action "test" → sender eit testvarsel til den som spør (eigne einingar)
//
// VAPID-nøklane blir laga her og lagra i tabellen push_config, som berre
// service role kan lese. Ingen treng å skrive inn hemmelege nøklar for hand.

import { createClient } from "npm:@supabase/supabase-js@2.49.4";
import webpush from "npm:web-push@3.6.7";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function svar(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const db = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { persistSession: false } },
    );

    // Kven spør? Må vere ein godkjend medlem.
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: brukar } = await db.auth.getUser(token);
    const user = brukar?.user;
    if (!user) return svar({ error: "not_logged_in" }, 401);

    const { data: meg } = await db.from("members")
      .select("id, name, status").eq("id", user.id).maybeSingle();
    if (!meg || meg.status !== "approved") return svar({ error: "not_member" }, 403);

    // VAPID-nøklar (lagast automatisk første gong)
    let { data: cfg } = await db.from("push_config").select("*").eq("id", 1).maybeSingle();
    if (!cfg) {
      const k = webpush.generateVAPIDKeys();
      await db.from("push_config").insert({ id: 1, public_key: k.publicKey, private_key: k.privateKey });
      ({ data: cfg } = await db.from("push_config").select("*").eq("id", 1).single());
    }
    webpush.setVapidDetails("https://vikenesmc.no", cfg!.public_key, cfg!.private_key);

    const inn = await req.json().catch(() => ({}));

    if (inn.action === "key") return svar({ publicKey: cfg!.public_key });

    // Finn kven som skal få varsel
    let mottakarar: { endpoint: string; p256dh: string; auth: string; member_id: string }[] = [];
    let innhald: Record<string, string>;

    if (inn.action === "test") {
      const { data } = await db.from("push_subscriptions")
        .select("endpoint, p256dh, auth, member_id").eq("member_id", user.id);
      mottakarar = data ?? [];
      innhald = { title: "Vikenes MC", body: "Varsel verkar! 🏍️", url: "medlem.html", tag: "test" };
    } else if (inn.action === "send") {
      const { data: melding } = await db.from("chat_messages")
        .select("id, author_id, body, created_at").eq("id", Number(inn.message_id)).maybeSingle();
      if (!melding || melding.author_id !== user.id) return svar({ error: "not_found" }, 404);
      if (Date.now() - new Date(melding.created_at).getTime() > 5 * 60 * 1000) {
        return svar({ error: "too_old" }, 400);
      }
      const { data: godkjende } = await db.from("members").select("id").eq("status", "approved");
      const ok = new Set((godkjende ?? []).map((m) => m.id));
      const { data } = await db.from("push_subscriptions")
        .select("endpoint, p256dh, auth, member_id").neq("member_id", user.id);
      mottakarar = (data ?? []).filter((s) => ok.has(s.member_id));
      const tekst = melding.body.length > 180 ? melding.body.slice(0, 180) + " …" : melding.body;
      innhald = { title: meg.name, body: tekst, url: "medlem.html", tag: "chat" };
    } else {
      return svar({ error: "bad_action" }, 400);
    }

    let sendt = 0, fjerna = 0, feil = 0;
    await Promise.all(mottakarar.map(async (s) => {
      try {
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          JSON.stringify(innhald),
          { TTL: 86400, urgency: "high" },
        );
        sendt++;
      } catch (e) {
        const kode = (e as { statusCode?: number }).statusCode;
        if (kode === 404 || kode === 410) {
          // Eininga finst ikkje lenger (app sletta / varsel slått av)
          await db.from("push_subscriptions").delete().eq("endpoint", s.endpoint);
          fjerna++;
        } else {
          feil++;
        }
      }
    }));

    return svar({ sendt, fjerna, feil });
  } catch (e) {
    return svar({ error: String(e) }, 500);
  }
});
