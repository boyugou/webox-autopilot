---
name: webox-calendar
description: View and sync the local WeBox order calendar. Shows which meal slots are filled or open for this week and next week, syncs from WeBox order history, and maintains a long-term local record. Use when the user asks to see their order calendar, check what's been ordered, or sync their order history.
---

# WeBox Calendar Skill

Maintains and displays the local WeBox order calendar at `~/.webox-autopilot/order-calendar.md`.

The calendar has two distinct layers:
- **Long-term storage**: all ordered slots ever recorded, kept in the file indefinitely
- **Active context window**: only the past 14 days + next 7 days are loaded into working memory — enough for variety tracking and display, without ballooning context

---

## Step 1: Sync from WeBox

Always pull a fresh snapshot from WeBox regardless of cache age — this skill's purpose is to sync.

Navigate to `https://www.webox.com/order/list/normal` and extract all orders:

```javascript
(async () => {
  const orders = [...document.querySelectorAll('.order-item')].map(o => {
    const lines = o.innerText.split('\n').map(l => l.trim()).filter(Boolean);
    const dateLine = lines.find(l => /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+\d{2}\/\d{2}$/.test(l));
    const mealLine = lines.find(l => /Lunch|Dinner|HappyHour|Breakfast/.test(l));
    // Try to get order number if visible
    const orderNum = lines.find(l => /^#\d+/.test(l) || /Order\s*#\d+/i.test(l));
    return { date: dateLine, meal: mealLine, orderNum: orderNum || null };
  }).filter(o => o.date && o.meal);
  return JSON.stringify(orders);
})()
```

Also cross-reference with the existing `~/.webox-autopilot/plan-cache.md` to enrich slots with item details where available.

## Step 2: Update order-calendar.md

Read the existing `~/.webox-autopilot/order-calendar.md`. Merge the freshly scraped data:
- Add any new slots not already in the file
- Do not remove existing entries (the WeBox order list only shows recent history; older local entries may be correct)
- Update `last_synced` timestamp

### Calendar File Format

```markdown
# WeBox Order Calendar
last_synced: YYYY-MM-DD

<!-- Long-term record — do not prune. Only the active window is displayed. -->

## YYYY-MM
- Mon MM/DD Lunch  ✅ #3258578 | Mongolian Beef bento, Tea Egg, Taboulleh Salad
- Mon MM/DD Dinner ✅ #3258600 | Lanzhou Beef Noodles, Coconut Water
- Tue MM/DD Lunch  ✅ #3258601
- Wed MM/DD Lunch  —  (skipped — cutoff passed)
- Thu MM/DD Lunch  ✅ #3258578
- Fri MM/DD Lunch  ✅ #3258614 | Mongolian Beef bento, Tea Egg, Taboulleh Salad
- Fri MM/DD Dinner —  (not ordered)
```

Item details come from `plan-cache.md` when available; otherwise just the order number.

## Step 3: Display the Active Window

Show a formatted calendar covering **this week and next week** (Mon–Fri only unless the user asked for weekends):

```
📅 WeBox Order Calendar — Week of May 20 & May 27

This week (May 20–24)
  Mon May 20  Lunch  ✅  Mongolian Beef bento, Tea Egg, Taboulleh Salad
              Dinner —   not ordered
  Tue May 21  Lunch  ✅  [items from plan cache or just ✅]
              Dinner —   not ordered
  Wed May 22  Lunch  ⏰  cutoff passed — not ordered
  Thu May 23  Lunch  ✅
  Fri May 24  Lunch  ✅  Mongolian Beef bento, Tea Egg, Taboulleh Salad
              Dinner —   not ordered

Next week (May 27–31)
  Mon May 27  Lunch  ○   available
              Dinner ○   available
  Tue May 28  Lunch  ○   available
  ...         ...    ...
  [7-day window limit: orders beyond this date are not yet possible]
```

Legend:  ✅ ordered  ○ open  ⏰ cutoff passed  — not ordered  🔒 outside 7-day window

## Step 4: Summarize

After the calendar display, print a one-line summary:

```
This week: 5/10 slots ordered. Next week: 0/10 slots ordered — 7 open within the 7-day window.
```

If any open slots are within the 7-day ordering window, offer:
```
Want me to order the remaining open slots? Just say which days or meals.
```

## Context Window Discipline

When reading `order-calendar.md` for use by the `webox-order` skill (variety tracking), load only the entries from the past `avoid_repeat_days` days (default: 3). Do not load the full long-term history into context — it's there for the record, not for active reasoning.
