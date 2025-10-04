# Ranking & typo tuning

This page explains the composable tuning API for fine‑grained ranking and typo behavior. Use it to adjust prefix/infix mode, typo tolerances, and field weights.

## DSL usage

```ruby
rel = SearchEngine::Product
  .ranking(num_typos: 1, drop_tokens_threshold: 0.2, prioritize_exact_match: true, query_by_weights: { name: 3, description: 1 })
  .prefix(:disabled) # or :fallback/:always depending on research
```

Additional variations:

```ruby
# Prefix only
SearchEngine::Product.prefix(:fallback)

# Weights aligned to a three‑field query_by
# With config.default_query_by = "name, description, brand"
SearchEngine::Product
  .ranking(query_by_weights: { name: 3, description: 1 })
```

## Compiler mapping

- `ranking(num_typos:)` → `num_typos` (0/1/2)
- `ranking(drop_tokens_threshold:)` → `drop_tokens_threshold` (0.0..1.0)
- `ranking(prioritize_exact_match:)` → `prioritize_exact_match` (Boolean)
- `ranking(query_by_weights:)` → `query_by_weights` as a comma list aligned to the effective `query_by` fields; fields without explicit weight default to 1
- `prefix(mode)` → `infix` where:
  - `:disabled` → `"off"`
  - `:fallback` → `"fallback"`
  - `:always` → `"always"`

```mermaid
flowchart LR
  A[Relation.ranking/ prefix] --> B[Normalize (RankingPlan)]
  B --> C[Params: num_typos, drop_tokens_threshold, prioritize_exact_match, query_by_weights, infix]
  C --> D[Search request]
  D --> E[Explain: effective query_by + weights]
```

## Explain & DX

- `rel.dry_run!` includes the compiled params in `{ url:, body:, url_opts: }`
- `rel.explain` shows:
  - effective `query_by` fields
  - weight vector (defaults filled with 1)
  - `num_typos`, `drop_tokens_threshold`, `prioritize_exact_match`, `prefix` (via `infix` token)

See also: [DX](./dx.md), [Relation Guide](./relation_guide.md), and [Cookbook Queries](./cookbook_queries.md).

## Guidance

- Start with: `num_typos=1`, `drop_tokens_threshold≈0.2`, `prefix=:fallback`
- Increase weights gradually; avoid setting all weights to `0`
- Prefer explicit `query_by` per search or configure `SearchEngine.config.default_query_by`

## Troubleshooting

- Weight for unknown field:
  - Ensure the key exists in the effective `query_by` list; see [Relation Guide → selection](./relation_guide.md#selection)
- Threshold out of range:
  - Use `0.0..1.0`
- All weights zero:
  - At least one field must have weight `> 0`
- Unknown prefix mode:
  - Valid: `:disabled`, `:fallback`, `:always`

## Backlinks

- [DX](./dx.md)
- [Relation Guide](./relation_guide.md)
- [Cookbook Queries](./cookbook_queries.md)
- [Observability](./observability.md)
- [Highlighting](./highlighting.md)
- [Synonyms & Stopwords](./synonyms_stopwords.md)

