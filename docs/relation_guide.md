[← Back to Index](./index.md)

# Relation and Query DSL — Guide

Related: [Query DSL](./query_dsl.md), [Compiler](./compiler.md), [DX](./dx.md), [Observability](./observability.md)

## Intro

Use `Relation` to compose safe, immutable searches and the Query DSL to express predicates.
Prefer it over raw client calls for:
- **Safety**: quoting, validation, and redaction are centralized
- **Immutability**: AR‑style chainers return new relations without mutation
- **Debuggability**: `explain`, `to_curl`, `dry_run!` visualize requests with zero I/O

See also: [Relation](./relation.md) and [Debugging](./debugging.md).

## Building a query

`where` accepts hashes, raw strings, or template fragments with placeholders. Multiple
`where` calls compose with AND semantics.

Basics:
- **Primitives**: `where(active: true)` → `active:=true`
- **Arrays (IN)**: `where(brand_id: [1, 2, 3])` → `brand_id:=[1, 2, 3]`
- **Template + args**: `where(["price >= ?", 100])`, `where(["price <= ?", 200])`
- **Raw escape hatch**: `where("price:>100 && price:<200")`

Notes:
- Field names are validated against model attributes when declared
- Placeholders are strictly arity‑checked and safely quoted by the sanitizer
- OR semantics require a raw fragment (e.g., `"a:=1 || b:=2"`) or higher‑level AST usage
  (see [Query DSL → Builders](./query_dsl.md#builders))

## Chaining

Use AR‑style chainers to add sorting, selection, and pagination. Chain order does not
matter; the compiler emits a deterministic param set.

Verbatim example (chaining):

```ruby
SearchEngine::Product.where(price: 100..200).order(updated_at: :desc).page(2).per(20)
```

What it shows:
- **where(...)**: adds predicates (see edge‑case note on Ruby `Range` below)
- **order(updated_at: :desc)**: compiles to `sort_by: "updated_at:desc"`
- **page(2).per(20)**: compiles to `page: 2, per_page: 20`

Range note: Ruby `Range` (e.g., `100..200`) is not a first‑class numeric range literal in
`filter_by`. Prefer two comparators:

```ruby
SearchEngine::Product
  .where(["price >= ?", 100])
  .where(["price <= ?", 200])
```

See: [DX helpers](./dx.md#helpers--examples) to preview compiled params. NOT-IN is rendered as `NOT IN [...]` in explain output.

## Grouping

Group by a single field and optionally control per‑group hit count and whether missing
values form their own group:

```ruby
rel = SearchEngine::Product.group_by(:brand_id, limit: 1, missing_values: true)
rel.to_typesense_params
# => { q: "*", query_by: "name, description", group_by: "brand_id", group_limit: 1,
#      group_missing_values: true }
```

Caveats and interactions:
- **Limits**: `group_limit` must be a positive integer when present
- **Missing values**: included only when `true`
- **Ordering**: Group order and within‑group hit order are preserved
- **Selection**: Selection applies to hydrated hits; nested includes are unaffected
- **Sorting**: Sort is applied before grouping; within‑group order follows backend order

See: [Grouping](./grouping.md#grouping-%E2%80%94-overview--compiler-mapping),
[Guardrails & errors](./grouping.md#grouping-%E2%80%94-overview--compiler-mapping),
[Troubleshooting](./grouping.md#grouping-%E2%80%94-overview--compiler-mapping).

[Back to top ⤴](#relation-and-query-dsl-%E2%80%94-guide)

## Joins & presets (orientation)

- **Joins**: Declare associations on the model, apply with `.joins(:assoc)`, then filter
  and select using nested shapes (e.g., `where(authors: { last_name: "Rowling" })`,
  `include_fields(authors: [:first_name])`). See
  [Joins → DSL](./joins.md#dsl) and
  [Filtering/Ordering on joined fields](./joins.md#filtering-and-ordering-on-joined-fields).
- **Presets**: Attach server‑side bundles of defaults and choose a mode
  (`:merge`, `:only`, `:lock`). See
  [Presets → Relation DSL](./presets.md#relation-dsl) and
  [Strategies](./presets.md#strategies-merge-only-lock).

Keep deeper usage to those pages; this guide focuses on composition basics.

## Debugging

Zero‑I/O helpers:

```ruby
rel = SearchEngine::Product.where(active: true).order(updated_at: :desc).page(2).per(20)
rel.to_params_json           # redacted request body as JSON
rel.to_curl                  # single‑line, redacted curl
rel.dry_run!                 # { url:, body:, url_opts: } — no network I/O
puts rel.explain             # concise human summary
```

- All outputs are redacted and stable for copy‑paste
- `dry_run!` validates and returns a redacted body; no HTTP requests are made
- Use `explain` to preview grouping, joins, presets/curation, conflicts, and events

See: [DX](./dx.md#helpers--examples), [Debugging](./debugging.md#relationexplain).

[Back to top ⤴](#relation-and-query-dsl-%E2%80%94-guide)

## Compiler mapping

Relation state compiles into Typesense params deterministically. High‑level mapping:

```mermaid
flowchart LR
  subgraph R[Relation state]
    A[AST (where)]
    B[orders]
    C[selection<br/>include/exclude]
    D[grouping]
    E[preset name+mode]
    F[options (q,infix)]
  end
  R --> G[Compiler]
  G --> H[Params]
  H -->|keys| I[q, query_by, filter_by, sort_by,
per_page/page, include/exclude, group_* , preset]
  I --> J[Client]
```

See: [Compiler](./compiler.md#integration) for precedence, quoting rules, and join context.

## Edge cases

- **Quoting**: strings are double‑quoted; booleans `true/false`; `nil` → `null`; arrays are one‑level
  flattened and quoted element‑wise. Times are ISO8601 strings
  ([Sanitizer](../lib/search_engine/filters/sanitizer.rb)).
- **Booleans vs strings**: boolean fields coerce "true"/"false"; other fields treat strings literally
  (see [Parser](./query_dsl.md#builders)).
- **Empty arrays**: membership operators require non‑empty arrays
- **Range endpoints**: express with two comparators (see Chaining note above)
- **nil/missing**: `nil` compiles to `null`; use `not_eq(field, nil)` or `not_in(field, [nil])` to exclude nulls
- **Unicode/locale**: collation/tokenization follow index settings; normalize inputs in your app if needed
- **Joined fields**: require `.joins(:assoc)` before filtering/sorting/selection on `$assoc.field`
  (see [Joins](./joins.md)).
- **Grouping field**: base fields only; joined paths like `$assoc.field` are rejected
  (see [Grouping → Troubleshooting](./grouping.md#grouping-%E2%80%94-overview--compiler-mapping)).
- **Special characters**: raw fragments are passed through; prefer templates for quoting

[Back to top ⤴](#relation-and-query-dsl-%E2%80%94-guide)

### Selection, grouping & faceting

See `docs/faceting.md` for first-class faceting DSL: `facet_by`, `facet_query`, compiler mapping and result helpers.

---

Related links: [Query DSL](./query_dsl.md), [Compiler](./compiler.md), [DX](./dx.md),
[Observability](./observability.md), [Joins](./joins.md), [Grouping](./grouping.md),
[Presets](./presets.md), [Curation](./curation.md)
