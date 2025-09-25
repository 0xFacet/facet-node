unless Rails.env.production?
  require 'dotenv'
  
  Dotenv.load

  case ENV['L1_NETWORK']
  when 'sepolia'
    sepolia_env = Rails.root.join('.env.sepolia')
    Dotenv.load(sepolia_env) if File.exist?(sepolia_env)
  when 'mainnet'
    mainnet_env = Rails.root.join('.env.mainnet')
    Dotenv.load(mainnet_env) if File.exist?(mainnet_env)
  when 'hoodi'
    hoodi_env = Rails.root.join('.env.hoodi')
    Dotenv.load(hoodi_env) if File.exist?(hoodi_env)
  else
    raise "Unknown L1_NETWORK: #{ENV['L1_NETWORK']}"
  end
end
