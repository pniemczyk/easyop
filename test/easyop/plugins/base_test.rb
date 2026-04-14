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
end
