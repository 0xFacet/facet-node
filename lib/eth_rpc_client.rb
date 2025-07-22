class EthRpcClient
  attr_accessor :base_url

  def initialize(base_url = ENV['L1_RPC_URL'])
    self.base_url = base_url
  end
  
  def self.l1
    @_l1_client ||= new(ENV.fetch('L1_RPC_URL'))
  end

  def self.l2
    @_l2_client ||= new(ENV.fetch('NON_AUTH_GETH_RPC_URL'))
  end

  def get_block(block_number, include_txs = false)
    if block_number.is_a?(String)
      return query_api(
        method: 'eth_getBlockByNumber',
        params: [block_number, include_txs]
      )
    end
    
    query_api(
      method: 'eth_getBlockByNumber',
      params: ['0x' + block_number.to_s(16), include_txs]
    )
  end
  
  def get_nonce(address, block_number = "latest")
    query_api(
      method: 'eth_getTransactionCount',
      params: [address, block_number]
    ).to_i(16)
  end
  
  def get_chain_id
    query_api(method: 'eth_chainId').to_i(16)
  end
  
  def trace_block(block_number)
    query_api(
      method: 'debug_traceBlockByNumber',
      params: ['0x' + block_number.to_s(16), { tracer: "callTracer", timeout: "10s" }]
    )
  end

  def trace_transaction(transaction_hash)
    query_api(
      method: 'debug_traceTransaction',
      params: [transaction_hash, { tracer: "callTracer", timeout: "10s" }]
    )
  end

  def trace(tx_hash)
    trace_transaction(tx_hash)
  end
  
  def get_transaction(transaction_hash)
    query_api(
      method: 'eth_getTransactionByHash',
      params: [transaction_hash]
    )
  end
  
  def get_transaction_receipts(block_number)
    if block_number.is_a?(String)
      return query_api(
        method: 'eth_getBlockReceipts',
        params: [block_number]
      )
    end
    
    query_api(
      method: 'eth_getBlockReceipts',
      params: ["0x" + block_number.to_s(16)]
    )
  end
  
  def get_block_receipts(block_number)
    get_transaction_receipts(block_number)
  end
  
  def get_transaction_receipt(transaction_hash)
    query_api(
      method: 'eth_getTransactionReceipt',
      params: [transaction_hash]
    )
  end
  
  def get_block_number
    query_api(method: 'eth_blockNumber').to_i(16)
  end

  def query_api(method = nil, params = [], **kwargs)
    if kwargs.present?
      method = kwargs[:method]
      params = kwargs[:params]
    end
    
    unless method
      raise "Method is required"
    end
    
    data = {
      id: 1,
      jsonrpc: "2.0",
      method: method,
      params: params
    }

    url = base_url
    
    retries = 5
    begin
      response = HTTParty.post(url, body: data.to_json, headers: headers)
      
      if response.code != 200
        raise "HTTP error: #{response.code} #{response.message}"
      end

      parsed_response = JSON.parse(response.body, max_nesting: false)
      
      if parsed_response['error']
        raise "API error: #{parsed_response['error']['message']}"
      end

      parsed_response['result']
    rescue StandardError => e
      puts "Retrying #{retries} more times (last error: #{e.message.inspect})"
      
      retries -= 1
      if retries > 0
        sleep 1
        retry
      else
        raise "Failed after #{retries} retries: #{e.message.inspect}"
      end
    end
  end

  def call(method, params = [])
    query_api(method: method, params: params)
  end
  
  def eth_call(to:, data:, block_number: "latest")
    query_api(
      method: 'eth_call',
      params: [{ to: to, data: data }, block_number]
    )
  end
  
  def headers
    { 
      'Accept' => 'application/json',
      'Content-Type' => 'application/json'
    }
  end
  
  def get_code(address, block_number = "latest")
    query_api(
      method: 'eth_getCode',
      params: [address, block_number]
    )
  end

  def get_storage_at(address, slot, block_number = "latest")
    query_api(
      method: 'eth_getStorageAt',
      params: [address, slot, block_number]
    )
  end
end
