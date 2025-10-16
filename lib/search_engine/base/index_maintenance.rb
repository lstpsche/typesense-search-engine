# frozen_string_literal: true

require 'active_support/concern'
require 'set'

module SearchEngine
  class Base
    # Index lifecycle helpers: applying schema, indexing, retention cleanup.
    module IndexMaintenance
      extend ActiveSupport::Concern

      # rubocop:disable Metrics/BlockLength
      class_methods do
        # Run indexing workflow for this collection.
        # @param partition [Object, Array<Object>, nil]
        # @param client [SearchEngine::Client, nil]
        # @param pre [Symbol, nil] :ensure (ensure presence) or :index (ensure + fix drift)
        # @return [void]
        def indexate(partition: nil, client: nil, pre: nil)
          logical = respond_to?(:collection) ? collection.to_s : name.to_s
          puts
          puts(%(>>>>>> Indexating Collection "#{logical}"))
          client_obj = client || (SearchEngine.config.respond_to?(:client) && SearchEngine.config.client) || SearchEngine::Client.new

          if partition.nil?
            __se_indexate_full(client: client_obj, pre: pre)
          else
            __se_indexate_partial(partition: partition, client: client_obj, pre: pre)
          end
          nil
        end
      end

      class_methods do
        # Drop the collection and then run full indexation.
        # @param pre [Symbol, nil] :ensure or :index
        # @return [void]
        def reindexate!(pre: nil)
          drop_collection!
          indexate(pre: pre)
        end
      end

      class_methods do
        # Rebuild one or many partitions inline using the Indexer.
        # @param partition [Object, Array<Object>, nil]
        # @param into [String, nil]
        # @param pre [Symbol, nil] optional dependency preflight (:ensure or :index)
        # @return [SearchEngine::Indexer::Summary, Array<SearchEngine::Indexer::Summary>]
        def rebuild_partition!(partition:, into: nil, pre: nil)
          if pre
            client_obj = (SearchEngine.config.respond_to?(:client) && SearchEngine.config.client) || SearchEngine::Client.new
            __se_preflight_dependencies!(mode: pre, client: client_obj)
          end
          parts = if partition.nil? || (partition.respond_to?(:empty?) && partition.empty?)
                    [nil]
                  else
                    Array(partition)
                  end

          return SearchEngine::Indexer.rebuild_partition!(self, partition: parts.first, into: into) if parts.size == 1

          parts.map { |p| SearchEngine::Indexer.rebuild_partition!(self, partition: p, into: into) }
        end
      end

      class_methods do
        # Return the compiled Typesense schema for this collection model.
        # @return [Hash]
        def schema
          SearchEngine::Schema.compile(self)
        end
      end

      class_methods do
        # Retrieve the current live schema of the Typesense collection.
        # @return [Hash, nil]
        def current_schema
          client = (SearchEngine.config.respond_to?(:client) && SearchEngine.config.client) || SearchEngine::Client.new
          logical = respond_to?(:collection) ? collection.to_s : name.to_s
          physical = client.resolve_alias(logical) || logical
          client.retrieve_collection_schema(physical)
        end
      end

      class_methods do
        # Compute the diff between the model's compiled schema and the live schema.
        # @return [Hash]
        def schema_diff
          client = (SearchEngine.config.respond_to?(:client) && SearchEngine.config.client) || SearchEngine::Client.new
          res = SearchEngine::Schema.diff(self, client: client)
          res[:diff]
        end
      end

      class_methods do
        # Drop this model's Typesense collection.
        # @return [void]
        def drop_collection!
          client = (SearchEngine.config.respond_to?(:client) && SearchEngine.config.client) || SearchEngine::Client.new
          logical = respond_to?(:collection) ? collection.to_s : name.to_s

          alias_target = client.resolve_alias(logical)
          physical = if alias_target && !alias_target.to_s.strip.empty?
                       alias_target.to_s
                     else
                       live = client.retrieve_collection_schema(logical)
                       live ? logical : nil
                     end

          if physical.nil?
            puts('Drop Collection — skip (not present)')
            return
          end

          # New required lifecycle log wrappers
          puts
          puts(%(>>>>>> Dropping Collection "#{logical}"))
          puts("Drop Collection — processing (logical=#{logical} physical=#{physical})")
          client.delete_collection(physical)
          puts('Drop Collection — done')
          puts(%(>>>>>> Dropped Collection "#{logical}"))
          nil
        end
      end

      class_methods do
        # Recreate this model's Typesense collection (drop if present, then create).
        # @return [void]
        def recreate_collection!
          client = (SearchEngine.config.respond_to?(:client) && SearchEngine.config.client) || SearchEngine::Client.new
          logical = respond_to?(:collection) ? collection.to_s : name.to_s

          alias_target = client.resolve_alias(logical)
          physical = if alias_target && !alias_target.to_s.strip.empty?
                       alias_target.to_s
                     else
                       live = client.retrieve_collection_schema(logical)
                       live ? logical : nil
                     end

          if physical
            puts("Recreate Collection — dropping existing (logical=#{logical} physical=#{physical})")
            client.delete_collection(physical)
          else
            puts('Recreate Collection — no existing collection (skip drop)')
          end

          schema = SearchEngine::Schema.compile(self)
          puts("Recreate Collection — creating collection with schema (logical=#{logical})")
          client.create_collection(schema)
          puts('Recreate Collection — done')
          nil
        end
      end

      class_methods do
        # --------------------------- Full flow ---------------------------
        def __se_indexate_full(client:, pre: nil)
          logical = respond_to?(:collection) ? collection.to_s : name.to_s
          # Optional: preflight dependency indexation for belongs_to chains
          __se_preflight_dependencies!(mode: pre, client: client) if pre

          # Step 1: Presence
          diff = SearchEngine::Schema.diff(self, client: client)[:diff] || {}
          missing = __se_schema_missing?(diff)
          puts("Step 1: Presence — processing → #{missing ? 'missing' : 'present'}")

          applied, indexed_inside_apply = __se_full_apply_if_missing(client, missing)
          drift = __se_full_check_drift(diff, missing)
          applied, indexed_inside_apply = __se_full_apply_if_drift(client, drift, applied, indexed_inside_apply)
          __se_full_indexation(applied, indexed_inside_apply)
          __se_full_retention(applied, logical, client)
        end
      end

      class_methods do
        # Step 2: Create + apply schema if missing
        def __se_full_apply_if_missing(client, missing)
          applied = false
          indexed_inside_apply = false
          if missing
            puts('Step 2: Create+Apply Schema — processing')
            SearchEngine::Schema.apply!(self, client: client) do |new_physical|
              indexed_inside_apply = __se_index_partitions!(into: new_physical)
            end
            applied = true
            puts('Step 2: Create+Apply Schema — done')
          else
            puts('Step 2: Create+Apply Schema — skip (collection present)')
          end
          [applied, indexed_inside_apply]
        end
      end

      class_methods do
        # Step 3: Check schema status (only when present initially)
        def __se_full_check_drift(diff, missing)
          unless missing
            puts('Step 3: Check Schema Status — processing')
            drift = __se_schema_drift?(diff)
            puts("Step 3: Check Schema Status — #{drift ? 'drift' : 'in_sync'}")
            return drift
          end
          puts('Step 3: Check Schema Status — skip (just created)')
          false
        end
      end

      class_methods do
        # Step 4: Apply new schema when drift detected
        def __se_full_apply_if_drift(client, drift, applied, indexed_inside_apply)
          if drift
            puts('Step 4: Apply New Schema — processing')
            SearchEngine::Schema.apply!(self, client: client) do |new_physical|
              indexed_inside_apply = __se_index_partitions!(into: new_physical)
            end
            applied = true
            puts('Step 4: Apply New Schema — done')
          else
            puts('Step 4: Apply New Schema — skip')
          end
          [applied, indexed_inside_apply]
        end
      end

      class_methods do
        # Step 5: Indexation (when nothing was applied)
        def __se_full_indexation(applied, indexed_inside_apply)
          cascade_ok = false
          if applied && indexed_inside_apply
            puts('Step 5: Indexation — skip (performed during schema apply)')
            begin
              cascade_ok = indexed_inside_apply.to_sym == :ok
            rescue StandardError
              cascade_ok = false
            end
          else
            puts('Step 5: Indexation — processing')
            idx_status = __se_index_partitions!(into: nil)
            puts('Step 5: Indexation — done')
            cascade_ok = (idx_status == :ok)
          end
          # Trigger cascade for referencers only when main indexation succeeded
          __se_cascade_after_indexation!(context: :full) if cascade_ok
        end
      end

      class_methods do
        # Step 6: Retention cleanup
        def __se_full_retention(applied, logical, client)
          if applied
            puts('Step 6: Retention Cleanup — skip (handled by schema apply)')
          else
            puts('Step 6: Retention Cleanup — processing')
            dropped = __se_retention_cleanup!(logical: logical, client: client)
            puts("Step 6: Retention Cleanup — dropped=#{dropped.inspect}")
          end
        end
      end

      class_methods do
        # -------------------------- Partial flow -------------------------
        def __se_indexate_partial(partition:, client:, pre: nil)
          partitions = Array(partition)
          diff_res = SearchEngine::Schema.diff(self, client: client)
          diff = diff_res[:diff] || {}

          # Step 1: Presence
          missing = __se_schema_missing?(diff)
          puts("Step 1: Presence — processing → #{missing ? 'missing' : 'present'}")
          if missing
            puts('Partial: collection is not present. Quit early.')
            return
          end

          # Step 2: Schema status
          puts('Step 2: Check Schema Status — processing')
          drift = __se_schema_drift?(diff)
          if drift
            puts('Partial: schema is not up-to-date. Quit early (run full indexation).')
            return
          end
          puts('Step 2: Check Schema Status — in_sync')

          # Optional: preflight dependencies prior to partial indexation
          __se_preflight_dependencies!(mode: pre, client: client) if pre

          # Step 3: Partial indexing
          puts('Step 3: Partial Indexation — processing')
          all_ok = true
          partitions.each do |p|
            summary = SearchEngine::Indexer.rebuild_partition!(self, partition: p, into: nil)
            puts(SearchEngine::Logging::PartitionProgress.line(p, summary))
            begin
              all_ok &&= (summary.status == :ok)
            rescue StandardError
              all_ok &&= false
            end
          end
          puts('Step 3: Partial Indexation — done')
          # After partial indexation, trigger full fallback cascade for referencers only if all partitions succeeded
          __se_cascade_after_indexation!(context: :full) if all_ok
        end
      end

      class_methods do
        # ---------------------- Preflight dependencies ----------------------
        # Recursively ensure/index direct and transitive belongs_to dependencies
        # before indexing the current collection.
        # @param mode [Symbol] :ensure (only missing) or :index (missing + drift)
        # @param client [SearchEngine::Client]
        # @param visited [Set<String>, nil]
        # @return [void]
        def __se_preflight_dependencies!(mode:, client:, visited: nil)
          return unless mode

          visited ||= Set.new
          current = begin
            respond_to?(:collection) ? (collection || '').to_s : name.to_s
          rescue StandardError
            name.to_s
          end
          return if current.to_s.strip.empty?
          return if visited.include?(current)

          visited.add(current)

          configs = begin
            joins_config || {}
          rescue StandardError
            {}
          end
          deps = configs.values.select { |c| (c[:kind] || c['kind']).to_s == 'belongs_to' }
          return if deps.empty?

          puts
          puts(%(>>>>>> Preflight Dependencies (mode: #{mode})))

          deps.each do |cfg|
            dep_coll = (cfg[:collection] || cfg['collection']).to_s
            next if dep_coll.strip.empty?
            next if visited.include?(dep_coll)

            dep_klass = begin
              SearchEngine.collection_for(dep_coll)
            rescue StandardError
              nil
            end

            if dep_klass.nil?
              puts(%(  "#{dep_coll}" → skipped (unregistered)))
              visited.add(dep_coll)
              next
            end

            # Recurse first to ensure deeper dependencies are handled
            begin
              dep_klass.__se_preflight_dependencies!(mode: mode, client: client, visited: visited)
            rescue StandardError
              # ignore recursion errors to not block main flow
            end

            diff = begin
              SearchEngine::Schema.diff(dep_klass, client: client)[:diff] || {}
            rescue StandardError
              {}
            end
            missing = begin
              dep_klass.__se_schema_missing?(diff)
            rescue StandardError
              false
            end
            drift = begin
              dep_klass.__se_schema_drift?(diff)
            rescue StandardError
              false
            end

            case mode.to_s
            when 'ensure'
              if missing
                puts(%(  "#{dep_coll}" → ensure (missing) → indexate))
                # Avoid nested preflight to prevent redundant recursion cycles
                dep_klass.indexate(client: client)
              else
                puts(%(  "#{dep_coll}" → present (skip)))
              end
            when 'index'
              if missing || drift
                reason = missing ? 'missing' : 'drift'
                puts(%(  "#{dep_coll}" → index (#{reason}) → indexate))
                # Avoid nested preflight to prevent redundant recursion cycles
                dep_klass.indexate(client: client)
              else
                puts(%(  "#{dep_coll}" → in_sync (skip)))
              end
            else
              puts(%(  "#{dep_coll}" → skipped (unknown mode: #{mode})))
            end

            visited.add(dep_coll)
          end

          puts('>>>>>> Preflight Done')
        end
      end

      class_methods do
        # ----------------------------- Helpers ---------------------------
        # rubocop:disable Metrics/PerceivedComplexity
        def __se_cascade_after_indexation!(context: :full)
          puts
          puts(%(>>>>>> Cascade Referencers))
          results = SearchEngine::Cascade.cascade_reindex!(source: self, ids: nil, context: context)
          outcomes = Array(results[:outcomes])
          if outcomes.empty?
            puts('  none')
          else
            outcomes.each do |o|
              coll = o[:collection] || o['collection']
              mode = (o[:mode] || o['mode']).to_s
              case mode
              when 'partial'
                puts(%(  Referencer "#{coll}" → partial reindex))
              when 'full'
                puts(%(  Referencer "#{coll}" → full reindex))
              when 'skipped_unregistered'
                puts(%(  Referencer "#{coll}" → skipped (unregistered)))
              when 'skipped_cycle'
                puts(%(  Referencer "#{coll}" → skipped (cycle)))
              else
                puts(%(  Referencer "#{coll}" → #{mode}))
              end
            end
          end
          puts('>>>>>> Cascade Done')
        rescue StandardError => error
          # Provide more verbose error output for debugging
          base = "Cascade — error=#{error.class}: #{error.message.to_s[0, 200]}"
          if error.respond_to?(:status) || error.respond_to?(:body)
            status = begin
              error.respond_to?(:status) ? error.status : nil
            rescue StandardError
              nil
            end
            body_preview = begin
              b = error.respond_to?(:body) ? error.body : nil
              if b.is_a?(String)
                b[0, 500]
              elsif b.is_a?(Hash)
                b.inspect[0, 500]
              else
                b.to_s[0, 500]
              end
            rescue StandardError
              nil
            end
            warn([base, ("status=#{status}" if status), ("body=#{body_preview}" if body_preview)].compact.join(' '))
          else
            warn(base)
          end
        end
        # rubocop:enable Metrics/PerceivedComplexity

        def __se_schema_missing?(diff)
          opts = diff[:collection_options]
          opts.is_a?(Hash) && opts[:live] == :missing
        end

        def __se_schema_drift?(diff)
          added = Array(diff[:added_fields])
          removed = Array(diff[:removed_fields])
          changed = (diff[:changed_fields] || {}).to_h
          coll_opts = (diff[:collection_options] || {}).to_h
          added.any? || removed.any? || !changed.empty? || !coll_opts.empty?
        end
      end
      # rubocop:enable Metrics/BlockLength

      class_methods do
        def __se_extract_sample_error(summary)
          failed = begin
            summary.respond_to?(:failed_total) ? summary.failed_total.to_i : 0
          rescue StandardError
            0
          end
          return nil if failed <= 0

          batches = begin
            summary.respond_to?(:batches) ? summary.batches : nil
          rescue StandardError
            nil
          end
          return nil unless batches.is_a?(Array)

          batches.each do |b|
            next unless b.is_a?(Hash)

            samples = b[:errors_sample] || b['errors_sample']
            next if samples.nil?

            Array(samples).each do |m|
              s = m.to_s
              return s unless s.strip.empty?
            end
          end
          nil
        end
      end

      class_methods do
        def __se_index_partitions!(into:)
          compiled = SearchEngine::Partitioner.for(self)
          if compiled
            parts = Array(compiled.partitions)
            max_p = compiled.max_parallel.to_i
            return __se_index_partitions_seq!(parts, into) if max_p <= 1 || parts.size <= 1

            __se_index_partitions_parallel!(parts, into, max_p)
          else
            summary = SearchEngine::Indexer.rebuild_partition!(self, partition: nil, into: into)
            sample_err = __se_extract_sample_error(summary)
            puts(
              "  single → status=#{summary.status} docs=#{summary.docs_total} " \
              "failed=#{summary.failed_total} batches=#{summary.batches_total} " \
              "duration_ms=#{summary.duration_ms_total}" \
              "#{sample_err ? " sample_error=#{sample_err.inspect}" : ''}"
            )
            summary.status
          end
        end
      end

      class_methods do
        # Sequential processing of partition list
        def __se_index_partitions_seq!(parts, into)
          agg = :ok
          parts.each do |part|
            summary = SearchEngine::Indexer.rebuild_partition!(self, partition: part, into: into)
            puts(SearchEngine::Logging::PartitionProgress.line(part, summary))
            begin
              st = summary.status
              if st == :failed
                agg = :failed
              elsif st == :partial && agg == :ok
                agg = :partial
              end
            rescue StandardError
              agg = :failed
            end
          end
          agg
        end
      end

      class_methods do
        # Parallel processing via bounded thread pool
        def __se_index_partitions_parallel!(parts, into, max_p)
          require 'concurrent-ruby'
          pool = Concurrent::FixedThreadPool.new(max_p)
          ctx = SearchEngine::Instrumentation.context
          mtx = Mutex.new
          agg = :ok
          begin
            parts.each do |part|
              pool.post do
                SearchEngine::Instrumentation.with_context(ctx) do
                  summary = SearchEngine::Indexer.rebuild_partition!(self, partition: part, into: into)
                  mtx.synchronize do
                    puts(SearchEngine::Logging::PartitionProgress.line(part, summary))
                    begin
                      st = summary.status
                      if st == :failed
                        agg = :failed
                      elsif st == :partial && agg == :ok
                        agg = :partial
                      end
                    rescue StandardError
                      agg = :failed
                    end
                  end
                end
              rescue StandardError => error
                mtx.synchronize do
                  warn("  partition=#{part.inspect} → error=#{error.class}: #{error.message.to_s[0, 200]}")
                  agg = :failed
                end
              end
            end
          ensure
            pool.shutdown
            # Wait up to 1 hour, then force-kill and wait a bit more to ensure cleanup
            pool.wait_for_termination(3600) || pool.kill
            pool.wait_for_termination(60)
          end
          agg
        end
      end

      class_methods do
        # Single non-partitioned pass helper
        def __se_index_single!(into)
          summary = SearchEngine::Indexer.rebuild_partition!(self, partition: nil, into: into)
          sample_err = __se_extract_sample_error(summary)
          puts(
            "  single → status=#{summary.status} docs=#{summary.docs_total} " \
            "failed=#{summary.failed_total} batches=#{summary.batches_total} " \
            "duration_ms=#{summary.duration_ms_total}" \
            "#{sample_err ? " sample_error=#{sample_err.inspect}" : ''}"
          )
        end
      end

      class_methods do
        private

        def __se_retention_cleanup!(logical:, client:)
          keep = begin
            local = respond_to?(:schema_retention) ? (schema_retention || {}) : {}
            lk = local[:keep_last]
            lk.nil? ? SearchEngine.config.schema.retention.keep_last : Integer(lk)
          rescue StandardError
            SearchEngine.config.schema.retention.keep_last
          end
          keep = 0 if keep.nil? || keep.to_i.negative?

          alias_target = client.resolve_alias(logical)
          names = Array(client.list_collections).map { |c| (c[:name] || c['name']).to_s }
          re = /^#{Regexp.escape(logical)}_\d{8}_\d{6}_\d{3}$/
          physicals = names.select { |n| re.match?(n) }

          ordered = physicals.sort_by do |n|
            ts = __se_extract_timestamp(logical, n)
            seq = __se_extract_sequence(n)
            [-ts, -seq]
          end

          candidates = ordered.reject { |n| n == alias_target }
          to_drop = candidates.drop(keep)
          to_drop.each { |n| client.delete_collection(n) }
          to_drop
        end
      end

      class_methods do
        def __se_extract_timestamp(logical, name)
          base = name.to_s.delete_prefix("#{logical}_")
          parts = base.split('_')
          return 0 unless parts.size == 3

          (parts[0] + parts[1]).to_i
        end

        def __se_extract_sequence(name)
          name.to_s.split('_').last.to_i
        end
      end
    end
  end
end
