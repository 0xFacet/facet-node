class EthBlockImporter
  include SysConfig
  include Memery
  
  # Raised when the next block to import is not yet available on L1
  class BlockNotReadyToImportError < StandardError; end
  # Raised when a re-org is detected (parent hash mismatch)
  class ReorgDetectedError < StandardError; end
  
  attr_accessor :facet_block_cache, :ethereum_client, :eth_block_cache, :geth_driver, :prefetcher, :logger
  
  def initialize
    @facet_block_cache = {}
    @eth_block_cache = {}
    
    @ethereum_client ||= EthRpcClient.new(ENV.fetch('L1_RPC_URL'))
    
    @geth_driver = GethDriver
    
    @logger = Rails.logger
    
    MemeryExtensions.clear_all_caches!
    
    set_eth_block_starting_points
    populate_facet_block_cache
    
    @prefetcher = L1RpcPrefetcher.new(ethereum_client: @ethereum_client)
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
  
  def blocks_behind
    (current_block_number - next_block_to_import) + 1
  end
  
  def current_block_number
    ethereum_client.get_block_number
  end
  memoize :current_block_number, ttl: 12.seconds

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
    ImportProfiler.reset if ImportProfiler.enabled?

    # Initialize stats tracking
    stats_start_time = Time.current
    stats_start_block = current_max_eth_block_number
    blocks_imported_count = 0
    total_gas_used = 0
    total_transactions = 0
    imported_l2_blocks = []

    # Track timing for recent batch calculations
    recent_batch_start_time = Time.current

    loop do
      begin
        block_number = next_block_to_import

        if block_number.nil?
          raise BlockNotReadyToImportError.new("Block not ready")
        end

        l2_blocks, l1_blocks = import_single_block(block_number)
        blocks_imported_count += 1

        # Collect stats from imported L2 blocks
        if l2_blocks.any?
          imported_l2_blocks.concat(l2_blocks)
          l2_blocks.each do |l2_block|
            total_gas_used += l2_block.gas_used if l2_block.gas_used
            total_transactions += l2_block.facet_transactions.length if l2_block.facet_transactions
          end
        end

        # Report stats every 25 blocks
        if blocks_imported_count % 25 == 0
          recent_batch_time = Time.current - recent_batch_start_time
          report_import_stats(
            blocks_imported_count: blocks_imported_count,
            stats_start_time: stats_start_time,
            stats_start_block: stats_start_block,
            total_gas_used: total_gas_used,
            total_transactions: total_transactions,
            imported_l2_blocks: imported_l2_blocks,
            recent_batch_time: recent_batch_time
          )
          # Reset recent batch timer
          recent_batch_start_time = Time.current
        end

      rescue BlockNotReadyToImportError => e
        puts "#{e.message}. Stopping import."
        break
      rescue ReorgDetectedError => e
        logger.error "Reorg detected: #{e.message}"
        raise e
      end
    end
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
    
    # Also prune the prefetcher cache
    prefetcher.clear_older_than(oldest_eth_block_to_keep)
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
  
  def import_single_block(block_number)
    ImportProfiler.start('import_single_block')
    start = Time.current

    # Fetch block data from prefetcher
    ImportProfiler.start('prefetcher_fetch')
    response = prefetcher.fetch(block_number)
    ImportProfiler.stop('prefetcher_fetch')

    # Handle cancellation, fetch failure, or block not ready
    if response.nil?
      raise BlockNotReadyToImportError.new("Block #{block_number} fetch was cancelled or failed")
    end

    if response[:error] == :not_ready
      raise BlockNotReadyToImportError.new("Block #{block_number} not yet available on L1")
    end

    # Extract data from prefetcher response
    eth_block = response[:eth_block]
    facet_block = response[:facet_block]
    facet_txs = response[:facet_txs]

    facet_txs.each do |facet_tx|
      facet_tx.facet_block = facet_block
    end

    # Check for reorg by validating parent hash
    parent_eth_block = eth_block_cache[block_number - 1]
    if parent_eth_block && parent_eth_block.block_hash != eth_block.parent_hash
      logger.error "Reorg detected at block #{block_number}"
      raise ReorgDetectedError.new("Parent hash mismatch at block #{block_number}")
    end

    # Import the L2 block(s)
    ImportProfiler.start('propose_facet_block')
    imported_facet_blocks = propose_facet_block(
      facet_block: facet_block,
      facet_txs: facet_txs
    )
    ImportProfiler.stop('propose_facet_block')

    logger.debug "Block #{block_number}: Found #{facet_txs.length} facet txs, created #{imported_facet_blocks.length} L2 blocks"

    # Update caches
    imported_facet_blocks.each do |fb|
      facet_block_cache[fb.number] = fb
    end
    eth_block_cache[eth_block.number] = eth_block
    prune_caches

    ImportProfiler.stop('import_single_block')
    [imported_facet_blocks, [eth_block]]
  end

  # Thin wrapper for compatibility with specs that use import_blocks directly
  def import_blocks(block_numbers)
    all_facet_blocks = []
    all_eth_blocks = []

    block_numbers.each do |block_number|
      facet_blocks, eth_blocks = import_single_block(block_number)
      all_facet_blocks.concat(facet_blocks)
      all_eth_blocks.concat(eth_blocks)
    end

    [all_facet_blocks, all_eth_blocks]
  end
  
  def import_next_block
    block_number = next_block_to_import

    prefetcher.ensure_prefetched(block_number)

    import_single_block(block_number)
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
  
  def shutdown
    @prefetcher&.shutdown
  end

  def report_import_stats(blocks_imported_count:, stats_start_time:, stats_start_block:,
                         total_gas_used:, total_transactions:, imported_l2_blocks:, recent_batch_time:)
    elapsed_time = Time.current - stats_start_time
    current_block = current_max_eth_block_number

    # Calculate cumulative metrics (entire session)
    cumulative_blocks_per_second = blocks_imported_count / elapsed_time
    cumulative_transactions_per_second = total_transactions / elapsed_time
    total_gas_millions = (total_gas_used / 1_000_000.0).round(2)
    cumulative_gas_per_second_millions = (total_gas_used / elapsed_time / 1_000_000.0).round(2)

    # Calculate recent batch metrics (last 25 blocks using actual timing)
    recent_l2_blocks = imported_l2_blocks.last(25)
    recent_gas = recent_l2_blocks.sum { |block| block.gas_used || 0 }
    recent_transactions = recent_l2_blocks.sum { |block| block.facet_transactions&.length || 0 }

    recent_blocks_per_second = 25 / recent_batch_time
    recent_transactions_per_second = recent_transactions / recent_batch_time
    recent_gas_millions = (recent_gas / 1_000_000.0).round(2)
    recent_gas_per_second_millions = (recent_gas / recent_batch_time / 1_000_000.0).round(2)

    # Build single comprehensive stats message
    stats_message = <<~MSG
      #{"=" * 70}
      📊 IMPORT STATS
      🏁 Blocks: #{stats_start_block + 1} → #{current_block} (#{blocks_imported_count} total)

      ⚡ Speed: #{recent_blocks_per_second.round(1)} bl/s (#{cumulative_blocks_per_second.round(1)} session)
      📝 Transactions: #{recent_transactions} (#{total_transactions} total) | #{recent_transactions_per_second.round(1)}/s (#{cumulative_transactions_per_second.round(1)}/s session)
      ⛽ Gas: #{recent_gas_millions}M (#{total_gas_millions}M total) | #{recent_gas_per_second_millions.round(1)}M/s (#{cumulative_gas_per_second_millions.round(1)}M/s session)
      ⏱️  Time: #{recent_batch_time.round(1)}s recent | #{elapsed_time.round(1)}s total session
    MSG

    # Add prefetcher stats if available
    if blocks_imported_count >= 10
      stats = prefetcher.stats
      prefetcher_line = "🔄 Prefetcher: #{stats[:promises_fulfilled]}/#{stats[:promises_total]} fulfilled (#{stats[:threads_active]} active, #{stats[:threads_queued]} queued)"
      stats_message += "\n#{prefetcher_line}"
    end

    stats_message += "\n#{"=" * 70}"

    # Output single message
    logger.info stats_message

    # Output profiler report if enabled
    if ImportProfiler.enabled? && blocks_imported_count % 100 == 0
      ImportProfiler.report
      ImportProfiler.reset
    end
  end
end
