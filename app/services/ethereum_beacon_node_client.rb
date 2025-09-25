class EthereumBeaconNodeClient
  include Memery
  
  attr_accessor :base_url, :api_key

  def initialize(base_url: ENV['ETHEREUM_BEACON_NODE_API_BASE_URL'], api_key: ENV['ETHEREUM_BEACON_NODE_API_KEY'])
    self.base_url = base_url&.chomp('/')
    self.api_key = api_key
  end

  def get_blob_sidecars(block_id)
    base_url_with_key = [base_url, api_key].compact.join('/').chomp('/')
    url = [base_url_with_key, "eth/v1/beacon/blob_sidecars/#{block_id}"].join('/')
    
    response = HTTParty.get(url)
    raise "Failed to fetch blob sidecars: #{response.code}" unless response.success?
    
    response.parsed_response['data']
  end
  
  def get_block(block_id)
    base_url_with_key = [base_url, api_key].compact.join('/').chomp('/')
    url = [base_url_with_key, "eth/v2/beacon/blocks/#{block_id}"].join('/')
    
    response = HTTParty.get(url)
    raise "Failed to fetch block: #{response.code}" unless response.success?
    
    response.parsed_response['data']
  end
  
  def get_genesis
    base_url_with_key = [base_url, api_key].compact.join('/').chomp('/')
    url = [base_url_with_key, "eth/v1/beacon/genesis"].join('/')
    
    response = HTTParty.get(url)
    raise "Failed to fetch genesis: #{response.code}" unless response.success?
    
    response.parsed_response['data']
  end
  memoize :get_genesis

  # Fetches consensus spec values (e.g., seconds_per_slot). Field name casing
  # can differ across clients; we normalize in seconds_per_slot.
  def get_spec
    base_url_with_key = [base_url, api_key].compact.join('/').chomp('/')
    url = [base_url_with_key, "eth/v1/config/spec"].join('/')

    response = HTTParty.get(url)
    return {} unless response.success?
    
    response.parsed_response['data']
  end

  # Returns seconds per slot, falling back to 12 if unavailable.
  def seconds_per_slot
    @_seconds_per_slot ||= begin
      spec = get_spec || {}
      val = spec['SECONDS_PER_SLOT'] || spec['seconds_per_slot']
      (val || 12).to_i
    rescue StandardError
      12
    end
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
end