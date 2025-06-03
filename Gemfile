source "https://rubygems.org"

ruby "3.4.4"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "7.1.3.4"

gem 'bundler', '2.5.14'

# Use Redis adapter to run Action Cable in production
# gem "redis", ">= 4.0.1"

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ]
  gem "timecop"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
end

gem "pry", "~> 0.14.2"

gem "rspec", "~> 3.13"

gem "awesome_print", "~> 1.9"
gem 'keccak', '~> 1.3'

gem "eth", github: "0xFacet/eth.rb"

gem "dotenv-rails", "~> 3.1", :group => [:development, :test]

gem 'sorbet', :group => :development
gem 'sorbet-runtime'
gem 'tapioca', require: false, :group => [:development, :test]

# gem "pry-rails", "~> 0.3.11", :group => :development

gem "memery", "~> 1.5"

gem "httparty", "~> 0.22.0"

gem "jwt", "~> 2.8"

gem "clockwork", "~> 3.0"

gem "airbrake", "~> 13.0"
gem "clipboard", "~> 2.0", :group => [:development, :test]
gem "order_query", "~> 0.5.3"

gem "parallel", "~> 1.25"

gem "net-http-persistent", "~> 4.0"
