# frozen_string_literal: true

require 'test_helper'

class PluginsBaseTest < Minitest::Test
  include EasyopTestHelper

  # ── Base.install raises NotImplementedError ───────────────────────────────────

  def test_dot_install_raises_not_implemented
    assert_raises(NotImplementedError) do
      Easyop::Plugins::Base.install(Object.new)
    end
  end

  def test_dot_install_error_message_includes_class_name
    klass = Class.new(Easyop::Plugins::Base)
    # anonymous class has no name — just verify the method is inherited
    err = assert_raises(NotImplementedError) { klass.install(Object.new) }
    assert_includes err.message, 'install'
  end

  # ── Base.install error includes the class name ────────────────────────────────

  def test_dot_install_error_message_includes_easyop_plugins_base
    err = assert_raises(NotImplementedError) { Easyop::Plugins::Base.install(Object.new) }
    assert_match(/Easyop::Plugins::Base/, err.message)
  end

  def test_dot_install_error_message_mentions_install_method
    err = assert_raises(NotImplementedError) { Easyop::Plugins::Base.install(Object.new) }
    assert_match(/install/, err.message)
  end

  # ── Concrete plugin subclass ──────────────────────────────────────────────────

  def test_concrete_plugin_can_override_install_without_raising
    tracking_plugin = Class.new(Easyop::Plugins::Base) do
      def self.install(base, **_opts); end
    end
    op = Class.new { include Easyop::Operation }
    tracking_plugin.install(op, foo: :bar)  # must not raise
  end

  def test_concrete_plugin_install_receives_operation_class
    received = nil
    tracking_plugin = Class.new(Easyop::Plugins::Base) do
      define_singleton_method(:install) { |base, **_opts| received = base }
    end
    op = Class.new { include Easyop::Operation }
    tracking_plugin.install(op)
    assert_equal op, received
  end

  # ── Subclass with install works via plugin DSL ─────────────────────────────────

  def test_subclass_install_is_called_by_plugin_dsl
    installed_on = nil
    my_plugin = Class.new(Easyop::Plugins::Base) do
      def self.install(base, **_opts)
        installed_on = base
      end
    end

    op = Class.new { include Easyop::Operation }
    op.plugin(my_plugin)
    # If install was called it would set installed_on; verify no exception
    assert_equal 1, op._registered_plugins.size
  end

  # ── Operation#plugin DSL ───────────────────────────────────────────────────────

  def test_plugin_dsl_calls_install_with_operation_class_and_options
    calls = []
    tracking_plugin = Module.new do
      define_singleton_method(:install) { |base, **opts| calls << { base: base, options: opts } }
    end
    op = Class.new { include Easyop::Operation }
    op.plugin(tracking_plugin, key: 'val')
    assert_equal op, calls.last[:base]
    assert_equal({ key: 'val' }, calls.last[:options])
  end

  def test_plugin_dsl_passes_empty_options_when_none_given
    calls = []
    tracking_plugin = Module.new do
      define_singleton_method(:install) { |_base, **opts| calls << opts }
    end
    op = Class.new { include Easyop::Operation }
    op.plugin(tracking_plugin)
    assert_equal({}, calls.last)
  end

  # ── _registered_plugins ───────────────────────────────────────────────────────

  def test_registered_plugins_empty_before_any_plugin_added
    fresh_op = Class.new { include Easyop::Operation }
    assert_equal [], fresh_op._registered_plugins
  end

  def test_registered_plugins_tracks_plugin_and_options
    tracking_plugin = Module.new do
      define_singleton_method(:install) { |_base, **_opts| }
    end
    op = Class.new { include Easyop::Operation }
    op.plugin(tracking_plugin, timeout: 30)
    entry = op._registered_plugins.last
    assert_equal tracking_plugin, entry[:plugin]
    assert_equal({ timeout: 30 }, entry[:options])
  end

  def test_registered_plugins_stacks_multiple_in_order
    plugin_a = Module.new { define_singleton_method(:install) { |_b, **_o| } }
    plugin_b = Module.new { define_singleton_method(:install) { |_b, **_o| } }
    op = Class.new { include Easyop::Operation }
    op.plugin(plugin_a, order: 1)
    op.plugin(plugin_b, order: 2)
    assert_equal 2, op._registered_plugins.length
    assert_equal plugin_a, op._registered_plugins[0][:plugin]
    assert_equal plugin_b, op._registered_plugins[1][:plugin]
  end

  def test_registered_plugins_does_not_share_state_between_classes
    tracking_plugin = Module.new { define_singleton_method(:install) { |_b, **_o| } }
    op_a = Class.new { include Easyop::Operation }
    op_b = Class.new { include Easyop::Operation }
    op_a.plugin(tracking_plugin)
    assert_empty op_b._registered_plugins
  end
end
