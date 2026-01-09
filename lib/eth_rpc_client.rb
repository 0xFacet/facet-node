class EthRpcClient
  include Memery

  class HttpError < StandardError
    attr_reader :code, :http_message

    def initialize(code, http_message)
      @code = code
      @http_message = http_message
      super("HTTP error: #{code} #{http_message}")
    end
  end
  class ApiError < StandardError; end
  class ExecutionRevertedError < StandardError; end
  class MethodRequiredError < StandardError; end
  attr_accessor :base_url, :http

  def initialize(base_url = ENV['L1_RPC_URL'], jwt_secret: nil, retry_config: {})
    self.base_url = base_url
    @request_id = 0
    @mutex = Mutex.new

    # JWT support (optional)
    @jwt_secret = jwt_secret
    @jwt_enabled = !jwt_secret.nil?

    if @jwt_enabled
      @jwt_secret_decoded = ByteString.from_hex(jwt_secret).to_bin
    end

    # Customizable retry configuration
    @retry_config = {
      tries: 7,
      base_interval: 1,
      max_interval: 32,
      multiplier: 2,
      rand_factor: 0.4
    }.merge(retry_config)

    # HTTP persistent connection pool
    @uri = URI(base_url)
    @http = Net::HTTP::Persistent.new(
      name: "eth_rpc_#{@uri.host}:#{@uri.port}",
      pool_size: 100
    )
    @http.open_timeout = 5    # 5 seconds to establish connection
    @http.read_timeout = 10   # 10 seconds - allows multiple retries within prefetch timeout
    @http.idle_timeout = 30   # Keep connections alive for 30 seconds
  end

  def self.l1
    @_l1_client ||= new(ENV.fetch('L1_RPC_URL'))
  end

  def self.l1_prefetch
    # Fewer retries with shorter intervals for prefetching
    @_l1_prefetch_client ||= new(
      ENV.fetch('L1_RPC_URL'),
      retry_config: { tries: 3, base_interval: 1, max_interval: 4 }
    )
  end

  def self.l2
    @_l2_client ||= new(ENV.fetch('NON_AUTH_GETH_RPC_URL'))
  end

  def self.l2_engine
    @_l2_engine_client ||= new(
      ENV.fetch('GETH_RPC_URL'),
      jwt_secret: ENV.fetch('JWT_SECRET'),
      retry_config: { tries: 5, base_interval: 0.5, max_interval: 4 }
    )
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
      raise MethodRequiredError, "Method is required"
    end

    data = {
      id: next_request_id,
      jsonrpc: "2.0",
      method: method,
      params: params
    }

    Retriable.retriable(
      tries: @retry_config[:tries],
      base_interval: @retry_config[:base_interval],
      max_interval: @retry_config[:max_interval],
      multiplier: @retry_config[:multiplier],
      rand_factor: @retry_config[:rand_factor],
      on: [Net::ReadTimeout, Net::OpenTimeout, HttpError, ApiError, Errno::EPIPE, EOFError, Errno::ECONNREFUSED],
      on_retry: ->(exception, try, elapsed_time, next_interval) {
        Rails.logger.info "Retrying #{method} (attempt #{try}, next delay: #{next_interval&.round(2)}s) - #{exception.message}"
      }
    ) do
      send_http_request_simple(data)
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
    h = {
      'Accept' => 'application/json',
      'Content-Type' => 'application/json'
    }
    h['Authorization'] = "Bearer #{jwt}" if @jwt_enabled
    h
  end

  def jwt
    return nil unless @jwt_enabled
    JWT.encode({ iat: Time.now.to_i }, @jwt_secret_decoded, 'HS256')
  end
  memoize :jwt, ttl: 55

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

  private

  def send_http_request_simple(data)
    request = Net::HTTP::Post.new(@uri)
    request.body = data.to_json
    headers.each { |key, value| request[key] = value }

    response = @http.request(@uri, request)

    if response.code.to_i != 200
      raise HttpError.new(response.code.to_i, response.message)
    end

    parse_response_and_handle_errors(response.body)
  end

  def parse_response_and_handle_errors(response_text)
    parsed_response = JSON.parse(response_text, max_nesting: false)

    if parsed_response['error']
      error_message = parsed_response.dig('error', 'message') || 'Unknown API error'

      # Don't retry execution reverted errors as they're deterministic failures
      if error_message.include?('execution reverted')
        raise ExecutionRevertedError, "API error: #{error_message}"
      end

      raise ApiError, "API error: #{error_message}"
    end

    parsed_response['result']
  end

  def next_request_id
    @mutex.synchronize { @request_id += 1 }
  end
end
