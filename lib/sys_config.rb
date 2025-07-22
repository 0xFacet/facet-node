module SysConfig
  extend self
  
  FACET_INBOX_ADDRESS = Address20.from_hex("0x00000000000000000000000000000000000face7")
  L2_BLOCK_GAS_LIMIT = Integer(ENV.fetch('L2_BLOCK_GAS_LIMIT', 200_000_000))
  L2_BLOCK_TIME = 12
  
  def block_gas_limit(block)
    if is_first_v2_block?(block)
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
  
  def is_first_v2_block?(block)
    block.number == 1
  end
  
  def is_second_v2_block?(block)
    block.number == 2
  end
end
