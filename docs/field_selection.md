[← Back to Index](./index.md) · [Relation](./relation.md) · [JOINs](./joins.md) · [Materializers](./materializers.md)

# Field Selection DSL (select / exclude / reselect)

A concise, immutable DSL on `Relation` for selecting or excluding fields, with support for nested join fields and normalization.

## Overview

- `select(*fields)`: add fields to include list (root and nested); immutable, deduped, order preserved by first mention.
- `exclude(*fields)`: add fields to exclude list (root and nested); immutable, deduped, order preserved by first mention.
- `reselect(*fields)`: clear prior include/exclude state and set a new include list.

Nested fields are addressed via association-name keyed Hashes and require the association to be joined first.

```ruby
# Internal example state
{ include: Set[:id, :name], include_nested: { authors: Set[:first_name, :last_name] },
  exclude: Set[:legacy], exclude_nested: { brands: Set[:internal_score] } }
```

## Usage

```ruby
SearchEngine::Product
  .select(:id, :name)
  .exclude(:internal_score)
```

```ruby
SearchEngine::Book
  .joins(:authors)
  .select(:id, :title, authors: [:first_name, :last_name])
  .exclude(authors: [:middle_name])
```

## Normalization & Precedence

- Inputs accept symbols/strings and arrays; nested via `{ assoc => [:field, ...] }`.
- All names are coerced to symbols/strings consistently; blanks rejected; duplicates removed with first-mention preserved.
- Precedence:
  - When include is empty, effective selection is “all fields” (when attributes are known) minus explicit excludes.
  - When include is non-empty, effective selection is `include − exclude` (applied for root and each nested association).
  - `reselect` clears both include and exclude state.

### Nested joins

- Nested shapes require `joins(:assoc)` beforehand.
- For nested paths without explicit includes, the engine attempts to derive “all fields” from the joined collection’s declared `attributes` and subtract explicit excludes. If unknown, nested excludes may be emitted via `exclude_fields`.

## Inspect / Explain

- `inspect` includes compact tokens for current selection state, e.g. `sel="..." xsel="..."`.
- `explain` prints human-readable `select:` and `exclude:` lines when present.

## Flow

```mermaid
flowchart TD
  A[DSL calls: select/exclude/reselect] --> B[Normalization: root & nested maps]
  B --> C[Effective fields per path (precedence rules)]
  C --> D[Compiler: params/build]
  D --> E[Materializers: shaping fields on hydration]
```

## Comparison Table

| Input shape | Normalized state | Effective set |
| --- | --- | --- |
| `select(:id, :name)` | include: `[:id, :name]` | `[:id, :name]` |
| `exclude(:legacy)` | exclude: `[:legacy]` | include empty → all − `[:legacy]` |
| `select(authors: [:first_name])` | include_nested: `{ authors: ["first_name"] }` | authors: `["first_name"]` |
| `exclude(authors: [:middle_name])` | exclude_nested: `{ authors: ["middle_name"] }` | authors: include empty → all − `["middle_name"]` |

## See also

- [Relation](./relation.md)
- [JOINs](./joins.md)
- [Materializers](./materializers.md)

