---
name: webox-sync
description: One-stop sync from WeBox — refresh local order history (per-week JSON) AND favorites caches for upcoming orderable slots, then display this week and next week's slot calendar. Use when the user says "sync my WeBox", "show my calendar", "refresh favorites", "what's been ordered", "pull latest", or wants to make sure local state is current before ordering.
---

# WeBox Sync Skill

One-stop sync for all local WeBox state. Refreshes:
- **Order history** → `~/Documents/WeBox/orders/YYYY-Www.json` (per-week JSON; cancelled/refunded filtered)
- **Favorites caches** → `~/Documents/WeBox/menu-cache/YYYY-MM-DD-{Lunch,Dinner}.json` for the next 1–2 orderable slots

Then displays this week and next week's slot calendar.

For URL patterns and DOM selectors, see `~/.claude/skills/webox/SITEMAP.md`.

---

## Step 1: Prerequisite Check

Call `tabs_context_mcp`. If no tabs:
> Claude in Chrome doesn't seem to be connected. Make sure Chrome is running with the [Claude in Chrome extension](https://code.claude.com/docs/en/chrome) enabled.

---

## Step 2: Sync Order History

Navigate to `https://www.webox.com/order/list/normal` and run:

```javascript
(async () => {
  const maxScrolls = 10;  // bump to 30+ if user said "pull all my history"
  let lastCount = 0, stable = 0;
  for (let i = 0; i < maxScrolls; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 350));
    const cnt = document.querySelectorAll('.order-item').length;
    if (cnt === lastCount) { if (++stable >= 2) break; } else { stable = 0; }
    lastCount = cnt;
  }
  const now = new Date();
  const toFullDate = (md) => {
    const m = md.match(/(\d{2})\/(\d{2})/); if (!m) return null;
    let d = new Date(now.getFullYear(), +m[1]-1, +m[2]);
    if (d - now > 30*86400000) d = new Date(now.getFullYear()-1, +m[1]-1, +m[2]);
    return d.toISOString().slice(0, 10);
  };
  const isoWeek = (iso) => {
    const d = new Date(iso + 'T00:00:00'); d.setHours(0,0,0,0);
    d.setDate(d.getDate() + 4 - (d.getDay() || 7));
    const ys = new Date(d.getFullYear(), 0, 1);
    return `${d.getFullYear()}-W${String(Math.ceil((((d - ys)/86400000)+1)/7)).padStart(2,'0')}`;
  };
  const weekMonday = (wk) => {
    const [y, w] = wk.split('-W').map(Number);
    const jan4 = new Date(y, 0, 4); const dow = jan4.getDay() || 7;
    const mon = new Date(jan4); mon.setDate(jan4.getDate() - dow + 1 + (w-1)*7);
    return mon.toISOString().slice(0, 10);
  };
  const synced = now.toISOString();
  const weeks = {};
  for (const o of document.querySelectorAll('.order-item')) {
    const orderStatus = o.querySelector('.order-status')?.innerText?.trim() || 'Paid';
    if (/refund|cancel/i.test(orderStatus)) continue;
    const lines = o.innerText.split('\n').map(l => l.trim()).filter(Boolean);
    const dateLine = lines.find(l => /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{2}\/\d{2}$/.test(l));
    const mealLine = lines.find(l => /^(Lunch|Dinner|HappyHour)(\s|\(|$)/.test(l));
    if (!dateLine || !mealLine) continue;
    const meal = mealLine.match(/^(Lunch|Dinner|HappyHour)/)[1];
    const items = [...o.querySelectorAll('.product-item')].map(p => {
      const name = p.querySelector('[class*="item-name"]')?.innerText?.trim();
      const txt = p.innerText.split('\n').map(l => l.trim()).filter(Boolean);
      const desc = txt.find(l => l !== name && !/^\$/.test(l) && !/^(Refunded|Paid|Delivered|Request Refund)$/i.test(l));
      const pl = txt.find(l => /^\$[\d.]+/.test(l));
      return { name, brand: desc?.split(',')[0]?.replace(/^Cold\s*·\s*/, '').trim(), price: pl ? parseFloat(pl.slice(1)) : null };
    }).filter(x => x.name);
    if (!items.length) continue;
    const fullDate = toFullDate(dateLine);
    if (!fullDate) continue;
    const day = dateLine.split(/\s+/)[0];
    const wk = isoWeek(fullDate);
    if (!weeks[wk]) weeks[wk] = { week: wk, week_starts: weekMonday(wk), synced_at: synced, orders: [] };
    const key = `${fullDate}|${meal}|${items[0].name}`;
    if (weeks[wk].orders.some(x => `${x.date}|${x.meal}|${x.items[0].name}` === key)) continue;
    weeks[wk].orders.push({ date: fullDate, day, meal, items });
  }
  return JSON.stringify(weeks);
})()
```

**Output is directly writable** — keyed by ISO week: `{"2026-W21": {week, week_starts, synced_at, orders: [...]}, ...}`. For each key, write `~/Documents/WeBox/orders/<key>.json` with the value as the file content. Preserve any local entries with `planned: true` that don't appear in the scrape (they're pending checkout from `webox-order`).

**Trust the tool result; don't chunk-read.** Claude Code's terminal may visually truncate large tool outputs at ~1 KB with `[TRUNCATED]` — that's display-only; the agent's tool result contains the full string. Pass it straight to `Write` / `JSON.parse`. Don't loop `slice(0, N)` calls trying to "page through" the data — wasted round-trips.

