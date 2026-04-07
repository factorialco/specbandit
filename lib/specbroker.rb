# frozen_string_literal: true

require 'specbroker/version'
require 'specbroker/configuration'
require 'specbroker/redis_queue'
require 'specbroker/publisher'
require 'specbroker/worker'

module Specbroker
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
