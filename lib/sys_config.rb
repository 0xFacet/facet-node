module SysConfig
  extend self
  
  L2_BLOCK_GAS_LIMIT = Integer(ENV.fetch('L2_BLOCK_GAS_LIMIT', 200_000_000))
  L2_BLOCK_TIME = 12
  
  def block_gas_limit(block)
    if block.number == 1
      migration_gas + L2_BLOCK_GAS_LIMIT
    else
      L2_BLOCK_GAS_LIMIT
    end
  end
  
  def l1_genesis_block_number
    ENV.fetch("L1_GENESIS_BLOCK").to_i
  end
  
  def migration_gas
    if current_l1_network == "mainnet"
      3_871_347_580
    else
      3_870_476_472
    end
  end
  
  def current_l1_network
    ChainIdManager.current_l1_network
  end
  
  def genesis_timestamp
    @_genesis_timestamp ||= EthRpcClient.l1.get_block(l1_genesis_block_number)["timestamp"].to_i(16)
  end
  
  def bluebird_fork_block_number
    fork_time = bluebird_fork_time_stamp
    fork_time = genesis_timestamp if fork_time.zero?
    
    delta = fork_time - genesis_timestamp
    raise ArgumentError, "Bluebird fork timestamp (#{fork_time}) must be greater than genesis timestamp (#{genesis_timestamp})" if delta.negative?

    unless (delta % L2_BLOCK_TIME).zero?
      raise ArgumentError, "Bluebird fork timestamp (#{fork_time}) must align with L2 block time of #{L2_BLOCK_TIME} seconds"
    end

    block_num = delta / L2_BLOCK_TIME

    unless block_num.multiple_of?(10_000) || allow_unsafe_bluebird_fork_block_number?
      raise ArgumentError, "Bluebird fork block number (#{block_num}) must be a multiple of 10,000"
    end

    block_num
  end
  
  def timestamp_from_block_number(block_number)
    genesis_timestamp + (Integer(block_number) * L2_BLOCK_TIME)
  end
  
  def bluebird_fork_time_stamp
    if ENV['BLUEBIRD_TIMESTAMP'].present?
      Integer(ENV['BLUEBIRD_TIMESTAMP'])
    elsif ENV['BLUEBIRD_L2_BLOCK'].present?
      SysConfig.timestamp_from_block_number(ENV['BLUEBIRD_L2_BLOCK'])
    else
      raise "BLUEBIRD_TIMESTAMP or BLUEBIRD_L2_BLOCK must be set"
    end
  end
  
  def allow_unsafe_bluebird_fork_block_number?
    ENV['ALLOW_UNSAFE_BLUEBIRD_FORK_BLOCK_NUMBER'] == 'true'
  end
  
  def is_bluebird_fork_block?(block)
    block.number == bluebird_fork_block_number
  end
  
  def is_bluebird?(block)
    number = block.is_a?(Integer) ? block : block.number
    
    number >= bluebird_fork_block_number
  end
end
