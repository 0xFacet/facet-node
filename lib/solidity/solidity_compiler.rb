class SolidityCompiler
  def initialize(filename_or_solidity_code)
    if File.exist?(filename_or_solidity_code)
      @solidity_file = filename_or_solidity_code
      @solidity_code = nil
    else
      @solidity_code = filename_or_solidity_code
      @solidity_file = nil
    end
    @contracts = {}
    @current_contract = nil
  end

  class << self
    include Memery

    def compile(filename_or_solidity_code)
      if File.exist?(filename_or_solidity_code)
        last_modified = File.mtime(filename_or_solidity_code).to_i
        memoized_compile(filename_or_solidity_code, last_modified)
      else
        memoized_compile(filename_or_solidity_code)
      end
    end

    private

    def memoized_compile(filename_or_solidity_code, last_modified = nil)
      new(filename_or_solidity_code).get_solidity_bytecode_and_abi
    end
    memoize :memoized_compile
  end

  def self.deploy(file, contract, *constructor_args)
    bytecode = SolidityCompiler.compile(file)[contract]['bytecode']
    abi = SolidityCompiler.compile(file)[contract]['abi']
    
    contract = Eth::Contract.from_bin(name: contract, bin: bytecode, abi: abi)

    encoded_args = contract.parent.function_hash["constructor"].get_call_data(*constructor_args)
    
    deployment_data = bytecode + encoded_args
    
    evm = EVM.new(
      common: Common.stub,
      state_manager: StateManager.new(common: Common.stub),
      # performance_logger: performance_logger,
      # transient_storage: transient_storage,
      # opts_cached: opts_cached
    )
    
    result = evm.run_call(
      gasPrice: 1,
      caller: Address.from_string("0x32768bf8bf25915d43949eb17aa1c794e7d8f8c7"),
      value: 0,
      data: [deployment_data].pack('H*').unpack('C*'),
      gas_limit: 1_000_00000,
    )
  end
  
  def compile_solidity(file_path)
    pragma_version = nil
    File.foreach(file_path) do |line|
      if line =~ /pragma solidity (.+);/
        pragma_version = $1.strip
        break
      end
    end

    raise "Pragma version not found in #{file_path}" unless pragma_version

    # Extract the version number (e.g., from "^0.8.0" to "0.8.0")
    version_match = pragma_version.match(/(\d+\.\d+\.\d+)/)
    raise "Invalid pragma version format in #{file_path}" unless version_match

    version = version_match[1]

    # Set the Solidity version using solc-select
    system("solc-select use #{version}")

    # Compile with optimizer settings
    stdout, stderr, status = Open3.capture3("solc --combined-json abi,bin --optimize --optimize-runs 200 #{file_path}")
    raise "Error running solc: #{stderr}" unless status.success?
  
    # Parse the JSON output
    output = JSON.parse(stdout)
  
    # Extract the contract names, bytecode, and ABI
    contract_data = {}
    output['contracts'].each do |contract_name, contract_info|
      name = contract_name.split(':').last
      contract_data[name] = {
        'bytecode' => contract_info['bin'],
        'abi' => contract_info['abi']
      }
    end
  
    # Return the hash mapping contract names to their bytecode and ABI
    contract_data
  end

  def get_solidity_bytecode_and_abi
    if @solidity_file
      compile_solidity(@solidity_file)
    else
      Tempfile.open(['temp_contract', '.sol']) do |file|
        file.write(@solidity_code)
        file.flush
        compile_solidity(file.path)
      end
    end
  end
end