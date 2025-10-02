# SearchEngine

Mountless Rails::Engine wrapping Typesense with idiomatic Rails integration and AR-like querying.

## Docs
See [docs/index.md](./docs/index.md) for the full documentation set. Direct links: [Relation](./docs/relation.md), [Materializers](./docs/materializers.md).

## Quick Start

1) Add the gem to your host app:

```ruby
gem "search_engine"
```

2) Configure minimal connection settings (initializer):

```ruby
# config/initializers/search_engine.rb
SearchEngine.configure do |c|
  c.api_key  = ENV["TYPESENSE_API_KEY"]
  c.host     = ENV.fetch("TYPESENSE_HOST", "localhost")
  c.port     = ENV.fetch("TYPESENSE_PORT", 8108).to_i
  c.protocol = ENV.fetch("TYPESENSE_PROTOCOL", "http")
end
```

3) Perform your first search:

```ruby
client = SearchEngine::Client.new
client.search(
  collection: "products",
  params: { q: "milk", query_by: SearchEngine.config.default_query_by || "name" },
  url_opts: { use_cache: true }
)
```

Next: tune defaults in [docs/configuration.md](./docs/configuration.md) and see the client API in [docs/client.md](./docs/client.md).

## Purpose
Provide a thin, mountless layer around Typesense for Rails apps. No routes/controllers are included by default.

## License
See [LICENSE](./LICENSE).
