# Registry for managing priority poster authorization
# Determines who can post priority batches for each L1 block
class PriorityRegistry
  include Singleton
  
  attr_accessor :config
  
  def initialize
    @config = load_config
  end
  
  # Get the authorized signer for a given L1 block number
  # Returns Address20 or nil if no signer is authorized
  def authorized_signer(l1_block_number)
    return nil unless SysConfig.facet_batch_v2_enabled?
    
    case config[:mode]
    when 'static'
      # Single static address for all blocks
      config[:static_address] ? Address20.from_hex(config[:static_address]) : nil
      
    when 'rotation'
      # Simple rotation between multiple addresses
      return nil unless config[:rotation_addresses]&.any?
      
      addresses = config[:rotation_addresses]
      period = config[:rotation_period] || 100  # blocks per rotation
      
      index = (l1_block_number / period) % addresses.length
      Address20.from_hex(addresses[index])
      
    when 'mapping'
      # Explicit block number to address mapping
      return nil unless config[:block_mapping]
      
      # Find the entry with highest block number <= l1_block_number
      applicable = config[:block_mapping]
        .select { |entry| entry[:from_block] <= l1_block_number }
        .max_by { |entry| entry[:from_block] }
      
      applicable ? Address20.from_hex(applicable[:address]) : nil
      
    when 'disabled'
      # No priority poster (all batches are forced)
      nil
      
    else
      # Default to ENV variable for PoC
      ENV['PRIORITY_SIGNER_ADDRESS'] ? Address20.from_hex(ENV['PRIORITY_SIGNER_ADDRESS']) : nil
    end
  rescue => e
    Rails.logger.error "Failed to get authorized signer for block #{l1_block_number}: #{e.message}"
    nil
  end
  
  # Update configuration (for testing/admin purposes)
  def update_config(new_config)
    @config = new_config
  end
  
  private
  
  def load_config
    # Load from environment or config file
    if ENV['PRIORITY_REGISTRY_CONFIG']
      JSON.parse(ENV['PRIORITY_REGISTRY_CONFIG']).with_indifferent_access
    elsif File.exist?(config_file_path)
      JSON.parse(File.read(config_file_path)).with_indifferent_access
    else
      default_config
    end
  rescue => e
    Rails.logger.error "Failed to load priority registry config: #{e.message}"
    default_config
  end
  
  def config_file_path
    Rails.root.join('config', 'priority_registry.json')
  end
  
  def default_config
    {
      mode: ENV['PRIORITY_REGISTRY_MODE'] || 'env',
      static_address: ENV['PRIORITY_SIGNER_ADDRESS']
    }
  end
end