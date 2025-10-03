[← Back to Index](./index.md) · [Relation](./relation.md) · [Multi-search](./multi_search.md)

## Presets

Default presets are logical names you can assign per collection to represent a configuration profile (e.g., popular_products). This task introduces a global configuration for presets and a Base-level DSL to declare a per-collection default preset token. Resolution is deterministic and side‑effect‑free.

### Global configuration

`SearchEngine.config.presets` holds:

- **enabled**: Boolean, default `true`. When `false`, namespacing is ignored but declared tokens are still returned.
- **namespace**: String, optional. When present and `enabled`, the effective name is `"#{namespace}_#{name}"`.

Validation rules:

- `enabled` must be a Boolean
- `namespace` must be a non-empty String or `nil` (whitespace-only treated as `nil`)

Example (initializer snippet, verbatim):

```ruby
# config/initializers/search_engine.rb
SearchEngine.configure do |c|
  c.presets = OpenStruct.new(namespace: "prod", enabled: true)
end

class SearchEngine::Product < SearchEngine::Base
  default_preset :popular_products
end
```

### Per‑collection defaults

On a model subclassing `SearchEngine::Base`:

- **DSL**: `default_preset :name` declares the preset token (stored as a Symbol without namespace)
- **Reader**: `self.default_preset_name` returns the effective name (String)

Resolution:

- If presets `enabled` and `namespace` present → `"#{namespace}_#{declared}"`
- If presets `enabled` and no namespace → `"#{declared}"`
- If presets `disabled` → `"#{declared}"` (namespace ignored)

### Namespacing rule

When `namespace` is present and presets are enabled, the effective name is `"#{namespace}_#{name}"`. This prepends the namespace once; the declared token is stored without namespace to avoid double‑namespacing.

### Resolution diagram

```mermaid
flowchart TD
  A[Declared preset token on model] --> B[Global presets config]
  B -->|enabled & namespace present| C[Effective name = namespace + '_' + token]
  B -->|enabled & no namespace| D[Effective name = token]
  B -->|disabled| E[Effective name = token (namespace ignored)]
  C --> F[Reader: default_preset_name]
  D --> F
  E --> F
```

### FAQ & Edge cases

- **No declared preset**: `default_preset_name` returns `nil`.
- **Blank namespace**: treated as `nil`.
- **Disable globally**: set `SearchEngine.config.presets.enabled = false`; `default_preset_name` ignores namespace.

### See also

- [Index](./index.md)
- [Relation](./relation.md)
- [Multi-search](./multi_search.md)
