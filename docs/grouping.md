[← Back to Index](./index.md)

### Grouping

- See also: [Relation](./relation.md), [Materializers](./materializers.md)

#### Overview
Grouping allows you to request de-duplicated, grouped results by a single field while preserving the immutable, composable nature of a `Relation`. Each call returns a new `Relation` with normalized frozen state stored under `state[:grouping]`.

- **Single grouping per relation**: the last call to `group_by` replaces any previous grouping.
- **Normalization**: `{ field: :symbol, limit: Integer/nil, missing_values: true|false }` (frozen).
- **Composition**: plays nicely with `where`, `order`, `include_fields`, and `joins`.

#### API
```ruby
SearchEngine::Product
  .group_by(:brand_id, limit: 1, missing_values: true)
  .where(active: true)
  .order(updated_at: :desc)
```

- `field` (required): Symbol/String; coerced to Symbol; must be non-blank.
- `limit` (optional): Integer > 0 or nil.
- `missing_values` (optional): Boolean; default `false`.

Replacement semantics (last call wins):
```ruby
rel = SearchEngine::Product.group_by(:brand_id)
rel2 = rel.group_by('category_id') # replaces prior grouping
```

#### Behavior notes
- Independent of other chainers; call order does not matter.
- Joined fields are not supported in this ticket; use a base field only.
- Future work will map this state to Typesense params (`group_by`, `group_limit`, and possibly a missing-values flag).

#### Mermaid overview
```mermaid
flowchart LR
  A[Relation#group_by(field, limit, missing_values)] --> B[state[:grouping]\n{ field, limit, missing_values }]
  B --> C[Compiler/Materializer\n(future mapping to Typesense)]
```

#### Debugging
- Reader: `relation.grouping` → returns the frozen Hash or `nil`.
- Explain output includes a compact grouping summary when present:

```text
SearchEngine::Product Relation
  where: active:=true
  order: updated_at:desc
  group: group_by=brand_id limit=1 missing_values=true
```
