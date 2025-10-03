[← Back to Index](./index.md)

# Typesense Search Engine

Welcome to the SearchEngine documentation.

- [Installation](./installation.md)
- [Configuration](./configuration.md)
- [Client](./client.md)
- [Models](./models.md)
- [Relation](./relation.md)
- [Observability](./observability.md)
- [Materializers](./materializers.md)
- [Query DSL](./query_dsl.md)
- [Compiler](./compiler.md)
- [JOINs](./joins.md)
- [Grouping](./grouping.md)
- [Multi-search](./multi_search.md)
- [Indexer](./indexer.md)

## Overview

SearchEngine is a mountless Rails::Engine wrapping the official Typesense Ruby client. It provides Rails-friendly configuration, a thin client for single and federated multi-search, lightweight observability via ActiveSupport::Notifications, and a minimal model registry with ORM-like macros.

## What's implemented now vs planned

- Implemented: Configuration container, client wrapper (single and multi-search), notifications with compact logger, minimal model registry (`collection`, `attribute`).
- Planned: Document hydration into model instances, AR-like querying ergonomics, richer cache strategies, and collection/index management helpers.

## Component map

```mermaid
flowchart LR
  A[Host App] --> B[SearchEngine::Client]
  B -->|uses| C[Typesense::Client]
  B -->|emits| D[AS::Notifications]
  D --> E[CompactLogger (optional)]
  subgraph Config
    F[SearchEngine.config]
  end
  B -->|reads| F
```
