class EthereumBeaconNodeClient
  include Memery
  include RpcErrors

  attr_accessor :base_url

  def initialize(base_url = ENV['ETHEREUM_BEACON_NODE_API_BASE_URL'])
    self.base_url = base_url&.chomp('/')
  end

  def self.l1
    @_l1_client ||= new(ENV.fetch('ETHEREUM_BEACON_NODE_API_BASE_URL'))
  end

  def get_blob_sidecars(block_id)
    query_api("eth/v1/beacon/blob_sidecars/#{block_id}")
  end

  def get_block(block_id)
    query_api("eth/v2/beacon/blocks/#{block_id}")
  end

  def get_genesis
    query_api("eth/v1/beacon/genesis")
  end
  memoize :get_genesis

  def get_spec
    query_api("eth/v1/config/spec")
  end
  memoize :get_spec

  # Returns seconds per slot, falling back to 12 if unavailable.
  def seconds_per_slot
    spec = get_spec
    val = spec['SECONDS_PER_SLOT'] || spec['seconds_per_slot']
    (val || 12).to_i
  end

  # Compute the beacon slot corresponding to an execution block timestamp
  # using: slot = (timestamp - genesis_time) / seconds_per_slot
  def slot_for_execution_timestamp(timestamp)
    ts = timestamp.to_i
    genesis_time = get_genesis.fetch('genesis_time').to_i
    ((ts - genesis_time) / seconds_per_slot).to_i
  end

  # Convenience: fetch blob sidecars for the beacon slot corresponding to the
  # given execution block timestamp (in seconds).
  def get_blob_sidecars_for_execution_timestamp(timestamp)
    slot = slot_for_execution_timestamp(timestamp)
    get_blob_sidecars(slot)
  end

  # Convenience: fetch blob sidecars for a given execution block object (as
  # returned by JSON-RPC `eth_getBlockByNumber`), using its timestamp.
  # Accepts either a raw block result Hash or a wrapper { 'result' => { ... } }.
  def get_blob_sidecars_for_execution_block(execution_block)
    result = execution_block.is_a?(Hash) && execution_block['result'].is_a?(Hash) ? execution_block['result'] : execution_block
    ts_hex_or_int = result.fetch('timestamp')
    ts = ts_hex_or_int.is_a?(String) ? ts_hex_or_int.to_i(16) : ts_hex_or_int.to_i
    get_blob_sidecars_for_execution_timestamp(ts)
  end

  private

  def query_api(endpoint)
    # Parse API key from URL if it's embedded in the path (e.g., https://beacon.com/api-key/eth/v1/...)
    url = [base_url, endpoint].join('/')

    Retriable.retriable(
      tries: 7,
      base_interval: 1,
      max_interval: 32,
      multiplier: 2,
      rand_factor: 0.4,
      on: [Net::ReadTimeout, Net::OpenTimeout, RpcErrors::HttpError, RpcErrors::ApiError],
      on_retry: ->(exception, try, elapsed_time, next_interval) {
        Rails.logger.info "Retrying beacon API #{endpoint} (attempt #{try}, next delay: #{next_interval.round(2)}s) - #{exception.message}"
      }
    ) do
      response = HTTParty.get(url)
      
      unless response.success?
        raise RpcErrors::HttpError.new(response.code, response.message)
      end

      parsed = response.parsed_response

      # Check for API-level errors in the response
      if parsed.is_a?(Hash) && parsed['error']
        raise RpcErrors::ApiError, "API error: #{parsed['error']['message'] || parsed['error']}"
      end

      parsed
    end
  end
end