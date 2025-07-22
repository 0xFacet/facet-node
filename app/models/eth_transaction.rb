class EthTransaction < T::Struct
  include SysConfig
  
  const :block_hash, Hash32
  const :block_number, Integer
  const :block_timestamp, Integer
  const :tx_hash, Hash32
  const :transaction_index, Integer
  const :input, ByteString
  const :chain_id, T.nilable(Integer)
  const :from_address, Address20
  const :to_address, T.nilable(Address20)
  const :status, Integer
  const :logs, T::Array[T.untyped], default: []
  const :eth_block, T.nilable(EthBlock)
  const :facet_transactions, T::Array[FacetTransaction], default: []
  
  FacetLogInboxEventSig = ByteString.from_hex("0x00000000000000000000000000000000000000000000000000000000000face7")

  sig { params(block_result: T.untyped, receipt_result: T.untyped).returns(T::Array[EthTransaction]) }
  def self.from_rpc_result(block_result, receipt_result)
    block_hash = block_result['hash']
    block_number = block_result['number'].to_i(16)
    
    indexed_receipts = receipt_result.index_by{|el| el['transactionHash']}
    
    block_result['transactions'].map do |tx|
      current_receipt = indexed_receipts[tx['hash']]
      
      EthTransaction.new(
        block_hash: Hash32.from_hex(block_hash),
        block_number: block_number,
        block_timestamp: block_result['timestamp'].to_i(16),
        tx_hash: Hash32.from_hex(tx['hash']),
        transaction_index: tx['transactionIndex'].to_i(16),
        input: ByteString.from_hex(tx['input']),
        chain_id: tx['chainId']&.to_i(16),
        from_address: Address20.from_hex(tx['from']),
        to_address: tx['to'] ? Address20.from_hex(tx['to']) : nil,
        status: current_receipt['status'].to_i(16),
        logs: current_receipt['logs'],
      )
    end
  end
  
  sig { params(block_results: T.untyped, receipt_results: T.untyped).returns(T::Array[T.untyped]) }
  def self.facet_txs_from_rpc_results(block_results, receipt_results)
    eth_txs = from_rpc_result(block_results, receipt_results)
    eth_txs.sort_by(&:transaction_index).map(&:to_facet_tx).compact
  end
  
  sig { returns(T.nilable(FacetTransaction)) }
  def to_facet_tx
    return unless is_success?
    
    facet_tx_from_input || try_facet_tx_from_events
  end
  
  sig { returns(T.nilable(FacetTransaction)) }
  def facet_tx_from_input
    return unless to_address == FACET_INBOX_ADDRESS
    
    FacetTransaction.from_payload(
      contract_initiated: false,
      from_address: from_address,
      input: input,
      tx_hash: tx_hash,
      block_hash: block_hash
    )
  end
  
  sig { returns(T.nilable(FacetTransaction)) }
  def try_facet_tx_from_events
    facet_tx_creation_events.each do |log|
      facet_tx = FacetTransaction.from_payload(
        contract_initiated: true,
        from_address: Address20.from_hex(log['address']),
        input: ByteString.from_hex(log['data']),
        tx_hash: tx_hash,
        block_hash: block_hash
      )
      return facet_tx if facet_tx
    end
    nil
  end
  
  sig { returns(T::Boolean) }
  def is_success?
    status == 1
  end
  
  sig { returns(T::Array[T.untyped]) }
  def facet_tx_creation_events
    logs.select do |log|
      !log['removed'] && log['topics'].length == 1 &&
        FacetLogInboxEventSig == ByteString.from_hex(log['topics'].first)
    end.sort_by { |log| log['logIndex'].to_i(16) }
  end
  
  sig { returns(Hash32) }
  def facet_tx_source_hash
    tx_hash
  end
end
