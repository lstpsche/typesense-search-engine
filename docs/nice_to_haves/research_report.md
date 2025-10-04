# Deferred Typesense features — capability survey and DSL design

Short abstract: We catalog Typesense capabilities relevant to deferred features, summarize authoritative params/limits, and propose backward‑compatible DSL shapes and compiler mappings. We conclude with Now vs Later recommendations, risks, and migration notes.

### Related links
- [DX helpers](../dx.md)
- [Observability & OTel](../observability.md)
- [Relation guide](../relation_guide.md)
- [Cookbook queries](../cookbook_queries.md)
- [Multi‑search guide](../multi_search_guide.md)
- [CLI doctor](../cli.md)
- [Testing](../testing.md)
- [Schema/indexer E2E](../schema_indexer_e2e.md)

### Method & sources
- Primary: Official Typesense docs (API reference + feature guides), favoring versioned pages. Inline citations use bracketed labels (e.g., [TS‑SearchParams]). See Sources for URLs.
- Cross‑checks: When behavior seemed ambiguous, we verified across Search Parameters, Faceting, and Feature pages.
- Versioning: When docs do not specify version gates, we mark as TBD.

---

## Capability tables

Each table lists exact server parameter names, constraints, interactions, proposed DSL shape (additive/back‑compat), compiler mapping, and ship bucket.

### 1) Union (logical OR across collections/queries)

| Capability | Typesense params (authoritative names) | Since | Constraints & limits | Interactions | Defaults (server) | Proposed DSL surface (back‑compat) | Compiler mapping (Relation → params) | Migration notes | Risk | Ship bucket |
| ---------- | -------------------------------------- | ----- | -------------------- | ------------ | ----------------- | ---------------------------------- | ------------------------------------ | --------------- | ---- | ----------- |
| Union across collections/queries | `multi_search` endpoint with `searches: [...]` payload; each search has its own `collection`, `q`, `query_by`, etc [TS‑MultiSearch] | TBD | Results are independent per search; no native cross‑collection dedupe/merge. Response size/latency grows with N searches. | Pagination, sorting, and faceting are per‑search. | N/A | `union(queries:, merge: :append|:interleave, dedupe_by: nil)` | Compile to a Multi‑search request; perform merge/dedupe client‑side (respect sort orders). | Back‑compatible; purely additive. Clarify that ranking is not recomputed across collections. | M | Later |

Notes: In Typesense, “union” is not a first‑class server feature; client must aggregate multi‑search responses. [TS‑MultiSearch]

### 2) Synonyms / Stopwords (management + query‑time switches)

| Capability | Typesense params (authoritative names) | Since | Constraints & limits | Interactions | Defaults (server) | Proposed DSL surface (back‑compat) | Compiler mapping (Relation → params) | Migration notes | Risk | Ship bucket |
| ---------- | -------------------------------------- | ----- | -------------------- | ------------ | ----------------- | ---------------------------------- | ------------------------------------ | --------------- | ---- | ----------- |
| Synonym sets (per collection) | Synonyms API: CRUD at `/collections/{collection}/synonyms` [TS‑Synonyms] | TBD | Stored per collection; large sets affect index size and build times. | Affects token expansion and recall; interacts with typo tolerance. | Applied if present; no per‑query override documented. | `manage_synonyms(add:[], upsert:[], delete:[])` | Use client to call Synonyms API (out of band from Relation). | Management is orthogonal to query DSL; document CLI/doctor checks. | M | Later |
| Stopword lists (per collection) | Stopwords API: CRUD at `/collections/{collection}/stopwords` [TS‑Stopwords] | TBD | Excessive stopwords can reduce recall. | Interacts with token dropping thresholds. | Applied if present; no per‑query override documented. | `manage_stopwords(add:[], upsert:[], delete:[])` | Use client to call Stopwords API (out of band). | Same as synonyms; ensure indexer/docs cover precedence. | M | Later |

Notes: Per‑query enable/disable flags for synonyms/stopwords are not documented; treat as index‑time configuration. [TS‑Synonyms] [TS‑Stopwords]

### 3) Highlighting controls

