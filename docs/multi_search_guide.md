[← Back to Index](./index.md)

## Federated multi‑search: guide & patterns

Concise reference for running multiple labeled searches in a single Typesense round‑trip, handling results, and applying safe URL‑level caching.

- **What it is**: federates multiple `Relation`s into one request; results are mapped back to labels in order.
- **When to use**: homepage modules, typeahead+categories, federated search blocks; prefer it over multiple sequential calls to reduce latency.
- **When not to use**: completely independent pages with different lifecycles or when strong isolation/errors per request are critical.

### Builder DSL

Use `SearchEngine.multi_search(common: …) { |m| m.add(label, relation) }`. The `common:` hash is shallow‑merged into each compiled relation payload; per‑search values from the relation win on key conflicts.

Required verbatim example:

```ruby
res = SearchEngine.multi_search(common: { query_by: SearchEngine.config.default_query_by }) do |m|
  m.add :products, SearchEngine::Product.where(category_id: 5).per(5)
  m.add :brands,   SearchEngine::Brand.where("name:~rud").per(3)
end
res[:products].to_a
```

Minimal variations:

- Override pagination per search while inheriting `common:`:
  ```ruby
  res = SearchEngine.multi_search(common: { q: "milk", per_page: 50, query_by: SearchEngine.config.default_query_by }) do |m|
    m.add :products, SearchEngine::Product.all.per(10) # per_page=10 overrides common 50
    m.add :brands,   SearchEngine::Brand.all            # inherits per_page=50
  end
  ```
- Add field selection per search:
  ```ruby
  res = SearchEngine.multi_search(common: { q: "*", query_by: SearchEngine.config.default_query_by }) do |m|
    m.add :products, SearchEngine::Product.select(:id, :name).per(6)
    m.add :brands,   SearchEngine::Brand.select(:id).per(3)
  end
  ```

### Per‑search overrides

Per‑relation chainers and `options(...)` override or augment `common:` on a per‑entry basis:

- `where`/filters → `filter_by`
- `order` → `sort_by`
- `select`/`exclude` → `include_fields`/`exclude_fields`
- `page`/`per` → `page`/`per_page`
- `options(q: ..., query_by: ..., infix: ...)` map into the compiled body

Example (per‑search `query_by` and `filters` override `common:`):

```ruby
res = SearchEngine.multi_search(common: { q: params[:q].presence || "*", query_by: SearchEngine.config.default_query_by }) do |m|
  m.add :products, SearchEngine::Product.where(active: true).options(query_by: "name,description").per(6)
  m.add :brands,   SearchEngine::Brand.where(["name PREFIX ?", params[:q].to_s.first(12)]).per(3)
end
```

Guardrails:
- **Consistent `query_by` per collection**: ensure each collection’s fields exist; unknown fields raise during compile when strict field checks are enabled.
- **URL‑only knobs**: `use_cache`, `cache_ttl` live at the URL level and are filtered from both `common:` and per‑search bodies.

### Result handling with MultiResult

`SearchEngine.multi_search` returns `SearchEngine::Multi::ResultSet` (hash‑like). If you prefer a dedicated wrapper, use `SearchEngine.multi_search_result` which returns `SearchEngine::MultiResult`.

- Hash‑like access: `res[:products]` (matches the labels you added)
- Each entry is a `SearchEngine::Result` with `#to_a`, `#found`, `#empty?`, `#raw`, etc.
- Order is preserved; labels are case‑insensitive symbols internally.

From the snippet above, `res[:products].to_a` returns hydrated hits for the `:products` entry.

Example with `MultiResult` directly:

```ruby
mr = SearchEngine.multi_search_result(common: { q: params[:q].presence || "*", query_by: SearchEngine.config.default_query_by }) do |m|
  m.add :products, SearchEngine::Product.per(6)
  m.add :brands,   SearchEngine::Brand.per(3)
end

products = mr[:products]
brands   = mr[:brands]

count = products&.found.to_i
empty = brands&.empty?
```

