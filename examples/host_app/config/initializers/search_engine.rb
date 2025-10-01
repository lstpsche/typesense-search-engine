require 'search_engine'

# Touch autoloaded constants to prove paths are wired (no-op if eager-loaded)
SearchEngine::AppInfo.identifier if defined?(SearchEngine::AppInfo)
SearchEngine::TestAutoload::NAME if defined?(SearchEngine::TestAutoload)