| Capability | Typesense params (authoritative names) | Since | Constraints & limits | Interactions | Defaults (server) | Proposed DSL surface (back‑compat) | Compiler mapping (Relation → params) | Migration notes | Risk | Ship bucket |
| ---------- | -------------------------------------- | ----- | -------------------- | ------------ | ----------------- | ---------------------------------- | ------------------------------------ | --------------- | ---- | ----------- |
| Highlighting | `highlight_fields`, `highlight_full_fields`, `highlight_affix_num_tokens`, `highlight_start_tag`, `highlight_end_tag` [TS‑SearchParams] | TBD | Increasing affix tokens inflates payload size. | Interacts with `include_fields`/`exclude_fields`. | Start/end tags default to `<mark>`/`</mark>`; affix tokens default commonly to 4. | `highlight(fields:, full_fields: nil, affix_tokens: 4, start_tag: "<mark>", end_tag: "</mark>")` | Map 1:1 to `highlight_*` params; validate field presence against schema; redact highlighted text in logs via DX helpers. | Additive; default off maintains current behavior. | L | Now |

Validation: disallow both `include_fields` and `exclude_fields` hiding all highlighted fields; hint with [Error UX] to enable specific fields. [TS‑SearchParams]

### 4) Advanced faceting

| Capability | Typesense params (authoritative names) | Since | Constraints & limits | Interactions | Defaults (server) | Proposed DSL surface (back‑compat) | Compiler mapping (Relation → params) | Migration notes | Risk | Ship bucket |
| ---------- | -------------------------------------- | ----- | -------------------- | ------------ | ----------------- | ---------------------------------- | ------------------------------------ | --------------- | ---- | ----------- |
| Facets (basic + query) | `facet_by`, `max_facet_values`, `facet_query` [TS‑Faceting] | TBD | Large facet cardinalities increase response size and compute. | Interacts with filters and grouping; per‑page/page do not affect facet counts. | `max_facet_values` default commonly 10. | `facet(by:, max_values: nil, query: nil)` | Map 1:1; split multi‑field lists by comma; validate fields are facetable in schema. | Additive; aligns with existing Typesense semantics. | M | Now |
| Nested/combined facets; sampling; custom facet sort | Not documented as first‑class features [TS‑Faceting] | — | Treat as unsupported server‑side for now. | — | — | `facet_nested(...)`, `facet_sample(...)`, `facet_sort(...)` (shapes reserved) | N/A (intentionally not compiled) | Document as deferred; capture use‑cases. | M | Later |

### 5) Geo

| Capability | Typesense params (authoritative names) | Since | Constraints & limits | Interactions | Defaults (server) | Proposed DSL surface (back‑compat) | Compiler mapping (Relation → params) | Migration notes | Risk | Ship bucket |
| ---------- | -------------------------------------- | ----- | -------------------- | ------------ | ----------------- | ---------------------------------- | ------------------------------------ | --------------- | ---- | ----------- |
| Geo filters & distance sort | `filter_by` with geopoint expressions; `sort_by` with distance for a geopoint field [TS‑Geo] [TS‑FieldTypes] | TBD | Requires `geopoint` field in schema; precision depends on indexing. | Interacts with other filters and sorts; grouping unaffected. | N/A | `where_geo(within_radius: {field:, lat:, lng:, radius_m:})`, `sort_geo(by_distance: {field:, from:[lat,lng]})` | Compile to `filter_by` geo predicate and `sort_by: "<field>:asc(_distance from)"` or doc‑accurate grammar; validate schema and units. | Additive; keep off by default. | M | Later |

Notes: Exact `filter_by` grammar for geo is versioned; validate at compile‑time with doc‑linked hints. [TS‑Geo]

### 6) Vectors / AI (vector fields, ANN params, hybrid)

| Capability | Typesense params (authoritative names) | Since | Constraints & limits | Interactions | Defaults (server) | Proposed DSL surface (back‑compat) | Compiler mapping (Relation → params) | Migration notes | Risk | Ship bucket |
| ---------- | -------------------------------------- | ----- | -------------------- | ------------ | ----------------- | ---------------------------------- | ------------------------------------ | --------------- | ---- | ----------- |
| Vector search | `vector_query` with syntax like `embedding:([..], num_candidates: N)`; schema `vector` field type [TS‑Vector] | TBD | Vector dimensionality must match schema; high `num_candidates` affects latency. | Hybrid with keyword search typically combines ranks; check doc for precedence knobs. | N/A | `vectors(query:, field:, num_candidates: nil, weight: nil)` | Map to `vector_query` string for the given field; redact vector payloads from logs; optionally pass hybrid weights if server supports. | Additive; no effect unless used. | H | Later |

