[← Back to Observability](./observability.md) · [DX helpers](./dx.md) · [Client](./client.md)

## Testing utilities

Test-only helpers to run the search layer fully offline and write ergonomic assertions against unified events and compiled params.

### Quick start

- Enable the stub client in your test setup:

```ruby
# test_helper.rb or spec_helper.rb
require 'search_engine/test'

SearchEngine.configure do |c|
  c.client = SearchEngine::Test::StubClient.new
end
```

- Queue responses and inspect captured calls:

```ruby
stub = SearchEngine.config.client
stub.enqueue_response(:search, { 'hits' => [], 'found' => 0, 'out_of' => 0 })

# your relation execution here ...

calls = stub.search_calls
first = calls.first
first.url        # => compiled search URL
first.redacted?  # => true
first.redacted_body # => redacted subset for safe logs
```

- Programmable responses via blocks or exceptions:

```ruby
stub.enqueue_response(:search, ->(req) { { 'hits' => [], 'found' => 42, 'out_of' => 42 } })
stub.enqueue_response(:multi_search, RuntimeError.new('boom'))
```

### Event assertions

Unified events are emitted via ActiveSupport::Notifications. Capture them for a block and assert.

- RSpec matcher:

```ruby
expect { rel.to_a }.to emit_event("search_engine.search").with(hash_including(collection: "products"))
```

- Minitest helpers:

```ruby
include SearchEngine::Test::MinitestAssertions

assert_emits("search_engine.search", payload: ->(p) { p[:collection] == "products" }) { rel.to_a }

events = capture_events { rel.to_a }
```

- Params helpers in tests:

```ruby
expect(rel.to_params_json).to include("filter_by")
```

See also: `Relation#to_params_json`, `Relation#to_curl`, and `Relation#dry_run!`.

### Safety and redaction

- Captured bodies and event payloads are redacted via the central helper.
- No API keys, raw filter literals, or PII are stored; long strings are truncated.
- A `redacted?` marker is present on captured request entries.

### Parallel test safety

- Internals are protected by a lightweight mutex.
- Use `stub.reset!` between examples if needed.

Backlinks: [Observability](./observability.md), [DX](./dx.md), [Client](./client.md)
