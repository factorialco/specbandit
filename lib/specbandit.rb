# frozen_string_literal: true

require 'specbandit/version'
require 'specbandit/configuration'
require 'specbandit/redis_queue'
require 'specbandit/publisher'
require 'specbandit/worker'

module Specbandit
  class Error < StandardError; end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