Per-order schema: `{date, day, meal, items: [{name, brand, price}]}`. Cancelled/refunded are filtered at scrape time and never written.

---

## Step 3: Refresh Favorites for Upcoming Orderable Slots

Refresh the per-slot menu-cache for the next 1–2 orderable Lunch slots (and corresponding Dinners if appropriate). This gives the user a snappy first order without waiting on a fresh scrape.

Target dates:
- **Tomorrow's Lunch** (most likely the next order, cutoff is open)
- Optionally day-after-tomorrow's Lunch if within the 7-day window

For each target date+meal:

1. Navigate the same tab to:
   ```
   https://www.webox.com/menu/section/My%20Favorites?date=<DATE>&shippingTime=<MEAL>
   ```
2. Run the favorites scrape with redirect detection:
   ```javascript
   (async () => {
     await new Promise(r => setTimeout(r, 1500));
     // Redirect check — WeBox silently redirects favorites→full menu when cutoff passed
     const urlOk = /My%20Favorites|My Favorites/.test(location.href);
     const headerEl = [...document.querySelectorAll('.menu-section-header__title, [class*="section-header__title"]')]
       .find(e => /My Favorites/i.test((e.innerText || '').trim()));
     if (!urlOk || !headerEl) {
       return JSON.stringify({ error: 'redirected', urlOk, headerFound: !!headerEl, url: location.href });
     }
     const SEL = 'app-product-menu-item.menu-section-product-item, .new-menu-product-item';
     let lastCount = 0, stable = 0;
     for (let i = 0; i < 12; i++) {
       window.scrollTo(0, document.body.scrollHeight);
       await new Promise(r => setTimeout(r, 350));
       const cnt = document.querySelectorAll(SEL).length;
       if (cnt === lastCount) { if (++stable >= 2) break; } else { stable = 0; }
       lastCount = cnt;
     }
     const items = [...document.querySelectorAll(SEL)].map(item => {
       const w = item.querySelector('.product-item-content-wrapper');
       return {
         brand: w?.querySelector('.brand-wrapper')?.innerText?.trim(),
         name: w?.querySelector('.product-menu-title')?.innerText?.trim(),
         price: parseFloat(w?.querySelector('.product-price')?.innerText?.trim().replace('$', '') || '0'),
         rating: parseFloat(w?.querySelector('.product-menu-new-and-rating-wrapper')?.innerText?.trim().split('\n')[0]) || null,
         soldOut: (() => { const el = item.querySelector('.product-menu-top-sold-out-wrapper'); return el ? getComputedStyle(el).display !== 'none' : false; })()
       };
     }).filter(i => i.name && !i.soldOut);
     if (items.length > 250) return JSON.stringify({ error: 'suspect_redirect', count: items.length });
     return JSON.stringify({ items });
   })()
   ```
3. If the result is `{error: ...}`, the slot's cutoff has likely passed (or the page hiccupped) — skip and move to the next slot.
4. Otherwise write `~/Documents/WeBox/menu-cache/<DATE>-<MEAL>.json`:
   ```json
   {
     "cached_at": "ISO-8601",
     "date": "<DATE>",
     "meal": "<MEAL>",
     "sources": ["favorites"],
     "items": [
       { "brand": "...", "name": "...", "price": 14.95, "rating": 4.5, "in_favorites": true, "categories": ["favorites"] }
     ]
   }
   ```

Skip this whole step if the user explicitly said "just sync orders, don't touch favorites".

---

## Step 4: Display the Active Window

Load this week + next week's per-week JSON files. Display Mon–Fri unless the user asks for weekends:

```
📅 WeBox Order Calendar — Week of May 18 & May 25

This week (May 18–22)
  Mon May 18  Lunch  ✅  Mongolian Beef bento, Tea Egg ×2, Taboulleh
              Dinner —   not ordered
  Tue May 19  Lunch  ✅
              Dinner —   not ordered
  Wed May 20  Lunch  ⏰  cutoff passed
  Thu May 21  Lunch  ✅
  Fri May 22  Lunch  ✅  Mongolian Beef bento, Tea Egg ×2, Taboulleh
              Dinner —   not ordered

Next week (May 25–29)
  Mon May 25  Lunch  ○   available
              Dinner ○   available
  Tue May 26  Lunch  ○   available
  ...
```

Legend: ✅ ordered (active) | 📝 planned (from webox-order, not yet placed) | ○ open | ⏰ cutoff passed | 🔒 outside 7-day window | — not ordered

Only `✅` and `📝` block a slot.

---

## Step 5: Summary + Offer

```
This week: 5/10 slots ordered.
Next week: 0/10 slots ordered — 7 open within the 7-day window.
Favorites refreshed: Fri 05/22 Lunch (105 items), Mon 05/25 Lunch (98 items).
```

If open slots exist within the 7-day window, offer:
```
Want me to order the remaining open slots? Just say which days or meals.
```

---

## Context Window Discipline

`webox-order` reads order history for variety tracking — it loads only week files within `history_window_days` (default 28). Older files stay on disk as a long-term record.

This skill's display loads only the current and next week by default. The user can ask "show me last month" / "show me everything" and the skill loads more week files as needed.
