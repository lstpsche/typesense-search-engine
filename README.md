# Search Engine for Typesense [![CI][ci-badge]][ci-url] [![Gem][gem-badge]][gem-url] [![Docs][docs-badge]][docs-url]

> [!WARNING]
> **⚠️ This project is under maintenance – work in progress. APIs and docs may change. ⚠️**

Mountless Rails::Engine for [Typesense](https://typesense.org). Expressive Relation/DSL with JOINs, grouping, presets/curation — with strong DX and observability.

> [!NOTE]
> This project is not affiliated with [Typesense](https://typesense.org) and is a wrapper for the [`typesense` gem](https://github.com/typesense/typesense-ruby).

## Quickstart

```ruby
# Gemfile
gem "search-engine-for-typesense"
```

```ruby
# config/initializers/search_engine_for_typesense.rb
SearchEngine.configure do |c|
  c.host = ENV.fetch("TYPESENSE_HOST", "localhost")
  c.port = 8108
  c.protocol = "http"
  c.api_key = ENV.fetch("TYPESENSE_API_KEY")
end
```

```ruby
class SearchEngine::Product < SearchEngine::Base
  collection :products

  attribute :id, :integer
  attribute :name, :string

  query_by %i[name brand description]
end

SearchEngine::Product.where(name: "milk").select(:id, :name).limit(5).to_a
```

See Quickstart → [Quickstart](https://github.com/lstpsche/search-engine-for-typesense/wiki/Quickstart).

### Host app SearchEngine models

By default, the gem manages a dedicated Zeitwerk loader for your SearchEngine models under `app/search_engine/`. The loader is initialized after Rails so that application models/constants are available, auto-reloads in development, and is eager-loaded in production/test.

Customize or disable via configuration:

```ruby
# config/initializers/search_engine.rb
SearchEngine.configure do |c|
  # Relative to Rails.root or absolute; set to nil/false to disable
  c.search_engine_models = 'app/search_engine'
end
```

## Usage examples

```ruby
# Model
class SearchEngine::Product < SearchEngine::Base
  collection "products"

  attribute :id, :integer
  attribute :name, :string
end

# Basic query
SearchEngine::Product
  .where(name: "milk")
  # Explicit query_by always wins over model/global defaults
  .options(query_by: 'name,brand')
  .select(:id, :name)
  .order(price_cents: :asc)
  .limit(5)
  .to_a

# JOIN + nested selection
SearchEngine::Product
  .joins(:brands)
  .select(:id, :name, brands: %i[id name])
  .where(brands: { name: "Acme" })
  .per(10)
  .to_a

# Faceting + grouping
rel = SearchEngine::Product
        .facet_by(:brand_id, max_values: 5)
        .facet_by(:category)
        .group_by(:brand_id, limit: 3)
params = rel.to_h # compiled Typesense params

# Multi-search
result_set = SearchEngine.multi_search(common: { query_by: SearchEngine.config.default_query_by }) do |m|
  m.add :products, SearchEngine::Product.where("name:~rud").per(10)
  m.add :brands,   SearchEngine::Brand.all.per(5)
end
result_set[:products].found

# DX helpers
rel = SearchEngine::Product.where(category: "snacks").limit(3)
rel.dry_run!       # => { url:, body:, url_opts: }
rel.to_params_json # => pretty JSON with redactions
rel.to_curl        # => single-line curl with redacted API key
```

## Documentation

See the wiki → [Home](https://github.com/lstpsche/search-engine-for-typesense/wiki)

## Example app

See `examples/demo_shop` — demonstrates single/multi search, JOINs, grouping, presets/curation, and DX/observability. Supports offline mode via the stub client (see [Testing](https://github.com/lstpsche/search-engine-for-typesense/wiki/Testing)).

## Contributing

See [Docs style guide](https://github.com/lstpsche/search-engine-for-typesense/wiki/contributing/docs_style). Follow YARDoc for public APIs, add backlinks on docs landing pages, and redact secrets in examples.

<!-- Badge references (placeholders) -->
[ci-badge]: https://img.shields.io/github/actions/workflow/status/lstpsche/search-engine-for-typesense/ci.yml?branch=main
[ci-url]: #
[gem-badge]: https://img.shields.io/gem/v/search-engine-for-typesense.svg?label=gem
[gem-url]: https://rubygems.org/gems/search-engine-for-typesense
[docs-badge]: https://img.shields.io/badge/docs-index-blue
[docs-url]: https://github.com/lstpsche/search-engine-for-typesense/wiki
