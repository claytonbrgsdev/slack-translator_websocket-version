require 'sequel'
require 'rspec'
require_relative '../db/config'

# Run migrations first
Sequel.extension :migration
Sequel::Migrator.run(DB, File.expand_path('../db/migrations', __dir__))

# Now require service after migrations have run
require_relative '../slack_user_service'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = "spec/examples.txt"
  config.disable_monkey_patching!
  config.warnings = true

  config.order = :random
  Kernel.srand config.seed
  
  # Setup test database
  config.before(:suite) do
    # Ensure test tables exist
    Sequel.extension :migration
    Sequel::Migrator.run(DB, File.expand_path('../db/migrations', __dir__))
  end
  
  # Clean database before each test
  config.before(:each) do
    DB[:user_profiles].delete if DB.tables.include?(:user_profiles)
  end
end
