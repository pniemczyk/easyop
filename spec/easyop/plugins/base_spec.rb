require "spec_helper"
require "easyop/plugins/base"

RSpec.describe Easyop::Plugins::Base do
  describe ".install" do
    it "raises NotImplementedError with a helpful message" do
      expect { described_class.install(Object.new) }
        .to raise_error(NotImplementedError, /install\(base.*options\).*must be implemented/)
    end

    it "includes the plugin class name in the message" do
      expect { described_class.install(Object.new) }
        .to raise_error(NotImplementedError, /Easyop::Plugins::Base/)
    end
  end

  describe "concrete plugin subclass" do
    let(:concrete_plugin) do
      Class.new(Easyop::Plugins::Base) do
        def self.name; "ConcretePlugin"; end

        def self.install(base, **options)
          base.instance_variable_set(:@installed_with, options)
        end
      end
    end

    it "can override .install without raising" do
      op_class = Class.new { include Easyop::Operation }
      expect { concrete_plugin.install(op_class, foo: :bar) }.not_to raise_error
    end

    it "install receives the operation class as first argument" do
      op_class = Class.new { include Easyop::Operation }
      concrete_plugin.install(op_class)
      expect(op_class.instance_variable_get(:@installed_with)).not_to be_nil
    end
  end
end

RSpec.describe "Operation#plugin DSL" do
  let(:tracking_plugin) do
    Module.new do
      def self.name; "TrackingPlugin"; end

      def self.installs
        @installs ||= []
      end

      def self.install(base, **options)
        installs << { base: base, options: options }
      end
    end
  end

  let(:other_plugin) do
    Module.new do
      def self.name; "OtherPlugin"; end

      def self.installs
        @installs ||= []
      end

      def self.install(base, **options)
        installs << { base: base, options: options }
      end
    end
  end

  let(:op_class) { Class.new { include Easyop::Operation } }

  describe "calling plugin" do
    it "calls install with the operation class and options" do
      op_class.plugin(tracking_plugin, key: "val")
      expect(tracking_plugin.installs.last[:base]).to eq(op_class)
      expect(tracking_plugin.installs.last[:options]).to eq(key: "val")
    end

    it "passes no options when none given" do
      op_class.plugin(tracking_plugin)
      expect(tracking_plugin.installs.last[:options]).to eq({})
    end
  end

  describe "_registered_plugins" do
    it "is empty before any plugins are added" do
      fresh_op = Class.new { include Easyop::Operation }
      expect(fresh_op._registered_plugins).to eq([])
    end

    it "tracks the plugin and options after a plugin call" do
      op_class.plugin(tracking_plugin, timeout: 30)
      entry = op_class._registered_plugins.last
      expect(entry[:plugin]).to eq(tracking_plugin)
      expect(entry[:options]).to eq(timeout: 30)
    end

    it "stacks multiple plugin entries in order" do
      op_class.plugin(tracking_plugin, order: 1)
      op_class.plugin(other_plugin, order: 2)

      expect(op_class._registered_plugins.length).to eq(2)
      expect(op_class._registered_plugins[0][:plugin]).to eq(tracking_plugin)
      expect(op_class._registered_plugins[1][:plugin]).to eq(other_plugin)
    end

    it "does not share state between different operation classes" do
      op_a = Class.new { include Easyop::Operation }
      op_b = Class.new { include Easyop::Operation }

      op_a.plugin(tracking_plugin)
      expect(op_b._registered_plugins).to be_empty
    end
  end
end
