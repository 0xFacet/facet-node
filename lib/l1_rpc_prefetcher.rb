class L1RpcPrefetcher
  include Memery
  class BlockFetchError < StandardError; end

  def initialize(ethereum_client:,
                 ahead: ENV.fetch('L1_PREFETCH_FORWARD', Rails.env.test? ? 5 : 20).to_i,
                 threads: ENV.fetch('L1_PREFETCH_THREADS', Rails.env.test? ? 2 : 2).to_i)
    @eth = ethereum_client
    @ahead = ahead
    @threads = threads
    # 30s default - long enough for slow RPC calls, short enough to bail on stuck requests
    @fetch_timeout = ENV.fetch('L1_PREFETCH_TIMEOUT', Rails.env.test? ? 5 : 30).to_i

    # Thread-safe collections and pool
    @pool = Concurrent::FixedThreadPool.new(threads)
    @promises = Concurrent::Map.new
    @last_chain_tip = current_l1_block_number

    Rails.logger.info "L1RpcPrefetcher initialized with #{threads} threads"
  end

  def ensure_prefetched(from_block)
    distance_from_last_tip = @last_chain_tip - from_block
    latest = if distance_from_last_tip > 10
               cached_l1_block_number
             else
               current_l1_block_number
             end

    # Don't prefetch beyond chain tip
    to_block = [from_block + @ahead, latest].min

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

    # Wait for result - value! returns nil on timeout, raises on rejection
    begin
      result = promise.value!(@fetch_timeout)
    rescue => e
      raise BlockFetchError.new("Block #{block_number} fetch failed: #{e.message}")
    end

    if result.nil? || result == :not_ready_sentinel
      @promises.delete(block_number)
      message = result.nil? ?
        "Block #{block_number} fetch timed out after #{@fetch_timeout}s" :
        "Block #{block_number} not yet available on L1"
      raise BlockFetchError.new(message)
    end

    result
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
    @promises.each_pair do |_, promise|
      begin
        if promise.pending? && promise.respond_to?(:cancel)
          promise.cancel
        end
      rescue StandardError => e
        Rails.logger.warn "Failed cancelling promise during shutdown: #{e.message}"
      end
    end
    @promises.clear
    Rails.logger.info(
      terminated ?
        'L1 RPC Prefetcher thread pool shut down successfully' :
        'L1 RPC Prefetcher shutdown timed out after 3s, pool killed'
    )
    terminated
  rescue StandardError => e
    Rails.logger.error("Error during L1RpcPrefetcher shutdown: #{e.message}\n#{e.backtrace.join("\n")}")
    false
  end

  private

  def enqueue_single(block_number)
    @promises.compute_if_absent(block_number) do
      Concurrent::Promise.execute(executor: @pool) do
        fetch_job(block_number)
      end.rescue do |e|
        Rails.logger.error "[PREFETCH] Block #{block_number}: #{e.class} - #{e.message}"
        @promises.delete(block_number)
        raise e
      end
    end
  end

  def fetch_job(block_number)
    block = @eth.get_block(block_number, true)

    # Handle case where block doesn't exist yet (normal when caught up)
    if block.nil?
      Rails.logger.info "[PREFETCH] Block #{block_number} not yet available on L1"
      return :not_ready_sentinel
    end

    receipts = @eth.get_transaction_receipts(block_number)

    eth_block = EthBlock.from_rpc_result(block)
    facet_block = FacetBlock.from_eth_block(eth_block)
    facet_txs = EthTransaction.facet_txs_from_rpc_results(block, receipts)

    {
      eth_block: eth_block,
      facet_block: facet_block,
      facet_txs: facet_txs
    }
  end

  def current_l1_block_number
    @last_chain_tip = @eth.get_block_number
  end

  def cached_l1_block_number
    current_l1_block_number
  end
  memoize :cached_l1_block_number, ttl: 12.seconds
end
