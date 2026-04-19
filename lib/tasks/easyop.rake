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

  desc "Print available EasyOp rake tasks"
  task :help do
    puts
    puts "  EasyOp rake tasks:"
    puts
    puts "    rake easyop:install                              # Interactive setup wizard"
    puts "    rake easyop:generate:operation[ClassName]        # Generate a new operation"
    puts "    rake easyop:generate:flow[ClassName]             # Generate a new flow"
    puts
    puts "  Examples:"
    puts "    rake easyop:install"
    puts "    rake easyop:generate:operation[Users::Create]"
    puts "    rake easyop:generate:flow[Flows::ProcessOrder]"
    puts
  end
end
