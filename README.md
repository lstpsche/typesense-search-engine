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

See Quickstart for details → [docs/quickstart.md](./docs/quickstart.md).

## Documentation

- **Quickstart**: [docs/quickstart.md](./docs/quickstart.md)
- **Relation & DSL Guide**: [docs/relation_guide.md](./docs/relation_guide.md)
- **Cookbook (patterns)**: [docs/cookbook_queries.md](./docs/cookbook_queries.md)
- **Multi‑search Guide**: [docs/multi_search_guide.md](./docs/multi_search_guide.md)
- **JOINs, Selection & Grouping**: [docs/joins_selection_grouping.md](./docs/joins_selection_grouping.md)
- **Presets & Curation playbook**: [docs/presets_curation_playbook.md](./docs/presets_curation_playbook.md)
- **Observability, DX & Testing**: [docs/observability_dx_testing.md](./docs/observability_dx_testing.md)
- **CLI (doctor)**: [docs/cli.md](./docs/cli.md)
- **Schema & Indexer E2E**: [docs/schema_indexer_e2e.md](./docs/schema_indexer_e2e.md)
- **Testing utilities**: [docs/testing.md](./docs/testing.md)

## Example app

See `examples/demo_shop` — demonstrates single/multi search, JOINs, grouping, presets/curation, and DX/observability. Supports offline mode via the stub client (see [docs/testing.md](./docs/testing.md)).

## Mermaid & screenshots

Small diagrams illustrate key flows:
- Request flow: [docs/quickstart.md → Request flow](./docs/quickstart.md#request-flow)
- Doctor flow: [docs/cli.md → Doctor flow](./docs/cli.md#doctor-flow)
- Docs portal overview: [docs/index.md](./docs/index.md)

## Contributing

See [docs/contributing/docs_style.md](./docs/contributing/docs_style.md). Follow YARDoc for public APIs, add backlinks on docs landing pages, and redact secrets in examples.

## License

MIT — see [LICENSE](./LICENSE).

---

### Deep links

- Quickstart → [Installation](./docs/quickstart.md#install-the-gem), [Configure initializer](./docs/quickstart.md#configure-the-initializer)
- DX → [Helpers & examples (`dry_run!`, `to_params_json`, `to_curl`)](./docs/dx.md#helpers--examples)
- Ranking → [Ranking & typo tuning](./docs/ranking.md)
- CLI → [Doctor flow](./docs/cli.md#doctor-flow)

<!-- Badge references (placeholders) -->
[ci-badge]: https://img.shields.io/github/actions/workflow/status/lstpsche/typesense-search-engine/ci.yml?branch=main
[ci-url]: #
[gem-badge]: https://img.shields.io/gem/v/typesense-search-engine.svg?label=gem
[gem-url]: https://rubygems.org/gems/typesense-search-engine
[docs-badge]: https://img.shields.io/badge/docs-index-blue
[docs-url]: ./docs/index.md
