module EVMHelpers
  extend self
  include Memery

  def get_contract(contract_path, address)
    contract_name = contract_path.split('/').last
    contract_file = Rails.root.join('lib', 'solidity', "#{contract_path}.sol")
    contract_compiled = SolidityCompiler.compile(contract_file)
    contract_abi = contract_compiled[contract_name]['abi']
    Eth::Contract.from_abi(name: contract_name, address: address.to_s, abi: contract_abi)
  end
  
  def compile_contract(contract_path)
    checksum = SolidityCompiler.directory_checksum
    memoized_compile_contract(contract_path, checksum)
  end
  
  def memoized_compile_contract(contract_path, checksum)
    contract_name = File.basename(contract_path, ".sol")
    
    # Check if the path is already absolute
    if Pathname.new(contract_path).absolute?
      contract_file = Pathname.new(contract_path)
    else
      # If it's not absolute, assume it's relative to 'lib/solidity'
      contract_file = Rails.root.join('lib', 'solidity', contract_path)
    end
    
    contract_file += ".sol" unless contract_file.to_s.ends_with?(".sol")
    
    raise "Contract file not found: #{contract_file}" unless File.exist?(contract_file)
    
    contract_compiled = SolidityCompiler.compile(contract_file)
    contract_bytecode = contract_compiled[contract_name]['bytecode']
    contract_abi = contract_compiled[contract_name]['abi']
    contract_bin_runtime = contract_compiled[contract_name]['bin_runtime']
    contract = Eth::Contract.from_bin(name: contract_name, bin: contract_bytecode, abi: contract_abi)
    contract.parent.bin_runtime = contract_bin_runtime
    contract.freeze
  rescue => e
    binding.irb unless ChainIdManager.on_sepolia?
    raise
  end
  memoize :memoized_compile_contract

  def get_deploy_data(contract, constructor_args)
    encoded_constructor_params = contract.parent.function_hash['constructor'].get_call_data(*constructor_args)
    deploy_data = contract.bin + encoded_constructor_params
    deploy_data.freeze
  rescue => e
    binding.irb
    raise
  end
  memoize :get_deploy_data
end
