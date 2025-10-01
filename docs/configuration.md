[← Back to Index](./index.md)

### Configuration

This engine centralizes all knobs under `SearchEngine.config`. These values drive the future client and relation layers and are hydrated from ENV at boot by the engine initializer.

- See also: [Installation](./installation.md)

### Initializer

Place the following in your host app at `config/initializers/search_engine.rb`:

```ruby
# config/initializers/search_engine.rb
SearchEngine.configure do |c|
  c.host             = ENV.fetch("TYPESENSE_HOST", "localhost")
  c.port             = ENV.fetch("TYPESENSE_PORT", 8108).to_i
  c.protocol         = ENV.fetch("TYPESENSE_PROTOCOL", "http")
  c.api_key          = ENV.fetch("TYPESENSE_API_KEY")
  c.timeout_ms       = 5_000
  c.open_timeout_ms  = 1_000
  c.retries          = { attempts: 2, backoff: 0.2 }
  c.default_query_by = "name, description"
  c.default_infix    = "fallback"
  c.use_cache        = true
  c.cache_ttl_s      = 60
  c.logger           = Rails.logger
end
```

> [!NOTE]
> `ENV.fetch("TYPESENSE_API_KEY")` will raise if not set. This is intentional for production/staging. In development you can omit an initializer and rely on defaults/ENV.

### ENV fallbacks

The engine hydrates only blank/unset fields from ENV during boot; explicit initializer assignments take precedence.

- `TYPESENSE_HOST` → `host`
- `TYPESENSE_PORT` → `port`
- `TYPESENSE_PROTOCOL` → `protocol`
- `TYPESENSE_API_KEY` → `api_key`

### Caching knobs

- `use_cache` and `cache_ttl_s` are URL-level options consumed by the client. They should not be included in request bodies.

### Timeouts & retries

- `timeout_ms`: total request timeout (ms)
- `open_timeout_ms`: connect/open timeout (ms)
- `retries`: `{ attempts: Integer, backoff: Float }` with non-negative values

### Logger

Defaults to `Rails.logger` when available; otherwise a `$stdout` logger at INFO level. You may supply any object responding to `#info`, `#warn`, and `#error`.

### Validation & warnings

Calling `SearchEngine.configure { ... }` validates obvious misconfigurations (bad protocol, negative timeouts, etc.). At boot, the engine logs a one-time warning if `api_key` or `default_query_by` are missing; secrets are not printed.

```mermaid
flowchart LR
  A[ENV] -->|hydrate if nil| B[Engine initializer]
  B --> C[SearchEngine.config]
  C --> D[Client & Relations]
```

### Self-check

You can verify configuration without a host app by running the included script from the gem root:

```bash
ruby script/dev/check_config.rb
```

It prints the compiled configuration with secrets redacted and exits non-zero if invalid.

Common pitfalls:
- Run it from the repository root so the script can load `lib/` automatically.
- Ensure `lib/search_engine.rb` is loadable; the script prepends `lib/` to the `$LOAD_PATH` for convenience.
