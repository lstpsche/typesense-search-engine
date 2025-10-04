[← Back to Index](./index.md)

# Quickstart

Minimal setup to run your first search.

Related: [Installation](./installation.md), [Configuration](./configuration.md), [Client](./client.md), [DX](./dx.md)

## 1) Install

```bash
gem "typesense-search-engine"
```

## 2) Configure

```ruby
# config/initializers/search_engine.rb
SearchEngine.configure do |c|
  c.host = ENV.fetch("TYPESENSE_HOST", "localhost")
  c.port = Integer(ENV.fetch("TYPESENSE_PORT", 8108))
  c.protocol = ENV.fetch("TYPESENSE_PROTOCOL", "http")
  c.api_key = ENV["TYPESENSE_API_KEY"]
  c.default_query_by = "name,description"
end
```

## 3) Define a collection model

```ruby
class SearchEngine::Product < SearchEngine::Base
  collection "products"
  attribute :id, :integer
  attribute :name, :string
end
```

## 4) Run a search

```ruby
rel = SearchEngine::Product.where(name: /milk/)
result = rel.search

puts result.found
```

- Inspect with `rel.to_params_json` or `rel.to_curl`
- Preview behavior safely with `rel.dry_run!`
