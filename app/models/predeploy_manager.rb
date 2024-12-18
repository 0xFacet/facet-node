module PredeployManager
  extend self
  include Memery
  include SysConfig
  PREDEPLOY_INFO_PATH = Rails.root.join('config', 'predeploy_info.json')
  SOL_DIR = Rails.root.join('contracts')
  LEGACY_DIR = SOL_DIR.join('src', 'predeploys')
  
  def predeploy_to_local_map
    legacy_dir = Rails.root.join("contracts/src/predeploys")
    map = {}
    
    Dir.glob("#{legacy_dir}/*.sol").each do |file_path|
      filename = File.basename(file_path, ".sol")
  
      if filename.match(/V[a-f0-9]{3}$/i)
        add_to_map(map, LegacyContractArtifact.address_from_suffix(filename), filename)
        
        if is_deployed_by_contract?(filename)
          add_to_map(map, addr_from_name(filename), filename)
        end
      end
    end

    [
      "BaseRegistrar",
      "ExponentialPremiumPriceOracle",
      "L2Resolver",
      "RegistrarController",
      "Registry",
      "ReverseRegistrar",
      "StickerRegistry"
    ].each { |name| add_to_map(map, addr_from_name(name), name) }
    
    add_to_map(map, "0x11110000000000000000000000000000000000c5", "NonExistentContractShim")
    add_to_map(map, "0x22220000000000000000000000000000000000d6", "MigrationManager")
    
    map
  end
  memoize :predeploy_to_local_map
  
  def add_to_map(map, address, name)
    if map[address].present?
      raise "Address collision detected! #{name} collides with #{map[address]} at #{address}"
    end
    map[address] = name
  end
  
  def predeploy_info
    parsed = JSON.parse(File.read(PREDEPLOY_INFO_PATH))
    
    result = {}
    parsed.each do |contract_name, info|
      contract = Eth::Contract.from_bin(
        name: info.fetch('name'),
        bin: info.fetch('bin'),
        abi: info.fetch('abi'),
      )
      
      addresses = Array.wrap(info['address'])
      addresses.each do |address|
        result[address] = contract.dup.tap { |c| c.address = address }.freeze
      end
      
      result[contract_name] = contract.freeze
    end
    
    result.freeze
  end
  memoize :predeploy_info
  
  def get_contract_from_predeploy_info(address: nil, name: nil)
    predeploy_info.fetch(address || name)
  end
  memoize :get_contract_from_predeploy_info
  
  def local_from_predeploy(address)
    name = predeploy_to_local_map.fetch(address)
    "predeploys/#{name}"
  end
  memoize :local_from_predeploy
  
  def generate_alloc_for_genesis(l1_network_name:, use_dump: false)
    genesis_test = Rails.root.join('contracts', 'facet-local-genesis-allocs.json')
    our_allocs = JSON.parse(IO.read(genesis_test))
    
    optimism_file = Rails.root.join('config', "facet-optimism-genesis-allocs-#{l1_network_name}.json")
    unless File.exist?(optimism_file)
      raise "Optimism genesis allocs file not found: #{optimism_file}"
    end
    
    optimism_allocs = JSON.parse(File.read(optimism_file))
    
    duplicates = our_allocs.keys & optimism_allocs.keys
    if duplicates.any?
      raise KeyError, "Duplicate keys found: #{duplicates.join(', ')}"
    end
    
    merged = optimism_allocs.merge(our_allocs)
    
    if use_dump
      dump_dir = ENV.fetch('L2_GETH_DUMP_PATH')
      
      dump = processed_geth_dump(dump_dir)
      
      dump.each do |address, dump_data|
        if merged[address]
          merged[address]['storage'] = dump_data['storage']
        else
          merged[address] = dump_data
        end
      end
    end
    
    unless in_migration_mode?
      merged.delete('0x11110000000000000000000000000000000000c5')
    end
    
    merged.sort_by { |key, _| key.downcase }.to_h
  end
  
  def generate_predeploy_info_json
    foundry_file = Rails.root.join('contracts', 'predeploy-contracts.json')
    foundry_parsed = JSON.parse(File.read(foundry_file))  
    
    foundry_address_to_name = foundry_parsed.each_with_object({}) do |contract, hash|
      hash[contract['addr'].downcase] = contract['name']
    end
    
    predeploy_info = {}
    
    foundry_address_to_name.each do |address, contract_name|
      contract = EVMHelpers.compile_contract("predeploys/#{contract_name}")
      predeploy_info[contract_name] ||= {
        name: contract.name,
        address: [],
        abi: contract.abi,
        bin: contract.bin,
      }
      predeploy_info[contract_name][:address] << address
    end
    
    proxy_contract = EVMHelpers.compile_contract("libraries/ERC1967Proxy")
    predeploy_info['ERC1967Proxy'] = {
      name: proxy_contract.name,
      abi: proxy_contract.abi,
      bin: proxy_contract.bin,
    }
    
    File.write(PREDEPLOY_INFO_PATH, JSON.pretty_generate(predeploy_info))
    puts "Generated predeploy_info.json"
  end
  
  def generate_full_genesis_json(l1_network_name:, l1_genesis_block_number:, use_dump:)
    config = {
      chainId: ChainIdManager.l2_chain_id_from_l1_network_name(l1_network_name),
      homesteadBlock: 0,
      eip150Block: 0,
      eip155Block: 0,
      eip158Block: 0,
      byzantiumBlock: 0,
      constantinopleBlock: 0,
      petersburgBlock: 0,
      istanbulBlock: 0,
      muirGlacierBlock: 0,
      berlinBlock: 0,
      londonBlock: 0,
      mergeForkBlock: 0,
      mergeNetsplitBlock: 0,
      shanghaiTime: 0,
      cancunTime: cancun_timestamp(l1_network_name),
      terminalTotalDifficulty: 0,
      terminalTotalDifficultyPassed: true,
      bedrockBlock: 0,
      regolithTime: 0,
      canyonTime: 0,
      ecotoneTime: 0,
      fjordTime: 0,
      deltaTime: 0,
      optimism: {
        eip1559Elasticity: 2,
        eip1559Denominator: 8,
        eip1559DenominatorCanyon: 8
      }
    }
    
    timestamp, mix_hash = get_timestamp_and_mix_hash(l1_genesis_block_number)
    
    {
      config: config,
      timestamp: "0x#{timestamp.to_s(16)}",
      extraData: "0xb1bdb91f010c154dd04e5c11a6298e91472c27a347b770684981873a6408c11c",
      gasLimit: "0x#{SysConfig::L2_BLOCK_GAS_LIMIT.to_s(16)}",
      difficulty: "0x0",
      mixHash: mix_hash,
      alloc: generate_alloc_for_genesis(l1_network_name: l1_network_name, use_dump: use_dump)
    }
  end
  
  def get_timestamp_and_mix_hash(l1_block_number)
    l1_block_result = l1_rpc_client.get_block(l1_block_number)
    timestamp = l1_block_result['timestamp'].to_i(16)
    mix_hash = l1_block_result['mixHash']
    [timestamp, mix_hash, l1_block_result['timestamp']]
  end
  
  def cancun_timestamp(l1_network_name)
    l1_network_name == "mainnet" ? 1710338135 : 1706655072
  end
  
  def write_genesis_json(clear_cache: true, use_dump: ENV["USE_DUMP"] == 'true')
    Rails.cache.clear if clear_cache
    MemeryExtensions.clear_all_caches!
    SolidityCompiler.reset_checksum
    SolidityCompiler.compile_all_legacy_files
    
    foundry_root = Rails.root.join('contracts')
    system("cd #{foundry_root} && forge script script/L2Genesis.s.sol")
    
    geth_dir = ENV.fetch('LOCAL_GETH_DIR')
    
    network = ChainIdManager.current_l1_network
    
    filename = network == "mainnet" ? "facet-mainnet.json" : "facet-sepolia.json"
    facet_chain_dir = File.join(geth_dir, 'facet-chain')
    FileUtils.mkdir_p(facet_chain_dir) unless File.directory?(facet_chain_dir)
    genesis_path = File.join(facet_chain_dir, filename)

    # Generate the genesis data for the specific network
    genesis_data = generate_full_genesis_json(
      l1_network_name: network,
      l1_genesis_block_number: SysConfig.l1_genesis_block_number,
      use_dump: use_dump
    )

    # Write the data to the appropriate file
    File.write(genesis_path, JSON.pretty_generate(genesis_data))
    
    puts "Generated #{filename}"
    
    generate_predeploy_info_json
  end
  
  def l1_rpc_client
    @_l1_rpc_client ||= EthRpcClient.new(ENV.fetch('L1_RPC_URL'))
  end
  
  def processed_geth_dump(geth_dir = ENV.fetch('LOCAL_GETH_DIR'))
    raw_dump = GethDriver.get_state_dump(geth_dir)

    processed_alloc = {}

    raw_dump.each do |address, entry|
      next if entry['code'] == '0x'

      nonce = [entry['nonce'], 1].min
      nonce_hex = "0x" + nonce.to_s(16)

      processed_alloc[address] = {
        'balance' => '0x0',
        'nonce' => nonce_hex,
        'code' => entry['code'],
        'storage' => entry['storage']
      }
    end

    processed_alloc
  end
  
  def verify_contracts(rpc_url = "http://localhost:8545", blockscout_url = "http://localhost/api/")
    foundry_file = Rails.root.join('contracts', 'predeploy-contracts.json')
    foundry_parsed = JSON.parse(File.read(foundry_file))  
    
    foundry_parsed.each do |contract|
      address = contract['addr']
      contract_name = contract['name']
      
      next if address == "0x11110000000000000000000000000000000000c5"
      
      sol_file = SOL_DIR.join('src', 'predeploys').join("#{contract_name}.sol")
      
      if sol_file.exist?
        command = [
          "cd #{SOL_DIR} &&",  # Change to the Solidity directory
          "forge verify-contract",
          "--verifier blockscout",
          "--compiler-version 0.8.24",
          "--via-ir",
          "--optimizer-runs 200",
          "--verifier-url #{blockscout_url}",
          # "--watch",
          "--rpc-url #{rpc_url}",
          address,
          "src/predeploys/#{contract_name}.sol:#{contract_name}",
        ].join(" ")
        puts command
        puts "Verifying #{contract_name} at #{address}..."
        system(command)
        puts "Verification complete for #{contract_name}"
        puts "----------------------------------------"
      else
        puts "Skipping #{contract_name}: Solidity file not found at #{sol_file}"
      end
    end
  
    puts "All contracts processed."
  end
  
  def addr_from_name(name)
    Eth::Util.keccak256(name).last(20).bytes_to_hex
  end
  
  def is_deployed_by_contract?(contract_name)
    contract_name.start_with?("ERC20BridgeV") ||
    contract_name.start_with?("FacetBuddyV") ||
    contract_name.start_with?("FacetSwapPairV")
  end
end
