[← Back to Index](./index.md) · [Relation](./relation.md) · [Compiler](./compiler.md)

# Join Declarations on Base

Server‑side joins require lightweight association metadata declared on your model class. This page documents the model‑level DSL, the per‑class registry, and how the compiler/validator will consume this metadata.

## DSL

Declare joinable associations on your model using `join`:

```ruby
class SearchEngine::Book < SearchEngine::Base
  collection "books"
  attribute :id, :integer
  attribute :author_id, :integer

  join :authors, collection: "authors", local_key: :author_id, foreign_key: :id
  join :orders,  collection: "orders",  local_key: :id,        foreign_key: :book_id
end
```

- `name` (Symbol): logical association name.
- `collection` (String): target Typesense collection name.
- `local_key` (Symbol): local attribute used as the join key.
- `foreign_key` (Symbol): foreign key in the target collection.

## Registry and Read APIs

- `joins_config` returns a frozen mapping `{ name(Symbol) => JoinConfig(Hash) }`.
- `join_for(name)` returns a single normalized config or raises `SearchEngine::Errors::UnknownJoin` with suggestions.

The registry is per‑class, immutable to callers, and uses copy‑on‑write for safe updates. Subclasses inherit parent declarations and may add new ones; duplicate names raise.

## Relation Usage

Use `Relation#joins(*assocs)` to select join associations on a query. Names are validated against the model’s `joins_config` and stored in the relation’s immutable state in the order provided. Multiple calls append:

```ruby
SearchEngine::Book
  .joins(:authors, :orders)
  .where(authors: { last_name: "Rowling" })
  .where(orders: { total_price: 12.34 })
  .order(authors: { last_name: :asc })
```

```mermaid
flowchart LR
  R[Relation] -- joins(:authors) --> S[State joins=[authors]]
  S -- joins(:orders) --> S2[joins=[authors, orders]]
```

- `joins` accepts symbols/strings; inputs are normalized to symbols.
- Unknown names raise `SearchEngine::Errors::UnknownJoin` with an actionable message that lists available associations.
- Order is preserved and duplicates are not deduped by default; explicit chaining is honored.
- For debugging, `rel.joins_list` returns the frozen array of association names in state.

Backlinks: [← Back to Index](./index.md) · [Relation](./relation.md) · [Compiler](./compiler.md)

## Filtering and Ordering on Joined Fields

With joins applied, you can reference joined collection fields in `where` and `order` using nested hashes. Joined left‑hand‑sides render as `$assoc.field`.

| Input (Ruby) | Compiled filter_by | Compiled sort_by |
| --- | --- | --- |
| `where(authors: { last_name: "Rowling" })` | `$authors.last_name:="Rowling"` | – |
| `where(orders: { total_price: 12.34 })` | `$orders.total_price:=12.34` | – |
| `order(authors: { last_name: :asc })` | – | `$authors.last_name:asc` |
| `order("$authors.last_name:asc")` | – | `$authors.last_name:asc` |

Notes:
- Base fields continue to work unchanged (e.g., `where(active: true)`).
- Mixed base and joined predicates interleave as usual; the compiler preserves grouping semantics.
- Raw `order` strings are accepted as‑is; ensure you supply valid Typesense fragments.

### AST Path Diagram

The parser produces a normal predicate node with a joined field path for the LHS. The compiler renders it verbatim.

```mermaid
flowchart TD
  A[Hash input] -->|{ authors: { last_name: "Rowling" } }| P[Parser]
  P -->|LHS "$authors.last_name"| N[AST::Eq]
  N --> C[Compiler]
  C -->|filter_by| F[$authors.last_name:="Rowling"]
```

## Association Table Pattern

Render declared joins for a model to reason about relationships:

| Name    | Target collection | Local key   | Foreign key | Notes |
|---------|-------------------|-------------|-------------|-------|
| authors | authors           | author_id   | id          | one‑to‑many by author_id |
| orders  | orders            | id          | book_id     | order items linked to book |

## Mermaid Overview

```mermaid
flowchart LR
  subgraph Collections
    B[books]
    A[authors]
    O[orders]
  end

  B -- author_id = id --> A
  B -- id = book_id --> O
```

## Validation & Errors

- Missing or blank `collection` → `ArgumentError`.
- Unknown `local_key` (not declared via `attribute`) → `SearchEngine::Errors::InvalidField` with a hint.
- Duplicate `join` name → `ArgumentError` indicating the conflict.
- Unknown lookup via `join_for(:name)` → `SearchEngine::Errors::UnknownJoin` listing available names.
- Referencing joined fields without applying the join on the relation → `SearchEngine::Errors::JoinNotApplied` with guidance to call `.joins(:name)`.

## FAQ

- Inheritance: subclasses start with a snapshot of parent joins and can add their own. Overriding an existing name raises to avoid ambiguity.
- Types: the normalized record stores `:name, :collection, :local_key, :foreign_key`. Future compiler passes may add type hints; the DSL remains unchanged.
- Compiler usage: the compiler reads `joins_config`/`join_for` to determine target collection and key mapping for server‑side joins without loading foreign models.

---

## Nested field selection for joined collections

Backlinks: [← Back to Index](./index.md) · [Relation](./relation.md)

You can select fields from joined collections using a nested Ruby shape. These compile to Typesense `include_fields` with `$assoc(field,...)` segments.

```ruby
# Full relation example
SearchEngine::Book
  .joins(:authors)
  .include_fields(:id, :title, authors: [:first_name, :last_name])
```

Compiles to:

```
$authors(first_name,last_name),id,title
```

- **Input types**: mix base fields (`:id, "title"`) and nested hashes (`authors: [:first_name, :last_name]`).
- **Merging**: multiple calls merge and dedupe. First mention wins ordering; later calls append only new fields.

```ruby
# Merged across calls
SearchEngine::Book
  .include_fields(:id, authors: [:a])
  .include_fields(:title, authors: [:b, :a])
# => "$authors(a,b),id,title"
```

- **Ordering policy**: nested `$assoc(...)` segments are emitted first in association first-mention order, then base fields.
- **Validation**: association keys are validated against `klass.joins_config` (`UnknownJoin` on typos). Calling `.joins(:assoc)` before selecting nested fields is recommended; the compiler will still emit `$assoc(...)` even if `joins` wasn't chained yet.

See also: [Relation](./relation.md) for the `#select` / `#include_fields` chainers and [Compiler](./compiler.md) for parameter mapping.

