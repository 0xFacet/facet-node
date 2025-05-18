class EthBlockImporter
  include SysConfig
  include Memery
  
  # Raised when the next block to import is not yet available on L1
  class BlockNotReadyToImportError < StandardError; end
  # Raised when a re-org is detected (parent hash mismatch)
  class ReorgDetectedError < StandardError; end
  
  attr_accessor :l1_rpc_results, :facet_block_cache, :ethereum_client, :eth_block_cache, :geth_driver
  
  def initialize
    @l1_rpc_results = {}
    @facet_block_cache = {}
    @eth_block_cache = {}
    
    @ethereum_client ||= EthRpcClient.new(ENV.fetch('L1_RPC_URL'))
    
    @geth_driver = GethDriver
    
    MemeryExtensions.clear_all_caches!
    
    set_eth_block_starting_points
    populate_facet_block_cache
  end
  
  def current_max_facet_block_number
    facet_block_cache.keys.max
  end
  
  def current_max_eth_block_number
    eth_block_cache.keys.max
  end
  
  def current_max_eth_block
    eth_block_cache[current_max_eth_block_number]
  end
  
  def populate_facet_block_cache
    epochs_found = 0
    current_block_number = current_max_facet_block_number - 1
    
    while epochs_found < 64 && current_block_number >= 0
      hex_block_number = "0x#{current_block_number.to_s(16)}"
      block_data = geth_driver.client.call("eth_getBlockByNumber", [hex_block_number, false])
      current_block = FacetBlock.from_rpc_result(block_data)
      
      l1_attributes = GethDriver.client.get_l1_attributes(current_block.number)
      current_block.assign_l1_attributes(l1_attributes)
      
      facet_block_cache[current_block.number] = current_block

      if current_block.sequence_number == 0 || current_block_number == 0
        epochs_found += 1
        logger.info "Found epoch #{epochs_found} at block #{current_block_number}"
      end

      current_block_number -= 1
    end

    logger.info "Populated facet block cache with #{facet_block_cache.size} blocks from #{epochs_found} epochs"
  end
  
  def logger
    Rails.logger
  end
  
  def blocks_behind
    (current_block_number - next_block_to_import) + 1
  end
  
  def current_block_number
    ethereum_client.get_block_number
  end
  memoize :current_block_number, ttl: 12.seconds
  
  def import_batch_size
    [blocks_behind, ENV.fetch('BLOCK_IMPORT_BATCH_SIZE', 2).to_i].min
  end
  
  def find_first_l2_block_in_epoch(l2_block_number_candidate)
    l1_attributes = GethDriver.client.get_l1_attributes(l2_block_number_candidate)
    
    if l1_attributes[:sequence_number] == 0
      return l2_block_number_candidate
    end
    
    return find_first_l2_block_in_epoch(l2_block_number_candidate - 1)
  end
  
  def set_eth_block_starting_points
    latest_l2_block = GethDriver.client.call("eth_getBlockByNumber", ["latest", false])
    latest_l2_block_number = latest_l2_block['number'].to_i(16)
    
    if latest_l2_block_number == 0
      l1_block = EthRpcClient.l1.get_block(SysConfig.l1_genesis_block_number)
      eth_block = EthBlock.from_rpc_result(l1_block)
      facet_block = FacetBlock.from_rpc_result(latest_l2_block)
      l1_attributes = GethDriver.client.get_l1_attributes(latest_l2_block_number)
      
      facet_block.assign_l1_attributes(l1_attributes)
      
      facet_block_cache[0] = facet_block
      eth_block_cache[eth_block.number] = eth_block
      
      return [eth_block.number, 0]
    end
    
    l1_attributes = GethDriver.client.get_l1_attributes(latest_l2_block_number)
    
    l1_candidate = l1_attributes[:number]
    l2_candidate = latest_l2_block_number
    
    max_iterations = 1000
    iterations = 0
    
    while iterations < max_iterations
      l2_candidate = find_first_l2_block_in_epoch(l2_candidate)
      
      l1_result = ethereum_client.get_block(l1_candidate)
      l1_hash = Hash32.from_hex(l1_result['hash'])
      
      l1_attributes = GethDriver.client.get_l1_attributes(l2_candidate)
      
      l2_block = GethDriver.client.call("eth_getBlockByNumber", ["0x#{l2_candidate.to_s(16)}", false])
      
      if l1_hash == l1_attributes[:hash] && l1_attributes[:number] == l1_candidate
        eth_block_cache[l1_candidate] = EthBlock.from_rpc_result(l1_result)
        
        facet_block = FacetBlock.from_rpc_result(l2_block)
        facet_block.assign_l1_attributes(l1_attributes)
        
        facet_block_cache[l2_candidate] = facet_block
        return [l1_candidate, l2_candidate]
      else
        logger.info "Mismatch on block #{l2_candidate}: #{l1_hash.to_hex} != #{l1_attributes[:hash].to_hex}, decrementing"
        
        l2_candidate -= 1
        l1_candidate -= 1
      end
      
      iterations += 1
    end
    
    raise "No starting block found after #{max_iterations} iterations"
  end
  
  def import_blocks_until_done
    MemeryExtensions.clear_all_caches!
    
    loop do
      begin
        block_numbers = next_blocks_to_import(import_batch_size)
        
        if block_numbers.blank?
          raise BlockNotReadyToImportError.new("Block not ready")
        end
        
        populate_l1_rpc_results(block_numbers)
        
        import_blocks(block_numbers)
      rescue BlockNotReadyToImportError => e
        puts "#{e.message}. Stopping import."
        break
      end
    end
  end
  
  def populate_l1_rpc_results(block_numbers)
    next_start_block = block_numbers.last + 1
    next_block_numbers = (next_start_block...(next_start_block + import_batch_size * 2)).to_a
    
    blocks_to_import = block_numbers
    
    if blocks_behind > 1
      blocks_to_import += next_block_numbers.select do |num|
        num <= current_block_number
      end
    end
    
    blocks_to_import -= l1_rpc_results.keys
    
    l1_rpc_results.reverse_merge!(get_blocks_promises(blocks_to_import))
  end
  
  def get_blocks_promises(block_numbers)
    block_numbers.map do |block_number|
      block_promise = Concurrent::Promise.execute do
         ethereum_client.get_block(block_number, true)
      end
      
      receipt_promise = Concurrent::Promise.execute do
        ethereum_client.get_transaction_receipts(block_number)
      end
      
      [block_number, {
        block: block_promise,
        receipts: receipt_promise
      }.with_indifferent_access]
    end.to_h
  end
  
  def fetch_block_from_cache(block_number)
    block_number = [block_number, 0].max
    
    facet_block_cache.fetch(block_number)
  end
  
  def prune_caches
    eth_block_threshold = current_max_eth_block_number - 65
  
    # Remove old entries from eth_block_cache
    eth_block_cache.delete_if { |number, _| number < eth_block_threshold }
  
    # Find the oldest Ethereum block number we want to keep
    oldest_eth_block_to_keep = eth_block_cache.keys.min
  
    # Remove old entries from facet_block_cache based on Ethereum block number
    facet_block_cache.delete_if do |_, facet_block|
      facet_block.eth_block_number < oldest_eth_block_to_keep
    end
  end
  
  def current_facet_block(type)
    case type
    when :head
      fetch_block_from_cache(current_max_facet_block_number)
    when :safe
      find_block_by_epoch_offset(32)
    when :finalized
      find_block_by_epoch_offset(64)
    else
      raise ArgumentError, "Invalid block type: #{type}"
    end
  end
    
  def find_block_by_epoch_offset(offset)
    current_eth_block_number = current_facet_head_block.eth_block_number
    target_eth_block_number = current_eth_block_number - (offset - 1)

    matching_block = facet_block_cache.values
      .select { |block| block.eth_block_number <= target_eth_block_number }
      .max_by(&:number)

    matching_block || oldest_known_facet_block
  end
  
  def oldest_known_facet_block
    facet_block_cache.values.min_by(&:number)
  end
  
  def current_facet_head_block
    current_facet_block(:head)
  end
  
  def current_facet_safe_block
    current_facet_block(:safe)
  end
  
  def current_facet_finalized_block
    current_facet_block(:finalized)
  end
  
  def import_blocks(block_numbers)
    puts "Block Importer: importing blocks #{block_numbers.join(', ')}"
    start = Time.current
    
    block_responses = l1_rpc_results.select do |block_number, _|
      block_numbers.include?(block_number)
    end.to_h.transform_values do |hsh|
      hsh.transform_values(&:value!)
    end
  
    l1_rpc_results.reject! { |block_number, _| block_responses.key?(block_number) }
    
    eth_blocks = []
    facet_blocks = []
    res = []
    
    block_numbers.each.with_index do |block_number, index|
      block_response = block_responses[block_number]
      
      block_result = block_response['block']
      receipt_result = block_response['receipts']
      
      parent_eth_block = eth_block_cache[block_number - 1]
      
      if parent_eth_block && parent_eth_block.block_hash != Hash32.from_hex(block_result['parentHash'])
        logger.info "Reorg detected at block #{block_number}"
        raise ReorgDetectedError
      end
      
      eth_block = EthBlock.from_rpc_result(block_result)

      facet_block = FacetBlock.from_eth_block(eth_block)
      
      facet_txs = EthTransaction.facet_txs_from_rpc_results(block_result, receipt_result)
      
      facet_txs.each do |facet_tx|
        facet_tx.facet_block = facet_block
      end
      
      imported_facet_blocks = propose_facet_block(
        facet_block: facet_block,
        facet_txs: facet_txs
      )
      
      imported_facet_blocks.each do |facet_block|
        facet_block_cache[facet_block.number] = facet_block
      end
      
      eth_block_cache[eth_block.number] = eth_block
      
      prune_caches
      
      facet_blocks.concat(imported_facet_blocks)
      eth_blocks << eth_block
      
      res << OpenStruct.new(
        facet_block: imported_facet_blocks.last,
        transactions_imported: imported_facet_blocks.last.facet_transactions.length
      )
    end
  
    elapsed_time = Time.current - start
  
    blocks = res.map(&:facet_block)
    total_gas = blocks.sum(&:gas_used)
    total_transactions = res.sum(&:transactions_imported)
    blocks_per_second = (blocks.length / elapsed_time).round(2)
    transactions_per_second = (total_transactions / elapsed_time).round(2)
    total_gas_millions = (total_gas / 1_000_000.0).round(2)
    average_gas_per_block_millions = (total_gas / blocks.length / 1_000_000.0).round(2)
    gas_per_second_millions = (total_gas / elapsed_time / 1_000_000.0).round(2)
  
    logger.info "Time elapsed: #{elapsed_time.round(2)} s"
    logger.info "Imported #{block_numbers.length} blocks. #{blocks_per_second} blocks / s"
    logger.info "Imported #{total_transactions} transactions (#{transactions_per_second} / s)"
    logger.info "Total gas used: #{total_gas_millions} million (avg: #{average_gas_per_block_millions} million / block)"
    logger.info "Gas per second: #{gas_per_second_millions} million / s"
  
    [facet_blocks, eth_blocks]
  end
  
  def import_next_block
    block_number = next_block_to_import
    
    populate_l1_rpc_results([block_number])
    
    import_blocks([block_number])
  end
  
  def next_block_to_import
    next_blocks_to_import(1).first
  end
  
  def next_blocks_to_import(n)
    max_imported_block = current_max_eth_block_number
    
    start_block = max_imported_block + 1
    
    (start_block...(start_block + n)).to_a
  end
  
  def propose_facet_block(facet_block:, facet_txs:)
    geth_driver.propose_block(
      transactions: facet_txs,
      new_facet_block: facet_block,
      head_block: current_facet_head_block,
      safe_block: current_facet_safe_block,
      finalized_block: current_facet_finalized_block
    )
  end
  
  def geth_driver
    @geth_driver
  end
end
