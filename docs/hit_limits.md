# Hit limits & validation

This page explains how to cap or validate the number of matching hits for a query.

- Early limit: proactively cap work at the backend when supported.
- Post‑fetch validation: assert a hard upper bound on total hits and raise when exceeded.

## DSL usage

Verbatim from the ticket:

```ruby
SearchEngine::Product.limit_hits(1_000).validate_hits!(max: 10_000)
```

Common combinations in prose:
- Apply only an early limit to avoid over‑fetching when you only need a small page.
- Add a post‑fetch validator to guard against unexpectedly broad queries in production.

## Compiler mapping

- Early limit: The Typesense API has no canonical total‑hits cap parameter. As a conservative fallback, the compiler lowers `per_page` when it exceeds the early limit. This avoids over‑fetching on the first page but does not emulate a hard cap across pages.
- Validation note: A non‑transmitted internal note is attached for DX so `dry_run!` and `explain` can show that a validator will run.

## Materializers

The validator runs once per materialization and only after the first response is available, using the backend’s total hits field (`found`). It applies to:
- `to_a`, `each`, `first`, `last`, `take`, `pluck`, `ids`
- `count`, `exists?` (via a minimal metadata fetch)

For multi‑search, each search is validated independently.

## Troubleshooting

- Repeated errors: Narrow your filters or increase `validate_hits!(max:)`.
- Multi‑search failures: Treat offending searches independently; raise or log details with labels where available.
- `per` lower than expected: This is the conservative `per_page` adjustment from `limit_hits(n)`; increase your early limit if appropriate.

## DX surfaces

- `dry_run!` shows the compiled body with any `per_page` adjustment and notes about a pending validator.
- `explain` summarizes early limit, per adjustment, and the validator threshold.

## Backlinks

- [Developer experience](./dx.md)
- [Relation DSL](./relation_guide.md)
- [Multi‑search](./multi_search_guide.md)
- [Observability](./observability.md)
- [Ranking & typo tuning](./ranking.md)
