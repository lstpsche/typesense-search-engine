[← Back to Index](./index.md)

# Installation

Related: [Quickstart](./quickstart.md), [Configuration](./configuration.md), [CLI](./cli.md)

Add the gem to your host app:

```ruby
gem "typesense-search-engine"
```

Create an initializer `config/initializers/search_engine.rb`:

```ruby
require "search_engine"
```

On boot, Zeitwerk will load from `lib/` and `app/search_engine/` as configured by the engine.

See [Configuration](./configuration.md) for available knobs and ENV fallbacks.

## Requirements

- Ruby >= 3.1, Rails >= 6.1
- Dependency: `typesense >= 4.1.0` (pulled automatically, but may conflict with base64 gem - requires v0.2.0)
- A running Typesense server reachable at `host:port` over `protocol` with a valid API key

## Environment variables

- `TYPESENSE_HOST` (e.g., `localhost`)
- `TYPESENSE_PORT` (e.g., `8108`)
- `TYPESENSE_PROTOCOL` (`http` or `https`)
- `TYPESENSE_API_KEY` (never commit to source control)

## Post-install checklist

1. Bundle and boot your app.
2. Verify configuration without leaking secrets:
   ```bash
   ruby script/dev/check_config.rb
   ```
3. Run a smoke search against your Typesense server:
   ```bash
   ruby script/dev/smoke_client.rb
   ```

Next: tune defaults in [Configuration](./configuration.md) and explore the [Client](./client.md).
