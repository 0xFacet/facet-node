module ChainIdManager
  extend self
  include Memery

  MAINNET_CHAIN_ID = 1
  SEPOLIA_CHAIN_ID = 11155111
  HOODI_CHAIN_ID = 13371337

  FACET_MAINNET_CHAIN_ID = 0xface7
  FACET_SEPOLIA_CHAIN_ID = 0xface7a
  FACET_HOODI_CHAIN_ID = 0xface7b

  def current_l2_chain_id
    candidate = l2_chain_id_from_l1_network_name(current_l1_network)
    # according_to_geth = GethDriver.client.call('eth_chainId').to_i(16)
    # unless according_to_geth == candidate
    #   raise "Invalid L2 chain ID: #{candidate} (according to geth: #{according_to_geth})"
    # end
    candidate
  end
  memoize :current_l2_chain_id

  def l2_chain_id_from_l1_network_name(l1_network_name)
    case l1_network_name
    when 'mainnet'
      FACET_MAINNET_CHAIN_ID
    when 'sepolia'
      FACET_SEPOLIA_CHAIN_ID
    when 'hoodi'
      FACET_HOODI_CHAIN_ID
    else
      raise "Unknown L1 network name: #{l1_network_name}"
    end
  end

  def on_sepolia?
    current_l1_network == 'sepolia'
  end

  def on_hoodi?
    current_l1_network == 'hoodi'
  end

  def current_l1_network
    l1_network = ENV.fetch('L1_NETWORK')
    unless ['sepolia', 'mainnet', 'hoodi'].include?(l1_network)
      raise "Invalid L1 network: #{l1_network}"
    end
    l1_network
  end

  def current_l1_chain_id
    case current_l1_network
    when 'sepolia'
      SEPOLIA_CHAIN_ID
    when 'mainnet'
      MAINNET_CHAIN_ID
    when 'hoodi'
      HOODI_CHAIN_ID
    else
      raise "Unknown L1 network: #{current_l1_network}"
    end
  end

  def on_mainnet?
    current_l1_network == 'mainnet'
  end

  def on_testnet?
    !on_mainnet?
  end
end
