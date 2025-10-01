module SearchEngine
  # Rails engine for the SearchEngine gem.
  # Configures autoloading and eager-loading paths.
  class Engine < ::Rails::Engine
    engine_name 'search_engine'
    # isolate_namespace SearchEngine # enable later if controllers/routes appear

    # Ensure Zeitwerk loads from lib/
    config.autoload_paths << root.join('lib').to_s

    # Ensure app/search_engine is eager-loadable in production
    config.paths.add 'app/search_engine', eager_load: true
  end
end
