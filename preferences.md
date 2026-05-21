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
avoid_repeat_days: 3    # don't re-order the same item within this many days
plan_cache_days: 14     # keep order history for variety tracking (days)
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
