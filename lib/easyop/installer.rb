# frozen_string_literal: true

require "pathname"
require_relative "installer/tui"
require_relative "installer/generator"

module Easyop
  module Installer
    PLUGINS = [
      {
        name:        "Instrumentation",
        value:       :instrumentation,
        requires:    ["easyop/plugins/instrumentation"],
        plugin_line: "plugin Easyop::Plugins::Instrumentation",
        selected:    true,
        hint:        "logs every execution via Rails.logger"
      },
      {
        name:        "Recording",
        value:       :recording,
        requires:    ["easyop/plugins/recording"],
        plugin_line: "plugin Easyop::Plugins::Recording, model: OperationLog",
        selected:    true,
        hint:        "persists each execution to OperationLog (requires AR)"
      },
      {
        name:        "Transactional",
        value:       :transactional,
        requires:    ["easyop/plugins/transactional"],
        plugin_line: "plugin Easyop::Plugins::Transactional",
        selected:    false,
        hint:        "wraps each call in an AR transaction"
      },
      {
        name:        "Async",
        value:       :async,
        requires:    ["easyop/plugins/async"],
        plugin_line: "plugin Easyop::Plugins::Async, queue: \"operations\"",
        selected:    false,
        hint:        "enqueue operations as ActiveJob"
      },
      {
        name:        "Events",
        value:       :events,
        requires:    %w[easyop/events/event easyop/events/bus easyop/events/registry easyop/plugins/events],
        plugin_line: "plugin Easyop::Plugins::Events",
        selected:    false,
        hint:        "emit domain events after each execution"
      }
    ].freeze

    module_function

    # ─── main entry points ─────────────────────────────────────────────────

    def run!(root: detect_rails_root)
      Tui.banner
      Tui.say "Welcome! This wizard will configure EasyOp for your project."
      Tui.say "Press #{Tui.bold("Ctrl-C")} at any time to abort."
      Tui.separator

      config = gather_config
      config[:root] = root

      Tui.section("Preview")
      preview(config)

      unless Tui.yes?("Generate these files?", default: true)
        Tui.say Tui.yellow("Aborted — no files written.")
        return
      end

      Tui.section("Writing files")
      generate_files(config)

      Tui.say
      Tui.success "Done! #{Tui.bold("EasyOp")} is ready."
      print_next_steps(config)
    end

    def generate_operation!(class_name, root: detect_rails_root)
      Tui.banner
      Tui.section("Generate Operation — #{Tui.bold(class_name)}")

      config = gather_operation_config(class_name)
      config[:root] = root

      gen = Generator.new(root)
      Tui.say
      Tui.section("Writing files")
      gen.write_operation(class_name, config)
      Tui.say
      Tui.success "Generated #{Tui.bold(class_name)}"
    end

    def generate_flow!(class_name, root: detect_rails_root)
      Tui.banner
      Tui.section("Generate Flow — #{Tui.bold(class_name)}")

      config = gather_flow_config(class_name)
      config[:root] = root

      gen = Generator.new(root)
      Tui.say
      Tui.section("Writing files")
      gen.write_flow(class_name, config)
      Tui.say
      Tui.success "Generated #{Tui.bold(class_name)}"
    end

    # ─── config gathering ──────────────────────────────────────────────────

    def gather_config
      config = {}

      Tui.section("Base class")
      config[:base_class] = Tui.ask("ApplicationOperation class name", default: "ApplicationOperation")

      Tui.section("Plugins")
      selected_values = Tui.multiselect("Which plugins to install?", PLUGINS)
      selected_plugins = PLUGINS.select { |p| selected_values.include?(p[:value]) }
      config[:plugins]              = selected_plugins
      config[:plugin_values]        = selected_values
      config[:instrumentation]      = selected_values.include?(:instrumentation)
      config[:recording]            = selected_values.include?(:recording)

      if config[:recording]
        Tui.section("Recording")
        config[:create_migration]   = Tui.yes?("Create OperationLog migration?", default: true)
        config[:create_model]       = Tui.yes?("Create OperationLog model?",     default: true)
        config[:encryption]         = Tui.yes?("Enable encrypted params (encrypt_params DSL)?", default: false)
        if config[:encryption]
          Tui.info "Set EASYOP_RECORDING_SECRET in your environment (≥ 32 bytes)."
          Tui.info "See: https://pniemczyk.github.io/easyop/rails.html#encryption-secret"
        end
      end

      Tui.section("Rails version")
      config[:rails_version] = detect_rails_version

      Tui.section("Sample operation")
      if Tui.yes?("Generate a sample operation?", default: true)
        class_name  = Tui.ask("Operation class name", default: "Users::Create")
        op_config   = gather_operation_config(class_name, base_class: config[:base_class],
                                                          encryption: config[:encryption])
        config[:sample_operation] = { class_name: class_name, config: op_config }
      end

      Tui.section("Sample flow")
      if Tui.yes?("Generate a sample flow?", default: false)
        class_name  = Tui.ask("Flow class name", default: "Flows::ProcessOrder")
        flow_config = gather_flow_config(class_name, base_class: config[:base_class])
        config[:sample_flow] = { class_name: class_name, config: flow_config }
      end

      config
    end

    def gather_operation_config(class_name, base_class: "ApplicationOperation", encryption: false)
      config = { base_class: base_class, encryption: encryption }

      raw = Tui.ask("Param names (comma-separated, blank to skip)", default: "")
      config[:param_names] = raw.split(",").map(&:strip).reject(&:empty?)

      if config[:param_names].any?
        config[:record_params_attrs] = config[:param_names]

        if encryption
          raw = Tui.ask("Params to encrypt (comma-separated, blank to skip)", default: "")
          config[:encrypt_keys] = raw.split(",").map(&:strip).reject(&:empty?)
        else
          config[:encrypt_keys] = []
        end

        raw = Tui.ask("Params to filter/redact (comma-separated, blank to skip)", default: "")
        config[:filter_keys] = raw.split(",").map(&:strip).reject(&:empty?)
      else
        config[:record_params_attrs] = []
        config[:encrypt_keys]        = []
        config[:filter_keys]         = []
      end

      raw = Tui.ask("Result attrs to record (comma-separated, blank to skip)", default: "")
      config[:record_result_attrs] = raw.split(",").map(&:strip).reject(&:empty?)

      config
    end

    def gather_flow_config(class_name, base_class: "ApplicationOperation")
      config = { base_class: base_class }

      raw = Tui.ask("Step class names (comma-separated)", default: "Step1, Step2")
      config[:step_names] = raw.split(",").map(&:strip).reject(&:empty?)

      config
    end

    # ─── generation ────────────────────────────────────────────────────────

    def generate_files(config)
      gen = Generator.new(config[:root])

      gen.write_initializer(config)
      gen.write_application_operation(config)

      if config[:recording]
        gen.write_operation_log_migration(config) if config[:create_migration]
        gen.write_operation_log_model(config)     if config[:create_model]
      end

      if (op = config[:sample_operation])
        gen.write_operation(op[:class_name], op[:config])
      end

      if (fl = config[:sample_flow])
        gen.write_flow(fl[:class_name], fl[:config])
      end
    end

    # ─── preview ───────────────────────────────────────────────────────────

    def preview(config)
      gen = Generator.new(config[:root])

      files = [
        "config/initializers/easyop.rb",
        "app/operations/application_operation.rb"
      ]
      files << "db/migrate/TIMESTAMP_create_operation_logs.rb" if config.dig(:recording) && config[:create_migration]
      files << "app/models/operation_log.rb"                   if config.dig(:recording) && config[:create_model]

      if (op = config[:sample_operation])
        files << gen.class_name_to_path(op[:class_name], "app/operations")
      end

      if (fl = config[:sample_flow])
        files << gen.class_name_to_path(fl[:class_name], "app/operations")
      end

      Tui.say "Files to generate:"
      files.each { |f| Tui.say "  #{Tui.green("+")} #{f}" }

      if config[:plugins]&.any?
        Tui.say
        Tui.say "Plugins: #{config[:plugins].map { |p| Tui.bold(p[:name]) }.join(", ")}"
      end
    end

    # ─── next steps ────────────────────────────────────────────────────────

    def print_next_steps(config)
      Tui.section("Next steps")
      steps = []
      steps << "Run #{Tui.bold("bin/rails db:migrate")} to create the operation_logs table" if config.dig(:recording) && config[:create_migration]
      steps << "Set #{Tui.bold("EASYOP_RECORDING_SECRET")} in your environment (≥ 32 bytes)" if config[:encryption]
      steps << "Add #{Tui.bold("require \"easyop\"")} to your Gemfile if not already present"
      steps << "Restart your Rails server"

      steps.each_with_index do |s, i|
        Tui.say "  #{Tui.cyan("#{i + 1}.")} #{s}"
      end
      Tui.say
    end

    # ─── detection helpers ─────────────────────────────────────────────────

    def detect_rails_root
      return Pathname.new(Rails.root) if defined?(Rails) && Rails.respond_to?(:root) && Rails.root

      dir = Pathname.new(Dir.pwd)
      until dir.root?
        return dir if (dir / "config" / "application.rb").exist?
        dir = dir.parent
      end
      Pathname.new(Dir.pwd)
    end

    def detect_rails_version
      return Rails::VERSION::STRING.split(".").first(2).join(".") if defined?(Rails::VERSION)

      gemfile = detect_rails_root / "Gemfile.lock"
      if gemfile.exist?
        match = gemfile.read.match(/^\s+rails \((\d+\.\d+)/)
        return match[1] if match
      end

      "7.1"
    end
  end
end
