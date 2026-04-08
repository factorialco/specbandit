# frozen_string_literal: true

require 'specbandit'

RSpec.configure do |config|
  config.before(:each) do
    Specbandit.reset_configuration!
  end
end
