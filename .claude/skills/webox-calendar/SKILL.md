---
name: webox-calendar
description: View and sync the local WeBox order history calendar. Shows which meal slots are filled or open for this week and next week, syncs from WeBox order history, and maintains a long-term local record. Use when the user asks to see their order calendar, check what's been ordered, or sync their order history.
---

# WeBox Calendar Skill

Displays and syncs `~/Documents/WeBox/order-history.md` — the unified record of all WeBox orders (past, planned, and skipped).

The file has two layers:
- **Long-term storage:** all order entries kept indefinitely
- **Active window:** only entries within `history_window_days` (default 28 = ~3 weeks past + 7-day future window) loaded into context

---

## Step 1: Sync from WeBox

This skill always pulls a fresh snapshot regardless of cache age — syncing is its purpose.

Navigate to `https://www.webox.com/order/list/normal`. Scroll 5–10 times to load history:

```javascript
(async () => {
  for (let i = 0; i < 5; i++) {
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 800));
  }
  const orders = [...document.querySelectorAll('.order-item')].map(o => {
    const lines = o.innerText.split('\n').map(l => l.trim()).filter(Boolean);
    const dateLine = lines.find(l => /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{2}\/\d{2}$/.test(l));
    const mealLine = lines.find(l => /Lunch|Dinner|HappyHour|Breakfast/.test(l));
    const orderNum = lines.find(l => /^#\d+/.test(l) || /Order\s*#\d+/i.test(l));
    const itemLines = lines.filter(l =>
      l !== dateLine && l !== mealLine && l !== orderNum &&
      l.length > 3 && !/^\$/.test(l) && !/^(Cancel|View|Reorder|Track)/i.test(l)
    );
    return { date: dateLine, meal: mealLine, orderNum: orderNum || null, items: itemLines };
  }).filter(o => o.date && o.meal);
  return JSON.stringify(orders);
})()
```

If the user asks to "sync everything" or "pull all my history", scroll 20+ times to load deeper history.

## Step 2: Merge into order-history.md

Read `~/Documents/WeBox/order-history.md`. Merge the fresh scrape:
- Add slots not already in the file (new orders since last sync)
- Don't remove existing entries — local entries may have more detail (planned status, substitutions, item-level breakdown) than the scraped snapshot
- For slots that exist locally as `📝 planned` but now appear as scraped (real orders), update the status to `✅ #ORDERNUM` and keep the local item detail
- Update `last_synced:` to today

### Unified File Format

```markdown
# WeBox Order History
last_synced: YYYY-MM-DD

<!-- Long-term record. Recent entries (within history_window_days) are loaded for variety tracking. -->

## 2026-05

### Mon 05/18 Lunch ✅ #3258400
- Xiangchuan Kitchen — Mongolian Beef Bento × 1
- Northwest China Cuisine — Tea Egg × 2

### Mon 05/18 Dinner ✅ #3258411 — $20.50
- Ox 9 Lanzhou — Sliced Spicy Beef × 1
- Horizon — Organic Milk × 1

### Tue 05/19 Lunch ✅ #3258450
- (items not recorded — synced from history without detail)

### Thu 05/21 Lunch ✅ #3258578 — $26.85
- Xiangchuan Kitchen — Mongolian Beef Bento × 1
- Northwest China Cuisine — Tea Egg × 2
- Mediterranean Grill House — Taboulleh Salad × 1

### Fri 05/22 Lunch ✅ #3258614 — $25.85

### Fri 05/22 Dinner 🚫 — not ordered
```

Status icons:
- `✅` ordered (with order number, total optional)
- `📝` planned (not yet placed — managed by `webox-order`)
- `⏰` cutoff passed
- `🚫` skipped / not ordered
- `🔒` outside 7-day window

## Step 3: Display the Active Window

Show this week and next week (Mon–Fri unless the user asks for weekends):

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

Legend:  ✅ ordered  📝 planned  ○ open  ⏰ cutoff passed  🚫 skipped  🔒 outside window  — not ordered

## Step 4: Summary + Offer

```
This week: 5/10 slots ordered.
Next week: 0/10 slots ordered — 7 open within the 7-day window.
```

If any open slots are within the 7-day ordering window, offer:
```
Want me to order the remaining open slots? Just say which days or meals.
```

---

## Context Window Discipline

When `webox-order` reads this file for variety tracking, load only entries within `history_window_days` (default 28). Older entries stay in the file but are not loaded — they're the long-term record.

For `webox-calendar`'s own display, only the active week + next week is shown by default. The user can ask for a broader view ("show me last month") and the skill loads correspondingly more.
