# frozen_string_literal: true

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

    initializer 'search_engine.configuration' do
      cfg = SearchEngine.config
      # Hydrate only blank/unset fields from ENV to avoid clobbering
      # host app overrides. ENV resolution is centralized in Config.
      cfg.hydrate_from_env!(ENV, override_existing: false)
      cfg.warn_if_incomplete!
    end

    # Ignore hyphenated compatibility shim so Zeitwerk doesn't try to constantize it.
    initializer 'search_engine.zeitwerk_ignores', before: :set_autoload_paths do
      # Rails 6.1+ exposes a loader per engine via `loader`. Guard presence for safety.
      loader = respond_to?(:loader) ? self.loader : nil
      shim = root.join('lib', 'typesense-search-engine.rb').to_s
      loader&.ignore(shim)
    end

    initializer 'search_engine.observability' do
      cfg = SearchEngine.config

      # Prefer new structured LoggingSubscriber when configured; otherwise
      # fall back to legacy Notifications::CompactLogger gated by cfg.observability.
      begin
        require 'search_engine/logging_subscriber'
      rescue LoadError
        # no-op; allow running without ActiveSupport
      end

      if defined?(SearchEngine::LoggingSubscriber)
        logging_cfg = cfg.respond_to?(:logging) ? cfg.logging : nil
        # Opt-out when mode is nil or sample is explicitly 0.0
        if logging_cfg.respond_to?(:mode) && !logging_cfg.mode.nil?
          sample = logging_cfg.respond_to?(:sample) ? logging_cfg.sample : nil
          if sample.nil? || sample.to_f > 0.0
            SearchEngine::LoggingSubscriber.install!(logging_cfg)
            next
          end
        end
      end

      next unless cfg.observability&.enabled

      # Defer requiring subscriber to runtime to avoid eager load issues
      begin
        require 'search_engine/notifications/compact_logger'
      rescue LoadError
        # no-op; allow running without ActiveSupport
      end

      if defined?(SearchEngine::Notifications::CompactLogger)
        # Subscribe once per boot; store handle in a class ivar in the subscriber
        SearchEngine::Notifications::CompactLogger.subscribe(
          logger: cfg.logger,
          level: :info,
          include_params: false
        )
      end
    end

    initializer 'search_engine.opentelemetry' do
      SearchEngine.config
      begin
        require 'search_engine/otel'
      rescue LoadError
        # no-op; adapter is fully optional
      end

      if defined?(SearchEngine::OTel)
        # Start adapter only when SDK is present and config enables it
        SearchEngine::OTel.start!
      end
    end

    initializer 'search_engine.console_helpers' do
      if defined?(Rails::Console) || $PROGRAM_NAME&.end_with?('console')
        begin
          require 'search_engine/console_helpers'
          SearchEngine::ConsoleHelpers.install!
        rescue LoadError
          # no-op; helpers are optional
        end
      end
    end
  end
end
