# frozen_string_literal: true

module SearchEngine
  module Sources
    # SQL-backed source adapter that streams rows using server-side cursors (PG)
    # or streaming result modes where available.
    #
    # Yields arrays of rows in the chosen shape (:hash by default when low-overhead
    # is available). Always closes cursors/statements and releases connections.
    class SQLSource
      include Base

      # @param sql [String] SQL statement with optional bind placeholders
      # @param binds [Array, Hash, nil] bind values for placeholders (adapter-specific)
      # @param fetch_size [Integer, nil] override chunk size (defaults from config)
      # @param row_shape [Symbol, nil] :hash or :auto
      # @param statement_timeout_ms [Integer, nil] per-statement timeout override
      def initialize(sql:, binds: nil, fetch_size: nil, row_shape: nil, statement_timeout_ms: nil)
        @sql = sql.to_s
        @binds = binds
        cfg = SearchEngine.config.sources.sql
        @fetch_size = (fetch_size || cfg.fetch_size).to_i
        @row_shape = (row_shape || cfg.row_shape).to_sym
        @statement_timeout_ms = statement_timeout_ms || cfg.statement_timeout_ms
      end

      # Iterate over batches of rows.
      #
      # @param partition [Object, nil]
      # @param cursor [Object, nil]
      # @yieldparam rows [Array<Hash, Object>] array of rows
      # @return [Enumerator] when no block is given
      def each_batch(partition: nil, cursor: nil, &block)
        return enum_for(:each_batch, partition: partition, cursor: cursor) unless block_given?

        run_with_connection do |conn|
          if postgres_connection?(conn)
            stream_postgres(conn, partition: partition, cursor: cursor, &block)
          else
            stream_generic(conn, partition: partition, cursor: cursor, &block)
          end
        end
      rescue StandardError => error
        instrument_error(source: 'sql', error: error, partition: partition, cursor: cursor,
                         adapter_options: { fetch_size: @fetch_size, row_shape: @row_shape }
        )
        raise
      end

      private

      def run_with_connection
        unless defined?(ActiveRecord::Base)
          raise SearchEngine::Errors::InvalidParams, 'SQLSource requires ActiveRecord connection'
        end

        ActiveRecord::Base.connection_pool.with_connection do |ar_conn|
          raw = raw_connection(ar_conn)
          yield raw
        end
      end

      def raw_connection(ar_conn)
        if ar_conn.respond_to?(:raw_connection)
          ar_conn.raw_connection
        else
          ar_conn
        end
      end

      def postgres_connection?(conn)
        (defined?(PG) && conn.is_a?(PG::Connection)) || conn.class.name.include?('PG')
      end

      def stream_postgres(conn, partition:, cursor:)
        cursor_name = "se_cursor_#{object_id}"
        sql, params = build_sql_and_params(partition: partition, cursor: cursor)
        started = monotonic_ms
        begin
          set_statement_timeout(conn, @statement_timeout_ms) if @statement_timeout_ms
          # Use unnamed prepared statement + DECLARE CURSOR for streaming
          conn.exec('BEGIN READ ONLY')
          conn.exec_params("DECLARE #{cursor_name} NO SCROLL CURSOR FOR #{sql}", params)
          idx = 0
          loop do
            res = conn.exec("FETCH FORWARD #{@fetch_size} FROM #{cursor_name}")
            break if res.ntuples.zero?

            rows = rows_from_pg_result(res)
            duration = monotonic_ms - started
            instrument_batch_fetched(source: 'sql', batch_index: idx, rows_count: rows.size, duration_ms: duration,
                                     partition: partition, cursor: cursor,
                                     adapter_options: { fetch_size: @fetch_size, row_shape: @row_shape }
            )
            yield rows
            idx += 1
            started = monotonic_ms
          end
        ensure
          begin
            conn.exec("CLOSE #{cursor_name}")
          rescue StandardError
            # ignore
          end
          begin
            conn.exec('COMMIT')
          rescue StandardError
            # ignore
          end
          reset_statement_timeout(conn) if @statement_timeout_ms
        end
      end

      def rows_from_pg_result(res)
        if @row_shape == :hash || @row_shape == :auto
          res.to_a
        else
          res.values
        end
      end

      def stream_generic(_conn, partition:, cursor:)
        # Fallback: try ActiveRecord select_all with pagination via placeholders
        ar_conn = ActiveRecord::Base.connection
        sql, params = build_sql_and_params(partition: partition, cursor: cursor)
        idx = 0
        started = monotonic_ms
        loop do
          chunked_sql = sql_with_limit(sql, @fetch_size, idx)
          rows = ar_conn.exec_query(chunked_sql, 'SQLSource', params_for_ar(params)).to_a
          break if rows.empty?

          duration = monotonic_ms - started
          instrument_batch_fetched(source: 'sql', batch_index: idx, rows_count: rows.size, duration_ms: duration,
                                   partition: partition, cursor: cursor,
                                   adapter_options: { fetch_size: @fetch_size, row_shape: :hash }
          )
          yield rows
          idx += 1
          started = monotonic_ms
        end
      end

      def sql_with_limit(base_sql, fetch_size, page_idx)
        offset = page_idx * fetch_size
        "SELECT * FROM (#{base_sql}) se_sub LIMIT #{Integer(fetch_size)} OFFSET #{Integer(offset)}"
      end

      def params_for_ar(params)
        return [] if params.nil?

        return params if params.is_a?(Array)

        []
      end

      def build_sql_and_params(**)
        # For safety, do not mutate the original SQL. Bind support is adapter-specific.
        # We support a simple Hash expansion for named placeholders in PG `exec_params` style: $1, $2 ...
        sql = @sql.dup
        binds = []
        case @binds
        when Array
          binds = @binds.dup
        when Hash
          raise SearchEngine::Errors::InvalidParams,
                'SQLSource with Hash binds is not supported; use positional binds (Array)'
        when nil
          # noop
        else
          raise SearchEngine::Errors::InvalidParams, 'SQLSource binds must be an Array or nil'
        end

        # Partition/cursor semantics are adapter/domain-specific; callers should incorporate placeholders.
        [sql, binds]
      end

      def set_statement_timeout(conn, ms)
        conn.exec_params('SET LOCAL statement_timeout = $1', [Integer(ms)])
      rescue StandardError
        # ignore
      end

      def reset_statement_timeout(conn)
        conn.exec('RESET statement_timeout')
      rescue StandardError
        # ignore
      end
    end
  end
end
