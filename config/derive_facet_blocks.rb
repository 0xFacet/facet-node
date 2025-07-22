require 'clockwork'
require './config/boot'
require './config/environment'
require 'active_support/time'
require 'optparse'

# Define required arguments, descriptions, and defaults
REQUIRED_CONFIG = {
  'L1_NETWORK' => { description: 'L1 network (e.g., sepolia)', required: true },
  'GETH_RPC_URL' => { description: 'Geth RPC URL', required: true },
  'NON_AUTH_GETH_RPC_URL' => { description: 'Non-auth Geth RPC URL', required: true },
  'BLOCK_IMPORT_BATCH_SIZE' => { description: 'Block import batch size', default: '5' },
  'L1_RPC_URL' => { description: 'L1 RPC URL', required: true },
  'JWT_SECRET' => { description: 'JWT Secret', required: true },
  'L1_GENESIS_BLOCK' => { description: 'L1 Genesis Block number', required: true }
}

# Parse command line options
options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: clockwork derive_facet_blocks.rb [options]"
  
  REQUIRED_CONFIG.each do |key, config|
    flag = "--#{key.downcase.tr('_', '-')}"
    opts.on("#{flag} VALUE", config[:description]) do |v|
      options[key] = v
    end
  end
  
  opts.on("-h", "--help", "Show this help message") do
    puts opts
    exit
  end
end

parser.parse!

# Merge ENV vars with command line options and defaults
config = REQUIRED_CONFIG.each_with_object({}) do |(key, config_opts), hash|
  hash[key] = options[key] || ENV[key] || config_opts[:default]
end

# Check for missing required values
missing = config.select do |key, value| 
  REQUIRED_CONFIG[key][:required] && (value.nil? || value.empty?)
end

if missing.any?
  puts "Missing required configuration:"
  missing.each do |key, _|
    puts "  #{key}: #{REQUIRED_CONFIG[key][:description]}"
    puts "    Can be set via environment variable #{key}"
    puts "    Or via command line argument --#{key.downcase.tr('_', '-')}"
  end
  
  # Use the first missing key for the example
  example_key = missing.keys.first
  
  puts "\nExample usage:"
  puts "  #{example_key}=value bundle exec clockwork derive_facet_blocks.rb"
  puts "  bundle exec clockwork derive_facet_blocks.rb --#{example_key.downcase.tr('_', '-')} value"
  exit 1
end

# Set final values in ENV
config.each { |key, value| ENV[key] = value }

module Clockwork
  handler do |job|
    puts "Running #{job}"
  end

  error_handler do |error|
    report_exception_every = 15.minutes
    
    exception_key = ["clockwork-airbrake", error.class, error.message, error.backtrace[0]]
    
    last_reported_at = Rails.cache.read(exception_key)

    if last_reported_at.blank? || (Time.zone.now - last_reported_at > report_exception_every)
      Airbrake.notify(error)
      Rails.cache.write(exception_key, Time.zone.now)
    end
  end

  every(6.seconds, 'import_blocks_until_done') do
    importer = EthBlockImporter.new

    loop do
      begin
        importer.import_blocks_until_done
      rescue EthBlockImporter::ReorgDetectedError
        Rails.logger.warn 'Reorg detected – reinitialising EthBlockImporter'
        importer = EthBlockImporter.new
        retry
      end

      sleep 6
    end
  end
end
