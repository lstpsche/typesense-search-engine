#!/usr/bin/env ruby
# frozen_string_literal: true

# Common helpers for docs audit scripts (stdlib-only)
# Provides deterministic utilities for scanning, parsing, and writing outputs
# under tmp/docs_audit and tmp/refactor without mutating docs/* files.

require 'json'
require 'ripper'
require 'find'
require 'set'
require 'fileutils'
require 'time'

module DocsAudit
  ROOT = File.expand_path('../..', __dir__)
  DOCS_DIR = File.join(ROOT, 'docs')
  TMP_AUDIT_DIR = File.join(ROOT, 'tmp', 'docs_audit')
  TMP_REFACTOR_DIR = File.join(ROOT, 'tmp', 'refactor')
  EXTLINK_RE = %r{\A(?:https?:)?//}i

  ALLOWED_LANGS = Set.new(
    %w[
      ruby rb bash sh zsh shell console irb
      json yaml yml sql xml html erb haml slim
      plaintext text markdown md javascript js typescript ts coffescript coffee
      css scss less diff graphql http ini toml dotenv
      mermaid
    ]
  )

  # Stable key order when writing JSON objects
  def self.build_object(keys_in_order, data_hash)
    obj = {}
    keys_in_order.each { |k| obj[k] = data_hash[k] }
    obj
  end

  def self.repo_relative(path)
    path.start_with?(ROOT) ? path.sub("#{ROOT}/", '') : path
  end

  def self.atomic_write(path, content)
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir)
    tmp = "#{path}.tmp"
    File.open(tmp, 'wb') { |f| f.write(content) }
    File.rename(tmp, path)
  end

  def self.ensure_dirs!
    FileUtils.mkdir_p(TMP_AUDIT_DIR)
    FileUtils.mkdir_p(TMP_REFACTOR_DIR)
  end

  # Return array of absolute markdown file paths
  def self.markdown_files
    return [] unless Dir.exist?(DOCS_DIR)

    files = []
    Find.find(DOCS_DIR) do |path|
      next if File.directory?(path)
      next unless path.end_with?('.md')

      files << path
    end
    files.sort
  end

  # Read file into lines array
  def self.read_lines(path)
    File.read(path).lines
  rescue StandardError
    []
  end

  # Extract markdown links and images: returns array of hashes {text, target, line}
  # Matches [text](target) and ![alt](target). Keeps raw target.
  def self.extract_markdown_links(lines)
    out = []
    re_with_text = /!?\[(?<text>[^\]]*)\]\((?<target>[^)\s]+)(?:\s+"[^"]*")?\)/
    lines.each_with_index do |line, idx|
      line.scan(re_with_text) do |text, target|
        out << { text: "[#{text}]", target: target, line: idx + 1 }
      end
    end
    out
  end

  # Extract headings with level and text
  # Returns [{ level:, text:, line: }]
  def self.extract_headings(lines)
    heads = []
    lines.each_with_index do |line, idx|
      next unless line.start_with?('#') && line =~ /\A(#+)\s+(.*)\s*\z/

      level = Regexp.last_match(1).length
      text = Regexp.last_match(2).strip
      heads << { level: level, text: text, line: idx + 1 }
    end
    heads
  end

  # GitHub-style slug (simplified, deterministic). Lowercase, remove punctuation except hyphens and spaces,
  # collapse spaces to single hyphens.
  def self.slugify(text)
    text.downcase.gsub(/[^a-z0-9\s-]/, '').strip.gsub(/[\s-]+/, '-')
  end

  # Build set of anchor ids for a file based on headings, accounting for duplicates
  def self.anchors_for(lines)
    counts = Hash.new(0)
    anchors = Set.new
    extract_headings(lines).each do |h|
      slug = slugify(h[:text])
      idx = counts[slug]
      anchors << (idx.zero? ? slug : "#{slug}-#{idx}")
      counts[slug] = idx + 1
    end
    anchors
  end

  # Resolve a relative markdown link target to absolute path and anchor
  # Returns [abs_path_or_nil, anchor_or_nil]
  def self.resolve_target(cur_file, target)
    return [nil, nil] if target.nil? || target.empty?

    # strip angle brackets if present
    t = target.gsub(/[<>]/, '')
    return [nil, nil] if EXTLINK_RE.match?(t) || t.start_with?('mailto:', 'tel:')

    # Split anchor
    path_part, anchor = t.split('#', 2)

    # abs var removed (unused)
    abs = if path_part.nil? || path_part.empty?
            cur_file
          elsif path_part.start_with?('/')
            # Treat as repo-root relative
            File.expand_path(path_part.sub(%r{^/}, ''), ROOT)
          elsif path_part.start_with?('./', '../')
            File.expand_path(path_part, File.dirname(cur_file))
          elsif path_part.start_with?('docs/')
            File.expand_path(path_part, ROOT)
          else
            # treat as same-directory relative
            File.expand_path(path_part, File.dirname(cur_file))
          end

    [abs, anchor]
  end

  def self.sort_findings(findings)
    findings.sort_by { |f| [f[:path], f[:line].to_i, f[:kind].to_s, f[:target].to_s] }
  end

  def self.write_json(path, array)
    json = JSON.pretty_generate(array)
    atomic_write(path, json)
  end

  def self.p_severity(kind)
    case kind
    when 'missing_file', 'missing_anchor', 'unclosed_fence', 'syntax_error', 'missing_const', 'missing_method'
      'p_1'
    when 'unknown_lang', 'missing_lang', 'heading_jump', 'duplicate_slug', 'maybe_redirect', 'yardoc_tag'
      'p_2'
    else
      'P3'
    end
  end

  # Parse Ruby public methods from lib/search_engine/relation.rb similar to scan_calls
  def self.parse_relation_public_methods
    relation_path = File.join(ROOT, 'lib', 'search_engine', 'relation.rb')
    return Set.new unless File.file?(relation_path)

    content = File.read(relation_path)
    sexp = Ripper.sexp(content)
    methods = Set.new

    walker = lambda do |node, stack, vis|
      return vis unless node.is_a?(Array)

      case node[0]
      when :program
        node[1].each { |c| vis = walker.call(c, stack, vis) }
      when :module
        vis = handle_module_node(node, stack, vis, walker)
      when :class
        vis = handle_class_node(node, stack, vis, walker)
      when :bodystmt
        (node[1] || []).each { |c| vis = walker.call(c, stack, vis) }
      when :vcall
        vis = handle_visibility_vcall(node, vis)
      when :command
        vis = handle_visibility_command(node, vis)
      when :def
        record_public_method(node, stack, vis, methods)
      else
        node[1..].each { |c| vis = walker.call(c, stack, vis) if c.is_a?(Array) }
      end
      vis
    end

    walker.call(sexp, [], :public)
    methods
  rescue StandardError
    Set.new
  end

  def self.const_from(sexp)
    return nil unless sexp.is_a?(Array)

    case sexp[0]
    when :const_ref
      tok = sexp[1]
      tok && tok[1]
    when :var_ref
      tok = sexp[1]
      tok && tok[0] == :@const ? tok[1] : nil
    when :const_path_ref
      left = const_from(sexp[1])
      right_tok = sexp[2]
      right = right_tok && right_tok[1]
      [left, right].compact.join('::')
    end
  end

  def self.handle_module_node(node, stack, _vis, walker)
    mod = const_from(node[1])
    stack.push(mod)
    vis = :public
    vis = walker.call(node[2], stack, vis)
    stack.pop
    vis
  end

  def self.handle_class_node(node, stack, _vis, walker)
    cls = const_from(node[1])
    stack.push(cls)
    vis = :public
    vis = walker.call(node[3], stack, vis)
    stack.pop
    vis
  end

  def self.handle_visibility_vcall(node, vis)
    id = node[1]
    return vis unless id && id[0] == :@ident

    case id[1]
    when 'private' then :private
    when 'protected' then :protected
    when 'public' then :public
    else vis
    end
  end

  def self.handle_visibility_command(node, vis)
    id = node[1]
    return vis unless id && id[0] == :@ident

    case id[1]
    when 'private' then :private
    when 'protected' then :protected
    when 'public' then :public
    else vis
    end
  end

  def self.record_public_method(node, stack, vis, methods)
    name_tok = node[1]
    return unless name_tok && name_tok[0] == :@ident

    full = stack.compact.join('::')
    methods << name_tok[1] if full == 'SearchEngine::Relation' && vis == :public
  end

  # Enumerate defined constants (module/class) under lib/ as strings like "SearchEngine::Client"
  def self.defined_constants
    constants = Set.new
    glob = File.join(ROOT, 'lib', '**', '*.rb')
    Dir.glob(glob).each do |path|
      content = File.read(path)
      sexp = Ripper.sexp(content)
      next unless sexp

      walker = lambda do |node, stack|
        return unless node.is_a?(Array)

        case node[0]
        when :program
          node[1].each { |c| walker.call(c, stack) }
        when :module
          mod = const_from(node[1])
          stack.push(mod)
          constants << stack.compact.join('::') if stack.compact.join('::')&.start_with?('SearchEngine')
          walker.call(node[2], stack)
          stack.pop
        when :class
          cls = const_from(node[1])
          stack.push(cls)
          constants << stack.compact.join('::') if stack.compact.join('::')&.start_with?('SearchEngine')
          walker.call(node[3], stack)
          stack.pop
        else
          node[1..].each { |c| walker.call(c, stack) if c.is_a?(Array) }
        end
      end
      walker.call(sexp, [])
    rescue StandardError
      next
    end
    constants
  end

  # Build set of API method names across SearchEngine code (public instance methods)
  def self.defined_api_methods
    methods = Set.new
    # include Relation public methods
    methods.merge(parse_relation_public_methods)
    # materializer & common DSL fallback
    fallback = %w[
      all where order select include_fields exclude joins limit offset page per per_page
      group_by ranking prefix facet_by facet_fields preset pin hide explain
      to_params_json to_curl dry_run! count first last take each to_a pluck size empty? any? none?
    ]
    methods.merge(fallback)
    methods
  end

  # Token-scan a snippet to collect SearchEngine constants and DSL-like method identifiers with line numbers
  # Returns { consts: [{name, line}], methods: [{name, line}] }
  def self.scan_snippet_for_api(snippet)
    tokens = Ripper.lex(snippet)
    consts = []
    methods = []

    i = 0
    while i < tokens.length
      (pos, type, str, _state) = tokens[i]
      if type == :on_const && str == 'SearchEngine'
        j = i + 1
        parts = ['SearchEngine']
        while j + 1 < tokens.length && tokens[j][1] == :on_op && tokens[j][2] == '::' && tokens[j + 1][1] == :on_const
          parts << tokens[j + 1][2]
          j += 2
        end
        consts << { name: parts.join('::'), line: pos[0] }
        i = j
      elsif type == :on_ident
        name = str
        methods << { name: name, line: pos[0] }
      end
      i += 1
    end

    {
      consts: consts,
      methods: methods
    }
  end

  # Enumerate ruby code blocks from a markdown file. Yields hashes { lang, code, start_line }
  def self.each_ruby_fence(lines)
    i = 0
    while i < lines.length
      line = lines[i]
      if line =~ /\A```\s*(\w*)\s*\z/
        lang = Regexp.last_match(1).downcase
        start_line = i + 1
        if %w[ruby rb].include?(lang)
          buf = []
          j = i + 1
          while j < lines.length && lines[j] !~ /\A```\s*\z/ # rubocop:disable Metrics/BlockNesting
            buf << lines[j]
            j += 1
          end
          yield({ lang: lang, code: buf.join, start_line: start_line })
        else
          j = i + 1
          j += 1 while j < lines.length && lines[j] !~ /\A```\s*\z/ # rubocop:disable Metrics/BlockNesting
        end
        i = j
      end
      i += 1
    end
  end

  # Heuristic: skip known illustrative snippets
  def self.pseudocode?(code)
    return true if code.include?('...')
    return true if code.include?('YOUR_')
    return true if code.match?(/#\s*pseudo/i)
    return true if code.include?('<TBD>')

    false
  end
end
