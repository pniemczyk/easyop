# frozen_string_literal: true

module Easyop
  # Generates Mermaid flowchart definitions from Easyop::Flow classes.
  #
  # Designed for use in rake tasks and tooling. The easyop-ui gem builds on this
  # class for browser-based DAG visualization.
  #
  # Usage (standalone):
  #   require "easyop"
  #   require "easyop/dag_builder"
  #
  #   mermaid_text = Easyop::DagBuilder.new(MyFlow).to_mermaid
  #   html         = Easyop::DagBuilder.to_html(MyFlow)
  #
  # Rake tasks (in Rails apps):
  #   rake easyop:dag:print[MyFlow]    # prints Mermaid definition
  #   rake easyop:dag:generate         # generates tmp/easyop_dags/index.html
  #   rake easyop:dag:generate FLOW=MyFlow OUTPUT=public/flows
  class DagBuilder
    CLASSDEFS = <<~MERMAID.strip
      classDef sync     fill:#eef2ff,stroke:#6366f1,color:#1e1b4b
      classDef async    fill:#fef3c7,stroke:#d97706,color:#92400e
      classDef durable  fill:#ede9fe,stroke:#7c3aed,color:#4c1d95
      classDef guard    fill:#f3f4f6,stroke:#9ca3af,color:#374151
      classDef start    fill:#d1fae5,stroke:#10b981,color:#065f46
      classDef subflow  fill:#eff6ff,stroke:#3b82f6,color:#1e3a5f
    MERMAID

    def initialize(flow_class, depth: 0, prefix: nil)
      @flow  = flow_class
      @depth = depth
      @pfx   = prefix || safe_id(flow_class.name || 'Flow')
      @guard_seq = 0
    end

    # Returns the full Mermaid `flowchart TD` definition as a string.
    def to_mermaid
      lines = ['flowchart TD']
      lines << "  %% #{@flow.name || @pfx}"
      build_body.each { |l| lines << "  #{l}" }
      lines << ''
      lines << CLASSDEFS.gsub(/^/, '  ')
      lines.join("\n")
    end

    # Returns subgraph lines for embedding inside another DagBuilder's output.
    def to_subgraph_lines(indent: '  ')
      label = @flow.name&.split('::')&.last || @pfx
      lines = ["subgraph #{@pfx}[\"#{label} (flow)\"]", '  direction TD']
      build_body.each { |l| lines << "  #{l}" }
      lines << 'end'
      lines.map { |l| "#{indent}#{l}" }
    end

    # Generates a standalone HTML file with Mermaid.js loaded from CDN.
    def self.to_html(flow_class, title: nil)
      t       = title || flow_class.name || 'Flow DAG'
      mermaid = new(flow_class).to_mermaid

      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <title>#{t}</title>
          <style>
            body{margin:0;background:#0f172a;color:#f1f5f9;font-family:system-ui,sans-serif;}
            h1{padding:1.25rem 1.5rem;font-size:1rem;margin:0;border-bottom:1px solid #334155;display:flex;align-items:center;gap:0.5rem;}
            h1 a{color:#818cf8;font-size:0.75rem;text-decoration:none;}
            .dag{padding:2rem;}
            .mermaid{background:#1e293b;border-radius:8px;padding:2rem;border:1px solid #334155;}
          </style>
        </head>
        <body>
          <h1>#{t} <a href="index.html">← back</a></h1>
          <div class="dag">
            <div class="mermaid">
        #{mermaid.gsub(/^/, '      ')}
            </div>
          </div>
          <script src="https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js"></script>
          <script>mermaid.initialize({startOnLoad:true,theme:'base',themeVariables:{
            background:'#1e293b',primaryColor:'#eef2ff',primaryTextColor:'#1e1b4b',
            primaryBorderColor:'#6366f1',lineColor:'#6366f1',fontFamily:'system-ui',fontSize:'13px'
          }});</script>
        </body>
        </html>
      HTML
    end

    # Discover all Easyop::Flow classes in the current Ruby object space.
    # Only returns named classes outside the Easyop:: namespace.
    def self.all_flow_classes(excluded_prefixes: %w[Easyop:: RSpec:: Minitest::])
      ObjectSpace.each_object(Class).select { |klass|
        klass.name &&
          klass.ancestors.include?(Easyop::Flow) &&
          excluded_prefixes.none? { |prefix| klass.name.start_with?(prefix) }
      }.sort_by(&:name)
    end

    # Export HTML for a collection of flow classes into output_dir.
    # Creates one file per flow plus an index.html listing.
    def self.export_html(flow_classes, output_dir)
      require 'fileutils'
      FileUtils.mkdir_p(output_dir)

      flow_classes.each do |klass|
        file_name = "#{safe_class_id(klass)}.html"
        path      = File.join(output_dir, file_name)
        File.write(path, to_html(klass))
      end

      index_html = build_index_html(flow_classes)
      File.write(File.join(output_dir, 'index.html'), index_html)
    end

    def self.build_index_html(flow_classes)
      rows = flow_classes.map do |klass|
        mode  = mode_label(klass)
        steps = klass._flow_steps.reject { |s| s.is_a?(Proc) }.size
        link  = "#{safe_class_id(klass)}.html"
        "<tr><td><a href=\"#{link}\">#{klass.name}</a></td><td>#{mode}</td><td>#{steps}</td></tr>"
      end.join("\n")

      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <title>Easyop — Flow DAGs</title>
          <style>
            body{margin:0;background:#0f172a;color:#f1f5f9;font-family:system-ui,sans-serif;}
            h1{padding:1.25rem 1.5rem;font-size:1.125rem;margin:0;border-bottom:1px solid #334155;}
            .wrap{padding:1.5rem;}
            p{color:#94a3b8;font-size:0.875rem;margin-bottom:1.5rem;}
            table{width:100%;border-collapse:collapse;font-size:0.875rem;}
            th{background:#1e293b;padding:0.625rem 0.875rem;text-align:left;color:#94a3b8;
               font-size:0.75rem;text-transform:uppercase;letter-spacing:0.04em;border-bottom:1px solid #334155;}
            td{padding:0.625rem 0.875rem;border-bottom:1px solid #1e293b;}
            tr:hover td{background:#1a2540;}
            a{color:#818cf8;text-decoration:none;}
            a:hover{text-decoration:underline;}
          </style>
        </head>
        <body>
          <h1>⬡ Easyop — Flow DAGs</h1>
          <div class="wrap">
            <p>#{flow_classes.size} flows discovered · generated #{Time.now.utc.strftime('%Y-%m-%d %H:%M UTC')}</p>
            <table>
              <thead><tr><th>Flow</th><th>Mode</th><th>Steps</th></tr></thead>
              <tbody>#{rows}</tbody>
            </table>
          </div>
        </body>
        </html>
      HTML
    end

    private_class_method :build_index_html

    def self.mode_label(klass)
      return 'Mode 3 — durable'        if klass._durable_flow?
      has_async = klass._flow_steps.any? { |s| s.is_a?(Easyop::Operation::StepBuilder) && s.opts[:async] }
      has_async ? 'Mode 2 — async' : 'Mode 1 — sync'
    end
    private_class_method :mode_label

    def self.safe_class_id(klass)
      klass.name.to_s.gsub(/[^A-Za-z0-9]/, '_').gsub(/_+/, '_').downcase
    end
    private_class_method :safe_class_id

    private

    def build_body
      steps     = @flow._flow_steps
      start_id  = "#{@pfx}_START"
      end_id    = "#{@pfx}_END"
      result    = ["#{start_id}([▶ start]):::start"]
      nodes     = preprocess(steps)
      prev_id   = start_id
      pending   = nil

      nodes.each_with_index do |node, idx|
        case node[:type]
        when :guard
          gid = "#{@pfx}_G#{node[:seq]}"
          result << "#{gid}{guard λ}:::guard"
          result << "#{prev_id} --> #{gid}"
          pending = gid
          prev_id = nil

        when :step
          step_id, lines = render_step(node[:entry])
          lines.each { |l| result << l }

          if pending
            result << "#{pending} -->|truthy| #{step_id}"
            next_id = next_step_id(nodes, idx + 1, end_id)
            result << "#{pending} -->|falsy – skip| #{next_id}"
            pending = nil
          else
            result << "#{prev_id} --> #{step_id}" if prev_id
          end
          prev_id = last_id(node[:entry], step_id)
        end
      end

      result << "#{end_id}([■ done]):::start"
      result << "#{prev_id} --> #{end_id}" if prev_id
      result
    end

    def preprocess(steps)
      result = []
      steps.each do |entry|
        if entry.is_a?(Proc)
          @guard_seq += 1
          result << { type: :guard, seq: @guard_seq }
        else
          result << { type: :step, entry: entry }
        end
      end
      result
    end

    def next_step_id(nodes, from, default)
      (from...nodes.size).each do |i|
        return node_id(nodes[i][:entry]) if nodes[i][:type] == :step
      end
      default
    end

    def render_step(entry)
      klass = entry.is_a?(Easyop::Operation::StepBuilder) ? entry.klass : entry
      opts  = entry.is_a?(Easyop::Operation::StepBuilder) ? entry.opts : {}
      nid   = node_id(entry)

      if klass.is_a?(Class) && klass.ancestors.include?(Easyop::Flow)
        sub     = self.class.new(klass, depth: @depth + 1, prefix: "#{@pfx}_#{safe_id(klass.name || '')}")
        lines   = sub.to_subgraph_lines
        first   = "#{@pfx}_#{safe_id(klass.name || '')}_START"
        return [first, lines]
      end

      label  = klass.name&.split('::')&.last || klass.to_s
      annots = []
      annots << '⚡ async'             if opts[:async]
      annots << "wait: #{opts[:wait]}" if opts[:wait]
      annots << 'skip_if λ'           if opts[:skip_if]
      annots << "on_exc: #{opts[:on_exception]}" if opts[:on_exception]

      display = annots.empty? ? label : "#{label}\n#{annots.join(', ')}"
      css     = opts[:on_exception] || opts[:tags] ? 'durable' : opts[:async] ? 'async' : 'sync'

      [nid, ["#{nid}[\"#{display}\"]:::#{css}"]]
    end

    def node_id(entry)
      klass = entry.is_a?(Easyop::Operation::StepBuilder) ? entry.klass : entry
      "#{@pfx}_#{safe_id(klass.name || klass.to_s)}"
    end

    def last_id(entry, default)
      klass = entry.is_a?(Easyop::Operation::StepBuilder) ? entry.klass : entry
      if klass.is_a?(Class) && klass.ancestors.include?(Easyop::Flow)
        "#{@pfx}_#{safe_id(klass.name || '')}_END"
      else
        default
      end
    end

    def safe_id(str)
      str.to_s.gsub(/[^A-Za-z0-9]/, '_').gsub(/_+/, '_').sub(/^_/, '').sub(/_$/, '')
    end
  end
end
