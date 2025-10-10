# frozen_string_literal: true

require 'active_support/concern'

module SearchEngine
  class Base
    # Index lifecycle helpers: applying schema, indexing, retention cleanup.
    module IndexMaintenance
      extend ActiveSupport::Concern

      class_methods do
        # Run indexing workflow for this collection.
        # @param partition [Object, Array<Object>, nil]
        # @param client [SearchEngine::Client, nil]
        # @return [void]
        def indexate(partition: nil, client: nil)
          client_obj = client || (SearchEngine.config.respond_to?(:client) && SearchEngine.config.client) || SearchEngine::Client.new

          if partition.nil?
            __se_indexate_full(client: client_obj)
          else
            __se_indexate_partial(partition: partition, client: client_obj)
          end
          nil
        end
      end

      class_methods do
        # Rebuild one or many partitions inline using the Indexer.
        # @param partition [Object, Array<Object>, nil]
        # @param into [String, nil]
        # @return [SearchEngine::Indexer::Summary, Array<SearchEngine::Indexer::Summary>]
        def rebuild_partition!(partition:, into: nil)
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

          puts("Drop Collection — processing (logical=#{logical} physical=#{physical})")
          client.delete_collection(physical)
          puts('Drop Collection — done')
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
        def __se_indexate_full(client:)
          logical = respond_to?(:collection) ? collection.to_s : name.to_s

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
              __se_index_partitions!(into: new_physical)
              indexed_inside_apply = true
            end
            applied = true
            puts('Step 2: Create+Apply Schema — done')
          else
            puts('Step 2: Create+Apply Schema — skip (already present)')
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
              __se_index_partitions!(into: new_physical)
              indexed_inside_apply = true
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
          if applied && indexed_inside_apply
            puts('Step 5: Indexation — skip (performed during schema apply)')
          else
            puts('Step 5: Indexation — processing')
            __se_index_partitions!(into: nil)
            puts('Step 5: Indexation — done')
          end
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
        def __se_indexate_partial(partition:, client:)
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

          # Step 3: Partial indexing
          puts('Step 3: Partial Indexation — processing')
          partitions.each do |p|
            summary = SearchEngine::Indexer.rebuild_partition!(self, partition: p, into: nil)
            sample_err = __se_extract_sample_error(summary)
            puts(
              "  partition=#{p.inspect} → status=#{summary.status} docs=#{summary.docs_total} " \
              "failed=#{summary.failed_total} batches=#{summary.batches_total} " \
              "duration_ms=#{summary.duration_ms_total}" \
              "#{sample_err ? " sample_error=#{sample_err.inspect}" : ''}"
            )
          end
          puts('Step 3: Partial Indexation — done')
        end
      end

      class_methods do
        # ----------------------------- Helpers ---------------------------
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
            compiled.partitions.each do |part|
              summary = SearchEngine::Indexer.rebuild_partition!(self, partition: part, into: into)
              sample_err = __se_extract_sample_error(summary)
              puts(
                "  partition=#{part.inspect} → status=#{summary.status} " \
                "docs=#{summary.docs_total} " \
                "failed=#{summary.failed_total} " \
                "batches=#{summary.batches_total} " \
                "duration_ms=#{summary.duration_ms_total}" \
                "#{sample_err ? " sample_error=#{sample_err.inspect}" : ''}"
              )
            end
          else
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
