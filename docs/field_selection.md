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
- `explain` prints human-readable `select:` and `exclude:` lines when present and a compact one-line summary of the effective selection after precedence, e.g. `selection: sel=id,name; xsel=legacy | authors[sel=first_name,last_name; xsel=middle_name]`.

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

## Compiler Mapping (Typesense params)

- **include_fields**: base tokens and nested joins encoded as `$assoc(field1,field2)`.
- **exclude_fields**: base tokens and nested joins encoded similarly.
- **Precedence**: final effective set is `include − exclude` per path (root and each association). **Exclude wins**. Empty groups are omitted.

### Mapping table

| Normalized state | include_fields | exclude_fields |
| --- | --- | --- |
| include: `[:id, :name]` | `id,name` | — |
| exclude: `[:legacy]` | — | `legacy` |
| include: `[:id]`, include_nested: `{ authors: ["first_name","last_name"] }` | `$authors(first_name,last_name),id` | — |
| exclude_nested: `{ brands: ["internal_score"] }` | — | `$brands(internal_score)` |
| include: `[:id,:title]`, include_nested: `{ authors: ["first_name","last_name"] }`, exclude: `[:legacy]`, exclude_nested: `{ brands: ["internal_score"] }` | `id,title,$authors(first_name,last_name)` | `legacy,$brands(internal_score)` |
| include_nested: `{ authors: ["first_name","last_name"] }`, exclude_nested: `{ authors: ["last_name"] }` | `$authors(first_name)` | — |

Notes:
- Only add `include_fields` if there is at least one effective include (root or nested).
- Only add `exclude_fields` if there is at least one exclude (root or nested). You may keep excludes even if they are redundant due to precedence; keeping them is harmless and documents intent.
- Multiple assoc groups are comma‑separated; no `$assoc()` empty groups are emitted.

### Flow

```mermaid
flowchart TD
  A[Normalized selection state] --> B[Apply precedence: include − exclude per path]
  B --> C[Encode root: sort + join]
  B --> D[Encode nested: $assoc(field1,field2) sorted]
  C --> E[include_fields]
  D --> E
  F[Raw excludes (root + nested)] --> G[Sort + encode ($assoc(...))]
  G --> H[exclude_fields]
```

### Example

```ruby
rel = SearchEngine::Book
        .joins(:authors, :brands)
        .select(:id, :title, authors: [:first_name, :last_name])
        .exclude(:legacy, brands: [:internal_score])
rel.to_typesense_params[:include_fields]
# => "id,title,$authors(first_name,last_name)"
rel.to_typesense_params[:exclude_fields]
# => "legacy,$brands(internal_score)"
```

## Guardrails & errors

Validation happens during chaining (after normalization, before mutating state) and raises actionable errors early. Suggestions are provided when attribute registries are available.

- **UnknownField**: base attribute not declared on the model.
- **UnknownJoinField**: nested attribute not declared on the given association.
- **ConflictingSelection**: invalid/ambiguous shapes that cannot be normalized deterministically.

Example (verbatim):

```
UnknownJoinField: :middle_name is not declared on association :authors for SearchEngine::Book
```

Notes:
- Suggestion source: Levenshtein/prefix against the relevant registry (top 1–3, stable order).
- Overlap between include and exclude is allowed; precedence still applies. Conflicts are only about malformed shapes.

See also: [Relation](./relation.md), [JOINs](./joins.md), and [Materializers](./materializers.md#pluck--selection).

## Strict vs Lenient selection

Hydration respects selection by assigning only attributes present in each hit. Missing attributes are never synthesized.

- **Lenient (default)**: Missing requested fields are left unset; readers should return `nil` if they rely on ivars.
- **Strict**: If a requested field is absent in the hit, hydration raises `SearchEngine::Errors::MissingField` with guidance.

Backed by:
- Per‑relation override via `options(selection: { strict_missing: true })`
- Global default via `SearchEngine.configure { |c| c.selection = OpenStruct.new(strict_missing: false) }`

```ruby
# initializer
SearchEngine.configure { |c| c.selection = OpenStruct.new(strict_missing: false) }
# per relation
rel = SearchEngine::Product.select(:id).options(selection: { strict_missing: true })
```

Hydration decision flow:

```mermaid
flowchart TD
  A[Typesense hit] --> B[Extract present keys]
  R[Relation selection (effective)] --> C[Requested keys]
  B --> D[Assign only present keys]
  C --> E{strict_missing?}
  D --> F[All good]
  E -- yes --> G[Missing = Requested − Present]
  G -- empty --> F
  G -- non-empty --> H[Raise MissingField with guidance]
  E -- no --> I[Leave absents unset (no ivars)] --> F
```

See also: [Relation](./relation.md), [Materializers](./materializers.md#pluck--selection), and [Compiler](./compiler.md).

