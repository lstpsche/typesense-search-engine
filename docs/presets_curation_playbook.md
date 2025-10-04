## Observability hooks

Expected events (keys and counts only; values redacted):

- `search_engine.preset.apply`
- `search_engine.curation.apply`
- `search_engine.curation.compile` (curation state present)
- `search_engine.compile` (unified compile stage)
- `search_engine.search`

The doctor CLI surfaces config basics (namespaces, locked domains) for troubleshooting; it does not
change behavior.

---
