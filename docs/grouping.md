[← Back to Index](./index.md)

# Grouping — overview & compiler mapping

Backlinks: [Field Selection](./field_selection.md), [Relation](./relation.md)

See example: `examples/demo_shop/app/controllers/groups_controller.rb`.

- **State source**: `Relation#group_by(field, limit: nil, missing_values: false)` stores normalized state in `@state[:grouping]`
- **Compiler**: `Relation#to_typesense_params` emits Typesense params: `group_by`, `group_limit`, `group_missing_values`

```ruby
rel = SearchEngine::Product.group_by(:brand_id, limit: 1, missing_values: true)
# => { q: "*", query_by: "name, description", group_by: "brand_id", group_limit: 1, group_missing_values: true }
```

| Call | Params |
| --- | --- |
| `.group_by(:brand_id)` | `group_by: "brand_id"` |
| `.group_by(:brand_id, limit: 2)` | `group_by: "brand_id"`, `group_limit: 2` |
| `.group_by(:brand_id, missing_values: true)` | `group_by: "brand_id"`, `group_missing_values: true` |
| `.group_by(:brand_id, limit: 1, missing_values: true)` | `group_by: "brand_id"`, `group_limit: 1`, `group_missing_values: true` |

```mermaid
flowchart LR
  A[Relation#group_by] --> B[@state[:grouping]
  C[Compiler] --> D{ group_by, group_limit, group_missing_values }]
```

```ruby
result = SearchEngine::Product.group_by(:brand_id, limit: 2).to_a
res = SearchEngine::Product.group_by(:brand_id, limit: 2).execute
```

Backlinks: [README](../README.md), [Field Selection](./field_selection.md)

```json
{"event":"search","collection":"products","status":200,"duration.ms":12.3,"cache":true,"ttl":60,"group_by":"brand_id","group_limit":1,"group_missing_values":true}
```
