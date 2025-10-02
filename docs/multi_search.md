[← Back to Index](./index.md) · [Client](./client.md) · [Materializers](./materializers.md)

## Multi-search DSL

Federate multiple labeled `Relation`s into a single Typesense multi-search request while preserving order and mapping results back to labels.

- **Pure builder:** collects labeled relations, no HTTP
- **Order preserved:** results map back in insertion order
- **Unique labels:** labels are case-insensitive and must be unique
- **Common params:** `common:` is shallow-merged into each per-search payload; per-search keys win
- **No URL knobs in body:** cache options are handled as URL/common params by the client

### DSL

```ruby
res = SearchEngine.multi_search(common: { query_by: SearchEngine.config.default_query_by }) do |m|
  m.add :products, Product.where(category_id: 5).select(:id, :name).per(10)
  m.add :brands,   Brand.where('name:~rud').per(5)
end

res[:products].found
res.dig(:brands).to_a
res.labels #=> [:products, :brands]
```

### Label rules

- Accepts `String` or `Symbol`
- Canonicalization: `label.to_s.downcase.to_sym`
- Must be unique (case-insensitive)

### Common params merge

- Merge precedence: per-search params override `common:` keys
- URL-only keys filtered from bodies: `use_cache`, `cache_ttl` (these live in URL opts)
- Example:

```ruby
res = SearchEngine.multi_search(common: { q: 'milk', per_page: 50 }) do |m|
  m.add :products, Product.all.per(10) # per_page: 10 overrides common 50
  m.add :brands,   Brand.all           # per_page not present, inherits 50
end
```

### Mapping (Relation → per-search payload)

| Relation aspect | Per-search key |
| --- | --- |
| query (`q`, default `*`) | `q` |
| fields to search | `query_by` |
| filters (AST / `where`) | `filter_by` |
| order (`order`) | `sort_by` |
| select (`select`) | `include_fields` |
| pagination (`page`/`per`) | `page`, `per_page` |
| infix (config or override) | `infix` |

Example payload shape:

```ruby
{
  collection: "products",
  q: "*",
  query_by: SearchEngine.config.default_query_by,
  filter_by: "category_id:=5",
  include_fields: "id,name",
  per_page: 10
}
```

### Compile flow

```mermaid
flowchart LR
  A[Relations] --> B[Params compile]
  B --> C[Merge common]
  C --> D[searches[] payload]
```

### Per-search API key policy

Per-search `api_key` is not supported by the underlying Typesense multi-search API. Passing a non-nil `api_key` to `m.add` raises an `ArgumentError`. Use the global `SearchEngine.config.api_key` instead.

### Result mapping

The helper pairs Typesense responses back to the original labels and model classes, returning a `SearchEngine::Multi::ResultSet`:

- `#[]` / `#dig(label)` → `SearchEngine::Result`
- `#labels` → `[:label_a, :label_b, ...]` in insertion order
- `#to_h` → `{ label: Result, ... }`
- `#each_pair` → iterate `(label, result)` in order

### See also

- [Client](./client.md) for URL/common params and error mapping
- [Relation](./relation.md) for query composition and compilation
