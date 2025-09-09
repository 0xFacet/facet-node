# Represents a standard EIP-2718 typed transaction (EIP-1559, EIP-2930, or legacy)
# These are the transactions that come from batches and go into L2 blocks,
# as opposed to FacetTransaction which is the special V1 single transaction format (0x7D/0x7E)
class StandardL2Transaction < T::Struct
  const :raw_bytes, ByteString
  const :tx_hash, Hash32
  const :from_address, Address20
  const :to_address, T.nilable(Address20)
  const :nonce, Integer
  const :gas_limit, Integer
  const :value, Integer
  const :data, ByteString
  const :tx_type, Integer  # 0x00 (legacy), 0x01 (EIP-2930), 0x02 (EIP-1559)
  
  # EIP-1559 specific fields
  const :max_fee_per_gas, T.nilable(Integer)
  const :max_priority_fee_per_gas, T.nilable(Integer)
  
  # Legacy/EIP-2930 field
  const :gas_price, T.nilable(Integer)
  
  # Block association - writable property so it can be set after creation
  prop :facet_block, T.nilable(FacetBlock)
  
  # Return raw bytes for proposer - compatible with block building
  def to_raw
    raw_bytes
  end
  
  # Return payload for Geth - standard transactions just return their raw bytes
  def to_facet_payload
    raw_bytes.to_hex
  end
  
  # Parse raw transaction bytes into StandardL2Transaction
  def self.from_raw_bytes(raw_bytes)
    bytes = raw_bytes.is_a?(ByteString) ? raw_bytes : ByteString.from_bin(raw_bytes)
    tx_hash = Hash32.from_bin(Eth::Util.keccak256(bytes.to_bin))
    
    # Determine transaction type
    first_byte = bytes.to_bin[0].ord
    
    case first_byte
    when 0x02
      parse_eip1559_transaction(bytes, tx_hash)
    when 0x01
      parse_eip2930_transaction(bytes, tx_hash)
    else
      # Legacy transaction (no type byte or invalid type)
      parse_legacy_transaction(bytes, tx_hash)
    end
  end
  
  private
  
  def self.parse_eip1559_transaction(raw_bytes, tx_hash)
    # Skip type byte and decode RLP
    rlp_data = raw_bytes.to_bin[1..-1]
    decoded = Eth::Rlp.decode(rlp_data)
    
    # EIP-1559 format:
    # [chain_id, nonce, max_priority_fee, max_fee, gas_limit, to, value, data, access_list, v, r, s]
    
    chain_id = deserialize_int(decoded[0])
    nonce = deserialize_int(decoded[1])
    max_priority_fee = deserialize_int(decoded[2])
    max_fee = deserialize_int(decoded[3])
    gas_limit = deserialize_int(decoded[4])
    to_address = decoded[5].empty? ? nil : Address20.from_bin(decoded[5])
    value = deserialize_int(decoded[6])
    data = ByteString.from_bin(decoded[7])
    
    # Recover from address using signature
    v = deserialize_int(decoded[9])
    r = decoded[10]
    s = decoded[11]
    
    from_address = recover_address_eip1559(decoded, v, r, s, chain_id)
    
    new(
      raw_bytes: raw_bytes,
      tx_hash: tx_hash,
      from_address: from_address,
      to_address: to_address,
      nonce: nonce,
      gas_limit: gas_limit,
      value: value,
      data: data,
      tx_type: 0x02,
      max_fee_per_gas: max_fee,
      max_priority_fee_per_gas: max_priority_fee,
      gas_price: nil
    )
  end
  
  def self.parse_eip2930_transaction(raw_bytes, tx_hash)
    # Skip type byte and decode RLP
    rlp_data = raw_bytes.to_bin[1..-1]
    decoded = Eth::Rlp.decode(rlp_data)
    
    # EIP-2930 format:
    # [chain_id, nonce, gas_price, gas_limit, to, value, data, access_list, v, r, s]
    
    chain_id = deserialize_int(decoded[0])
    nonce = deserialize_int(decoded[1])
    gas_price = deserialize_int(decoded[2])
    gas_limit = deserialize_int(decoded[3])
    to_address = decoded[4].empty? ? nil : Address20.from_bin(decoded[4])
    value = deserialize_int(decoded[5])
    data = ByteString.from_bin(decoded[6])
    
    # Recover from address using signature
    v = deserialize_int(decoded[8])
    r = decoded[9]
    s = decoded[10]
    
    from_address = recover_address_eip2930(decoded, v, r, s, chain_id)
    
    new(
      raw_bytes: raw_bytes,
      tx_hash: tx_hash,
      from_address: from_address,
      to_address: to_address,
      nonce: nonce,
      gas_limit: gas_limit,
      value: value,
      data: data,
      tx_type: 0x01,
      max_fee_per_gas: nil,
      max_priority_fee_per_gas: nil,
      gas_price: gas_price
    )
  end
  
  def self.parse_legacy_transaction(raw_bytes, tx_hash)
    # Legacy transaction - decode RLP directly
    decoded = Eth::Rlp.decode(raw_bytes.to_bin)
    
    # Legacy format:
    # [nonce, gas_price, gas_limit, to, value, data, v, r, s]
    
    nonce = deserialize_int(decoded[0])
    gas_price = deserialize_int(decoded[1])
    gas_limit = deserialize_int(decoded[2])
    to_address = decoded[3].empty? ? nil : Address20.from_bin(decoded[3])
    value = deserialize_int(decoded[4])
    data = ByteString.from_bin(decoded[5])
    
    # Recover from address using signature
    v = deserialize_int(decoded[6])
    r = decoded[7]
    s = decoded[8]
    
    from_address = recover_address_legacy(decoded[0..5], v, r, s)
    
    new(
      raw_bytes: raw_bytes,
      tx_hash: tx_hash,
      from_address: from_address,
      to_address: to_address,
      nonce: nonce,
      gas_limit: gas_limit,
      value: value,
      data: data,
      tx_type: 0x00,
      max_fee_per_gas: nil,
      max_priority_fee_per_gas: nil,
      gas_price: gas_price
    )
  end
  
  def self.deserialize_int(data)
    return 0 if data.empty?
    data.unpack1('H*').to_i(16)
  end
  
  def self.recover_address_eip1559(decoded, v, r, s, chain_id)
    # Create signing hash for EIP-1559
    # Exclude signature fields (last 3 elements)
    tx_data = decoded[0..8]  # Everything except v, r, s
    
    # Prefix with transaction type
    encoded = "\x02" + Eth::Rlp.encode(tx_data)
    signing_hash = Eth::Util.keccak256(encoded)
    
    # Recover public key from signature
    sig = Eth::Signature.new(
      signature_bytes: r + s + [(v == 0 || v == 1) ? v : v - 27].pack('C')
    )
    
    public_key = sig.recover_public_key(signing_hash)
    Address20.from_hex(Eth::Util.public_key_to_address(public_key))
  rescue => e
    Rails.logger.error "Failed to recover EIP-1559 address: #{e.message}"
    Address20.from_hex("0x" + "0" * 40)
  end
  
  def self.recover_address_eip2930(decoded, v, r, s, chain_id)
    # Create signing hash for EIP-2930
    # Exclude signature fields (last 3 elements)
    tx_data = decoded[0..7]  # Everything except v, r, s
    
    # Prefix with transaction type
    encoded = "\x01" + Eth::Rlp.encode(tx_data)
    signing_hash = Eth::Util.keccak256(encoded)
    
    # Recover public key from signature
    sig = Eth::Signature.new(
      signature_bytes: r + s + [(v == 0 || v == 1) ? v : v - 27].pack('C')
    )
    
    public_key = sig.recover_public_key(signing_hash)
    Address20.from_hex(Eth::Util.public_key_to_address(public_key))
  rescue => e
    Rails.logger.error "Failed to recover EIP-2930 address: #{e.message}"
    Address20.from_hex("0x" + "0" * 40)
  end
  
  def self.recover_address_legacy(tx_data, v, r, s)
    # Create signing hash for legacy transaction
    encoded = Eth::Rlp.encode(tx_data)
    signing_hash = Eth::Util.keccak256(encoded)
    
    # Adjust v for EIP-155 if needed
    recovery_id = if v >= 35
      chain_id = (v - 35) / 2
      (v - 35) % 2
    else
      v - 27
    end
    
    # Recover public key from signature
    sig = Eth::Signature.new(
      signature_bytes: r + s + [recovery_id].pack('C')
    )
    
    public_key = sig.recover_public_key(signing_hash)
    Address20.from_hex(Eth::Util.public_key_to_address(public_key))
  rescue => e
    Rails.logger.error "Failed to recover legacy address: #{e.message}"
    Address20.from_hex("0x" + "0" * 40)
  end
end