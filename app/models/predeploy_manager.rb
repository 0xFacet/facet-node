module PredeployManager
  extend self
  include Memery
  
  PREDEPLOY_INFO_PATH = Rails.root.join('config', 'predeploy_info.json')
  
  class LocalContract < T::Struct
    const :name, String
    const :path, Pathname
  end
  
  def predeploy_to_local_map
    legacy_dir = Rails.root.join("lib/solidity/legacy")
    predeploy_dir = Rails.root.join("lib/solidity/predeploy")
    map = {}
    
    Dir.glob("#{legacy_dir}/*.sol").each do |file_path|
      filename = File.basename(file_path, ".sol")
  
      if filename.match(/V[a-f0-9]{3}$/i)
        begin
          address = LegacyContractArtifact.address_from_suffix(filename)
        rescue LegacyContractArtifact::AmbiguousSuffixError => e
          next if ChainIdManager.on_testnet?
          raise
        end
        
        map[address] = LocalContract.new(name: filename, path: Pathname.new(file_path))
        
        deployed_by_contract_prefixes = %w(ERC20Bridge FacetBuddy FacetSwapPair)
        
        if deployed_by_contract_prefixes.any? { |prefix| filename.match(/^#{prefix}V[a-f0-9]{3}$/i) }
          contract = EVMHelpers.compile_contract(legacy_dir.join(file_path))
        
          c = LocalContract.new(name: filename, path: Pathname.new(file_path))
          map["0x" + contract.parent.init_code_hash.last(40)] = c
        end
      end
    end
    
    map["0x00000000000000000000000000000000000000c5"] = LocalContract.new(name: "NonExistentContractShim", path: predeploy_dir.join("NonExistentContractShim.sol"))
    map["0x4200000000000000000000000000000000000015"] = LocalContract.new(name: "L1Block", path: predeploy_dir.join("L1Block.sol"))
    
    map
  end
  memoize :predeploy_to_local_map
  
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
    predeploy_to_local_map.fetch(address&.downcase)
  end
  memoize :local_from_predeploy

  def get_code(address)
    local = local_from_predeploy(address)
    contract = EVMHelpers.compile_contract(local.path)
    raise unless contract.parent.bin_runtime
    unless is_valid_hex?("0x" + contract.parent.bin_runtime)
      binding.irb
      raise
    end
    contract.parent.bin_runtime
  end
  
  def is_valid_hex?(hex)
    hex.match?(/^0x[0-9a-fA-F]+$/) && hex.length.even?
  end
  
  def generate_alloc_for_genesis
    initializable_slot = "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffbf601132"
    
    max_uint64 = 2 ** 64 - 1

    result = max_uint64 << 1

    hex_result = result.zpad(32).bytes_to_hex
    
    predeploy_to_local_map.map do |address, _|
      [
        address,
        {
          "code" => "0x" + get_code(address),
          "balance" => 0,
          "storage" => {
            initializable_slot => hex_result
          }
        }
      ]
    end.to_h
  end
  
  def generate_predeploy_info_json
    predeploy_info = {}
    
    predeploy_to_local_map.each do |address, contract_struct|
      contract = EVMHelpers.compile_contract(contract_struct.path)
      predeploy_info[contract_struct.name] ||= {
        name: contract.name,
        address: [],
        abi: contract.abi,
        bin: contract.bin,
      }
      predeploy_info[contract_struct.name][:address] << address
    end
    
    proxy_contract = EVMHelpers.compile_contract("legacy/ERC1967Proxy")
    predeploy_info['ERC1967Proxy'] = {
      name: proxy_contract.name,
      abi: proxy_contract.abi,
      bin: proxy_contract.bin,
    }

    File.write(PREDEPLOY_INFO_PATH, JSON.pretty_generate(predeploy_info))
    puts "Generated predeploy_info.json"
  end
  
  def generate_full_genesis_json(l1_network_name)
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
      deltaTime: 0,
      optimism: {
        eip1559Elasticity: 2,
        eip1559Denominator: 8,
        eip1559DenominatorCanyon: 8
      }
    }
    
    timestamp = l1_network_name == "mainnet" ? 1701353099 : 1706742588
    mix_hash = l1_network_name == "mainnet" ?
      "0xf9202de594a3697695c54a4ee8a392f686ca1fc26337eb821e4ca6deb71b2dd7" :
      "0xc4b4bbd867f5566c344e8ba74372ca493c91c00bb3e10f85a45bd9e89344a977"
    
    {
      config: config,
      timestamp: "0x#{timestamp.to_s(16)}",
      extraData: "Think outside the block".ljust(32).bytes_to_hex,
      gasLimit: "0x#{300e6.to_i.to_s(16)}",
      difficulty: "0x0",
      mixHash: mix_hash,
      alloc: generate_alloc_for_genesis
    }
  end
  
  def cancun_timestamp(l1_network_name)
    l1_network_name == "mainnet" ? 1710338135 : 1706655072
  end
  
  def write_genesis_json(clear_cache: true)
    Rails.cache.clear if clear_cache
    MemeryExtensions.clear_all_caches!
    SolidityCompiler.reset_checksum
    SolidityCompiler.compile_all_legacy_files
    
    geth_dir = ENV.fetch('LOCAL_GETH_DIR')
    
    ["mainnet", "sepolia"].each do |network|
      filename = network == "mainnet" ? "facet-mainnet.json" : "facet-sepolia.json"
      facet_chain_dir = File.join(geth_dir, 'facet-chain')
      FileUtils.mkdir_p(facet_chain_dir) unless File.directory?(facet_chain_dir)
      genesis_path = File.join(facet_chain_dir, filename)

      # Generate the genesis data for the specific network
      genesis_data = generate_full_genesis_json(network)

      # Write the data to the appropriate file
      File.write(genesis_path, JSON.pretty_generate(genesis_data))
      
      puts "Generated #{filename}"
    end
    
    generate_predeploy_info_json
  end
end
