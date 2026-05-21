---
name: webox-sync-calendar
description: Sync the local WeBox order history from WeBox, then display this week and next week's slot calendar. Updates per-week JSON files in ~/Documents/WeBox/orders/. Use when the user asks to see their order calendar, check what's been ordered or what's open, sync orders, or pull the latest history from WeBox.
---

# WeBox Sync Calendar Skill

Syncs order history from WeBox into per-week JSON files at `~/Documents/WeBox/orders/`, then displays this week and next week's slot calendar.

Order history layout:
- One JSON file per ISO week (e.g. `2026-W21.json` covers Mon 2026-05-18 – Sun 2026-05-24)
- Schema: `{ week, week_starts, synced_at, orders: [{date, day, meal, orderId, status, total, items: [...]}] }`
- Status values: `"active"` (real order placed) or `"planned"` (written by webox-order before checkout)
- Cancelled/refunded orders are filtered out at sync — never appear in local files
- Files are kept forever; downstream skills load only `history_window_days` worth (default 28)

For URL patterns and DOM selectors, see `~/.claude/skills/webox/SITEMAP.md`.

---

## Step 1: Sync from WeBox

Navigate to `https://www.webox.com/order/list/normal`. Scroll smart-style (stops on no new items):

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

**Output is directly writable.** Result is an object keyed by ISO week: `{"2026-W21": {week, week_starts, synced_at, orders: [...]}, ...}`. The agent just iterates keys and writes each value as `~/Documents/WeBox/orders/<key>.json`. No post-processing.

Per-order schema is minimal: `{date, day, meal, items: [{name, brand, price}]}`. Dropped: `orderId`, `status`, `total`, `isActive`. We only return active orders so status/isActive are constants; `total` is always $0 for subsidized accounts; `orderId` isn't needed downstream (date+meal is the natural slot key).

## Step 2: Merge into per-week JSON files

For each scraped order:
1. Convert `"Mon 05/18"` to a full ISO date (use current year; if the resulting date is in the future, use previous year).
2. Compute the ISO week → `YYYY-Www` (e.g. `2026-W21`).
3. Read or create `~/Documents/WeBox/orders/<YYYY-Www>.json` with the schema below.
4. Dedupe new orders against existing entries by `orderId`. New orders → append. Existing → update.
5. Preserve any local `status: "planned"` entries until they appear as `"active"` in the scrape (then update inline).
6. Set `synced_at` on every touched week file.

### Per-week file schema (matches scraper output directly)

```json
{
  "week": "2026-W21",
  "week_starts": "2026-05-18",
  "synced_at": "2026-05-21T14:30:00Z",
  "orders": [
    {
      "date": "2026-05-18",
      "day": "Mon",
      "meal": "Lunch",
      "items": [
        { "name": "Mongolian Beef Bento", "brand": "Xiangchuan Kitchen", "price": 17.45 },
        { "name": "Tea Egg", "brand": "Northwest China Cuisine", "price": 2.45 }
      ]
    }
  ]
}
```

The agent doesn't need to transform anything — the scraper returns this exact shape, keyed by week. Just write `Object.entries(result).forEach(([wk, content]) => writeFile(\`~/Documents/WeBox/orders/${wk}.json\`, JSON.stringify(content, null, 2)))`.

**Cancelled/refunded orders are filtered out at scrape time and never written.** The slot stays openable. If the user wants to audit cancelled history, point them at `/order/list/normal`.

If a local week file has `planned: true` entries (from webox-order Step 6), preserve them when merging — only overwrite entries whose date+meal pair matches a newly-scraped active order.

## Step 3: Display the Active Window

Load this week and next week's files. Display Mon–Fri unless the user asks for weekends.

```
📅 WeBox Order Calendar — Week of May 20 & May 27

This week (May 20–24)
  Mon May 20  Lunch  ✅  Mongolian Beef bento, Tea Egg ×2, Taboulleh
              Dinner —   not ordered
  Tue May 21  Lunch  ✅
              Dinner —   not ordered
  Wed May 22  Lunch  ⏰  cutoff passed
  Thu May 23  Lunch  ✅
  Fri May 24  Lunch  ✅  Mongolian Beef bento, Tea Egg ×2, Taboulleh
              Dinner —   not ordered

Next week (May 27–31)
  Mon May 27  Lunch  ○   available
              Dinner ○   available
  Tue May 28  Lunch  ○   available
  ...
  Fri May 31  ○ ○        (last day in 7-day window)
```

Legend: ✅ ordered (active) | 📝 planned (not yet placed) | ○ open | ⏰ cutoff passed | 🔒 outside 7-day window | — not ordered

Only `✅` and `📝` block a slot. Anything else = open.

## Step 4: Summary + Offer

```
This week: 5/10 slots ordered.
Next week: 0/10 slots ordered — 7 open within the 7-day window.
```

If open slots exist within the 7-day window, offer:
```
Want me to order the remaining open slots? Just say which days or meals.
```

---

## Context Window Discipline

When `webox-order` reads order history for variety tracking, it loads only the week files overlapping `history_window_days` (default 28). Older week files stay on disk indefinitely as a long-term record.

This skill's own display loads only this week + next week by default. The user can ask for broader views ("show me last month", "show me everything") and the skill loads correspondingly more week files.