Partial failures: if Typesense returns per‑entry error statuses inside a 200 response, inspect `entry.raw` to branch UI gracefully (avoid raising globally):

```ruby
entry = mr[:brands]
if (code = entry&.raw&.fetch("code", 200).to_i) != 200
  # render a soft error for this box, keep other boxes
else
  # render hits
end
```

### Controller usage patterns (Rails)

Keep controllers thin; build relations with only request‑dependent inputs and pass a single multi‑result to the view.

```ruby
class HomeController < ApplicationController
  def index
    q    = params[:q].to_s
    page = params[:page]
    per  = params[:per]

    common = { q: q.presence || "*", query_by: SearchEngine.config.default_query_by }

    products_rel = SearchEngine::Product.where(active: true).per(6)
    brands_rel   = SearchEngine::Brand.where(["name PREFIX ?", q.first(24)]).per(3)

    @results = SearchEngine.multi_search_result(common: common) do |m|
      m.add :products, products_rel
      m.add :brands,   brands_rel
    end

    # Suggested fragment cache key derived from stable URL inputs
    @cache_key = ["home/index", params.slice(:q, :page, :per, :filters).to_unsafe_h]
  end
end
```

Caching notes:
- Prefer URL/request‑level cache keys derived from stable inputs (e.g., `params.slice(:q, :page, :per, :filters)`).
- Multi‑search uses URL‑level cache knobs from config: `{ use_cache: SearchEngine.config.use_cache, cache_ttl: SearchEngine.config.cache_ttl_s }`.
- Per‑relation `options(use_cache:, cache_ttl:)` are not applied in the multi‑search path; set them via config for multi‑search.
- Consider setting HTTP cache headers at the controller/edge layer based on those inputs; avoid embedding secrets.

### Compile flow

```mermaid
flowchart LR
  R[Relations] --> M[Multi builder]
  M --> C[Compiler (per search)]
  C --> P[Multi payload]
  P --> CL[Client]
  CL --> TS[Typesense]
  TS --> MR[MultiResult]
```

### DX & debugging

Prefer network‑safe introspection for demos and debugging:

```ruby
rel = SearchEngine::Product.where(category_id: 5).per(5)
rel.dry_run!   # => { url:, body:, url_opts: } with redaction
rel.to_curl    # one‑liner with redacted API key
puts rel.explain # multi‑line overview (no network I/O)
```

- See the DX page for details and redaction policy.
- For fully offline tests/examples, use the stub client approach in the Testing page.

### Presets & Curation in multi‑search

Applied per relation. Each `m.add` carries its own preset/curation context and compiles independently.
- Presets: per‑search `preset` and `preset_mode` (merge/only/lock) are honored during compile.
- Curation: `pinned_hits`, `hidden_hits`, `override_tags`, `filter_curated_hits` are emitted body‑only when present.

See the dedicated Presets and Curation docs for details and caveats.

### Edge cases & troubleshooting

- **Misaligned `query_by`**: ensure each collection’s fields exist; validate with `rel.explain` and `rel.dry_run!`.
- **Unknown fields**: selection and filtering validate against declared attributes; fix names or disable strictness per environment.
- **Mixed grouping**: grouping options are compiled per relation; UI should handle grouped vs non‑grouped results independently.
- **Differing `per`/`page`**: expected; each box paginates independently.
- **Partial failures**: the helper augments raised API errors with failing label when the HTTP status is non‑2xx; for 2xx with per‑entry errors, inspect `result.raw` per label and degrade gracefully.
- **Redaction**: never print API keys or raw `filter_by` directly; use `dry_run!`, `to_curl`, or `explain` which apply redaction.

---

### Related links

- [Index](./index.md)
- [Relation Guide](./relation.md)
- [Cookbook queries](./cookbook_queries.md)
- [DX](./dx.md)
- [Observability](./observability.md)
- [Presets](./presets.md)
- [Curation](./curation.md)
