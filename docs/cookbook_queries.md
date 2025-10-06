[← Back to Index](./index.md)

# Query Cookbook — Common Patterns

Related: [Relation](./relation.md), [Query DSL](./query_dsl.md), [DX](./dx.md)

## Intro

Copy these minimal patterns and adapt fields to your models. Prefer `dry_run!` and
`explain` to debug locally without network I/O.

> Reference: The chaining form shown in the Guide (“Ranges + Pagination”) uses
> `SearchEngine::Product.where(price: 100..200).order(updated_at: :desc).page(2).per(20)`.

## Index of patterns

- [Exact match](#exact-match)
- [Prefix/infix match](#prefixinfix-match)
- [Any of list (IN)](#any-of-list-in)
- [Price range + sort](#price-range--sort)
- [Pagination](#pagination)
- [Facet filters](#facet-filters)
- [Faceting DSL](#faceting-dsl)
- [Pinned/hidden curation](#pinnedhidden-curation)
- [Grouping top‑N](#grouping-top-n)
- [Joins — basic](#joins--basic)
- [Multi‑search two relations](#multi-search-two-relations)

[Back to top ⤴](#query-cookbook-%E2%80%94-common-patterns)

## Recipes

### Exact match

Small set lookup by ID.

```ruby
SearchEngine::Product.where(id: 42)
```

Why it works / gotchas:
- Simple `Eq` predicate; validated field name
- Use arrays for `IN` (see below)
- Links: [Query DSL → Builders](./query_dsl.md#builders)

---

### Prefix/infix match

Begins‑with or contains‑like filters via templates/raw.

```ruby
SearchEngine::Product.where(["name PREFIX ?", "mil"])  # prefix
SearchEngine::Product.where("name:~=milk")               # infix (raw)
```

Why / gotchas:
- `PREFIX` is parsed to AST; infix shown as raw Typesense fragment
- Consider query text in `q` for full‑text; this is a filter
- Links: [Query DSL](./query_dsl.md#builders), [Compiler](./compiler.md#node-mapping)

---

### Any of list (IN)

Match any of several brands.

```ruby
SearchEngine::Product.where(brand_id: [1, 2, 3])
```

Why / gotchas:
- Non‑empty arrays only; values coerced per attribute type
- Links: [Query DSL → Parsing examples](./query_dsl.md#parsing-examples)

---

### Price range + sort

Use two comparators for numeric ranges.

```ruby
SearchEngine::Product
  .where(["price >= ?", 100])
  .where(["price <= ?", 200])
  .order(price: :asc)
```

Why / gotchas:
- Typesense has no range literal in `filter_by`; use `>=` and `<=`
- Links: [Compiler → Quoting & types](./compiler.md#quoting--types)

---

### Pagination

Classic page/per; prefer this over `limit/offset` unless you need offset math.

```ruby
SearchEngine::Product.page(2).per(20)
```

Why / gotchas:
- `page >= 1`, `per >= 1`; wins over `limit/offset`
- Links: [Relation → order/select/pagination](./relation.md#order--select--pagination)

---

### Facet filters

Combine multiple filters with AND semantics across calls.

```ruby
SearchEngine::Product
  .where(category: "dairy")
  .where(brand_id: [1, 2])
  .where(["price <= ?", 500])
```

Why / gotchas:
- Each `where` appends; compiled with `AND`
- Links: [Query DSL → Where it fits](./query_dsl.md#where-it-fits)

---

### Pinned/hidden curation

Pin two IDs and hide one; keep network‑safe while inspecting.

```ruby
rel = SearchEngine::Product.pin("p_12", "p_34").hide("p_99")
rel.dry_run!
```

Why / gotchas:
- Curation keys are body‑only; redacted in logs
- Hide wins when an ID is both pinned and hidden
- Links: [Curation](./curation.md#dsl), [Observability](./observability.md#observability)

---

### Grouping top‑N

First hit per group, up to N hits inside each.

```ruby
SearchEngine::Product.group_by(:brand_id, limit: 2)
```

Why / gotchas:
- `group_limit` caps hits per group; pagination applies to number of groups
- Links: [Grouping](./grouping.md#pagination-interaction)

---

### Joins — basic

Filter on a joined collection field.

```ruby
SearchEngine::Book
  .joins(:authors)
  .where(authors: { last_name: "Rowling" })
  .include_fields(authors: [:first_name])
```

Why / gotchas:
- Call `.joins(:assoc)` before referencing `$assoc.field`
- Links: [Joins](./joins.md#relation-usage), [Compiler](./compiler.md#integration)

---

### Multi‑search two relations

Send two labeled relations in one round‑trip.

```ruby
res = SearchEngine.multi_search do |m|
  m.add :products, SearchEngine::Product.where(category: "dairy").per(5)
  m.add :brands,   SearchEngine::Brand.where(["name PREFIX ?", "mil"]).per(3)
end
```

Why / gotchas:
- Per‑search params compiled independently; order preserved by labels
- Links: [Multi‑search](./multi_search.md#dsl)

---

## Debug each recipe

Use `explain` or `dry_run!` to preview without I/O:

```ruby
rel = SearchEngine::Product.where(active: true).order(updated_at: :desc).per(10)
puts rel.explain
rel.dry_run!
```

Redaction policy hides literals and secrets; bodies remain copyable.

[Back to top ⤴](#query-cookbook-%E2%80%94-common-patterns)

## Edge‑case callouts

- **Quoting**: strings double‑quoted; booleans and `null` literal; arrays flattened one level
- **Boolean coercion**: only for boolean‑typed fields; strings "true"/"false" accepted
- **Empty arrays**: invalid for membership; provide at least one value
- **Reserved characters**: prefer templates with placeholders to avoid manual escaping
- **Ambiguous names**: unknown fields raise with suggestions when attributes are declared
- **Sort vs group order**: sort applies before grouping; group order preserved

---

Related links: [Query DSL](./query_dsl.md), [Compiler](./compiler.md), [DX](./dx.md),
[Observability](./observability.md), [Joins](./joins.md), [Grouping](./grouping.md),
[Presets](./presets.md), [Curation](./curation.md)

### Faceting DSL

Add facets and facet queries:

```ruby
rel = SearchEngine::Product
  .facet_by(:brand_id, max_values: 20)
  .facet_query(:price, "[0..9]", label: "under_10")

res = rel.execute
res.facet_values("brand_id") # => array of { value:, count:, ... }
```

See `docs/faceting.md` for details.
