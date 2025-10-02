# frozen_string_literal: true

require 'json'
require 'search_engine'
require 'search_engine/cli'

namespace :search_engine do
  # ------------------------- Schema tasks -------------------------
  namespace :schema do
    desc 'Diff compiled schema vs live collection. Usage: rails search_engine:schema:diff[collection]'
    task :diff, [:collection] => :environment do |_t, args|
      begin
        klass = SearchEngine::CLI.resolve_collection!(args[:collection])
      rescue ArgumentError => error
        warn("Error: #{error.message}")
        print_schema_usage
        Kernel.exit(1)
      end

      payload = {
        task: 'schema:diff',
        collection: (klass.respond_to?(:collection) ? klass.collection : klass.name)
      }
      result = nil
      SearchEngine::CLI.with_task_instrumentation('schema:diff', payload) do
        result = SearchEngine::Schema.diff(klass)
      end

      diff = result[:diff]
      drift = diff[:added_fields].any? ||
              diff[:removed_fields].any? ||
              !diff[:changed_fields].to_h.empty? ||
              !diff[:collection_options].to_h.empty?

      if SearchEngine::CLI.json_output?
        out = { status: (drift ? 'drift' : 'in_sync'), diff: diff }
        puts(JSON.generate(out))
      else
        puts(result[:pretty])
        if SearchEngine::CLI.boolean_env?('VERBOSE')
          puts("\n-- diff (verbose) --\n")
          puts(JSON.pretty_generate(diff))
        end
      end

      Kernel.exit(drift ? 10 : 0)
    rescue StandardError => error
      warn("schema:diff failed: #{error.message}")
      Kernel.exit(1)
    end

    desc 'Apply schema (create + reindex + swap + retention). Usage: rails search_engine:schema:apply[collection]'
    task :apply, [:collection] => :environment do |_t, args|
      begin
        klass = SearchEngine::CLI.resolve_collection!(args[:collection])
      rescue ArgumentError => error
        warn("Error: #{error.message}")
        print_schema_usage
        Kernel.exit(1)
      end

      payload = {
        task: 'schema:apply',
        collection: (klass.respond_to?(:collection) ? klass.collection : klass.name)
      }
      summary = nil
      SearchEngine::CLI.with_task_instrumentation('schema:apply', payload) do
        summary = SearchEngine::Schema.apply!(klass) do |physical|
          # Inline reindex across all partitions into the new physical
          parts = SearchEngine::CLI.partitions_for(klass)
          parts = [nil] if parts.nil? || parts.respond_to?(:empty?) && parts.empty?
          parts.each do |part|
            SearchEngine::Indexer.rebuild_partition!(klass, partition: part, into: physical)
          end
        end
      end

      if SearchEngine::CLI.json_output?
        puts(JSON.generate({ status: 'ok' }.merge(summary)))
      else
        puts("Logical: #{summary[:logical]}")
        puts("New physical: #{summary[:new_physical]}")
        puts("Previous physical: #{summary[:previous_physical] || 'none'}")
        puts("Dropped old physicals: #{Array(summary[:dropped_physicals]).size}")
      end

      Kernel.exit(0)
    rescue ArgumentError => error
      warn("schema:apply failed: #{error.message}")
      Kernel.exit(1)
    rescue StandardError => error
      warn("schema:apply failed: #{error.message}")
      Kernel.exit(1)
    end

    desc 'Rollback schema alias to previous retained physical. Usage: rails search_engine:schema:rollback[collection]'
    task :rollback, [:collection] => :environment do |_t, args|
      begin
        klass = SearchEngine::CLI.resolve_collection!(args[:collection])
      rescue ArgumentError => error
        warn("Error: #{error.message}")
        print_schema_usage
        Kernel.exit(1)
      end

      payload = {
        task: 'schema:rollback',
        collection: (klass.respond_to?(:collection) ? klass.collection : klass.name)
      }
      summary = nil
      begin
        SearchEngine::CLI.with_task_instrumentation('schema:rollback', payload) do
          summary = SearchEngine::Schema.rollback(klass)
        end
      rescue ArgumentError => error
        warn("schema:rollback not possible: #{error.message}")
        Kernel.exit(2)
      end

      if SearchEngine::CLI.json_output?
        puts(JSON.generate({ status: 'ok' }.merge(summary)))
      else
        puts("Logical: #{summary[:logical]}")
        puts("New target: #{summary[:new_target]}")
        puts("Previous target: #{summary[:previous_target] || 'none'}")
      end

      Kernel.exit(0)
    rescue StandardError => error
      warn("schema:rollback failed: #{error.message}")
      Kernel.exit(1)
    end
  end

  # ------------------------- Index tasks -------------------------
  namespace :index do
    desc 'Rebuild entire index (all partitions or single). Usage: rails search_engine:index:rebuild[collection]'
    task :rebuild, [:collection] => :environment do |_t, args|
      begin
        klass = SearchEngine::CLI.resolve_collection!(args[:collection])
      rescue ArgumentError => error
        warn("Error: #{error.message}")
        print_index_usage
        Kernel.exit(1)
      end

      dry_run = SearchEngine::CLI.boolean_env?('DRY_RUN')
      payload = {
        task: 'index:rebuild',
        collection: (klass.respond_to?(:collection) ? klass.collection : klass.name),
        dry_run: dry_run
      }

      if dry_run
        SearchEngine::CLI.with_task_instrumentation('index:rebuild', payload) do
          partitions = Array(SearchEngine::CLI.partitions_for(klass))
          partition = partitions.first
          into = SearchEngine::CLI.resolve_into!(klass, partition: partition, into: nil)
          enum = SearchEngine::CLI.docs_enum_for_first_batch(klass, partition)
          preview = SearchEngine::Indexer.dry_run!(klass, into: into, enum: enum, action: :upsert)
          if SearchEngine::CLI.json_output?
            puts(JSON.generate(preview.merge(partition: partition)))
          else
            puts("Into: #{preview[:collection]} (partition=#{partition.inspect})")
            puts("Action: #{preview[:action]}")
            puts("Docs (first batch): #{preview[:docs_count]}, Bytes est: #{preview[:bytes_estimate]}")
            if SearchEngine::CLI.boolean_env?('VERBOSE') && preview[:sample_line]
              puts("Sample: #{preview[:sample_line]}")
            end
          end
        end
        Kernel.exit(0)
      end

      # Non-dry run
      actions = []
      SearchEngine::CLI.with_task_instrumentation('index:rebuild', payload) do
        compiled = SearchEngine::Partitioner.for(klass)
        if compiled
          mode = SearchEngine::CLI.resolve_dispatch_mode(ENV['DISPATCH'])
          compiled.partitions.each do |part|
            res = SearchEngine::Dispatcher.dispatch!(
              klass,
              partition: part,
              into: nil,
              mode: mode,
              queue: nil,
              metadata: { task: 'index:rebuild' }
            )
            actions << res
          end
        else
          # No partitioning DSL: single inline run
          summary = SearchEngine::Indexer.rebuild_partition!(
            klass,
            partition: nil,
            into: SearchEngine::CLI.resolve_into!(klass, partition: nil, into: nil)
          )
          actions << {
            mode: :inline,
            indexer_summary: {
              status: summary.status,
              docs_total: summary.docs_total,
              batches_total: summary.batches_total,
              duration_ms_total: summary.duration_ms_total
            },
            partition: nil
          }
        end
      end

      if SearchEngine::CLI.json_output?
        puts(JSON.generate({ status: 'ok', actions: actions }))
      elsif actions.empty?
        puts('No actions performed')
      else
        actions.each do |a|
          if a[:mode] == :active_job
            puts("Enqueued partition=#{a[:partition].inspect} to queue=#{a[:queue]} (job_id=#{a[:job_id]})")
          else
            sum = a[:indexer_summary]
            puts(
              "Imported partition=#{a[:partition].inspect} " \
              "status=#{sum[:status]} " \
              "docs=#{sum[:docs_total]} " \
              "batches=#{sum[:batches_total]} " \
              "duration_ms=#{sum[:duration_ms_total]}"
            )
          end
        end
      end

      Kernel.exit(0)
    rescue StandardError => error
      warn("index:rebuild failed: #{error.message}")
      Kernel.exit(1)
    end

    desc 'Rebuild a single partition. Usage: rails search_engine:index:rebuild_partition[collection,partition]'
    task :rebuild_partition, %i[collection partition] => :environment do |_t, args|
      begin
        klass = SearchEngine::CLI.resolve_collection!(args[:collection])
      rescue ArgumentError => error
        warn("Error: #{error.message}")
        print_index_usage
        Kernel.exit(1)
      end
      partition = SearchEngine::CLI.parse_partition(args[:partition])
      payload = {
        task: 'index:rebuild_partition',
        collection: (klass.respond_to?(:collection) ? klass.collection : klass.name),
        partition: partition
      }

      action = nil
      SearchEngine::CLI.with_task_instrumentation('index:rebuild_partition', payload) do
        mode = SearchEngine::CLI.resolve_dispatch_mode(ENV['DISPATCH'])
        if mode == :active_job
          action = SearchEngine::Dispatcher.dispatch!(
            klass,
            partition: partition,
            into: nil,
            mode: :active_job,
            queue: nil,
            metadata: { task: 'index:rebuild_partition' }
          )
        else
          summary = SearchEngine::Indexer.rebuild_partition!(
            klass,
            partition: partition,
            into: SearchEngine::CLI.resolve_into!(klass, partition: partition, into: nil)
          )
          action = {
            mode: :inline,
            indexer_summary: {
              status: summary.status,
              docs_total: summary.docs_total,
              batches_total: summary.batches_total,
              duration_ms_total: summary.duration_ms_total
            }
          }
        end
      end

      if SearchEngine::CLI.json_output?
        puts(JSON.generate({ status: 'ok' }.merge(action)))
      elsif action[:mode] == :active_job
        puts("Enqueued partition=#{partition.inspect} to queue=#{action[:queue]} (job_id=#{action[:job_id]})")
      else
        sum = action[:indexer_summary]
        puts(
          "Imported partition=#{partition.inspect} " \
          "status=#{sum[:status]} " \
          "docs=#{sum[:docs_total]} " \
          "batches=#{sum[:batches_total]} " \
          "duration_ms=#{sum[:duration_ms_total]}"
        )
      end

      Kernel.exit(0)
    rescue StandardError => error
      warn("index:rebuild_partition failed: #{error.message}")
      Kernel.exit(1)
    end

    desc 'Delete stale documents (by filter). Usage: rails search_engine:index:delete_stale[collection,partition]'
    task :delete_stale, %i[collection partition] => :environment do |_t, args|
      begin
        klass = SearchEngine::CLI.resolve_collection!(args[:collection])
      rescue ArgumentError => error
        warn("Error: #{error.message}")
        print_index_usage
        Kernel.exit(1)
      end
      partition = SearchEngine::CLI.parse_partition(args[:partition])
      strict = SearchEngine::CLI.boolean_env?('STRICT')
      dry_run = SearchEngine::CLI.boolean_env?('DRY_RUN')

      payload = {
        task: 'index:delete_stale',
        collection: (klass.respond_to?(:collection) ? klass.collection : klass.name),
        partition: partition,
        dry_run: dry_run,
        strict: strict
      }

      # Pre-check for filter definition
      if SearchEngine::StaleFilter.for(klass).nil?
        msg = 'No stale_filter_by defined for this collection.'
        if strict
          warn("STRICT mode: #{msg}")
          Kernel.exit(3)
        else
          warn("Warning: #{msg} Skipping.")
          Kernel.exit(0)
        end
      end

      summary = nil
      SearchEngine::CLI.with_task_instrumentation('index:delete_stale', payload) do
        summary = SearchEngine::Indexer.delete_stale!(klass, partition: partition, dry_run: dry_run)
      end

      if SearchEngine::CLI.json_output?
        puts(JSON.generate(summary))
      elsif summary[:status] == :ok
        puts(
          "Deleted #{summary[:deleted_count]} docs from #{summary[:into]} " \
          "(partition=#{summary[:partition].inspect}) " \
          "in #{summary[:duration_ms]}ms"
        )
      elsif summary[:status] == :skipped
        puts('Skipped (disabled or empty filter)')
      else
        puts("Failed: #{summary[:error_class]} #{summary[:message_truncated]}")
      end

      Kernel.exit(0)
    rescue StandardError => error
      warn("index:delete_stale failed: #{error.message}")
      Kernel.exit(1)
    end
  end

  # ------------------------- Helpers -------------------------
  def print_schema_usage
    puts <<~USAGE
      Usage:
        rails search_engine:schema:diff[collection]
        rails search_engine:schema:apply[collection]
        rails search_engine:schema:rollback[collection]

      Examples:
        rails search_engine:schema:diff[SearchEngine::Product]
        rails search_engine:schema:apply[products]
        rails search_engine:schema:rollback[products]

      Tips:
        - Quote arguments that contain commas or spaces.
        - Example: rails search_engine:index:rebuild_partition[SearchEngine::Product,42]
    USAGE
  end

  def print_index_usage
    puts <<~USAGE
      Usage:
        rails search_engine:index:rebuild[collection]
        rails search_engine:index:rebuild_partition[collection,partition]
        rails search_engine:index:delete_stale[collection,partition]

      Environment:
        DRY_RUN=1    Preview first batch only (no HTTP); also for delete_stale shows filter and estimation when enabled
        DISPATCH=... Override dispatch mode for rebuild_partition (:inline or :active_job)
        VERBOSE=1    More verbose output
        FORMAT=json  Machine-readable output
        STRICT=1     For delete_stale: treat missing filter as violation (exit 3)

      Examples:
        rails search_engine:index:rebuild[SearchEngine::Product]
        rails search_engine:index:rebuild_partition[products,42]
        rails search_engine:index:delete_stale[SearchEngine::Product,42]

      Tip about commas:
        Use brackets without spaces. Example with class + partition id:
        rails search_engine:index:rebuild_partition[SearchEngine::Product,42]
    USAGE
  end
end