Optional mini‑diagram:

```mermaid
flowchart LR
  A[Client Query q + vector v] --> B{Compiler}
  B -->|keyword| C[Typesense search params]
  B -->|vector| D[vector_query: field(v), num_candidates]
  C --> E[Server]
  D --> E
  E --> F[Combined ranking (server-defined)]
```

### 7) Hit limits (caps, per‑group limits, pagination interactions)

| Capability | Typesense params (authoritative names) | Since | Constraints & limits | Interactions | Defaults (server) | Proposed DSL surface (back‑compat) | Compiler mapping (Relation → params) | Migration notes | Risk | Ship bucket |
| ---------- | -------------------------------------- | ----- | -------------------- | ------------ | ----------------- | ---------------------------------- | ------------------------------------ | --------------- | ---- | ----------- |
| Pagination & caps | `per_page`, `page`, `group_by`, `group_limit`, `exhaustive_search`, `search_cutoff_ms` [TS‑Pagination] [TS‑Grouping] [TS‑SearchParams] | TBD | Large `per_page` inflates payloads; `exhaustive_search:false` can truncate recall under cutoff. | Grouping limits apply within groups; affects perceived per‑page. | `page=1`, `per_page=10` typical defaults. | `limit(per_page:, page: 1)`, `group(by:, limit:)`, `exhaustive(on:)`, `cutoff_ms(ms:)` | Map 1:1; validate positive integers; hint when `group_limit * groups` < `per_page`. | Additive; preserves current defaults when unset. | L | Now |

---

## Recommendations

- Now (ship in this bucket)
  - Highlighting controls: 1:1 param mapping; low risk; straightforward compile‑time validation. Add DX redaction for highlighted snippets in logs. Minimal DSL: `highlight(fields:, full_fields:, affix_tokens:, start_tag:, end_tag:)`.
  - Basic faceting controls: `facet_by`, `max_facet_values`, `facet_query`. Minimal DSL: `facet(by:, max_values:, query:)`. Tests: compile mapping + param validation.
  - Hit limits & pagination: `per_page`, `page`, `group_by`, `group_limit`, `exhaustive_search`, `search_cutoff_ms`. Minimal DSL: `limit`, `group`, `exhaustive`, `cutoff_ms`. Tests: pagination math + grouping interactions.

- Later (defer)
  - Union across collections: requires client‑side merge/dedupe policy and observability; define deterministic interleaving before shipping. Prereq: merge policy & perf guardrails. Unknowns: cross‑search ranking.
  - Synonyms/Stopwords management: scope belongs to admin/CLI; wire separately from Relation DSL. Add doctor checks and docs; no query‑time flag exposed in docs today.
  - Geo: finalize grammar coverage and unit handling; add compiler validations tied to schema `geopoint`. Prereq: stable grammar reference per server version.
  - Vectors/Hybrid: high‑variance feature set; finalize `vector_query` grammar, hybrid weighting, and redaction. Prereq: server version gating and perf SLOs.
  - Advanced faceting extras (nested/sampling/custom sort): out of scope until server primitives exist.

- Flags & defaults
  - Config kill‑switches: `config.features.highlighting`, `config.features.faceting`, `config.features.grouping`, `config.features.exhaustive_search` (default off for new features).
  - Presets: ship safe defaults aligned with server (e.g., `affix_tokens=4`, `max_facet_values=10`, `page=1`, `per_page=10`).
  - Observability: when active, log feature flags and normalized params into our instrumentation events (see [Observability & OTel](../observability.md)).

---

## Open questions & risk register

Per capability:

- Union
  - Open: How do we interleave/dedupe results deterministically across searches? What’s the pagination model? [TS‑MultiSearch]
  - Risk: M — correctness/perf of client‑side merge. Mitigation: stable policy + benchmarks + feature flag.

