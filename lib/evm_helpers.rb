module EVMHelpers
  extend self
  include Memery

  def get_contract(contract_path, address)
    contract_name = contract_path.split('/').last
    contract_file = Rails.root.join('contracts', 'src', "#{contract_path}.sol")
    contract_compiled = SolidityCompiler.compile(contract_file)
    contract_abi = contract_compiled[contract_name]['abi']
    Eth::Contract.from_abi(name: contract_name, address: address.to_s, abi: contract_abi)
  end
  
  def compile_contract(contract_path)
    checksum = SolidityCompiler.directory_checksum
    memoized_compile_contract(contract_path, checksum)
  end
  
  def memoized_compile_contract(contract_path, checksum)
    contract_name = contract_path.split('/').last
    contract_path += ".sol" unless contract_path.ends_with?(".sol")
    contract_file = Rails.root.join('contracts', 'src', contract_path)
    
    contract_compiled = SolidityCompiler.compile(contract_file)
    contract_bytecode = contract_compiled[contract_name]['bytecode']
    contract_abi = contract_compiled[contract_name]['abi']
    contract_bin_runtime = contract_compiled[contract_name]['bin_runtime']
    contract = Eth::Contract.from_bin(name: contract_name, bin: contract_bytecode, abi: contract_abi)
    contract.parent.bin_runtime = contract_bin_runtime
    contract.freeze
  end
  memoize :memoized_compile_contract

  def get_deploy_data(contract, constructor_args)
    encoded_constructor_params = contract.parent.function_hash['constructor'].get_call_data(*constructor_args)
    deploy_data = contract.bin + encoded_constructor_params
    deploy_data.freeze
  end
  memoize :get_deploy_data

  def compare_geth_instances(other_rpc_url, geth_rpc_url = ENV.fetch('NON_AUTH_GETH_RPC_URL'))
    geth_client = GethClient.new(geth_rpc_url)
    other_client = GethClient.new(other_rpc_url)

    # Fetch the latest block number from the Geth instance
    latest_geth_block = geth_client.call("eth_getBlockByNumber", ["latest", false])
    latest_geth_block_number = latest_geth_block['number'].to_i(16)

    # Fetch the latest block number from the other database
    latest_other_block = other_client.call("eth_getBlockByNumber", ["latest", false])
    latest_other_block_number = latest_other_block['number'].to_i(16)

    # Determine the smaller of the two block numbers
    max_block_number = [latest_geth_block_number, latest_other_block_number].min

    # Check if the latest common block hash matches
    geth_block = geth_client.call("eth_getBlockByNumber", ["0x" + max_block_number.to_s(16), false])
    geth_hash = geth_block['hash']
    other_block = other_client.call("eth_getBlockByNumber", ["0x" + max_block_number.to_s(16), false])
    other_hash = other_block['hash']

    if geth_hash == other_hash
      puts "Latest common block (#{max_block_number}) hashes match. No discrepancies found."
      return true
    else
      puts "Mismatch found at the latest common block (#{max_block_number}): #{other_hash} != #{geth_hash}"
      puts "Searching for the point of divergence..."
    end

    find_divergence_point(geth_client, other_client, 0, max_block_number)
  end

  def find_divergence_point(geth_client, other_client, start_block, end_block)
    while start_block < end_block
      mid_block = (start_block + end_block) / 2

      geth_block = geth_client.call("eth_getBlockByNumber", ["0x" + mid_block.to_s(16), false])
      geth_hash = geth_block['hash']
      other_block = other_client.call("eth_getBlockByNumber", ["0x" + mid_block.to_s(16), false])
      other_hash = other_block['hash']

      if geth_hash == other_hash
        # Hashes match, divergence point is after this block
        start_block = mid_block + 1
      else
        # Hashes don't match, divergence point is this block or before
        end_block = mid_block
      end
    end

    # At this point, start_block is the first block where hashes differ
    puts "Divergence found at block #{start_block}"
    compare_transactions(geth_client, other_client, start_block, other_hash, geth_hash)
    start_block
  end

  def compare_transactions(geth_client, other_client, block_number, other_block_hash, geth_block_hash)
    # Fetch transactions from the other client
    other_block = other_client.call("eth_getBlockByNumber", ["0x" + block_number.to_s(16), true])
    other_txs = other_block['transactions'].map { |tx| tx['hash'] }

    # Fetch transactions from the Geth instance
    geth_block = geth_client.call("eth_getBlockByNumber", ["0x" + block_number.to_s(16), true])
    geth_txs = geth_block['transactions'].map { |tx| tx['hash'] }

    other_txs.each_with_index do |tx_hash, index|
      next if tx_hash == geth_txs[index]

      puts "Transaction mismatch found at index #{index} in block number #{block_number}: #{tx_hash} != #{geth_txs[index]}"
      puts "Their tx: "
      ap geth_client.call("eth_getTransactionByHash", [geth_txs[index]])
      puts "Our tx: "
      ap other_client.call("eth_getTransactionByHash", [tx_hash])
      return
    end
  end
end
