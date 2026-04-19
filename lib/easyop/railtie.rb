# frozen_string_literal: true

module Easyop
  class Railtie < ::Rails::Railtie
    rake_tasks do
      load File.expand_path("../tasks/easyop.rake", __dir__)
    end
  end
end
