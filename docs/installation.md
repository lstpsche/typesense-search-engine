[← Back to Index](./index.md)

# Installation

Add the gem to your host app:

```ruby
gem "search_engine", path: "../search_engine" # for local dev
```
or when published:
```ruby
gem "search_engine"
```

Create an initializer `config/initializers/search_engine.rb`:

```ruby
require "search_engine"
```

On boot, Zeitwerk will load from `lib/` and `app/search_engine/` as configured by the engine.

See [Configuration](./configuration.md) for available knobs and ENV fallbacks.
