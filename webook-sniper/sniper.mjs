#!/usr/bin/env node
/* =============================================================================
 * Webook Sniper — Node driver (Playwright)
 * -----------------------------------------------------------------------------
 * Opens a webook event booking page in Chrome, and gets the REAL seat list two
 * ways (whichever fires first):
 *
 *   1) NETWORK CAPTURE (primary, generalizes to any event): Playwright can read
 *      the SeatCloud iframe's own API responses — including the full seat list
 *      from `.../event/<id>/items` — with complete bodies. This is impossible
 *      from inside the page (CORS + service-worker cache), which is exactly why
 *      a Playwright-driven bot is the right tool. From the parsed list we know
 *      every section, price and which seats are FREE, then hold the real labels.
 *
 *   2) IN-PAGE DISCOVERY (fallback): if the list can't be read, the injected
 *      engine probes candidate sections by holding/releasing to map them.
 *
 * Grabbing itself uses SeatCloud's own selectObjects (authenticated, captcha-
 * scored) so holds are legitimate.
 *
 * Usage:
 *   node sniper.mjs <eventBookingUrl>
 *   node sniper.mjs <eventBookingUrl> --price 450 --count 3 --loop
 *   node sniper.mjs <eventBookingUrl> --dump           (just print the venue)
 *
 * First run opens Chrome with a fresh profile in ./.profile — log into webook
 * once; the session is saved for next time.
 * ========================================================================== */
import { chromium } from "playwright";
import readline from "node:readline";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ENGINE = path.join(__dirname, "src", "engine.js");
const PROFILE = path.join(__dirname, ".profile");

const argv = process.argv.slice(2);
const url = argv.find((a) => a.startsWith("http"));
const flag = (n) => { const i = argv.indexOf("--" + n); return i >= 0 ? argv[i + 1] : undefined; };
const opts = {
  price: flag("price") ?? null,
  count: flag("count") ? Number(flag("count")) : null,
  section: flag("section") ?? null,
  loop: argv.includes("--loop"),
  headless: argv.includes("--headless"),
  dump: argv.includes("--dump"),
  debug: argv.includes("--debug"),
};
if (!url) {
  console.error("\n  Usage: node sniper.mjs <eventBookingUrl> [--price 450 --count 3 --loop] [--dump]\n");
  process.exit(1);
}

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
const ask = (q) => new Promise((res) => rl.question(q, res));
const log = (...a) => console.log("•", ...a);

// ------------------------- seat-list parsing ------------------------------
// SeatCloud's item payload shape isn't documented; find the array of seat-like
// objects wherever it lives and normalize it.
const FREE = new Set(["free", "available", null, undefined]);
function looksLikeSeat(o) {
  return o && typeof o === "object" &&
    ("label" in o || "id" in o || "objectLabel" in o) &&
    ("status" in o || "state" in o || "category" in o || "categoryKey" in o);
}
function normSeat(o) {
  const label = o.label || o.id || o.objectLabel || "";
  if (!label) return null;
  const status = o.status || o.state;
  const cat = o.category && (o.category.key ?? o.category) ;
  const catLabel = o.category && o.category.label;
  const price = (o.pricing && o.pricing.price) ?? o.price ?? null;
  return { label: String(label), status, category: cat != null ? String(cat) : null, categoryLabel: catLabel || null, price: price != null ? Number(price) : null };
}
function extractSeats(json) {
  const out = [];
  const seen = new Set();
  (function walk(d, depth) {
    if (d == null || depth > 6) return;
    if (Array.isArray(d)) {
      let hit = 0;
      const n = Math.min(d.length, 100);
      for (let i = 0; i < n; i++) if (looksLikeSeat(d[i])) hit++;
      if (n && hit / n > 0.5) { for (const el of d) { const s = normSeat(el); if (s && !seen.has(s.label)) { seen.add(s.label); out.push(s); } } return; }
      for (const el of d) walk(el, depth + 1);
      return;
    }
    if (typeof d === "object") {
      // label -> status map
      const keys = Object.keys(d);
      let sm = 0; const sample = Math.min(keys.length, 40);
      for (let i = 0; i < sample; i++) if (typeof d[keys[i]] === "string") sm++;
      if (sample > 5 && sm / sample > 0.7 && keys[0] && keys[0].includes("-")) {
        for (const k of keys) if (!seen.has(k)) { seen.add(k); out.push({ label: k, status: d[k], category: null, categoryLabel: null, price: null }); }
        return;
      }
      for (const k of keys) walk(d[k], depth + 1);
    }
  })(json, 0);
  return out;
}

