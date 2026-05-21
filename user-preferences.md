# WeBox Order Preferences

This file is read by the `webox-order` Claude Code skill at the start of every session.
Edit any field and the next order will pick up your changes automatically.

---

## Budget

```yaml
budget: 30.00           # Hard cap per meal slot (food items only, not fees)
budget_mode: spend-up-to  # spend-up-to | ceiling-only
                          # spend-up-to: aim to use most of the budget with variety
                          # ceiling-only: pick the best items without trying to fill the budget
validate_budget: false    # true: run a Python script to strictly verify item totals <= budget
                          # false: trust Claude's arithmetic (faster, usually fine)
```

## Confirmation Mode

```yaml
confirm_before_order: false  # false (auto): Claude decides and orders in one shot,
                             #   only pauses for errors or genuine ambiguity
                             # true (confirm): Claude presents the full plan first,
                             #   waits for your approval before placing any orders
```

## Plan Cache

```yaml
plan_cache_days: 14   # Keep plan history for this many days (used for variety tracking
                      # and as a record of what was ordered). Set to 0 to disable caching.
```

## Meal Type Defaults

```yaml
default_meals:
  - Lunch
  - Dinner
# When no meal type is specified, order both Lunch and Dinner.
# Set to [Lunch] if you only want lunch ordered by default.

skip_weekends: true   # true: skip Sat/Sun when ordering a multi-day range (default)
                      # false: include weekends (only useful for HappyHour / Self Pay)
```

## Dietary Restrictions (Always Enforced)

```yaml
restrictions:
  - none   # vegetarian | vegan | gluten-free | halal | kosher | ...
```

## Allergens to Avoid

```yaml
avoid_allergens:
  - none   # nuts | shellfish | dairy | eggs | soy | wheat | sesame | ...
```

## Cuisine Preferences

```yaml
preferred_cuisines:
  - Chinese
  - Japanese
  # Korean | Indian | Mediterranean | Thai | Salads | ...

cuisines_to_avoid:
  - none
```

## Food Preferences

```yaml
foods_i_like:
  - none   # e.g. spicy food, rice-based dishes, cold noodles, bento boxes

foods_to_avoid:
  - none   # e.g. mushrooms, very spicy dishes, fried food
```

## Drink Policy

```yaml
order_drinks: true          # Include drinks in orders
avoid_sugary_drinks: false
preferred_drinks:
  - water
  - unsweetened tea
  # coconut water | sparkling water | organic milk | ...
```

## Other Notes

```yaml
avoid_repeat_days: 3   # Avoid re-ordering the same item if it was ordered within this many days
```

# (Additional free-text notes for Claude)
# Add anything here that doesn't fit the structured fields above.
# Example: "Prefer eco-friendly packaging when available."
#          "I'm trying to eat less red meat this month."
