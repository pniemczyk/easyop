# frozen_string_literal: true

require "erb"
require "fileutils"
require_relative "tui"

module Easyop
  module Installer
    class Generator
      include Tui

      TEMPLATES_DIR = File.expand_path("../templates", __dir__)

      attr_reader :root

      def initialize(root)
        @root = Pathname.new(root)
      end

      # ─── top-level generators ──────────────────────────────────────────────

      def write_initializer(config)
        write_template("initializer.rb.tt",
                        root / "config" / "initializers" / "easyop.rb",
                        config)
      end

      def write_application_operation(config)
        write_template("application_operation.rb.tt",
                        root / "app" / "operations" / "application_operation.rb",
                        config)
      end

      def write_operation_log_migration(config)
        ts   = Time.now.strftime("%Y%m%d%H%M%S")
        dest = root / "db" / "migrate" / "#{ts}_create_operation_logs.rb"
        write_template("operation_log_migration.rb.tt", dest, config)
      end

      def write_operation_log_model(config)
        write_template("operation_log_model.rb.tt",
                        root / "app" / "models" / "operation_log.rb",
                        config)
      end

      def write_operation(class_name, config)
        path = class_name_to_path(class_name, "app/operations")
        write_template("operation.rb.tt", root / path,
                        operation_vars(class_name, config))
      end

      def write_flow(class_name, config)
        path = class_name_to_path(class_name, "app/operations")
        write_template("flow.rb.tt", root / path,
                        flow_vars(class_name, config))
      end

      # ─── helpers ───────────────────────────────────────────────────────────

      def class_name_to_path(class_name, base_dir)
        parts = class_name.split("::")
        dirs  = parts[0..-2].map { |p| underscore(p) }
        file  = underscore(parts.last) + ".rb"
        File.join(base_dir, *dirs, file)
      end

      private

      def write_template(template_name, dest, vars)
        dest = Pathname.new(dest)
        template_path = File.join(TEMPLATES_DIR, template_name)
        content = render_template(template_path, vars)

        rel = dest.relative_path_from(root) rescue dest.to_s

        if dest.exist?
          Tui.status("exist", rel)
          return false
        end

        FileUtils.mkdir_p(dest.dirname)
        dest.write(content)
        Tui.status("create", rel)
        true
      end

      def render_template(template_path, vars)
        source  = File.read(template_path)
        context = TemplateContext.new(vars)
        ERB.new(source, trim_mode: "-").result(context.get_binding)
      end

      def operation_vars(class_name, config)
        parts = class_name.split("::")
        namespaces  = parts[0..-2]
        short_name  = parts.last

        indent = namespaces.empty? ? "" : "  " * namespaces.size

        if namespaces.empty?
          header = "class #{class_name} < #{config[:base_class]}"
          footer = "end"
        else
          header = namespaces.map.with_index { |ns, i| "  " * i + "module #{ns}" }.join("\n") +
                   "\n" + "  " * namespaces.size + "class #{short_name} < #{config[:base_class]}"
          footer = namespaces.size.downto(0).map { |i| "  " * i + "end" }.join("\n")
        end

        config.merge(
          class_header:        header,
          class_footer:        footer,
          indent:              indent,
          class_name_full:     class_name,
          param_names:         Array(config[:param_names]),
          record_params_attrs: Array(config[:record_params_attrs]),
          record_result_attrs: Array(config[:record_result_attrs]),
          encrypt_keys:        Array(config[:encrypt_keys]),
          filter_keys:         Array(config[:filter_keys])
        )
      end

      def flow_vars(class_name, config)
        parts = class_name.split("::")
        namespaces = parts[0..-2]
        short_name = parts.last

        if namespaces.empty?
          header = "class #{class_name} < #{config[:base_class]}"
          footer = "end"
        else
          header = namespaces.map.with_index { |ns, i| "  " * i + "module #{ns}" }.join("\n") +
                   "\n" + "  " * namespaces.size + "class #{short_name} < #{config[:base_class]}"
          footer = namespaces.size.downto(0).map { |i| "  " * i + "end" }.join("\n")
        end

        indent = namespaces.empty? ? "" : "  " * namespaces.size

        config.merge(
          class_header:    header,
          class_footer:    footer,
          indent:          indent,
          class_name_full: class_name,
          step_names:      Array(config[:step_names])
        )
      end

      def underscore(str)
        str.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
           .gsub(/([a-z\d])([A-Z])/, '\1_\2')
           .downcase
      end

      class TemplateContext
        def initialize(vars)
          vars.each do |k, v|
            instance_variable_set(:"@#{k}", v)
            singleton_class.define_method(k) { instance_variable_get(:"@#{k}") }
          end
        end

        def get_binding = binding
      end
    end
  end
end
