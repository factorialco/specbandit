# frozen_string_literal: true

require 'specbroker'

RSpec.configure do |config|
  config.before(:each) do
    Specbroker.reset_configuration!
  end
end
