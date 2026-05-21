# webox-autopilot

> Order your WeBox meals autonomously with Claude Code — favorites-first, budget-aware, variety-conscious.

**webox-autopilot** is a Claude Code skill that lets you order food from [WeBox](https://webox.com) by simply telling Claude what you want. It uses your existing logged-in Chrome session, scrapes the menu, picks items based on your preferences, and checks out — all without leaving your terminal.

```
Order lunch and dinner Mon–Fri next week, Chinese and Japanese only.
```

## Quick Install

**Option A — tell Claude Code to install it for you:**

```
Install the webox-order skill from https://github.com/boyugou/webox-autopilot, then order my lunch for tomorrow.
```

Claude Code reads `CLAUDE.md` in this repo and handles the rest automatically.

**Option B — one-liner:**

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot && bash /tmp/webox-autopilot/install.sh && rm -rf /tmp/webox-autopilot
```

## Requirements

- [Claude Code](https://claude.ai/code) (any recent version)
- Google Chrome with the **[Claude in Chrome](https://claude.ai/docs/claude-code/chrome-extension)** extension
- An active WeBox account (logged in to Chrome)
- A direct Anthropic plan (Pro, Max, Team, or Enterprise)

## Usage

Start Claude Code with Chrome integration:

```bash
claude --chrome
```

Then just ask:

```
Order my lunch for tomorrow.
```

```
Order lunch and dinner Mon–Fri next week. Prefer Chinese food, budget $25.
```

```
Order dinner for tonight — something healthy, under $20.
```

```
Update my WeBox preferences: I'm vegetarian now.
```

## How It Works

```
User prompt
    │
    ▼
1. Read ~/.webox-autopilot/user-preferences.md
    │
    ▼
2. Check /order/list/normal → skip already-ordered dates
    │
    ▼
3. Scrape favorites page → available items with prices
   (+ cuisine categories if needed for variety)
    │
    ▼
4. Select items within budget using preferences + prompt
    │
    ▼
5. For each item: add to cart
   • No options  → JS click (instant)
   • Simple options (e.g. "Choose Rice") → accept default → Add to Cart
   • Complex options (poke bowls, build-your-own) → Claude uses judgment
    │
    ▼
6. Quick Checkout → order confirmed ✅
```

## Defaults

| Setting | Default |
|---------|---------|
| Meal types | Lunch **and** Dinner (when not specified) |
| Multi-day ranges | Weekdays only (Mon–Fri); weekends skipped |
| Budget | $30.00 per meal slot |
| Budget mode | Spend-up-to (use most of budget with variety) |

## Persistent Preferences

Edit `~/.webox-autopilot/user-preferences.md` to set:

- Budget and budget mode
- Dietary restrictions and allergens
- Preferred / avoided cuisines
- Specific foods to always or never order
- Drink policy

Claude reads this at the start of every order session. The file is created from the template in this repo on first install.

## Automation Breakdown

| Step | Method | Reliability |
|------|--------|-------------|
| Scrape menu items | Pure JavaScript | ✅ 100% |
| Check existing orders | Pure JavaScript | ✅ 100% |
| Add to cart (no options) | JS click | ✅ 100% |
| Add to cart (simple options) | JS click + find "Add to Cart" | ✅ 95% |
| Add to cart (complex options) | Claude model judgment | Adaptive |
| Checkout | find "Quick Checkout" + click | ✅ 99% |

## FAQ

**Q: Will it double-order a day I've already ordered?**
A: No — it checks your order history first and skips any already-ordered date+meal.

**Q: What if an item is sold out?**
A: Sold-out items are filtered during scraping. Claude picks the next best available option.

**Q: What if the total would exceed my budget?**
A: Claude won't add an item that would push the food total over budget. It picks cheaper alternatives.

**Q: Can I cancel an order it placed?**
A: Yes — go to `webox.com/order/list/normal` and cancel within the allowed window.

**Q: Does it work for Dinner and HappyHour?**
A: Yes — specify the meal type in your prompt, or Claude defaults to both Lunch and Dinner.

**Q: How far in advance can it order?**
A: WeBox allows ordering up to 7 days ahead. Claude won't attempt dates beyond that window.

## Updating

```bash
git clone https://github.com/boyugou/webox-autopilot.git /tmp/webox-autopilot && bash /tmp/webox-autopilot/install.sh && rm -rf /tmp/webox-autopilot
```

Your `~/.webox-autopilot/user-preferences.md` is never overwritten by updates.

## Contributing

PRs welcome. Key areas:

- Smarter item selection heuristics
- HappyHour / weekend ordering support  
- Cancel-order functionality
- Weekly meal planning with persistent state
- Budget tracking across multiple orders

## License

Apache 2.0 — see [LICENSE](LICENSE).
