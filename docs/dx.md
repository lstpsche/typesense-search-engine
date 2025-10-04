[← Back to Index](./index.md)

# Developer Experience (DX)

Related: [Debugging](./debugging.md), [Troubleshooting → DX](./troubleshooting.md#dx)

Developer‑experience helpers on `Relation` visualize compiled requests and enable a safe, zero‑I/O dry run.

- `Relation#to_params_json(pretty: true)` — redacted JSON body after compile. Pretty output has stable key ordering for copy/paste and diffs.
- `Relation#to_curl` — single‑line cURL with POST to the resolved endpoint, JSON body, and redacted API key.
- `Relation#dry_run!` — compiles and validates without network I/O; returns `{ url:, body:, url_opts: }`.
- `Relation#explain` — extended overview with grouping, joins, presets/curation, conflicts, correlation ID preview (when present), and predicted events.

## Helpers & examples

```ruby
rel = SearchEngine::Product
        .where(active: true)
        .order(updated_at: :desc)
        .select(:id, :name)
        .page(2).per(20)

rel.to_params_json
# => "{\n  \"filter_by\": \"active:=***\", ... }"

rel.to_curl
# => "curl -X POST https://host/... -H 'Content-Type: application/json' -H 'X-TYPESENSE-API-KEY: ***' -d '{...}'"

rel.dry_run!
# => { url: "https://host:8108/collections/products/documents/search", body: "{...}", url_opts: { use_cache: true, cache_ttl: 60 } }

puts rel.explain
```

### Event prediction (no emit)

Use `rel.explain` to preview which events would fire without emitting them:

```text
Events that would fire: search_engine.compile → search_engine.joins.compile → search_engine.grouping.compile → search_engine.search
```

### Redaction policy

- All helpers are pure and do not mutate the relation.
- `dry_run!` validates and returns a redacted body; no HTTP requests are made.
- Redaction follows observability rules, masking secrets and literals.

## Generators & Console helpers

Install and scaffold minimal models using Rails generators:

```bash
rails g search_engine:install
rails g search_engine:model Product --collection products --attrs id:integer name:string
```

In `rails console`, use inline helpers: `SE.q("milk")`, `SE.ms { |m| m.add :products, SE.q("milk").per(5) }`.

- **Default model resolution**: set `SearchEngine.config.default_console_model` (Class or String). If unset, the helper falls back to the single registered model; ambiguous cases raise with a hint.
- **Options**: `SE.q` accepts `select:`, `per:`, `page:`, and `where:`. Any remaining options are forwarded to the relation via `options(...)`.

Backlinks: [Quickstart](./quickstart.md), [Relation](./relation.md), [Multi‑search](./multi_search.md), [Observability](./observability.md)

### Troubleshooting

- **No default model configured**: Set `SearchEngine.config.default_console_model = 'SearchEngine::Product'` or ensure only one model is registered. See section above.
- **Unknown attribute type**: Allowed types are `string`, `integer`, `float`, `boolean`, `datetime`, `json`. See [Field selection → Guardrails](./field_selection.md#guardrails--errors) and [Troubleshooting](./troubleshooting.md).
