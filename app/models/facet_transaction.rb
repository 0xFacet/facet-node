class FacetTransaction < T::Struct
  include SysConfig
  include AttrAssignable

  prop :chain_id, T.nilable(Integer)
  prop :l1_data_gas_used, T.nilable(Integer)
  prop :contract_initiated, T.nilable(T::Boolean)
  prop :eth_transaction_hash, T.nilable(Hash32)
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
  DEPOSIT_TX_TYPE = 0x7E
  
  USER_DEPOSIT_SOURCE_DOMAIN = 0
  L1_INFO_DEPOSIT_SOURCE_DOMAIN = 1
  UPGRADE_DEPOSITED_SOURCE_DOMAIN = 2
  
  SYSTEM_ADDRESS = Address20.from_hex("0xdeaddeaddeaddeaddeaddeaddeaddeaddead0001")
  L1_INFO_ADDRESS = Address20.from_hex("0x4200000000000000000000000000000000000015")
  MIGRATION_MANAGER_ADDRESS = Address20.from_hex("0x22220000000000000000000000000000000000d6")
  
  def self.from_ethscription(ethscription)
    tx = new
    tx.ethscription = ethscription
    tx.chain_id = ChainIdManager.current_l2_chain_id
    tx.to_address = ethscription.facet_tx_to
    tx.value = 0
    tx.input = ethscription.facet_tx_input
    
    tx.eth_transaction_hash = ethscription.transaction_hash
    tx.from_address = ethscription.creator
    
    tx.contract_initiated = ethscription.contract_initiated
    
    payload = [
      ethscription.block_hash.to_bin,
      ethscription.transaction_hash.to_bin,
      Eth::Util.zpad_int(0, 32)
    ].join
    
    tx.source_hash = FacetTransaction.compute_source_hash(
      ByteString.from_bin(payload),
      USER_DEPOSIT_SOURCE_DOMAIN
    )
    
    tx
  end
  
  sig { params(tx_count_in_block: Integer).returns(Integer) }
  def assign_gas_limit_from_tx_count_in_block(tx_count_in_block)
    block_gas_limit = SysConfig.block_gas_limit(facet_block)
    self.gas_limit = block_gas_limit / (tx_count_in_block + 1) # Attributes tx
  end
  
  sig { params(hex_string: ByteString, contract_initiated: T::Boolean).returns(Integer) }
  def self.calculate_data_gas_used(hex_string, contract_initiated:)
    bytes = hex_string.to_bin
    zero_count = bytes.count("\x00")
    non_zero_count = bytes.bytesize - zero_count
    
    if contract_initiated
      bytes.bytesize * 8
    else
      zero_count * 4 + non_zero_count * 16
    end
  end
  
  sig { params(
    contract_initiated: T::Boolean,
    from_address: Address20,
    input: ByteString,
    tx_hash: Hash32,
    block_hash: Hash32
  ).returns(T.nilable(FacetTransaction)) }
  def self.from_payload(
    contract_initiated:,
    from_address:,
    input:,
    tx_hash:,
    block_hash:
  )
    hex = input.to_hex
    
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
    tx.chain_id = clamp_uint(chain_id, 256)
    tx.to_address = to
    tx.value = clamp_uint(value, 256)
    tx.gas_limit = clamp_uint(gas_limit, 64)
    tx.input = data
    
    tx.eth_transaction_hash = tx_hash
    tx.from_address = from_address
    
    tx.contract_initiated = contract_initiated
    
    tx.l1_data_gas_used = calculate_data_gas_used(
      input,
      contract_initiated: tx.contract_initiated
    )
    
    tx.source_hash = tx_hash
    
    tx
  rescue *tx_decode_errors, InvalidAddress, InvalidRlpInt => e
    nil
  end
  
  def self.l1_attributes_tx_from_blocks(facet_block)
    calldata = L1AttributesTxCalldata.build(facet_block)
    
    tx = new
    tx.chain_id = ChainIdManager.current_l2_chain_id
    tx.to_address = L1_INFO_ADDRESS
    tx.value = 0
    tx.mint = 0
    tx.gas_limit = 1_000_000
    tx.input = calldata
    tx.from_address = SYSTEM_ADDRESS
    
    tx.facet_block = facet_block
    
    payload = [
      facet_block.eth_block_hash.to_bin,
      Eth::Util.zpad_int(facet_block.sequence_number, 32)
    ].join
    
    tx.source_hash = FacetTransaction.compute_source_hash(
      ByteString.from_bin(payload),
      L1_INFO_DEPOSIT_SOURCE_DOMAIN
    )
    
    tx
  end
  
  def self.v1_to_v2_migration_tx_from_block(facet_block, batch_number:)
    unless SysConfig.is_first_v2_block?(facet_block)
      raise "Invalid block number #{facet_block.number}!"
    end
    
    function_selector = ByteString.from_bin(Eth::Util.keccak256('executeMigration()').first(4))
    upgrade_intent = "emit events required to complete v1 to v2 migration batch ##{batch_number}"

    tx = new
    tx.chain_id = ChainIdManager.current_l2_chain_id
    tx.to_address = MIGRATION_MANAGER_ADDRESS
    tx.value = 0
    tx.mint = 0
    tx.gas_limit = 10_000_000
    tx.input = function_selector
    tx.from_address = SYSTEM_ADDRESS
    
    tx.facet_block = facet_block
    
    tx.source_hash = FacetTransaction.compute_source_hash(
      ByteString.from_bin(Eth::Util.keccak256(upgrade_intent)),
      L1_INFO_DEPOSIT_SOURCE_DOMAIN
    )
    
    tx
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

    tx_type = Eth::Util.serialize_int_to_big_endian(DEPOSIT_TX_TYPE)
    ByteString.from_bin("#{tx_type}#{tx_encoded}")
  end
  
  def self.l1_block_implementation_deployment_tx(block)
    filename = Rails.root.join("contracts/src/upgrades/L1Block.sol")
    # TODO: use a flat file for the bytecode
    compiled = SolidityCompiler.compile(filename)
    bytecode = compiled["L1Block"]["bytecode"]

    upgrade_intent = "deploy new L1Block implementation for Bluebird upgrade"

    tx = new
    tx.chain_id = ChainIdManager.current_l2_chain_id
    tx.to_address = nil  # nil for contract creation
    tx.value = 0
    tx.mint = 0
    tx.gas_limit = 10_000_000
    tx.input = "0x" + bytecode
    tx.from_address = SYSTEM_ADDRESS

    tx.facet_block = block

    tx.source_hash = FacetTransaction.compute_source_hash(
      Eth::Util.keccak256(upgrade_intent),
      L1_INFO_DEPOSIT_SOURCE_DOMAIN
    )

    tx
  end

  def self.l1_block_proxy_upgrade_tx(block, deployment_nonce)
    # Calculate the implementation address that will be deployed
    rlp_encoded = Eth::Util.rlp_encode([
      SYSTEM_ADDRESS.to_bin,
      deployment_nonce
    ])
    implementation_address_bytes_32 = Eth::Util.keccak256(rlp_encoded).last(20).rjust(32, "\x00")
    implementation_address_hex = implementation_address_bytes_32.bytes_to_hex
    # Create upgradeTo transaction
    function_selector = Eth::Util.keccak256('upgradeTo(address)').first(4)
    upgrade_data = function_selector + implementation_address_bytes_32

    upgrade_intent = "upgrade L1Block proxy to Bluebird implementation at #{implementation_address_hex}"

    tx = new
    tx.chain_id = ChainIdManager.current_l2_chain_id
    tx.to_address = L1_BLOCK_ADDRESS
    tx.value = 0
    tx.mint = 0
    tx.gas_limit = 10_000_000
    tx.input = upgrade_data.bytes_to_hex
    tx.from_address = SYSTEM_ADDRESS

    tx.facet_block = block

    tx.source_hash = FacetTransaction.compute_source_hash(
      Eth::Util.keccak256(upgrade_intent),
      L1_INFO_DEPOSIT_SOURCE_DOMAIN
    )

    tx
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
end
