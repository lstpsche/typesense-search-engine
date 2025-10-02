[← Back to Index](./index.md) · [Relation](./relation.md) · [Compiler](./compiler.md) · [Materializers](./materializers.md) · [Debugging](./debugging.md)

# Query DSL (Predicate AST)

The Predicate AST models query predicates in a compiler‑agnostic, immutable structure under `SearchEngine::AST`. It separates predicate construction from compilation to Typesense `filter_by`, enabling safer composition, inspection, and future optimizations.

## Overview

- **Safety**: Values are carried as plain Ruby data; quoting/escaping is handled later by the compiler/sanitizer.
- **Immutability**: All nodes are frozen on construction; arrays are deep‑frozen to avoid accidental mutation.
- **Uniform interface**: Nodes expose `#type` and consistent accessors (`#field`, `#value`, `#values`, `#children`, etc.).
- **Debuggable**: Stable `#to_s` and compact `#inspect` shapes for logging.

## Node catalog

- **Comparison**: `Eq`, `NotEq`, `Gt`, `Gte`, `Lt`, `Lte` — binary nodes with `field`, `value`.
- **Membership**: `In`, `NotIn` — binary nodes with `field`, `values` (non‑empty Array).
- **Pattern**: `Matches` (regex‑like; stores pattern source), `Prefix` (string begins‑with) — binary nodes with `field`, `pattern/prefix`.
- **Boolean**: `And`, `Or` — N‑ary nodes over one or more children; `nil` dropped; same‑type nodes flattened.
- **Grouping**: `Group` — wraps a single child to preserve explicit precedence.
- **Escape hatch**: `Raw` — raw string fragment passed through by the compiler.

```mermaid
classDiagram
  direction LR
  class Node
  class Eq
  class NotEq
  class Gt
  class Gte
  class Lt
  class Lte
  class In
  class NotIn
  class Matches
  class Prefix
  class And
  class Or
  class Group
  class Raw
  Node <|-- Eq
  Node <|-- NotEq
  Node <|-- Gt
  Node <|-- Gte
  Node <|-- Lt
  Node <|-- Lte
  Node <|-- In
  Node <|-- NotIn
  Node <|-- Matches
  Node <|-- Prefix
  Node <|-- And
  Node <|-- Or
  Node <|-- Group
  Node <|-- Raw
```

## Builders

Ergonomic constructors are exposed as module functions on `SearchEngine::AST`:

- `eq(field, value)` / `not_eq(field, value)`
- `gt(field, value)` / `gte(field, value)` / `lt(field, value)` / `lte(field, value)`
- `in_(field, values)` / `not_in(field, values)`
- `matches(field, pattern)` (accepts `String` or `Regexp`; stores `source` only)
- `prefix(field, prefix)`
- `and_(*nodes)` / `or_(*nodes)`
- `group(node)`
- `raw(fragment)`

### Validations

- `field` must be non‑blank `String`/`Symbol`.
- `values` must be a non‑empty `Array` (for membership nodes).
- `pattern` must be `String`/`Regexp`; only the regex source is stored.
- Boolean nodes require ≥ 1 child after dropping `nil`; nested same‑type nodes are flattened.

## Immutability & equality

- All nodes `freeze` on construction; internal arrays are deep‑frozen.
- Nodes compare by value (`#==`, `#eql?`) and have stable `#hash`, so they can be used as Hash keys or in Sets.

## Debugging

- `to_s` emits a human‑friendly outline, e.g., `and(eq(:active, true), in(:brand_id, [1, 2]))`.
- `inspect` uses a compact `#<AST ...>` shape with truncated payloads.
- No quoting/escaping occurs here; the compiler performs adapter‑specific formatting.

## Where it fits

`Relation#where` accepts Hash, raw String, and SQL‑ish fragment+args. The parser converts these inputs into AST nodes and stores them alongside legacy string filters. A later compiler pass will prefer AST when present.

### Parsing examples

