[← Back to Index](./index.md)

# Troubleshooting

Quick reference for common issues. Each section links to deeper docs.

Related: [Observability](./observability.md), [CLI](./cli.md), [Testing](./testing.md)

## Joins

- Missing or invalid join name
  - Ensure you declared it on the model with `join :name, ...`
  - See [Joins → DSL](./joins.md#dsl)
- Joined fields not appearing in selection
  - Use nested include fields and prefix joined fields with `$assoc.field`
  - See [Field selection](./field_selection.md)

## Grouping

- `group_limit` ignored
  - Provide a positive integer; omitted when `nil`
  - See [Grouping → Mapping](./grouping.md#mapping-ruby-dsl--typesense-params)
- Unexpected missing‑values behavior
  - Set `missing_values: true` explicitly
  - See [Grouping → State → Params](./grouping.md#state--params)

## Presets

- Defaults not applied
  - Confirm `default_preset` on the model and `presets.enabled`
  - See [Presets → Config & Default](./presets.md#config--default-preset)
- `:lock` mode not locking as expected
  - Check `locked_domains` normalization and compiler pruning
  - See [Presets → Modes](./presets.md#modes)

## Curation

- Hidden IDs still visible
  - Ensure `filter_curated_hits` is set when you want hidden hits excluded
  - See [Curation → DSL](./curation.md#dsl)
- Order of pinned hits unstable
  - Pin order is first‑occurrence; avoid duplicates
  - See [Curation → Inspect/explain](./curation.md#inspectexplain)

## CLI

- Task arguments parsed incorrectly
  - Quote args and avoid spaces inside brackets
  - See [CLI → Usage](./cli.md#usage)
- `doctor` exits with 1
  - Run with `VERBOSE=1` or `FORMAT=json` for details
  - See [CLI → Doctor flow](./cli.md#doctor-flow)

## DX

- `to_curl` shows API key
  - Keys are redacted; update to latest, or file an issue with a snippet
  - See [DX](./dx.md)
- `dry_run!` performs I/O
  - `dry_run!` compiles only; check for accidental client calls
  - See [DX → Helpers](./dx.md#helpers--examples)

## Schema

- Drift not detected
  - Use aliases correctly; compare compiled vs active physical
  - See [Schema → Diff](./schema.md#diff-shape)
- Rollback unavailable
  - Retention may be insufficient; ensure previous physical retained
  - See [Schema → API](./schema.md#api)

## Indexer

- 413 Payload Too Large
  - Batches split recursively; reduce `batch_size`
  - See [Indexer → Retries & backoff](./indexer.md#retries--backoff)
- Memory spikes
  - Ensure streaming JSONL and avoid materializing large arrays
  - See [Indexer → Memory notes](./indexer.md#memory-notes)

## Testing

- Stub not capturing calls
  - Ensure `SearchEngine.config.client = SearchEngine::Test::StubClient.new`
  - See [Testing → Quick start](./testing.md#quick-start)

## Observability

- Missing events
  - Wrap calls with instrumentation helpers and enable subscriber
  - See [Observability → Events](./observability.md#events)
- Too much PII in logs
  - Redaction rules mask secrets and filter literals; use `params_preview`
  - See [Observability → Redaction rules](./observability.md#payload-reference)
