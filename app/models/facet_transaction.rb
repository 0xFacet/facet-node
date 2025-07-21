class FacetTransaction < T::Struct
  include SysConfig
  include AttrAssignable

  prop :chain_id, T.nilable(Integer)
  prop :contract_initiated, T.nilable(T::Boolean)
  prop :eth_transaction_hash, T.nilable(Hash32)
  prop :eth_transaction_input, T.nilable(ByteString)
  prop :eth_call_index, T.nilable(Integer)
  prop :block_hash, T.nilable(Hash32)
  prop :block_number, T.nilable(Integer)
  prop :deposit_receipt_version, T.nilable(String)
  prop :from_address, T.nilable(Address20)
  prop :gas_limit, T.nilable(Integer)
  prop :tx_hash, T.nilable(Hash32)
  prop :input, T.nilable(ByteString)
  prop :source_hash, T.nilable(Hash32)
  prop :to_address, T.nilable(Address20)
  prop :transaction_index, T.nilable(Integer)
  prop :tx_type, T.nilable(String)
  prop :mint, T.nilable(Integer)
  prop :value, T.nilable(Integer)

  prop :facet_block, T.nilable(FacetBlock)
  
  class InvalidAddress < StandardError; end
  class InvalidRlpInt < StandardError; end
  
  FACET_TX_TYPE = 0x46
  
  USER_DEPOSIT_SOURCE_DOMAIN = 0
  L1_INFO_DEPOSIT_SOURCE_DOMAIN = 1
  UPGRADE_DEPOSITED_SOURCE_DOMAIN = 2
  
  SYSTEM_ADDRESS = Address20.from_hex("0xdeaddeaddeaddeaddeaddeaddeaddeaddead0001")
  L1_INFO_ADDRESS = Address20.from_hex("0x4200000000000000000000000000000000000015")
  MIGRATION_MANAGER_ADDRESS = Address20.from_hex("0x22220000000000000000000000000000000000d6")
  PROXY_ADMIN_ADDRESS = Address20.from_hex("0x4200000000000000000000000000000000000018")
  
  sig { params(tx_count_in_block: Integer).returns(Integer) }
  def assign_gas_limit_from_tx_count_in_block(tx_count_in_block)
    block_gas_limit = SysConfig.block_gas_limit(facet_block)
    self.gas_limit = block_gas_limit / (tx_count_in_block + 1) # Attributes tx
  end
  
  sig { params(facet_block_number: Integer).returns(Integer) }
  def l1_data_gas_used(facet_block_number)
    bytes = eth_transaction_input.to_bin

    # Contract-initiated txs use the old 8-gas-per-byte rule regardless of fork
    return bytes.bytesize * 8 if contract_initiated

    zero_count = bytes.count("\x00")
    non_zero_count = bytes.bytesize - zero_count

    if SysConfig.is_bluebird?(facet_block_number)
      # EIP-7623 floor pricing: 10 gas per zero byte, 40 gas per non-zero byte
      zero_count * 10 + non_zero_count * 40
    else
      # Pre-Bluebird 4/16 pricing
      zero_count * 4 + non_zero_count * 16
    end
  end
  
  sig { params(
    contract_initiated: T::Boolean,
    from_address: Address20,
    eth_transaction_input: ByteString,
    tx_hash: Hash32
  ).returns(T.nilable(FacetTransaction)) }
  def self.from_payload(
    contract_initiated:,
    from_address:,
    eth_transaction_input:,
    tx_hash:
  )
    hex = eth_transaction_input.to_hex
    
    hex = Eth::Util.remove_hex_prefix hex
    type = hex[0, 2]
    
    unless type.to_i(16) == FACET_TX_TYPE
      raise Eth::Tx::TransactionTypeError, "Invalid transaction type #{type}!"
    end

    bin = Eth::Util.hex_to_bin(hex[2..])
    tx = Eth::Rlp.decode(bin)

    unless tx.is_a?(Array)
      raise Eth::Tx::ParameterError, "Transaction is not an array!"
    end
    
    unless tx.size == 6
      raise Eth::Tx::ParameterError, "Transaction missing fields!"
    end
    
    unless tx.all? { |field| field.is_a?(String) }
      raise Eth::Tx::ParameterError, "Transaction fields are not strings!"
    end

    chain_id = deserialize_rlp_int(tx[0])
    
    unless chain_id == ChainIdManager.current_l2_chain_id
      raise Eth::Tx::ParameterError, "Invalid chain ID #{chain_id}!"
    end
    
    begin
      to = tx[1].length.zero? ? nil : Address20.from_bin(tx[1])
    rescue ByteString::InvalidByteLength => e
      raise InvalidAddress, "Invalid address length: #{e.message}"
    end
    
    value = deserialize_rlp_int(tx[2])
    gas_limit = deserialize_rlp_int(tx[3])
    data = ByteString.from_bin(tx[4])

    tx = new
    tx.eth_transaction_input = eth_transaction_input
    
    tx.chain_id = clamp_uint(chain_id, 256)
    tx.to_address = to
    tx.value = clamp_uint(value, 256)
    tx.gas_limit = clamp_uint(gas_limit, 64)
    tx.input = data
    
    tx.eth_transaction_hash = tx_hash
    tx.from_address = from_address
    
    tx.contract_initiated = contract_initiated
    
    tx.source_hash = tx_hash
    
    tx
  rescue *tx_decode_errors, InvalidAddress, InvalidRlpInt => e
    nil
  end
  
  sig { params(payload: ByteString, source_domain: Integer).returns(Hash32) }
  def self.compute_source_hash(payload, source_domain)
    bin_val = Eth::Util.keccak256(
      Eth::Util.zpad_int(source_domain, 32) +
      Eth::Util.keccak256(payload.to_bin)
    )
    
    Hash32.from_bin(bin_val)
  end
  
  sig { returns(ByteString) }
  def to_facet_payload
    tx_data = []
    tx_data.push(source_hash.to_bin)
    tx_data.push(calculated_from_address.to_bin)
    tx_data.push(to_address ? to_address.to_bin : '')
    tx_data.push(Eth::Util.serialize_int_to_big_endian(mint))
    tx_data.push(Eth::Util.serialize_int_to_big_endian(value))
    tx_data.push(Eth::Util.serialize_int_to_big_endian(gas_limit))
    tx_data.push('')
    tx_data.push(input.to_bin)
    tx_encoded = Eth::Rlp.encode(tx_data)

    tx_type = Eth::Util.serialize_int_to_big_endian(deposit_tx_type)
    ByteString.from_bin("#{tx_type}#{tx_encoded}")
  end
  
  def self.tx_decode_errors
    [
      Eth::Rlp::DecodingError,
      Eth::Tx::TransactionTypeError,
      Eth::Tx::ParameterError,
      Eth::Tx::DecoderError
    ]
  end
  
  def trace
    GethDriver.trace_transaction(tx_hash)
  end
  
  def calculated_from_address
    if contract_initiated
      AddressAliasHelper.apply_l1_to_l2_alias(from_address)
    else
      from_address
    end
  end
  
  def self.clamp_uint(input, max_bits)
    [input.to_i, 2 ** max_bits - 1].min
  end
  
  def self.deserialize_rlp_int(bytes)
    bytes = bytes.b
    
    if bytes.starts_with?("\x00")
      raise InvalidRlpInt, "Invalid RLP integer: #{ByteString.from_bin(bytes).to_hex}"
    end
    
    Eth::Util.deserialize_big_endian_to_int(bytes)
  end
  
  def deposit_tx_type
    if SysConfig.is_bluebird?(facet_block.number)
      0x7D
    else
      0x7E
    end
  end
end
