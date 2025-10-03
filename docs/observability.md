[← Back to Index](./index.md) · [Client](./client.md) · [Presets](./presets.md) · [Curation](./curation.md)

### Observability

This engine emits lightweight ActiveSupport::Notifications events around client calls and provides an opt-in compact logging subscriber. Events are redacted and stable to keep logs useful without leaking secrets.

- **Events**
  - `search_engine.search` — wraps `SearchEngine::Client#search`
  - `search_engine.multi_search` — wraps the top-level helper around `Client#multi_search`
  - `search_engine.schema.diff` — around schema diffing
  - `search_engine.schema.apply` — around schema apply lifecycle (create → reindex → swap → retention)
  - `search_engine.preset.apply` — emitted during compile when a preset is applied (keys-only payload)
  - `search_engine.indexer.partition_start` — partition processing started (inline or ActiveJob)
  - `search_engine.indexer.partition_finish` — partition processing finished with summary
  - `search_engine.indexer.batch_import` — each bulk import attempt
  - `search_engine.indexer.delete_stale` — stale delete lifecycle (started/ok/failed/skipped)
  - `search_engine.joins.compile` — compile-time summary of JOINs usage
  - `search_engine.grouping.compile` — compile-time summary of grouping (field/limit/missing_values)
  - `search_engine.selection.compile` — compile-time summary of selection counts (include/exclude/nested)

Duration is available via the event (`ev.duration`).

### Payload reference

- **collection/collections**: String or Array<String> of collections involved
- **params**: Redacted params excerpt (single: Hash, multi: Array<Hash>)
- **url_opts**: `{ use_cache: Boolean, cache_ttl: Integer|nil }`
- **status/http_status**: Integer when available, otherwise `:ok`/`:error`
- **error_class**: String or nil
- **retries**: Attempts used (reserved; nil by default)
- **partition/partition_hash**: Numeric raw key or short hash for strings
- **into**: Physical collection name
- **duration_ms**: Float measured duration in milliseconds
- **grouping.compile**: `{ field: String, limit: Integer|nil, missing_values: Boolean, collection?: String, duration_ms?: Float }`
- **selection.compile**: `{ include_count: Integer, exclude_count: Integer, nested_assoc_count: Integer }`

Redaction rules:
- Sensitive keys matching `/key|token|secret|password/i` are redacted
- Only whitelisted param keys are preserved: `q`, `query_by`, `per_page`, `page`, `infix`, `filter_by`, `group_by`, `group_limit`, `group_missing_values`
- `q` is truncated when longer than 128 chars
- `filter_by` literals are masked while preserving structure (e.g., `price:>10` → `price:>***`)
- `filter_by` is never logged as-is; a `filter_hash` (sha1) is provided instead for stale deletes

| Key            | Type                 | Redaction |
|----------------|----------------------|-----------|
| `collection`   | String               | N/A |
| `collections`  | Array<String>        | N/A |
| `labels`       | Array<String>        | N/A |
| `searches_count` | Integer            | N/A |
| `params`       | Hash/Array<Hash>     | Whitelisted keys only; `q` truncated; `filter_by` masked |
| `url_opts`     | Hash                 | Includes only `use_cache` and `cache_ttl` |
| `status`/`http_status` | Integer or Symbol | N/A |
| `error_class`  | String, nil          | N/A |
| `retries`      | Integer, nil         | Reserved; nil by default |
| `duration`     | Float (ms) via event | N/A |
| `partition`    | Numeric or hidden    | Hidden for strings; use `partition_hash` |
| `partition_hash` | String (sha1 prefix) | N/A |
| `filter_hash`  | String (sha1)        | Raw filter never logged |
| `group_by`     | String               | N/A |
| `group_limit`  | Integer, nil         | N/A |
| `group_missing_values` | Boolean      | N/A |
| `selection_include_count` | Integer   | Counts only |
| `selection_exclude_count` | Integer   | Counts only |
| `selection_nested_assoc_count` | Integer | Counts only |

For URL/cache knobs, see [Configuration](./configuration.md).

### Enable compact logging

One-liner subscriber that logs compact, single-line entries for both events:

```ruby
SearchEngine::Notifications::CompactLogger.subscribe
```

Options:

```ruby
SearchEngine::Notifications::CompactLogger.subscribe(
  logger: Rails.logger,    # default: SearchEngine.config.logger || STDOUT
  level: :info,            # :debug, :info, :warn, :error
  include_params: false,   # when true, logs only whitelisted param keys
  format: :kv              # :kv (default), :json
)
```

Example lines:

```
[se.search] collection=products status=200 duration=12.3ms cache=true ttl=60 grp=brand_id:1:mv q="milk" per_page=5
[se.multi] count=2 labels=products,brands status=200 duration=18.6ms cache=true ttl=60
```

JSON example (one line):

```json
{"event":"search","collection":"products","status":200,"duration.ms":12.3,"cache":true,"ttl":60,"group_by":"brand_id","group_limit":1,"group_missing_values":true}
```

### Event flow

```mermaid
flowchart TD
  A[Schema Diff] -->|schema.diff| N[Notifications]
  B[Schema Apply] -->|schema.apply| N
  C[Partition Start] -->|indexer.partition_start| N
  D[Batch Import] -->|indexer.batch_import| N
  E[Delete Stale] -->|indexer.delete_stale| N
  C2[Partition Finish] -->|indexer.partition_finish| N
  G[Grouping Compile] -->|grouping.compile| N
  J[JOINs Compile] -->|joins.compile| N
  N --> L[Compact Logger]
```

---

## Relation execution events

Execution initiated by `SearchEngine::Relation` results in a single client call and emits `search_engine.search` with a compact, redacted payload. When a preset is applied, compile also emits `search_engine.preset.apply`. See [Presets](./presets.md#observability).

- **Event**: `search_engine.search`
- **Payload**: `{ collection, params: Observability.redact(params), url_opts: { use_cache, cache_ttl }, status, error_class }`
- **Source**: `SearchEngine::Client#search` (Relation delegates execution to the client)

```mermaid
sequenceDiagram
  participant Rel as Relation
  participant Client as SearchEngine::Client
  participant Notif as AS::Notifications
  Rel->>Client: search(...)
  Client->>Notif: instrument("search_engine.search", payload)
  Notif-->>Client: yield
  Client-->>Rel: Result
```

Backlinks: [Relation](./relation.md), [Materializers](./materializers.md), [Client](./client.md), [Schema](./schema.md), [Indexer](./indexer.md)
