# Presets: Relation#preset and Merge Strategies

Back to: [Index](./index.md) · See also: [Relation](./relation.md) · Multi-search: [Multi](./multi_search.md)

## Overview

Apply a server-side preset to a relation with a selectable merge strategy using `Relation#preset(name, mode: :merge)`.

### Examples

```ruby
# Merge (default)
SearchEngine::Product.preset(:popular_products)
  .where(active: true)
  .order(updated_at: :desc)

# Only preset
SearchEngine::Product.preset(:aggressive_sale, mode: :only).page(1).per(24)

# Locked preset (chain cannot override preset filters/sorts)
SearchEngine::Product.preset(:brand_curated, mode: :lock).order(price: :asc) # order will be dropped
```

## Namespacing

Effective preset name is computed using global presets configuration (`SearchEngine.config.presets`). When enabled and a non-empty `namespace` is present, the effective name is `"#{namespace}_#{token}"`; otherwise the token is used as-is.

- **Enabled + namespace:** `prod_popular_products`
- **Disabled or no namespace:** `popular_products`

## Strategies

- **mode=:merge (default)**: preset is emitted along with all chain-derived params; on key overlaps, chain wins (Typesense semantics). No conflicts recorded.
- **mode=:only**: preset is emitted and only essential params are kept from the chain. Optional params like `filter_by`, `sort_by`, `include_fields` are dropped. No conflicts recorded.
- **mode=:lock**: preset is emitted and chain params are kept except those managed by preset (`filter_by`, `sort_by`, `include_fields`, etc.). Dropped keys are recorded and surfaced by `explain`.

### Strategy comparison

| Mode  | What is sent | Who wins on overlaps | Conflicts recorded |
|------|---------------|----------------------|--------------------|
| merge | preset + all chain params | chain | no |
| only  | preset + essentials (q, query_by, page, per_page, infix) | n/a (others dropped) | no |
| lock  | preset + chain minus preset-managed keys | preset | yes (dropped keys) |

## Explain & Inspect

- `inspect` adds a compact token, e.g., `preset=prod_popular_products(mode=lock)` when applied.
- `explain` prints a `preset:` line and, for `mode: :lock`, includes `dropped:` keys, e.g. `preset: prod_popular_products (mode=lock dropped: filter_by,sort_by)`.

## Mermaid: strategy flow

```mermaid
flowchart TD
  A[Relation#preset(name, mode)] --> B[Compute effective preset name (namespace?)]
  B --> C{mode}
  C -- merge --> D[Emit preset + all chain params; chain wins on overlaps]
  C -- only --> E[Emit preset + ESSENTIAL params only]
  C -- lock --> F[Emit preset + chain params; drop chain keys in PRESET_MANAGED; record conflicts]
  D --> G[Final Typesense params]
  E --> G
  F --> G
```

## Notes

- Essential params include: `q`, `query_by`, `page`, `per_page`, `infix`.
- Preset-managed keys include: `filter_by`, `sort_by`, `include_fields`, `exclude_fields`, `facet_by`, `max_facet_values`, `group_by`, `group_limit`, `group_missing_values`.
- The API is immutable and copy-on-write; invalid mode or name raises `ArgumentError`.
