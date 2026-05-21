# WeBox Order Preferences

This file is read by the `webox-order` Claude Code skill to personalize food ordering.
Edit it any time — Claude will apply these preferences on the next order.

## Budget

```
budget: 30.00
mode: spend-up-to   # Options: spend-up-to | ceiling-only
```

- `spend-up-to`: Try to use most of the budget while keeping variety (default)
- `ceiling-only`: Budget is just a hard limit; pick what seems best

## Dietary Restrictions (Always Enforced)

```
restrictions:
  - none   # Replace with: vegetarian, vegan, gluten-free, halal, kosher, etc.
```

## Allergens to Avoid

```
avoid_allergens:
  - none   # Replace with: nuts, shellfish, dairy, eggs, soy, wheat, sesame, etc.
```

## Cuisine Preferences

```
preferred_cuisines:
  - Chinese
  - Japanese

cuisines_to_avoid:
  - none
```

## Food Preferences

Things I like:
- (Add your preferences, e.g., "spicy food", "rice-based dishes", "light salads")

Things I dislike / never order:
- (Add items to avoid, e.g., "mushrooms", "very spicy dishes", "sugary drinks")

## Drink Policy

```
order_drinks: true       # Whether to include drinks in orders
avoid_sugary_drinks: false
preferred_drinks:
  - water
  - unsweetened tea
```

## Other Notes

- (Any other ordering preferences, e.g., "prefer eco-friendly packaging", "avoid reordering the same item within 3 days")
