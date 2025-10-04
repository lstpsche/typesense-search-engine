# Synonyms & Stopwords

This page covers how to manage synonym and stopword sets and how to control their usage at runtime per query.

## Overview

- Synonyms expand recall by matching alternate spellings or equivalent terms.
- Stopwords remove low-information tokens (like "and", "the"). Overuse can hurt recall.
- Runtime toggles allow per-query control when you need to experiment or override defaults.

## Management (admin API)

Use the admin helpers to upsert sets per collection.

```ruby
SearchEngine::Admin::Synonyms.upsert!(collection: "products", id: "colors", terms: %w[color colour])
SearchEngine::Admin::Stopwords.upsert!(collection: "products", id: "common", terms: %w[the and])
```

Optional helpers for CLI:

- `SearchEngine::Admin::Synonyms.list(collection: "products")`
- `SearchEngine::Admin::Synonyms.get(collection: "products", id: "colors")`
- `SearchEngine::Admin::Synonyms.delete!(collection: "products", id: "colors")`
- `SearchEngine::Admin::Stopwords.list(...)`, `get(...)`, `delete!(...)`

Normalization rules:
- `collection` and `id` must be non-empty strings; `id` must match `/\A[\w\-:\.]+\z/`.
- `terms` are stripped, downcased, de-duplicated; empty inputs are rejected.

## CLI import/export

Rake tasks provide stable JSON import/export with dry-run support.

- `rails search_engine:synonyms:export[collection,path]`
- `rails search_engine:synonyms:import[collection,path]`
- `rails search_engine:stopwords:export[collection,path]`
- `rails search_engine:stopwords:import[collection,path]`

Schema (stable):

```json
{
  "collection": "products",
  "kind": "synonyms",
  "updated_at": "2025-01-01T00:00:00Z",
  "items": [
    { "id": "colors", "terms": ["color", "colour"] }
  ]
}
```

Flags:
- `DRY_RUN=1` to preview (no writes).
- `HALT_ON_ERROR=1` to stop on first failure.
- `FORMAT=json` to output a machine-readable summary.

## Runtime toggles (Relation)

Enable or disable per-query, chainably and immutably:

```ruby
SearchEngine::Product.where(q: "red color").use_synonyms(true).use_stopwords(false)
```

- `use_synonyms(value)` and `use_stopwords(value)` accept `true`, `false`, or `nil` (to clear override).
- Booleans are strictly coerced; the last call wins.
- See `#explain` to preview effective flags.

## Compiler mapping

These flags are compiled into Typesense parameters:
- `use_synonyms` → `enable_synonyms=true|false`
- `use_stopwords` → `remove_stop_words=true|false` (inversion of our DSL)

Notes:
- The engine adds an internal preview `_runtime_flags` for observability; it is stripped before HTTP.
- If server parameter names change, the DSL remains stable and mapping is adapted here.

## Troubleshooting

- Empty `terms`: ensure at least one non-empty term (duplicates are removed).
- Conflicting IDs: delete then re-upsert the desired set.
- Flag seems ignored: verify collection vs alias and confirm the set exists for the target physical collection.
- Invalid JSON during import: expected keys `collection`, `kind`, `items[] {id, terms[]}`.

## Observability

Events emitted:
- `search_engine.admin.synonyms.upsert`, `search_engine.admin.stopwords.upsert`
- `search_engine.compile`, `search_engine.search`

## Backlinks

- See `docs/dx.md`, `docs/relation_guide.md`, `docs/cookbook_queries.md`, `docs/observability.md`, `docs/cli.md`, `docs/testing.md`.
