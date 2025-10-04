# Highlighting

When you want to emphasize matched query terms, use highlighting. It supports concise affix snippets around matches or fully highlighted fields.

## DSL usage

Verbatim ticket example:

```ruby
rel = SearchEngine::Product
  .highlight(fields: %i[name description], full_fields: %i[description], start_tag: "<em>", end_tag: "</em>", affix_tokens: 8, snippet_threshold: 30)
```

Variations:

```ruby
# Use <mark> tags and only snippet fields
SearchEngine::Product.highlight(fields: %i[name], start_tag: "<mark>", end_tag: "</mark>")

# Only full_fields (no affix snippets)
SearchEngine::Product.highlight(fields: %i[name], full_fields: %i[description])
```

## Compiler mapping

```mermaid
flowchart LR
  A[Relation.highlight opts] --> B[Normalize (HighlightPlan)]
  B --> C[Params: highlight_* + snippet_threshold]
  C --> D[Search request]
  D --> E[Response: highlights per hit]
  E --> F[Hit decorators: highlights & snippet_for]
```

Emitted Typesense params:
- `highlight_fields`
- `highlight_full_fields`
- `highlight_affix_num_tokens`
- `highlight_start_tag`
- `highlight_end_tag`
- `snippet_threshold`

## Options and validation

- `fields:` Array<Symbol/String> — required. At least one non‑blank field.
- `full_fields:` Array<Symbol/String> — optional.
- `start_tag`/`end_tag:` simple HTML‑like tokens such as `<em>`, `</em>`, `<mark>`, `</mark>`. Attributes are not allowed.
- `affix_tokens`/`snippet_threshold:` non‑negative integers; strings of digits are coerced.

On invalid values the API raises `SearchEngine::Errors::InvalidOption` with a helpful hint.

See: `#options` in this page.

## Result helpers

Each hydrated hit gets two helpers:
- `hit.highlights` → `Hash{ field_name => [ { value:, matched_tokens:, snippet: true/false } ] }`
- `hit.snippet_for(:description, full: false)` → HTML safe string (Rails `SafeBuffer` when present)

Safety:
- Only your configured `start_tag`/`end_tag` are preserved. All other markup is escaped to prevent XSS.
- If the server returns different tags, they are normalized to your configured tags.

## Troubleshooting

- Missing highlights: ensure `fields:` includes the attributes you search over and that Typesense has highlighting enabled for the collection.
- Tags not applied: invalid tags are rejected; use simple tokens like `<em>` and `</em>`.
- Snippets too long/short: adjust `affix_tokens` and `snippet_threshold`.

## Backlinks

- See `docs/dx.md` for DX helpers (`to_params_json`, `dry_run!`, `explain`).
- See `docs/relation_guide.md` and `docs/cookbook_queries.md` for composing DSL calls.
- See `docs/observability.md` for event names.
- See `docs/testing.md` for the stub client and testing patterns.
- Related: `docs/faceting.md` if you combine facets and highlighting.
