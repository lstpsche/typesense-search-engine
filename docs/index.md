[← Back to Index](./index.md)

# SearchEngine Docs

SearchEngine is a mountless Rails::Engine that wraps Typesense for Rails apps.

- [Installation](./installation.md)
- [Configuration](./configuration.md)

```mermaid
flowchart LR
  A[Gem: search_engine] --> B[Rails::Engine]
  B --> C[Host app boot]
```
