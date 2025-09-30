class L1RpcPrefetcher
  include Memery
  
  def initialize(ethereum_client:,
                 ahead: ENV.fetch('L1_PREFETCH_FORWARD', Rails.env.test? ? 5 : 20).to_i,
                 threads: ENV.fetch('L1_PREFETCH_THREADS', Rails.env.test? ? 2 : 2).to_i)
    @eth = ethereum_client
    @ahead = ahead
    @threads = threads

    # Thread-safe collections and pool
    @pool = Concurrent::FixedThreadPool.new(threads)
    @promises = Concurrent::Map.new
    @last_chain_tip = current_l1_block_number

    Rails.logger.info "L1RpcPrefetcher initialized with #{threads} threads"
  end
  
  def ensure_prefetched(from_block)
    distance_from_last_tip = @last_chain_tip - from_block
    
    current_tip = if distance_from_last_tip > 10
      cached_current_l1_block_number
    else
      current_l1_block_number
    end
    
    # Don't prefetch beyond chain tip
    to_block = [from_block + @ahead, current_tip].min

    # Only create promises for blocks we don't have yet
    blocks_to_fetch = (from_block..to_block).reject { |n| @promises.key?(n) }

    return if blocks_to_fetch.empty?

    Rails.logger.debug "Enqueueing #{blocks_to_fetch.size} blocks: #{blocks_to_fetch.first}..#{blocks_to_fetch.last}"

    blocks_to_fetch.each { |block_number| enqueue_single(block_number) }
  end

  def fetch(block_number)
    ensure_prefetched(block_number)

    # Get or create promise
    promise = @promises[block_number] || enqueue_single(block_number)

    # Wait for result - if it's already done, this returns immediately
    timeout = Rails.env.test? ? 5 : 30

    Rails.logger.debug "Fetching block #{block_number}, promise state: #{promise.state}"

    begin
      result = promise.value!(timeout)
      Rails.logger.debug "Got result for block #{block_number}"

      # Diagnostic: value! should never return nil; log state/reason and raise
      if result.nil?
        Rails.logger.error "Prefetch promise returned nil for block #{block_number}; state=#{promise.state}, reason=#{promise.reason.inspect}"
        # Remove the fulfilled-with-nil promise so next call can recreate it
        @promises.delete(block_number)
        raise "Prefetch promise returned nil for block #{block_number}"
      end

      # Clean up :not_ready promises so they can be retried
      if result[:error] == :not_ready
        @promises.delete(block_number)
      end

      result
    rescue Concurrent::TimeoutError => e
      Rails.logger.error "Timeout fetching block #{block_number} after #{timeout}s"
      @promises.delete(block_number)
      raise
    end
  end

  def clear_older_than(min_keep)
    # Memory management - remove old promises
    return if min_keep.nil?

    deleted = 0
    @promises.keys.each do |n|
      if n < min_keep
        @promises.delete(n)
        deleted += 1
      end
    end

    Rails.logger.debug "Cleared #{deleted} promises older than #{min_keep}" if deleted > 0
  end

  def stats
    total = @promises.size
    # Count fulfilled promises by iterating
    fulfilled = 0
    pending = 0
    @promises.each_pair do |_, promise|
      if promise.fulfilled?
        fulfilled += 1
      elsif promise.pending?
        pending += 1
      end
    end

    {
      promises_total: total,
      promises_fulfilled: fulfilled,
      promises_pending: pending,
      threads_active: @pool.length,
      threads_queued: @pool.queue_length
    }
  end
  
  def shutdown
    @pool.shutdown
    terminated = @pool.wait_for_termination(3)
    @pool.kill unless terminated
  
    # Explicitly remove any outstanding promises
    @promises.each_pair { |_, pr| pr.cancel if pr.pending? rescue nil }
    @promises.clear
  
    Rails.logger.info(
      terminated ?
        'L1 RPC Prefetcher thread pool shut down successfully' :
        "L1 RPC Prefetcher shutdown timed out after 10s, pool killed"
    )
  
    terminated
  rescue StandardError => e
    Rails.logger.error("Error during L1RpcPrefetcher shutdown: #{e.message}\n#{e.backtrace.join("\n")}")
    false
  end

  def enqueue_single(block_number)
    @promises.compute_if_absent(block_number) do
      Rails.logger.debug "Creating promise for block #{block_number}"

      Concurrent::Promise.execute(executor: @pool) do
        Rails.logger.debug "Executing fetch for block #{block_number}"
        fetch_job(block_number)
      end.then do |res|
        if res.nil?
          Rails.logger.error "Prefetch fulfilled with nil for block #{block_number}; deleting cached promise entry"
          @promises.delete(block_number)
        end
        res
      end.rescue do |e|
        Rails.logger.error "Prefetch failed for block #{block_number}: #{e.message}"
        # Clean up failed promise so it can be retried
        @promises.delete(block_number)
        raise e
      end
    end
  end

  def fetch_job(block_number)
    # Use shared persistent client (thread-safe with HTTParty)
    client = @eth

    Retriable.retriable(tries: 3, base_interval: 1, max_interval: 4) do
      block = client.get_block(block_number, true)

      # Handle case where block doesn't exist yet (normal when caught up)
      if block.nil?
        Rails.logger.debug "Block #{block_number} not yet available on L1"
        return { error: :not_ready, block_number: block_number }
      end

      receipts = client.get_transaction_receipts(block_number)

      eth_block = EthBlock.from_rpc_result(block)
      facet_block = FacetBlock.from_eth_block(eth_block)

      # Use batch collection v2 if enabled, otherwise use v1
      facet_txs = if SysConfig.facet_batch_v2_enabled?
        collect_facet_transactions_v2(block, receipts)
      else
        EthTransaction.facet_txs_from_rpc_results(block, receipts)
      end

      {
        eth_block: eth_block,
        facet_block: facet_block,
        facet_txs: facet_txs,
        block_result: block,
        receipt_result: receipts
      }
    end
  end

  # Collect Facet transactions using the v2 batch-aware system
  def collect_facet_transactions_v2(block_result, receipt_result)
    block_number = block_result['number'].to_i(16)

    # Use the batch collector to find all transactions
    collector = FacetBatchCollector.new(
      eth_block: block_result,
      receipts: receipt_result,
      blob_provider: blob_provider,
      logger: Rails.logger
    )

    collected = collector.call

    # Build the final transaction order
    builder = FacetBlockBuilder.new(
      collected: collected,
      l2_block_gas_limit: SysConfig::L2_BLOCK_GAS_LIMIT,
      get_authorized_signer: ->(block_num) { PriorityRegistry.instance.authorized_signer(block_num) },
      logger: Rails.logger
    )

    builder.ordered_transactions(block_number)
  end

  def blob_provider
    @blob_provider ||= BlobProvider.new
  end
  
  def current_l1_block_number
    @last_chain_tip = @eth.get_block_number
  end
  
  def cached_current_l1_block_number
    current_l1_block_number
  end
  memoize :cached_current_l1_block_number, ttl: 12.seconds
end