- Synonyms/Stopwords
  - Open: Any per‑query enable/disable flags? If not, should we simulate via presets? [TS‑Synonyms] [TS‑Stopwords]
  - Risk: M — admin surface creep in query DSL. Mitigation: keep in CLI/admin; add doctor checks.

- Highlighting
  - Open: Confirm defaults per server version for `highlight_affix_num_tokens`. [TS‑SearchParams]
  - Risk: L — payload size/perf. Mitigation: conservative defaults and size logging.

- Advanced faceting
  - Open: Are nested/sampled facets planned server‑side? [TS‑Faceting]
  - Risk: M — API churn if we guess semantics. Mitigation: reserve DSL names; do not compile until server supports.

- Geo
  - Open: Exact `filter_by` grammar variants for geo across versions; supported distance sort notations. [TS‑Geo]
  - Risk: M — incorrect compile grammar. Mitigation: strict compile‑time validation and doc‑linked hints.

- Vectors/Hybrid
  - Open: Confirm `vector_query` grammar (e.g., `num_candidates`, hybrid weighting knobs) and version gates. [TS‑Vector]
  - Risk: H — perf/costs + redaction. Mitigation: feature flag, strict redaction, and SLO‑based guardrails.

- Hit limits
  - Open: Interactions between `group_limit`, `group_by`, and `per_page` across edge cases; clarify `exhaustive_search` semantics with `search_cutoff_ms`. [TS‑Pagination]
  - Risk: L — UX confusion. Mitigation: compile‑time hints and cookbook examples.

---

## Migration & documentation plan

- YARD earmarks: add short docstrings for new public DSL entry points (`highlight`, `facet`, `limit`, `group`, `exhaustive`, `cutoff_ms`) describing param mapping and defaults.
- Docs: link this memo from `docs/index.md`; add anchors in `docs/relation_guide.md` and examples in `docs/cookbook_queries.md` for highlighting/faceting/pagination.
- CLI/doctor: add checks that surface misconfigurations (e.g., requesting highlight on non‑indexed fields; `group_limit` > `per_page`).
- Observability: extend event payload to include normalized feature flags and redacted values.

### Related links (again)
- [DX helpers](../dx.md)
- [Observability & OTel](../observability.md)
- [Relation guide](../relation_guide.md)
- [Cookbook queries](../cookbook_queries.md)
- [Multi‑search guide](../multi_search_guide.md)
- [CLI doctor](../cli.md)
- [Testing](../testing.md)
- [Schema/indexer E2E](../schema_indexer_e2e.md)

---

## Sources
- [TS‑SearchParams] Typesense — Search Parameters (versioned): `https://typesense.org/docs/0.25.x/api/search.html`
- [TS‑Faceting] Typesense — Faceting (on Search Parameters page): `https://typesense.org/docs/0.25.x/api/search.html#faceting`
- [TS‑Highlight] Typesense — Highlighting (on Search Parameters page): `https://typesense.org/docs/0.25.x/api/search.html#highlighting`
- [TS‑Pagination] Typesense — Pagination (on Search Parameters page): `https://typesense.org/docs/0.25.x/api/search.html#pagination`
- [TS‑Grouping] Typesense — Grouping results: `https://typesense.org/docs/0.25.x/api/search.html#grouping`
- [TS‑MultiSearch] Typesense — Multi‑Search API: `https://typesense.org/docs/0.25.x/api/multi-search.html`
- [TS‑Synonyms] Typesense — Synonyms API: `https://typesense.org/docs/0.25.x/api/synonyms.html`
- [TS‑Stopwords] Typesense — Stopwords API: `https://typesense.org/docs/0.25.x/api/stopwords.html`
- [TS‑FieldTypes] Typesense — Field types (`geopoint`): `https://typesense.org/docs/0.25.x/api/field-types.html`
- [TS‑Geo] Typesense — Geo search (see Search Parameters and guides): `https://typesense.org/docs/0.25.x/api/search.html#geosearch`
- [TS‑Vector] Typesense — Vector Search: `https://typesense.org/docs/0.25.x/api/vector-search.html`
