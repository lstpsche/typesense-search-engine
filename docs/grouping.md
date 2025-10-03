[← Back to Index](./index.md) · [Relation](./relation.md) · [Compiler](./compiler.md) · [Materializers](./materializers.md)

# Grouping

Group results by a field and optionally control the number of hits per group and whether documents with missing values form their own group.

- **State source**: `Relation#group_by(field, limit: nil, missing_values: false)` stores normalized state in `@state[:grouping]`
- **Compiler**: `Relation#to_typesense_params` emits Typesense params: `group_by`, `group_limit`, `group_missing_values`

## Quick example

```ruby
rel = SearchEngine::Product.group_by(:brand_id, limit: 1, missing_values: true)
rel.to_typesense_params
# => { q: "*", query_by: "name, description", group_by: "brand_id", group_limit: 1, group_missing_values: true }
```

## Mapping (Ruby DSL → Typesense params)

| Ruby DSL                                       | Typesense params                                                                     |
| ---                                            | ---                                                                                  |
| `.group_by(:brand_id)`                         | `group_by: "brand_id"`                                                              |
| `.group_by(:brand_id, limit: 2)`               | `group_by: "brand_id"`, `group_limit: 2`                                           |
| `.group_by(:brand_id, missing_values: true)`   | `group_by: "brand_id"`, `group_missing_values: true`                                |
| `.group_by(:brand_id, limit: 1, missing_values: true)` | `group_by: "brand_id"`, `group_limit: 1`, `group_missing_values: true`   |

Notes:
- `group_limit` is included only when provided and must be a positive integer
- `group_missing_values` is included only when `true`

## State → Params

```mermaid
flowchart LR
  A[Relation#group_by] --> B[@state[:grouping]
{ field, limit, missing_values }]
  B --> C[Relation#to_typesense_params]
  C --> D[Typesense params
{ group_by, group_limit, group_missing_values }]
```

## Working with groups

```ruby
result = SearchEngine::Product.group_by(:brand_id, limit: 2).to_a
# result is an Array of first hit per group
res = SearchEngine::Product.group_by(:brand_id, limit: 2).execute
res.grouped?       #=> true
res.groups.first.key   #=> { "brand_id" => 12 }
res.groups.first.hits  #=> [<Product ...>, <Product ...>] # hydrated
```

- **key**: Hash mapping field name → value, e.g., `{ "brand_id" => 12 }`. Missing values are represented as `nil`.
- **hits**: Hydrated objects in backend order within the group.
- **size**: Number of hits in the group (alias to `hits.length`).

`Result#hits` / `to_a` remain ergonomic: when grouped, they return the first hydrated hit from each group (skipping empty groups). When not grouped, they return all hydrated hits as before.

### Response flow

```mermaid
flowchart TD
  A[Typesense grouped response] -->|grouped_hits| B[Result shaping]
  B --> C[Groups array (Result::Group)]
  C --> D[First-hit list for hits/to_a]
```

### Gotchas

- **Ordering**: Group order and within-group hit order are preserved.
- **Large groups**: Accessing `groups` hydrates hits per group; be mindful of memory for very large `group_limit`.
- **Access patterns**: Use `#groups` / `#each_group` to iterate all hits; use `#to_a` / `#hits` when only the first hit per group is needed.

## Pagination interaction

When grouping is enabled, Typesense applies `per_page` to the number of groups returned. `group_limit` caps the number of hits within each group. For example, `per(10)` returns up to 10 groups; with `group_limit: 3`, each group contains at most 3 hits.

## Validation

- `field` must be present as a Symbol or String
- `limit` must be a positive Integer when provided
- `missing_values` must be a Boolean

## Guardrails & errors

Backlinks: [← Back to Index](./index.md) · [Relation](./relation.md) · [Materializers](./materializers.md)

Misuse → behavior:

- Unknown field:
  - Raises `SearchEngine::Errors::InvalidGroup` with suggestions when available.
  - Example error:
    - `InvalidGroup: unknown field :brand for grouping on SearchEngine::Product (did you mean :brand_id?)`
- Invalid limit:
  - Raises `SearchEngine::Errors::InvalidGroup`.
  - Example: `InvalidGroup: limit must be a positive integer (got 0)`
- Non-boolean `missing_values`:
  - Raises `SearchEngine::Errors::InvalidGroup`.
  - Example: `InvalidGroup: missing_values must be boolean (got "yes")`
- Unsupported path (joined field):
  - Raises `SearchEngine::Errors::UnsupportedGroupField`.
  - Example: `UnsupportedGroupField: grouping supports base fields only (got "$authors.last_name")`

Warnings (non-fatal, can be suppressed via `SearchEngine.config.grouping.warn_on_ambiguous = false`):

- Grouping with `order`: `order` affects hits, not group ordering; groups follow engine ranking. Use filters to control which items appear as the first hit per group.
- Grouping by a field that is omitted from `include_fields`: Consider including the field or read it from `Group#key`.
- `missing_values: true` while filters exclude `null` for the grouping field: May produce fewer "missing" groups than expected.

Examples:

```ruby
# Raises unknown field with suggestion
SearchEngine::Product.group_by(:brand)

# Raises invalid limit
SearchEngine::Product.group_by(:brand_id, limit: 0)

# Warns about order not affecting group ordering
SearchEngine::Product.group_by(:brand_id).order(updated_at: :desc).to_typesense_params
```

See also: [Relation](./relation.md) · [Compiler](./compiler.md) · [Materializers](./materializers.md)
