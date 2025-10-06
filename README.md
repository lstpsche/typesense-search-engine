# SearchEngine

> [!WARNING]
> **⚠️ This project is under maintenance – work in progress. APIs and docs may change. ⚠️**

Mountless Rails::Engine for Typesense. Expressive Relation/DSL with JOINs, grouping, presets/curation — with strong DX and observability.

[![CI][ci-badge]][ci-url] [![Gem][gem-badge]][gem-url] [![Docs][docs-badge]][docs-url]

## Quickstart

```ruby
# Gemfile
gem "typesense-search-engine"
```

```ruby
# config/initializers/typesense_search_engine.rb
SearchEngine.configure do |c|
  c.host = ENV.fetch("TYPESENSE_HOST", "localhost")
  c.port = 8108; c.protocol = "http"; c.api_key = ENV.fetch("TYPESENSE_API_KEY")
  c.default_query_by = "name, description"
end
```

```ruby
class SearchEngine::Product < SearchEngine::Base
  collection "products"
  attribute :id, :integer
  attribute :name, :string
end

SearchEngine::Product.where(name: "milk").select(:id, :name).limit(5).to_a
```

See Quickstart for details → [docs/quickstart.md])(https://github.com/lstpsche/typesense-search-engine/wiki).

## Documentation

- **Quickstart**: [docs/quickstart.md])(https://github.com/lstpsche/typesense-search-engine/wiki)
- **Relation & DSL Guide**: [docs/relation_guide.md])(https://github.com/lstpsche/typesense-search-engine/wiki)
- **Cookbook (patterns)**: [docs/cookbook_queries.md])(https://github.com/lstpsche/typesense-search-engine/wiki)
- **Multi‑search Guide**: [docs/multi_search_guide.md])(https://github.com/lstpsche/typesense-search-engine/wiki)
- **JOINs, Selection & Grouping**: [docs/joins_selection_grouping.md])(https://github.com/lstpsche/typesense-search-engine/wiki)
- **Presets & Curation playbook**: [docs/presets_curation_playbook.md])(https://github.com/lstpsche/typesense-search-engine/wiki)
- **Observability, DX & Testing**: [docs/observability_dx_testing.md])(https://github.com/lstpsche/typesense-search-engine/wiki)
- **CLI (doctor)**: [docs/cli.md])(https://github.com/lstpsche/typesense-search-engine/wiki)
- **Schema & Indexer E2E**: [docs/schema_indexer_e2e.md])(https://github.com/lstpsche/typesense-search-engine/wiki)
- **Testing utilities**: [docs/testing.md])(https://github.com/lstpsche/typesense-search-engine/wiki)

## Example app

See `examples/demo_shop` — demonstrates single/multi search, JOINs, grouping, presets/curation, and DX/observability. Supports offline mode via the stub client (see [docs/testing.md])(https://github.com/lstpsche/typesense-search-engine/wiki)).

## Mermaid & screenshots

Small diagrams illustrate key flows:
- Request flow: [docs/quickstart.md → Request flow])(https://github.com/lstpsche/typesense-search-engine/wiki)
- Doctor flow: [docs/cli.md → Doctor flow])(https://github.com/lstpsche/typesense-search-engine/wiki)
- Docs portal overview: [docs/index.md])(https://github.com/lstpsche/typesense-search-engine/wiki)

## Contributing

See [docs/contributing/docs_style.md])(https://github.com/lstpsche/typesense-search-engine/wiki). Follow YARDoc for public APIs, add backlinks on docs landing pages, and redact secrets in examples.

## License

MIT — see [LICENSE](./LICENSE).

---

### Deep links

- Quickstart → [Installation])(https://github.com/lstpsche/typesense-search-engine/wiki), [Configure initializer])(https://github.com/lstpsche/typesense-search-engine/wiki)
- DX → [Helpers & examples (`dry_run!`, `to_params_json`, `to_curl`)])(https://github.com/lstpsche/typesense-search-engine/wiki)
- Ranking → [Ranking & typo tuning])(https://github.com/lstpsche/typesense-search-engine/wiki)
- CLI → [Doctor flow])(https://github.com/lstpsche/typesense-search-engine/wiki)

<!-- Badge references (placeholders) -->
[ci-badge]: https://img.shields.io/github/actions/workflow/status/lstpsche/typesense-search-engine/ci.yml?branch=main
[ci-url]: #
[gem-badge]: https://img.shields.io/gem/v/typesense-search-engine.svg?label=gem
[gem-url]: https://rubygems.org/gems/typesense-search-engine
[docs-badge]: https://img.shields.io/badge/docs-index-blue
[docs-url]: https://github.com/lstpsche/typesense-search-engine/wiki
