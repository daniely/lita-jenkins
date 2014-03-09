require "spec_helper"

describe Lita::Handlers::Jenkins, lita_handler: true do
  it { routes_command('jenkins list').to(:jenkins_list) }
  it { routes_command('jenkins list filter').to(:jenkins_list) }
end
