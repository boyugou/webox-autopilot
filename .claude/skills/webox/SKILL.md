---
name: webox
description: General WeBox knowledge loader for ad-hoc tasks. Loads URL patterns, DOM selectors, and useful JavaScript snippets, then lets the agent decide how to handle the request. Use for free-form WeBox questions like "what's available for lunch tomorrow", "check my cart", "search for noodles on Friday", "show what's in my favorites" — anything that doesn't fit the dedicated webox-order / webox-favorite / webox-sync-calendar / webox-onboard / webox-reset skills.
---

# WeBox General Skill (Knowledge Loader)

This skill is invoked for **ad-hoc WeBox tasks** that don't map cleanly to one of the dedicated skills. It loads environment knowledge and lets the agent improvise.

## Step 1: Load WeBox knowledge

Read `~/.claude/skills/webox/SITEMAP.md` (full content). It catalogs:
- All URL patterns (favorites, cuisine categories, food-type categories, search via `queryText`, checkout, order history)
- DOM selectors for menu cards, modals, cart, qty stepper, order list, checkout
- Two checkout paths (Path A: cart icon → /checkout → Place Order; Path B: side drawer Quick Checkout)
- Login state probe
- Background-tab caveats (sequential scraping is the safe contract)
- Multi-window limitation (Claude in Chrome can't open new windows)
- Useful tiny scripts (search, cart inspect, clear cart)

## Step 2: Prerequisite check

1. Call `tabs_context_mcp`. If no tabs, ask the user to enable [Claude in Chrome](https://code.claude.com/docs/en/chrome).
2. Verify WeBox login: navigate to `https://www.webox.com` and check for `a.cart.fr` (only present when logged in).

If the user has a `~/Documents/WeBox/preferences.md`, you may also consult it for context (budget, dietary, etc.) — but this skill doesn't require onboarding.

## Step 3: Use judgment

You now have:
- Full WeBox URL and DOM knowledge (SITEMAP.md)
- A logged-in Chrome session
- The user's specific request

Decide how to handle it. Common patterns:

| User says | Recommended approach |
|---|---|
| "What's available for dinner Friday?" | Navigate to favorites URL for Friday Dinner, scrape, summarize |
| "Search for noodles on Tuesday" | Navigate to `?date=...&queryText=noodles`, list top results |
| "What's in my cart?" | Navigate to `/checkout` via `a.cart.fr` click, list line items |
| "Clear my cart" | Use the clear-cart script from SITEMAP.md |
| "Open the WeBox order history page" | Navigate to `/order/list/normal` |
| "Show me my last 3 orders" | Scrape `/order/list/normal`, return top 3 active entries |
| "Cancel my order #123" | This requires user interaction — open `/order/list/normal` and direct the user to cancel manually (WeBox confirms cancellation via a modal we don't automate) |

**JS-first principle still applies** — use URL navigation and JS selectors from SITEMAP.md rather than slow image+coordinate clicks.

## Step 4: When to hand off to a dedicated skill

If the user's request matches a dedicated skill's job, suggest invoking that skill explicitly rather than improvising:

- Wants to **place an order** → `/webox-order` (smart default, full curated menu) or `/webox-favorite` (favorites-only narrow)
- Wants to **view/sync their order calendar** → `/webox-sync-calendar`
- Wants to **set up or update preferences** → `/webox-onboard`
- Wants to **wipe local data** → `/webox-reset`

For everything else — search, inspect, browse, ad-hoc queries — handle it inline using SITEMAP.md.

## Step 5: Don't write to local files

This skill is read-only by default. Don't modify `~/Documents/WeBox/` files (preferences, order-history, item-reviews, menu-cache) unless the user explicitly asks for it (e.g., "save this dish as a 5/5 review" — that would map to appending to `item-reviews.md`).

Mutations belong in the dedicated skills which have proper state-management logic.