```ruby
Parser.parse({ id: 1 }, klass: Product)              # => AST.eq(:id, 1)
Parser.parse(["price > ?", 100], klass: Product)    # => AST.gt(:price, 100)
Parser.parse("brand_id:=[1,2,3]", klass: Product)   # => AST::Raw("brand_id:=[1,2,3]")
```

### Input → AST flow

```mermaid
flowchart LR
  A[where input] --> B[Parser]
  B -->|hash| C[Eq / In nodes]
  B -->|fragment+args| D[Gt/Gte/Lt/Lte/In/NotIn/Matches/Prefix]
  B -->|raw string| E[Raw]
  C --> F[relation.ast]
  D --> F[relation.ast]
  E --> F[relation.ast]
```

Note: field names are validated against the model's declared `attributes`. Raw strings are accepted as an escape hatch and bypass validation.

### Integration with Relation

- `Relation#where` parses inputs into AST and appends to `relation.ast`.
- `Relation#to_typesense_params` compiles `relation.ast` via the [Compiler](./compiler.md) when present; otherwise falls back to legacy string `filters`.

See also: [Relation](./relation.md) · [Materializers](./materializers.md)

## Re‑chainers (reselect / rewhere / unscope)

[← Back to Index](./index.md) · [Relation](./relation.md) · [Compiler](./compiler.md)

AR‑style helpers to adjust a built relation immutably:

- `reselect(*fields)` — replace the selected fields (Typesense `include_fields`).
- `rewhere(input, *args)` — clear previous predicates, parse new input into AST.
- `unscope(:order, :where, :select, :limit, :offset, :page, :per)` — remove parts of state.

```ruby
rel.reselect(:id, :name)
rel.rewhere(active: true)
rel.unscope(:order)
```

Behavior notes:

- `reselect` flattens, strips, stringifies, drops blanks, and de‑duplicates preserving first occurrence. Raises when empty or unknown fields (when attributes are declared).
- `rewhere` clears both AST and legacy string `filters`, then parses the new input via the Parser. Parser errors surface as‑is.
- `unscope(:where)` clears all predicates; `:order` clears orders; `:select` clears field selection; `:limit/:offset/:page/:per` clear their counterparts (`per` clears `per_page`).

The compiled params reflect these changes: `include_fields` mirrors `reselect`; `filter_by` is rebuilt from the new AST after `rewhere`; `unscope(:where)` removes `filter_by` entirely until new predicates are added.

```mermaid
flowchart LR
  A[Relation State] -->|reselect| B[Replace select]
  A -->|rewhere| C[Clear AST -> Parse -> New AST]
  A -->|unscope(:where)| D[Clear AST]
  A -->|unscope(:order)| E[Clear orders]
  A -->|unscope(:page/per)| F[Clear pagination]
```

## Error reference

[← Back to Index](./index.md) · [Relation](./relation.md) · [Compiler](./compiler.md)

Validation happens primarily in the Parser, with light shape checks in the Compiler. `AST::Raw` deliberately bypasses validation.

| Error | Cause | Typical fix |
|------|-------|-------------|
| `SearchEngine::Errors::InvalidField` | Unknown/disallowed field for the model | Fix the field name or declare it with `attribute`; use `raw` to bypass if necessary |
| `SearchEngine::Errors::InvalidOperator` | Unrecognized operator, or placeholder/arity mismatch | Use one of: `=`, `!=`, `>`, `>=`, `<`, `<=`, `IN`, `NOT IN`, `MATCHES`, `PREFIX`; fix `?` count |
| `SearchEngine::Errors::InvalidType` | Value cannot be coerced to the declared type; empty array for membership | Coerce inputs (e.g., strings to integers), supply a non‑empty array |

- `SearchEngine.config.strict_fields` controls field validation only:
  - When `true` (default in development/test), unknown fields raise `InvalidField`.
  - When `false`, unknown fields are allowed; operator/shape/type errors are still enforced.
- `AST::Raw` nodes bypass all field/type checks by design; use sparingly and preferably behind tests.

Allowed example message:

```text
InvalidField: unknown field :colour for SearchEngine::Product (did you mean :color?)
```
