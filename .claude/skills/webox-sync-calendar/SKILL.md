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
  const orders = [...document.querySelectorAll('.order-item')].map(o => {
    const orderId = o.querySelector('.order-id')?.innerText?.trim();
    const orderStatus = o.querySelector('.order-status')?.innerText?.trim();
    const lines = o.innerText.split('\n').map(l => l.trim()).filter(Boolean);
    const dateLine = lines.find(l => /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{2}\/\d{2}$/.test(l));
    const mealLine = lines.find(l => /^(Lunch|Dinner|HappyHour)(\s|\(|$)/.test(l));
    const meal = mealLine?.match(/^(Lunch|Dinner|HappyHour)/)?.[1];
    const itemLines = lines.filter(l =>
      l !== dateLine && l !== mealLine && l !== orderId && l !== orderStatus &&
      !/^(Order|Invoice|Details|Reorder|Cancel|View|Track|Total:|Refunded|Paid|No\.\d)/i.test(l) &&
      !/^\$/.test(l) && l.length > 3
    );
    const isActive = !orderStatus || !/refund|cancel/i.test(orderStatus);
    return { date: dateLine, meal, orderId, orderStatus: orderStatus || 'active', isActive, items: itemLines };
  }).filter(o => o.date && o.meal && o.isActive);  // FILTER cancelled/refunded out
  return JSON.stringify(orders);
})()
```

## Step 2: Merge into per-week JSON files

For each scraped order:
1. Convert `"Mon 05/18"` to a full ISO date (use current year; if the resulting date is in the future, use previous year).
2. Compute the ISO week → `YYYY-Www` (e.g. `2026-W21`).
3. Read or create `~/Documents/WeBox/orders/<YYYY-Www>.json` with the schema below.
4. Dedupe new orders against existing entries by `orderId`. New orders → append. Existing → update.
5. Preserve any local `status: "planned"` entries until they appear as `"active"` in the scrape (then update inline).
6. Set `synced_at` on every touched week file.

### Per-week file schema

```json
{
  "week": "2026-W21",
  "week_starts": "2026-05-18",
  "synced_at": "2026-05-21T14:30:00",
  "orders": [
    {
      "date": "2026-05-18",
      "day": "Mon",
      "meal": "Lunch",
      "orderId": "No.3258400",
      "status": "active",
      "total": 28.30,
      "items": [
        { "brand": "Xiangchuan Kitchen", "name": "Mongolian Beef Bento", "qty": 1, "price": 17.45 },
        { "brand": "Northwest China Cuisine", "name": "Tea Egg", "qty": 2, "price": 2.45 }
      ]
    }
  ]
}
```

**Cancelled/refunded orders are filtered out at scrape time and never written.** The slot stays openable. If the user wants to audit cancelled history, point them at `/order/list/normal`.

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
