require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module SimpleVm
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w(assets tasks))
    
    config.active_record.schema_format = :sql
    
    config.active_record.async_query_executor = :global_thread_pool
    
    config.active_record.raise_int_wider_than_64bit = false
    
    config.api_only = true
    
    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
    config.middleware.insert_after ActionDispatch::Static, Rack::Deflater
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use ActionDispatch::Session::CookieStore
    
    additional_paths = %w(
      lib
      lib/solidity
      lib/extensions
    ).map{|i| Rails.root.join(i)}
    config.autoload_paths += additional_paths
    config.eager_load_paths += additional_paths
  end
end
