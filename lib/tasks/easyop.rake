# frozen_string_literal: true

namespace :easyop do
  desc "Interactive TUI wizard — configure EasyOp and generate initial files"
  task :install do
    require "easyop/version"
    require "easyop/installer"
    Easyop::Installer.run!
  end

  namespace :generate do
    desc "Generate an operation: rake easyop:generate:operation[ClassName]  (e.g. Users::Create)"
    task :operation, [:class_name] do |_, args|
      klass = args[:class_name]
      if klass.nil? || klass.strip.empty?
        puts "Usage: rake easyop:generate:operation[ClassName]"
        puts "  e.g. rake easyop:generate:operation[Users::Create]"
        exit 1
      end
      require "easyop/version"
      require "easyop/installer"
      Easyop::Installer.generate_operation!(klass.strip)
    end

    desc "Generate a flow:      rake easyop:generate:flow[ClassName]       (e.g. Flows::ProcessOrder)"
    task :flow, [:class_name] do |_, args|
      klass = args[:class_name]
      if klass.nil? || klass.strip.empty?
        puts "Usage: rake easyop:generate:flow[ClassName]"
        puts "  e.g. rake easyop:generate:flow[Flows::ProcessOrder]"
        exit 1
      end
      require "easyop/version"
      require "easyop/installer"
      Easyop::Installer.generate_flow!(klass.strip)
    end
  end

  # ── DAG tasks ────────────────────────────────────────────────────────────
  namespace :dag do
    desc <<~DESC
      Generate DAG diagrams for all flows as a standalone HTML file.

        rake easyop:dag:generate               # all flows → tmp/easyop_dags/index.html
        rake easyop:dag:generate FLOW=MyFlow   # single flow
        rake easyop:dag:generate OUTPUT=public/dags
    DESC
    task :generate => :environment do
      require 'easyop/dag_builder'

      flow_classes = Easyop::DagBuilder.all_flow_classes
      if (target = ENV['FLOW']).present?
        flow_classes = flow_classes.select { |k| k.name == target || k.name.end_with?(target) }
        if flow_classes.empty?
          $stderr.puts "easyop:dag:generate — no flow matching '#{target}' found."
          $stderr.puts "Available: #{Easyop::DagBuilder.all_flow_classes.map(&:name).join(', ')}"
          exit 1
        end
      end

      if flow_classes.empty?
        $stderr.puts "easyop:dag:generate — no Easyop::Flow classes found in object space."
        $stderr.puts "Make sure eager_load is on or flows are required before running this task."
        exit 1
      end

      output_dir = ENV.fetch('OUTPUT', Rails.root.join('tmp', 'easyop_dags').to_s)
      Easyop::DagBuilder.export_html(flow_classes, output_dir)

      puts
      puts "  ✓ #{flow_classes.size} DAG#{flow_classes.size == 1 ? '' : 's'} generated → #{output_dir}/index.html"
      puts
      flow_classes.each do |klass|
        mode = klass._durable_flow? ? 'Mode 3' : 'Mode 1/2'
        steps = klass._flow_steps.reject { |s| s.is_a?(Proc) }.size
        puts "    #{klass.name.ljust(50)} #{mode}   #{steps} steps"
      end
      puts
    end

    desc <<~DESC
      Print the Mermaid definition for a single flow to stdout.

        rake easyop:dag:print[MyFlow]
        rake easyop:dag:print FLOW=MyFlow
    DESC
    task :print, [:class_name] => :environment do |_, args|
      require 'easyop/dag_builder'

      klass_name = args[:class_name] || ENV['FLOW']
      unless klass_name.present?
        $stderr.puts 'Usage: rake easyop:dag:print[ClassName]'
        exit 1
      end

      begin
        klass = klass_name.constantize
      rescue NameError
        $stderr.puts "easyop:dag:print — class '#{klass_name}' not found."
        exit 1
      end

      unless klass.ancestors.include?(Easyop::Flow)
        $stderr.puts "easyop:dag:print — '#{klass_name}' does not include Easyop::Flow."
        exit 1
      end

      puts Easyop::DagBuilder.new(klass).to_mermaid
    end

    desc "List all discovered Easyop::Flow classes"
    task :list => :environment do
      require 'easyop/dag_builder'

      flows = Easyop::DagBuilder.all_flow_classes
      if flows.empty?
        puts "No Easyop::Flow classes found."
      else
        puts "\n  Registered flows (#{flows.size}):\n\n"
        flows.each do |klass|
          mode  = klass._durable_flow? ? 'Mode 3 durable' : 'Mode 1/2'
          steps = klass._flow_steps.reject { |s| s.is_a?(Proc) }.size
          puts "    #{klass.name.ljust(52)} #{mode.ljust(18)} #{steps} step#{steps == 1 ? '' : 's'}"
        end
        puts
      end
    end
  end

  desc "Print available EasyOp rake tasks"
  task :help do
    puts
    puts "  EasyOp rake tasks:"
    puts
    puts "    rake easyop:install                              # Interactive setup wizard"
    puts "    rake easyop:generate:operation[ClassName]        # Generate a new operation"
    puts "    rake easyop:generate:flow[ClassName]             # Generate a new flow"
    puts
    puts "    rake easyop:dag:generate                         # Export all flow DAGs → HTML"
    puts "    rake easyop:dag:generate FLOW=MyFlow             # Export a single flow DAG"
    puts "    rake easyop:dag:generate OUTPUT=public/dags      # Custom output directory"
    puts "    rake easyop:dag:print[ClassName]                 # Print Mermaid definition to stdout"
    puts "    rake easyop:dag:list                             # List all discovered flows"
    puts
    puts "  Examples:"
    puts "    rake easyop:install"
    puts "    rake easyop:generate:operation[Users::Create]"
    puts "    rake easyop:generate:flow[Flows::ProcessOrder]"
    puts "    rake easyop:dag:generate"
    puts "    rake easyop:dag:print[FulfillOrder]"
    puts
  end
end
