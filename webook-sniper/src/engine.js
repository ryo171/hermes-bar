/* =============================================================================
 * Webook Sniper — page engine (SeatCloud)
 * -----------------------------------------------------------------------------
 * This runs INSIDE the webook.com booking page (main world), injected by the
 * Node driver via Playwright's addInitScript BEFORE any page script executes.
 *
 * It does NOT depend on the old extension. Standalone.
 *
 * How SeatCloud works (reverse-engineered):
 *   - webook embeds SeatCloud, exposing window.seats with initializeMap(config).
 *     The config's onChartRendered(chart) hands us a controller exposing
 *     chart.selectObjects([labels]) / deselectObjects / clearSelection.
 *   - Seat labels are "SECTION-ROW-SEAT" (e.g. "C6-AB-16").
 *   - selectObjects holds only FREE, REAL seats — passing taken/non-existent
 *     labels is harmless and fast. So generating candidate labels both
 *     enumerates and books. A server hold cap (~5) limits each call.
 *   - config.pricing gives category -> price; onObjectSelected(object) gives a
 *     held seat's real price/category. That's how we learn prices, and how we
 *     auto-discover every section and its price (probe -> read -> release).
 *
 * Exposed API (called from Node via page.evaluate):
 *   window.WebookSniper.ready()            -> Promise resolved when chart ready
 *   window.WebookSniper.getVenue()         -> { prices, sections, sectionsByPrice }
 *   window.WebookSniper.discover(force?)    -> maps sections+prices, returns venue
 *   window.WebookSniper.grab(opts)          -> { price, count, sections?, loop?,
 *                                                timeoutMs? } -> result
 *   window.WebookSniper.getState()          -> live status
 *   window.WebookSniper.releaseAll()        -> deselect everything
 *   window.WebookSniper.stop()
 * ========================================================================== */