(async () => {
  log("Launching Chrome…");
  const ctx = await chromium.launchPersistentContext(PROFILE, {
    headless: opts.headless, channel: "chrome", viewport: null, args: ["--start-maximized"],
  }).catch(() => chromium.launchPersistentContext(PROFILE, { headless: opts.headless, viewport: null }));

  const page = ctx.pages()[0] || (await ctx.newPage());
  await page.addInitScript({ path: ENGINE });

  // ---- capture SeatCloud API responses across ALL frames ----
  const seatMap = new Map(); // label -> seat
  let pricingPairs = [];
  let token = null;       // hold token (from /token response)
  let eventBase = null;   // https://api.seatcloud.com/api/v2/<team>/event/<id>
  ctx.on("response", async (resp) => {
    try {
      const u = resp.url();
      if (!/seatcloud\.com/.test(u)) return;
      const m = u.match(/^(https:\/\/[^/]+\/api\/v2\/[^/]+\/event\/[^/]+)\//);
      if (m) eventBase = m[1];
      const ct = (resp.headers()["content-type"] || "");
      if (!/json/.test(ct)) return;
      const json = await resp.json().catch(() => null);
      if (!json) return;
      if (opts.debug) log("net:", u.split("?")[0].split("/").slice(-2).join("/"), Array.isArray(json) ? `[${json.length}]` : Object.keys(json).slice(0, 6).join(","));
      if (json.token && /\/token\//.test(u)) token = json.token;
      if (Array.isArray(json.pricing)) pricingPairs = json.pricing;
      const seats = extractSeats(json);
      for (const s of seats) { const prev = seatMap.get(s.label) || {}; seatMap.set(s.label, { ...prev, ...s }); }
    } catch (e) {}
  });

  // Fetch the full item list directly from Node (no browser CORS). The list
  // only hits the wire when a section is entered, so we pull it ourselves using
  // the captured token + event base. Cookies from the logged-in context are
  // included automatically by ctx.request.
  async function fetchItemsDirect() {
    if (!eventBase) return [];
    const base = eventBase + "/items";
    const tries = [
      { name: "plain", url: base, opts: {} },
      { name: "bearer", url: base, opts: { headers: token ? { Authorization: "Bearer " + token } : {} } },
      { name: "authRaw", url: base, opts: { headers: token ? { Authorization: token } : {} } },
      { name: "xHoldToken", url: base, opts: { headers: token ? { "X-Hold-Token": token } : {} } },
      { name: "qHoldToken", url: base + "?holdToken=" + encodeURIComponent(token || ""), opts: {} },
    ];
    for (const t of tries) {
      try {
        const r = await ctx.request.get(t.url, t.opts);
        const body = await r.text();
        if (opts.debug) log(`fetch /items [${t.name}]: ${r.status()} ${body.length}b`);
        if (r.ok() && body.length > 2) {
          const j = JSON.parse(body);
          const seats = extractSeats(j);
          if (seats.length) { log(`Got ${seats.length} seats via [${t.name}].`); return seats; }
        }
      } catch (e) { if (opts.debug) log(`fetch /items [${t.name}] err: ${e.message}`); }
    }
    return [];
  }

  log("Opening event page…");
  await page.goto(url, { waitUntil: "domcontentloaded" }).catch(() => {});
  log("Waiting for the seat map (log in if prompted)…");
  await page.waitForFunction(() => window.WebookSniper && window.WebookSniper.getState().ready, null, { timeout: 0, polling: 400 }).catch(() => {});

  // Give the renderer a moment; nudge it to load the item list by entering the
  // first category/section if needed, then wait for network capture.
  await page.waitForTimeout(3500);

  // Try to pull the full list directly first (works for any event).
  if (seatMap.size === 0) {
    log("Fetching the full seat list directly…");
    const direct = await fetchItemsDirect();
    for (const s of direct) { const prev = seatMap.get(s.label) || {}; seatMap.set(s.label, { ...prev, ...s }); }
  }

  // If still nothing, fall back to in-page discovery.
  let venue;
  if (seatMap.size === 0) {
    log("Direct fetch empty — running in-page discovery (a few seconds)…");
    venue = await page.evaluate(async () => { await window.WebookSniper.discover(false); return window.WebookSniper.getVenue(); });
  } else {
    // seed engine pricing so held seats show prices even if the list lacked them
    if (pricingPairs.length) await page.evaluate((p) => window.WebookSniper.seedPricing(p), pricingPairs.map((x) => ({ category: x.category, price: x.price })));
  }

  // Build a venue view from whichever source we have
  const seats = [...seatMap.values()];
  const priceMap = new Map(pricingPairs.map((p) => [String(p.category), Number(p.price)]));
  for (const s of seats) if (s.price == null && s.category != null && priceMap.has(s.category)) s.price = priceMap.get(s.category);
  const secByPrice = {};
  const freeByPrice = {};
  for (const s of seats) {
    const sec = s.label.split("-")[0];
    const pk = s.price == null ? "?" : String(s.price);
    (secByPrice[pk] = secByPrice[pk] || new Set()).add(sec);
    if (FREE.has(s.status)) (freeByPrice[pk] = freeByPrice[pk] || []).push(s.label);
  }

  console.log("\n=== Venue ===");
  if (seats.length) {
    for (const pk of Object.keys(secByPrice).sort((a, b) => Number(a) - Number(b))) {
      const free = (freeByPrice[pk] || []).length;
      console.log(`  ${pk} SAR  |  sections: ${[...secByPrice[pk]].join(", ")}  |  free seats: ${free}`);
    }
    console.log(`  total seats read: ${seats.length}`);
  } else if (venue) {
    const bp = venue.sectionsByPrice || {};
    for (const pk of Object.keys(bp).sort((a, b) => Number(a) - Number(b))) console.log(`  ${pk} SAR  |  sections: ${bp[pk].join(", ")}`);
    console.log(`  prices: ${(venue.prices || []).join(", ")}`);
  } else {
    console.log("  (could not read the seat list — the event may be sold out)");
  }
  console.log("");

  if (opts.dump) { rl.close(); console.log("(dump only — browser stays open)"); return; }

  // --------------------------- choices ---------------------------
  let price = opts.price;
  let count = opts.count;
  if (price == null) price = (await ask("Target price (blank = any): ")).trim();
  if (count == null) count = Number((await ask("How many tickets? [1]: ")).trim() || "1");
  const loop = opts.loop;

  console.log(`\n▶ Grabbing ${count} seat(s) @ ${price || "any"} price${loop ? " (loop)" : ""}…`);

  // Prefer real free labels from the captured list; else use in-page grab.
  let result;
  const freeLabels = (price ? (freeByPrice[String(price)] || []) : Object.values(freeByPrice).flat());
  if (freeLabels.length) {
    // hammer real free labels (fast, generalizes)
    do {
      result = await page.evaluate(({ labels, count, price }) => window.WebookSniper.grabByLabels(labels, count, price), { labels: freeLabels, count, price: price || "" });
      if (result.success || !loop) break;
      await page.waitForTimeout(400);
    } while (loop);
  } else {
    result = await page.evaluate((o) => window.WebookSniper.grab(o), { price: price || "", count, loop, sections: opts.section ? [opts.section] : null, timeoutMs: loop ? 300000 : 20000 });
  }

  console.log("\n=== Result ===");
  if (result.success) {
    console.log(`✅ Secured ${result.count} seat(s) in ${(result.ms / 1000).toFixed(1)}s:`);
    result.held.forEach((l, i) => console.log(`   ${l}  (${result.prices[i] ?? "?"} SAR)`));
    console.log("\n➡ Seats are HELD. Switch to the Chrome window and complete payment.");
  } else {
    console.log(`⚠ Secured ${result.count}/${result.target}. Held: ${result.held.join(", ") || "none"}`);
    console.log("  Try --loop, a different price, or check availability with --dump.");
  }

  rl.close();
  console.log("\n(Browser stays open. Close it when done.)");
})().catch((e) => { console.error("Fatal:", e.message); process.exit(1); });
