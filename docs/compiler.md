[← Back to Index](./index.md)

# Compiler (AST → Typesense `filter_by`)

Related: [Query DSL](./query_dsl.md), [Relation](./relation.md), [Debugging](./debugging.md)

> Instrumentation: `search_engine.compile` is emitted by the compiler. See [Debugging](./debugging.md).

## Compiled Params boundary

- Public output type: `SearchEngine::CompiledParams` — immutable, read-only wrapper around compiled Typesense params.
- Determinism: `to_h` returns a symbol-keyed, lexicographically ordered Hash; `to_json` is stable across runs.
- Usage: callers may treat it like a Hash for read methods (`[]`, `key?`, `keys`, `each`) or call `to_h`.
- Construction: internal to the relation/compiler; user code does not instantiate it directly.


The compiler turns a Predicate AST under `SearchEngine::AST` into a deterministic Typesense `filter_by` string. It is pure (no I/O), safe (centralized quoting/escaping), and consistent with the `where` DSL.

## Overview

- **Deterministic**: same AST → same string; no globals.
- **Safe quoting**: uses `SearchEngine::Filters::Sanitizer` for all values.
- **Parentheses & precedence**: explicit, predictable rules (`And` > `Or`).
- **Escape hatch**: `AST::Raw` is passed through as-is.

```mermaid
flowchart LR
  A[AST] --> B[Compiler]
  B --> C[filter_by string]
```

## Node mapping

| AST node | Syntax |
| --- | --- |
| `Eq(field, value)` | `field:=VALUE` |
| `NotEq(field, value)` | `field:!=VALUE` |
| `Gt(field, value)` | `field:>VALUE` |
| `Gte(field, value)` | `field:>=VALUE` |
| `Lt(field, value)` | `field:<VALUE` |
| `Lte(field, value)` | `field:<=VALUE` |
| `In(field, [v1, v2])` | `field:=[V1, V2]` |
| `NotIn(field, [v1, v2])` | `field:!=[V1, V2]` |
| `And(n1, n2, ...)` | `... && ...` |
| `Or(n1, n2, ...)` | `... || ...` |
| `Group(child)` | `( ... )` |
| `Raw(fragment)` | passthrough |

- `Matches` / `Prefix`: Typesense `filter_by` does not support these forms; compilation raises `UnsupportedNode`. Use `AST::Raw` for adapter-specific fragments if needed.

## Quoting & types

Values are rendered via `Filters::Sanitizer.quote`:

- **String**: double-quoted, with minimal escaping for `\` and `"`.
- **Boolean**: `true`/`false`.
- **Nil**: `null`.
- **Numeric**: as-is.
- **Time/Date/DateTime**: ISO8601 string (quoted). Upstream parsing coerces Date/DateTime to `Time.utc`.
- **Array**: one-level flatten; each element quoted; wrapped as `[a, b]`.

## Precedence & parentheses

- Precedence: `And` = 20, `Or` = 10. Leaves bind tighter.
- `Group` always inserts parentheses.
- Parentheses are added when a child has lower precedence than its parent.
- Whitespace: single spaces around `&&` and `||`.

## Examples

```ruby
Compiler.compile(AST.and_(AST.eq(:active, true), AST.in_(:brand_id, [1, 2])), klass: Product)
# => "active:=true && brand_id:=[1, 2]"

Compiler.compile(AST.or_(AST.eq(:a, 1), AST.and_(AST.eq(:b, 2), AST.eq(:c, 3))))
# => "a:=1 || (b:=2 && c:=3)"

Compiler.compile(AST.group(AST.or_(AST.eq(:a, 1), AST.eq(:b, 2))))
# => "(a:=1 || b:=2)"

Compiler.compile([AST.eq(:x, 1), AST.eq(:y, 2)])
# => "x:=1 && y:=2"
```

## Integration

- `Relation#to_typesense_params` prefers compiling `ast` when present, falling back to legacy string `filters` for backward compatibility.
- `Raw` fragments are preserved through the pipeline.
- When joins are applied, joined fields render as `$assoc.field` in `filter_by` and as `$assoc.field:dir` in `sort_by`. Nested `include_fields` compile to `$assoc(field1,field2,...)` segments emitted before base fields. The final `include_fields` reflects precedence: effective include set = include − exclude (per path); exclude always wins. Empty groups are omitted.
- Curation state maps to body params: `pinned_hits`, `hidden_hits`, `override_tags`, `filter_curated_hits` (omitted when empty/`nil`). See [Curation](./curation.md).

### Example with joins

```ruby
rel = SearchEngine::Book
  .joins(:authors)
  .include_fields(authors: [:first_name])
  .where(authors: { last_name: "Rowling" })
  .order(authors: { last_name: :asc })
rel.to_typesense_params
# => { q: "*", query_by: "name, description", include_fields: "$authors(first_name)", filter_by: "$authors.last_name:\"Rowling\"", sort_by: "$authors.last_name:asc", _join: { assocs: [:authors], fields_by_assoc: { authors: ["first_name"] }, referenced_in: { include: [:authors], filter: [:authors], sort: [:authors] } } }
```

Note: the `:_join` section is an internal context map for downstream components and may be removed by the HTTP layer before sending the request. See [Joins](./joins.md) for details.

See also: [DX](./dx.md#helpers--examples) for `Relation#to_params_json` — it uses `SearchEngine::CompiledParams` to ensure stable ordering.

See also: [Relation](./relation.md) · [Query DSL](./query_dsl.md) · [Joins](./joins.md)

## Troubleshooting

- **Unsupported node**: Use `AST::Raw` for adapter‑specific fragments not supported by `filter_by`.
- **Unexpected quoting**: All quoting is centralized in the sanitizer; ensure values are passed as plain Ruby objects.
- **Complex precedence**: Wrap with `AST.group` to force explicit parentheses.

Backlinks: [README](../README.md), [Query DSL](./query_dsl.md)