(function () {
  "use strict";
  if (window.WebookSniper) return;

  var SEP = "-";
  var HOLD_CAP = 8; // upper bound; SeatCloud enforces the real cap server-side

  var S = {
    chart: null,
    ready: false,
    readyResolvers: [],
    pricingByCategory: new Map(), // categoryKey -> price
    priceCategories: [], // [{key,label,price}]
    inventory: new Map(), // label -> {label,section,row,seat,price,category,status}
    held: new Set(),
    sectionPrices: new Map(), // section -> price (discovery result)
    discovered: false,
    discovering: false,
    running: false,
    lastError: null,
    _wrapped: false,
  };

  function log() { try { console.log.apply(console, ["[Sniper]"].concat([].slice.call(arguments))); } catch (e) {} }
  function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function num(v) { var n = parseInt(v, 10); return isNaN(n) ? null : n; }

  // ------------------------------ seat records ------------------------------
  function parseLabel(label) {
    var p = String(label).split(SEP);
    return { section: p[0], row: p[1], seat: p[2] };
  }
  function record(obj) {
    if (!obj) return null;
    var label = "";
    try { label = obj.label || obj.id || (obj.labels && obj.labels.displayedLabel) || ""; } catch (e) {}
    if (!label) return null;
    var pl = parseLabel(label);
    var status, catKey, catLabel, price;
    try { status = obj.status; } catch (e) {}
    try { var c = obj.category || {}; catKey = c.key != null ? String(c.key) : undefined; catLabel = c.label != null ? String(c.label) : undefined; } catch (e) {}
    try {
      price = obj.pricing && obj.pricing.price != null ? obj.pricing.price : obj.price;
      if (price == null && catKey != null) price = S.pricingByCategory.get(catKey);
    } catch (e) {}
    var prev = S.inventory.get(label) || {};
    var rec = {
      label: String(label), section: pl.section, row: pl.row, seat: pl.seat, seatNum: num(pl.seat),
      status: status, categoryKey: catKey, categoryLabel: catLabel,
      price: price != null ? Number(price) : prev.price != null ? prev.price : null,
    };
    for (var k in prev) if (rec[k] == null && prev[k] != null) rec[k] = prev[k];
    S.inventory.set(label, rec);
    return rec;
  }
  function priceOf(label) { var r = S.inventory.get(label); return r && r.price != null ? Number(r.price) : null; }

  // ----------------------------- embed hooking ------------------------------
  function compose(userFn, ourFn) {
    return function () {
      try { ourFn.apply(this, arguments); } catch (e) {}
      if (typeof userFn === "function") { try { return userFn.apply(this, arguments); } catch (e) {} }
    };
  }
  function colorHook(userFn) {
    return function (object, def, extra) {
      try { record(object); } catch (e) {}
      if (typeof userFn === "function") { try { return userFn.call(this, object, def, extra); } catch (e) { return def; } }
      return def;
    };
  }
  function augment(cfg) {
    if (!cfg || typeof cfg !== "object") return cfg;
    try {
      if (Array.isArray(cfg.pricing)) {
        S.priceCategories = cfg.pricing.map(function (p) {
          if (!p) return null;
          var key = p.category != null ? String(p.category) : undefined;
          var price = p.price != null ? Number(p.price) : null;
          var label = p.categoryLabel != null ? String(p.categoryLabel) : p.label != null ? String(p.label) : key;
          if (key != null && price != null) S.pricingByCategory.set(key, price);
          return { key: key, label: label, price: price };
        }).filter(Boolean);
      }
      cfg.onChartRendered = compose(cfg.onChartRendered, function (chart) {
        S.chart = chart; S.ready = true; log("chart ready");
        S.readyResolvers.splice(0).forEach(function (r) { r(); });
      });
      cfg.onObjectSelected = compose(cfg.onObjectSelected, function (o) { var r = record(o); if (r) S.held.add(r.label); });
      cfg.onObjectDeselected = compose(cfg.onObjectDeselected, function (o) { var r = record(o); if (r) S.held.delete(r.label); });
      cfg.objectColor = colorHook(cfg.objectColor);
    } catch (e) {}
    return cfg;
  }
  function wrapFactory(fn) {
    return function () {
      var a = arguments, i;
      for (i = 0; i < a.length; i++) if (a[i] && typeof a[i] === "object" && !Array.isArray(a[i])) { a[i] = augment(a[i]); break; }
      var res = fn.apply(this, a);
      try {
        if (res && typeof res.selectObjects === "function" && !S.chart) { S.chart = res; S.ready = true; S.readyResolvers.splice(0).forEach(function (r) { r(); }); }
        else if (res && typeof res.then === "function") res.then(function (c) { if (c && typeof c.selectObjects === "function" && !S.chart) { S.chart = c; S.ready = true; S.readyResolvers.splice(0).forEach(function (r) { r(); }); } });
      } catch (e) {}
      return res;
    };
  }
  function install(seats) {
    if (!seats || S._wrapped) return;
    try {
      if (typeof seats.initializeMap === "function") seats.initializeMap = wrapFactory(seats.initializeMap);
      if (seats.adapters && typeof seats.adapters.SIO === "function") seats.adapters.SIO = wrapFactory(seats.adapters.SIO);
      S._wrapped = true; log("embed wrapped");
    } catch (e) {}
  }
  (function trap() {
    if (window.seats) install(window.seats);
    else {
      var _s;
      try {
        Object.defineProperty(window, "seats", { configurable: true, enumerable: true, get: function () { return _s; }, set: function (v) { _s = v; try { install(v); } catch (e) {} } });
      } catch (e) {}
    }
    var iv = setInterval(function () { if (window.seats && !S._wrapped) install(window.seats); if (S._wrapped) clearInterval(iv); }, 40);
    setTimeout(function () { clearInterval(iv); }, 30000);
  })();

  // ----------------------------- chart actions ------------------------------
  function select(labels) {
    if (!S.chart) return Promise.reject(new Error("chart not ready"));
    var ids = [].concat(labels);
    try {
      if (typeof S.chart.trySelectObjects === "function") return Promise.resolve(S.chart.trySelectObjects(ids));
      if (typeof S.chart.selectObjects === "function") return Promise.resolve(S.chart.selectObjects(ids));
    } catch (e) { return Promise.reject(e); }
    return Promise.reject(new Error("no selectObjects"));
  }
  function deselect(labels) {
    if (!S.chart) return Promise.resolve();
    try { if (typeof S.chart.deselectObjects === "function") return Promise.resolve(S.chart.deselectObjects([].concat(labels))); } catch (e) {}
    return Promise.resolve();
  }
  async function releaseAll() {
    try { if (S.chart && S.chart.clearSelection) await S.chart.clearSelection(); } catch (e) {}
    try { await deselect(Array.from(S.held)); } catch (e) {}
    S.held.clear();
    return { released: true };
  }

  // --------------------------- candidate generation -------------------------
  function defaultRows() {
    var out = [], i;
    for (i = 65; i <= 90; i++) out.push(String.fromCharCode(i)); // A..Z
    for (i = 65; i <= 90; i++) out.push("A" + String.fromCharCode(i)); // AA..AZ
    return out;
  }
  function genSectionCandidates() {
    var out = [], L = ["A", "B", "C", "D", "E", "F", "G", "H"], i, n;
    for (i = 0; i < L.length; i++) for (n = 1; n <= 12; n++) out.push(L[i] + n);
    ["VIP", "VVIP", "VIP W", "VVIP W"].forEach(function (v) { for (n = 1; n <= 8; n++) out.push(v + " " + n); });
    for (n = 1; n <= 25; n++) out.push("Box" + n);
    ["GA", "Floor", "Standing", "Pitch", "Media"].forEach(function (s) { out.push(s); });
    return out;
  }
  function sectionLabels(section, seatMax) {
    var rows = defaultRows(), out = [], r, s;
    seatMax = seatMax || 60;
    for (r = 0; r < rows.length; r++) for (s = 1; s <= seatMax; s++) out.push(section + SEP + rows[r] + SEP + s);
    return out;
  }

  // ------------------------------ discovery ---------------------------------
  async function discover(force) {
    if (S.discovering) return sectionsByPrice();
    if (S.discovered && !force) return sectionsByPrice();
    if (!S.chart) return {};
    S.discovering = true;
    var cands = genSectionCandidates();
    var rows = ["A", "D", "G", "K", "N", "Q", "U", "Z", "AA", "AB"];
    var seats = [1, 6, 11, 16, 21, 26, 31];
    var noNew = 0;
    for (var round = 0; round < 30; round++) {
      var remaining = cands.filter(function (s) { return !S.sectionPrices.has(s); });
      if (!remaining.length) break;
      var probe = [];
      for (var c = 0; c < remaining.length && probe.length < 2800; c++)
        for (var r = 0; r < rows.length && probe.length < 2800; r++)
          for (var s = 0; s < seats.length && probe.length < 2800; s++)
            probe.push(remaining[c] + SEP + rows[r] + SEP + seats[s]);
      try { await select(probe); } catch (e) {}
      await wait(240);
      var gotNew = false;
      S.held.forEach(function (l) { var sec = l.split(SEP)[0]; if (!S.sectionPrices.has(sec)) { S.sectionPrices.set(sec, priceOf(l)); gotNew = true; } });
      await deselect(Array.from(S.held)); S.held.clear();
      await wait(110);
      if (!gotNew) { if (++noNew >= 2) break; } else noNew = 0;
    }
    S.discovering = false;
    S.discovered = true;
    return sectionsByPrice();
  }
  function sectionsByPrice() {
    var out = {};
    S.sectionPrices.forEach(function (price, sec) { var k = price == null ? "?" : String(price); (out[k] = out[k] || []).push(sec); });
    return out;
  }
  function getVenue() {
    var prices = new Set();
    S.pricingByCategory.forEach(function (p) { prices.add(p); });
    S.sectionPrices.forEach(function (p) { if (p != null) prices.add(p); });
    return {
      ready: S.ready,
      discovered: S.discovered,
      prices: Array.from(prices).sort(function (a, b) { return a - b; }),
      priceCategories: S.priceCategories,
      sections: Array.from(S.sectionPrices.keys()).sort(),
      sectionsByPrice: sectionsByPrice(),
    };
  }

  // -------------------------------- grab ------------------------------------
  function targetSections(opts) {
    if (opts.sections && opts.sections.length) return [].concat(opts.sections);
    var out = [];
    S.sectionPrices.forEach(function (price, sec) {
      if (opts.price == null || opts.price === "" || String(price) === String(opts.price)) out.push(sec);
    });
    if (out.length) return out;
    return genSectionCandidates();
  }
  function heldMatching(price) {
    var out = [];
    S.held.forEach(function (l) { if (price == null || price === "" || String(priceOf(l)) === String(price)) out.push(l); });
    return out;
  }
  function prune(price, count) {
    var drop = [], kept = 0;
    S.held.forEach(function (l) {
      var ok = price == null || price === "" || String(priceOf(l)) === String(price);
      if (ok && kept < count) kept++;
      else drop.push(l);
    });
    if (drop.length) { deselect(drop); drop.forEach(function (l) { S.held.delete(l); }); }
  }

  async function grab(opts) {
    opts = opts || {};
    var price = opts.price != null ? opts.price : "";
    var count = Math.max(1, opts.count || 1);
    var loop = !!opts.loop;
    var timeoutMs = opts.timeoutMs || (loop ? 0 : 15000);
    var seatMax = opts.seatMax || 60;
    var chunk = 1500;
    S.running = true;
    var t0 = Date.now();
    if (!S.discovered && (!opts.sections || !opts.sections.length)) { try { await discover(false); } catch (e) {} }

    do {
      var secs = targetSections({ price: price, sections: opts.sections });
      for (var i = 0; i < secs.length; i++) {
        if (!S.running) break;
        if (heldMatching(price).length >= count) break;
        var labels = sectionLabels(secs[i], seatMax);
        for (var j = 0; j < labels.length; j += chunk) {
          if (!S.running) break;
          if (heldMatching(price).length >= count) break;
          try { await select(labels.slice(j, j + chunk)); } catch (e) {}
          await wait(320);
          prune(price, count);
          if (heldMatching(price).length >= count) break;
        }
      }
      if (heldMatching(price).length >= count) break;
      if (timeoutMs && Date.now() - t0 > timeoutMs) break;
      if (loop) await wait(300 + Math.floor(Math.random() * 300));
    } while (loop && S.running);

    S.running = false;
    var got = heldMatching(price);
    return {
      success: got.length >= count,
      held: got,
      count: got.length,
      target: count,
      prices: got.map(priceOf),
      ms: Date.now() - t0,
    };
  }

  // Grab using an EXPLICIT list of real labels (supplied by the Node driver
  // after it reads the true seat list from the SeatCloud network response).
  // This is the generalizable path — no section-name guessing.
  async function grabByLabels(labels, count, price) {
    count = Math.max(1, count || 1);
    S.running = true;
    var t0 = Date.now();
    var chunk = 400;
    for (var i = 0; i < labels.length; i += chunk) {
      if (!S.running) break;
      if (heldMatching(price).length >= count) break;
      try { await select(labels.slice(i, i + chunk)); } catch (e) {}
      await wait(300);
      prune(price == null ? "" : price, count);
    }
    S.running = false;
    var got = heldMatching(price == null ? "" : price);
    return { success: got.length >= count, held: got, count: got.length, target: count, prices: got.map(priceOf), ms: Date.now() - t0 };
  }

  // Let the Node driver seed prices per category (from the /items or config).
  function seedPricing(pairs) {
    try { (pairs || []).forEach(function (p) { if (p && p.category != null && p.price != null) S.pricingByCategory.set(String(p.category), Number(p.price)); }); } catch (e) {}
  }

  function getState() {
    return {
      ready: S.ready, running: S.running, discovering: S.discovering, discovered: S.discovered,
      held: Array.from(S.held), heldPrices: Array.from(S.held).map(priceOf),
      sections: S.sectionPrices.size, lastError: S.lastError,
    };
  }
  function ready() {
    if (S.ready) return Promise.resolve();
    return new Promise(function (res) { S.readyResolvers.push(res); setTimeout(res, 40000); });
  }

  window.WebookSniper = {
    ready: ready, getVenue: getVenue, discover: discover, grab: grab,
    grabByLabels: grabByLabels, seedPricing: seedPricing,
    getState: getState, releaseAll: releaseAll,
    stop: function () { S.running = false; return { stopped: true }; },
    version: "1.0-seatcloud",
  };
  log("engine installed");
})();
