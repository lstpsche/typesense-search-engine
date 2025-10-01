[← Back to Index](./index.md) · [Client](./client.md)

# Relation

Relation is an immutable, chainable query object bound to a model class. It accumulates normalized query state without mutating previous instances.

## Quick start

```ruby
class SearchEngine::Product < SearchEngine::Base; end

r1 = SearchEngine::Product.all
r2 = r1.where(category: 'milk').order(:name).limit(10)
# r1 is unchanged
r1.object_id != r2.object_id #=> true
r1.empty?                    #=> true
```

## Immutability

Every chainer creates a new instance via copy-on-write. The original relation remains unchanged.

```ruby
r1 = SearchEngine::Product.all
r2 = r1.where(price: 10)
r1.object_id #=> 701...
r2.object_id #=> 702...
r1.empty?     #=> true
r2.empty?     #=> false
```

## API

- **all**: returns the relation itself (parity with AR).
- **where(*args)**: add filters. Accepts Hash, String/Symbol, arrays thereof.
- **order(clause)**: add order expressions. Accepts Symbol/String/Hash or arrays.
- **select(*fields)**: add selected fields; deduplicates while preserving order.
- **limit(n)**, **offset(n)**, **page(n)**, **per_page(n)**: numeric setters; coerced to non-negative integers or nil.
- **options(opts = {})**: shallow-merge additional options for future adapters.
- **empty?**: true when state equals the default empty state.
- **inspect**: concise single-line summary; shows only non-empty keys.

## Lifecycle

```mermaid
flowchart LR
  A[Model.all] --> B[Relation]
  B --> C[where]
  C --> D[order]
  D --> E[limit]
  E --> F[Relation (new each step)]
  F --> G[(Future: execute via Client)]
```

See [Client](./client.md) for execution context.
