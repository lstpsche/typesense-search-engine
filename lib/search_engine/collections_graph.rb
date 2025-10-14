# frozen_string_literal: true

module SearchEngine
  # Build and render an in-memory graph of Typesense collections and references.
  #
  # Public API:
  # - {.build(client:, style: :unicode, width: nil)} => Hash with nodes/edges and rendered ASCII
  #
  # The renderer produces a Unicode box-drawing diagram by default and falls
  # back to a compact ASCII list when the layout exceeds the available width.
  module CollectionsGraph
    class << self
      # Build a collections graph and produce ASCII renderings.
      #
      # @param client [SearchEngine::Client]
      # @param style [Symbol] :unicode or :ascii
      # @param width [Integer, nil] max diagram width; defaults to detected terminal width or 100
      # @return [Hash] { nodes:, edges:, cycles:, isolated:, ascii:, ascii_compact:, stats: { ... } }
      def build(client:, style: :unicode, width: nil)
        safe_style = style.to_s == 'ascii' ? :ascii : :unicode
        max_width = detect_width(width)

        # Build reverse graph from Typesense (with registry fallback)
        reverse_graph = SearchEngine::Cascade.build_reverse_graph(client: client)
        edges = forward_edges_from_reverse(reverse_graph)

        nodes, source = fetch_nodes(client, edges)
        isolated = compute_isolated(nodes, edges)
        cycles = detect_immediate_cycles(edges)

        ascii, layout_mode = render_ascii(nodes, edges, width: max_width, style: safe_style)
        ascii_compact = render_ascii_compact(nodes, edges, style: safe_style)
        mermaid = render_mermaid(nodes, edges)

        stats = {
          nodes: nodes.size,
          edges: edges.size,
          cycles: cycles.size,
          isolated: isolated.size,
          layout: layout_mode,
          source: source
        }

        if defined?(SearchEngine::Instrumentation)
          SearchEngine::Instrumentation.instrument('search_engine.collections.graph', stats) {}
        end

        {
          nodes: nodes,
          edges: edges,
          cycles: cycles,
          isolated: isolated,
          ascii: ascii,
          ascii_compact: ascii_compact,
          mermaid: mermaid,
          stats: stats
        }
      end

      private

      # Prefer IO.console, then ENV, then stty; default to 100 when unknown.
      def detect_width(explicit)
        return Integer(explicit) if explicit&.to_i&.positive?

        begin
          require 'io/console'
          w = IO.console&.winsize&.[](1)
          return Integer(w) if w&.to_i&.positive?
        rescue StandardError
          # ignore; fallback paths below
        end

        env_w = ENV['COLUMNS']
        return Integer(env_w) if env_w&.to_i&.positive?

        begin
          out = `stty size 2>/dev/null`.to_s
          parts = out.split
          return Integer(parts.last) if parts.size >= 2 && parts.last.to_i.positive?
        rescue StandardError
          # ignore
        end

        100
      end

      # Transform reverse graph (target => [{referrer, local_key, foreign_key}, ...])
      # into a flat forward edge list.
      def forward_edges_from_reverse(reverse_graph)
        edges = []
        reverse_graph.each do |target, arr|
          Array(arr).each do |e|
            from = (e[:referrer] || e['referrer']).to_s
            local_key = (e[:local_key] || e['local_key']).to_s
            foreign_key = (e[:foreign_key] || e['foreign_key']).to_s
            to = target.to_s
            next if from.empty? || to.empty?

            edges << { from: from, to: to, local_key: local_key, foreign_key: foreign_key }
          end
        end
        # Deduplicate identical edges deterministically
        edges.uniq.sort_by { |e| [e[:from], e[:to], e[:local_key], e[:foreign_key]] }
      end

      # Determine node set from Typesense (preferred) or fallback sources.
      def fetch_nodes(client, edges)
        begin
          list = Array(client.list_collections)
          return [list.map { |c| (c[:name] || c['name']).to_s }.reject(&:empty?).uniq.sort, :typesense]
        rescue StandardError
          # ignore; fallback to registry/edges
        end

        if defined?(SearchEngine::Registry)
          begin
            reg = SearchEngine::Registry.mapping || {}
            keys = reg.keys.map(&:to_s)
            return [keys.uniq.sort, :registry] unless keys.empty?
          rescue StandardError
            # ignore
          end
        end

        froms = edges.map { |e| e[:from] }
        tos = edges.map { |e| e[:to] }
        fallback = (froms + tos).uniq.sort
        [fallback, :inferred]
      end

      def compute_isolated(nodes, edges)
        touched = edges.flat_map { |e| [e[:from], e[:to]] }.uniq
        (nodes - touched).sort
      end

      # Immediate cycles only: A→B and B→A pairs.
      def detect_immediate_cycles(edges)
        set = edges.each_with_object({}) do |e, h|
          (h[e[:from]] ||= []) << e[:to]
        end
        pairs = []
        set.each do |a, outs|
          outs.each do |b|
            next unless set[b]&.include?(a)

            pairs << [a, b].sort
          end
        end
        pairs.uniq.sort
      end

      # Render boxes-per-edge when it fits; otherwise return compact list.
      # Returns [string, layout_mode]
      def render_ascii(nodes, edges, width:, style: :unicode)
        charset = charset_for(style)

        header = "Collections Graph (nodes: #{nodes.size}, edges: #{edges.size})"

        lines = [header, '']

        # Try to render each edge as a 3-line pair of boxes with a labeled connector.
        edges.each do |e|
          block = build_edge_block(e, charset, width)
          return [render_ascii_compact(nodes, edges, style: style, header: header), :compact] if block.nil?

          lines.concat(block)
        end

        # Add isolated and cycles summary
        iso = compute_isolated(nodes, edges)
        unless iso.empty?
          lines << ''
          lines << "Isolated: #{iso.join(', ')}"
        end

        cycles = detect_immediate_cycles(edges)
        lines << (cycles.empty? ? 'Cycles: none' : "Cycles: #{cycles.map { |a, b| "#{a}↔#{b}" }.join(', ')}")

        [lines.join("\n"), :layered]
      end

      # Compact grouped list renderer suitable for narrow terminals.
      def render_ascii_compact(nodes, edges, style: :unicode, header: nil)
        charset = charset_for(style)
        header ||= "Collections Graph (nodes: #{nodes.size}, edges: #{edges.size})"
        lines = [header]

        by_from = {}
        edges.each do |e|
          (by_from[e[:from]] ||= []) << e
        end

        by_from.keys.sort.each do |from|
          lines << "- #{from}"
          by_from[from].sort_by { |ee| [ee[:to], ee[:local_key], ee[:foreign_key]] }.each do |ee|
            via = label_for(ee, charset, ascii_arrow: true)
            line = if via.empty?
                     "  #{charset[:branch]} #{charset[:arrow]} #{ee[:to]}"
                   else
                     "  #{charset[:branch]} #{charset[:arrow]} #{ee[:to]} [via #{via}]"
                   end
            lines << line
          end
        end

        iso = compute_isolated(nodes, edges)
        lines << "Isolated: #{iso.join(', ')}" unless iso.empty?

        cycles = detect_immediate_cycles(edges)
        lines << (cycles.empty? ? 'Cycles: none' : "Cycles: #{cycles.map { |a, b| "#{a}↔#{b}" }.join(', ')}")

        lines.join("\n")
      end

      def label_for(edge, charset, ascii_arrow: false)
        lk = edge[:local_key].to_s
        fk = edge[:foreign_key].to_s
        mid = ascii_arrow ? '->' : charset[:thin_arrow]
        return '' if lk.empty? && fk.empty?

        return lk if fk.empty?

        return fk if lk.empty?

        "#{lk} #{mid} #{fk}"
      end

      def charset_for(style)
        if style == :ascii
          { tl: '+', tr: '+', bl: '+', br: '+', v: '|', h: '-', arrow: '>', thin_arrow: '->', branch: '+-' }
        else
          { tl: '┌', tr: '┐', bl: '└', br: '┘', v: '│', h: '─', arrow: '▶', thin_arrow: '→', branch: '└─' }
        end
      end

      # Build a single-line "boxed" label: ┌ name ┐ with balanced padding.
      def build_single_line_box(name, charset)
        s = name.to_s
        inner = " #{s} "
        charset[:tl] + inner.tr("\n", ' ') + charset[:tr]
      end

      # Build 3-line box (top, middle, bottom) for a name.
      def build_box_lines(name, charset)
        s = name.to_s
        content = " #{s} "
        top = charset[:tl] + (charset[:h] * content.length) + charset[:tr]
        mid = charset[:v] + content + charset[:v]
        bot = charset[:bl] + (charset[:h] * content.length) + charset[:br]
        [top, mid, bot]
      end

      # Build the 3-line block for an edge, or nil when it does not fit width.
      def build_edge_block(edge, charset, width)
        lt, lm, lb = build_box_lines(edge[:from], charset)
        rt, rm, rb = build_box_lines(edge[:to], charset)
        label = label_for(edge, charset)
        connector_mid = if label.empty?
                          " #{charset[:h] * 3}#{charset[:arrow]}  "
                        else
                          " #{charset[:h] * 2} via #{label} #{charset[:h]}#{charset[:arrow]}  "
                        end

        total_mid = lm.length + connector_mid.length + rm.length
        return nil if total_mid > width

        gap = ' ' * connector_mid.length
        [(lt + gap + rt), (lm + connector_mid + rm), (lb + gap + rb), '']
      end

      # Mermaid flowchart (LR) generator with labeled edges and node declarations.
      # @return [String]
      def render_mermaid(nodes, edges)
        # Prefer logical names from edges to avoid physical (timestamped) names.
        edge_names = edges.flat_map { |e| [e[:from].to_s, e[:to].to_s] }.reject(&:empty?).uniq
        names = edge_names.empty? ? Array(nodes).map(&:to_s) : edge_names

        # Stable ids for all names we intend to render.
        ids = {}
        names.each_with_index { |name, idx| ids[name] = sanitize_mermaid_id("C_#{idx}_#{name}") }

        lines = ['flowchart LR']

        # Declare nodes to ensure isolated logical nodes render as well.
        names.each do |name|
          id = ids[name]
          label = name.to_s.gsub('"', '\\"')
          lines << "  #{id}[\"#{label}\"]"
        end

        # Edges with labels (via ...), using logical names.
        edges.each do |e|
          from = ids[e[:from].to_s]
          to = ids[e[:to].to_s]
          next if from.nil? || to.nil?

          via = mermaid_edge_label(e)
          if via.empty?
            lines << "  #{from} --> #{to}"
          else
            esc = via.gsub('"', '\\"')
            lines << "  #{from} -- \"#{esc}\" --> #{to}"
          end
        end

        lines.join("\n")
      end

      def sanitize_mermaid_id(name)
        s = name.to_s
        s = s.gsub(/[^a-zA-Z0-9_]/, '_')
        s = "C_#{s}" if s.empty? || s[0] =~ /[^a-zA-Z_]/
        s
      end

      def mermaid_edge_label(edge)
        lk = edge[:local_key].to_s
        fk = edge[:foreign_key].to_s
        return '' if lk.empty? && fk.empty?

        return lk if fk.empty?

        return fk if lk.empty?

        "#{lk} -> #{fk}"
      end
    end
  end
end
