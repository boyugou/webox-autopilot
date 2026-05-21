# WeBox Preferences

This file lives in ~/Documents/WeBox/ — open it in any editor to change your settings.
Claude reads it at the start of every order session.

To update interactively, just tell Claude Code: "Update my WeBox preferences: I'm vegetarian now."

---

## Budget

```yaml
budget: 30.00
budget_mode: spend-up-to   # spend-up-to | ceiling-only
validate_budget: false      # true: Python sum check before ordering
```

## Ordering Behavior

```yaml
confirm_before_order: false  # false: auto-order | true: show plan first, wait for OK
default_meals:
  - Lunch
  - Dinner
skip_weekends: true          # skip Sat/Sun when ordering a multi-day range
```

## Variety

```yaml
avoid_repeat_days: 7      # don't re-order the same MAIN item within this many days
history_window_days: 28   # how many days of order-history to load into context
                          # (default 28 = ~3 weeks past + the 7-day ordering window)

# Variety only applies to "main" dishes. Sides, drinks, and fillers can repeat freely
# (you might want milk every day, or order 5 waters at once). Items matching any of
# these categories or name patterns are treated as fillers and exempt from variety rules.
allow_repeat_categories:
  - Drink
  - Side
  - Snack
  - Dairy & Eggs
  - Produce

allow_repeat_patterns:    # case-insensitive substring match on item name
  - milk
  - water
  - tea egg
  - sparkling
  - coconut
  - juice
  - yogurt
```

## Category Scraping (saves time)

```yaml
# Controls which menu categories Claude scrapes when favorites aren't enough.
# Set mode to "all" (scrape everything when needed), "whitelist" (only these),
# or "blacklist" (everything except these).
category_mode: blacklist   # all | whitelist | blacklist
category_list:
  - Dessert
  - Burger
  - Pizza
  - Burrito
  - Taco
  - Sandwich
  # Available: Deals, Chinese, Bowl, American, Drink, Side, Entrée, Noodles,
  # Salad, Japanese, Snack, Korean, Produce, Thai, Sandwich, Italian,
  # Vietnamese, Mexican, Burger, Mediterranean, Wrap, Indian, Dairy & Eggs,
  # Greek, Dessert, French, Taco, Sushi, Burrito, Pizza, Filipino, Burmese,
  # Nepalese
```

## Dietary Restrictions

```yaml
restrictions:
  - none   # vegetarian | vegan | gluten-free | halal | kosher | ...
```

## Allergens

```yaml
avoid_allergens:
  - none   # nuts | shellfish | dairy | eggs | soy | wheat | sesame | ...
```

## Cuisine Preferences

```yaml
preferred_cuisines:
  - Chinese
  - Japanese

cuisines_to_avoid:
  - none
```

## Food Preferences

```yaml
foods_i_like:
  - none   # e.g. spicy food, rice-based dishes, cold noodles, bento boxes

foods_to_avoid:
  - none   # e.g. mushrooms, very oily dishes
```

## Drinks

```yaml
order_drinks: true
avoid_sugary_drinks: false
preferred_drinks:
  - water
  - unsweetened tea
```

## Notes

# Anything else Claude should know — free text, any language.
