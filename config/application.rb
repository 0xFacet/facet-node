require_relative "boot"

# Instead of loading all railties (which pulls in ActiveRecord), require only what we need.
require "rails"

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
    
    
    additional_paths = %w(
      lib
      lib/solidity
      lib/extensions
    ).map{|i| Rails.root.join(i)}
    config.autoload_paths += additional_paths
    config.eager_load_paths += additional_paths
  end
end
