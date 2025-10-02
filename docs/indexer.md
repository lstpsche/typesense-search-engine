[← Back to Index](./index.md) · [Schema](./schema.md) · [Observability](./observability.md)

## Indexer

Stream documents into a physical collection via JSONL bulk import with retries, stable memory, and notifications.

### API

```ruby
SearchEngine::Indexer.import!(SearchEngine::Product, into: "products_20251001_010203_001", enum: enumerable_batches, batch_size: 2000)
```

- **into**: physical collection name
- **enum**: enumerable yielding batches (Arrays of Hash documents)
- **batch_size**: soft guard for JSONL production; batches are not re-sliced unless handling 413
- **action**: defaults to `:upsert`

### Data flow

```mermaid
flowchart TD
  S[Source] --> M[Mapper]
  M --> B[Batch JSONL]
  B --> I[Bulk upsert]
  I --> R[Metrics/Notifications]
```

### JSONL format

- One JSON object per line
- Newline between documents; trailing newline optional
- Strings are escaped by the JSON library

### Retries & backoff

- Transient errors (timeouts, connection, 429, 5xx) are retried with exponential backoff and jitter
- Non-transient errors (401/403/404/400/422) are not retried
- 413 Payload Too Large splits the batch recursively until it fits

### Memory notes

- Operates strictly batch-by-batch, reusing a single buffer
- No accumulation of all records in memory; per-batch array may be materialized to support 413 splitting

### Instrumentation

- Emits `search_engine.indexer.batch_import` per attempted batch
- Payload includes: `collection`, `batch_index`, `docs_count`, `success_count`, `failure_count`, `attempts`, `duration_ms`, `http_status`, `bytes_sent`, `transient_retry`, `error_sample`

### Dry-run

- `SearchEngine::Indexer.dry_run!(...)` builds JSONL for the first batch only and returns `{ collection, action, bytes_estimate, docs_count, sample_line }`

### FAQ

- **Do I need a mapper?** Not yet; provide Hash documents with at least an `id` field. A DSL may be introduced later.
- **Timeouts?** You can set `SearchEngine.config.indexer.timeout_ms` to override read timeout during import.

### Data Sources

Adapters provide batched records for the Indexer in a memory-stable way. Each adapter implements `each_batch(partition:, cursor:)` and yields arrays.

Examples:

```ruby
source :active_record, model: ::Product, scope: -> { where(active: true) }, batch_size: 2000
source :sql, sql: "SELECT * FROM products WHERE active = TRUE", fetch_size: 2000
source :lambda do |cursor: nil, partition: nil|
  Enumerator.new { |y| external_api.each_page(cursor) { |rows| y << rows } }
end
```

- `partition` and `cursor` are opaque; adapters interpret them per-domain (e.g., id ranges, keyset predicates, external API tokens).
- Instrumentation: emits `search_engine.source.batch_fetched` and `search_engine.source.error`.

### Mapper

Backlinks: [Sources](./indexer.md#data-sources), [Schema](./schema.md)

```ruby
class SearchEngine::Product < SearchEngine::Base
  collection "products"
  attribute :id, :integer
  attribute :shop_id, :integer
  attribute :brand_id, :integer
  attribute :brand_name, :string
  attribute :price_cents, :integer

  index do
    source :active_record, model: ::Product, scope: -> { where(active: true) }
    map do |r|
      { id: r.id, shop_id: r.shop_id, brand_id: r.brand_id, brand_name: r.brand&.name, price_cents: r.price_cents }
    end
  end
end
```

Model → Document mapping:

| Model field | Document field | Transform |
| --- | --- | --- |
| `id` | `id` | identity |
| `shop_id` | `shop_id` | identity |
| `brand_id` | `brand_id` | identity |
| `brand.name` | `brand_name` | rename + safe navigation |
| `price_cents` | `price_cents` | identity |

Validation:

- Missing required fields: errors like `Missing required fields: [:id, :title] for SearchEngine::Product mapper.`
- Unknown fields: warns by default; set `SearchEngine.config.mapper.strict_unknown_keys = true` to error.
- Type checks: invalid types reported (e.g., `Invalid type for field :price_cents (expected Integer, got String: "12.3").`).
- Coercions: enable with `SearchEngine.config.mapper.coercions[:enabled] = true` (safe integer/float/bool only).

Runtime API:

- `mapper = SearchEngine::Mapper.for(SearchEngine::Product)`
- `docs, report = mapper.map_batch!(rows, batch_index: 1)`
- Emits `search_engine.mapper.batch_mapped` per batch with: `collection`, `batch_index`, `docs_count`, `duration_ms`, `missing_required_count`, `extra_keys_count`, `invalid_type_count`, `coerced_count`.

Backlinks: [Index](./index.md), [Observability](./observability.md), [Client](./client.md)
