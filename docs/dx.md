[← Back to Index](./index.md) · [Relation](./relation.md) · [Compiler](./compiler.md) · [Observability](./observability.md)

# DX helpers

Developer‑experience helpers on `Relation` visualize compiled requests and enable a safe, zero‑I/O dry run.

- `Relation#to_params_json(pretty: true)` — redacted JSON body after compile. Pretty output has stable key ordering for copy/paste and diffs.
- `Relation#to_curl` — single‑line cURL with POST to the resolved endpoint, JSON body, and redacted API key.
- `Relation#dry_run!` — compiles and validates without network I/O; returns `{ url:, body:, url_opts: }`.
- `Relation#explain` — extended overview with grouping, joins, presets/curation, conflicts, correlation ID preview (when present), and predicted events.

## Examples

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

Notes:
- All helpers are pure and do not mutate the relation.
- `dry_run!` validates and returns a redacted body; no HTTP requests are made.
- Redaction follows the same rules as observability, masking secrets and literals.

Backlinks: [Relation](./relation.md) · [Compiler](./compiler.md) · [Observability](./observability.md)
