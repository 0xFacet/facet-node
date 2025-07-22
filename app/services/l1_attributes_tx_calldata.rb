module L1AttributesTxCalldata
  extend self
  
  FUNCTION_SELECTOR = Eth::Util.keccak256('setL1BlockValuesEcotone()').first(4)
  
  sig { params(
    timestamp: Integer,
    number: Integer,
    base_fee: Integer,
    hash: Hash32,
    sequence_number: Integer,
    fct_mint_rate: Integer,
    fct_mint_period_l1_data_gas: Integer,
    blob_base_fee: Integer
  ).returns(ByteString) }
  def build(
    timestamp:,
    number:,
    base_fee:,
    hash:,
    sequence_number:,
    fct_mint_rate:,
    fct_mint_period_l1_data_gas:,
    blob_base_fee: 1
  )
    base_fee_scalar = 0
    blob_base_fee_scalar = 1
    batcher_hash = "\x00" * 32
    
    hash = hash.to_bin
    
    unless hash.length == 32
      raise "Invalid hash length"
    end
    
    packed_data = [
      FUNCTION_SELECTOR,
      Eth::Util.zpad_int(base_fee_scalar, 4),
      Eth::Util.zpad_int(blob_base_fee_scalar, 4),
      Eth::Util.zpad_int(sequence_number, 8),
      Eth::Util.zpad_int(timestamp, 8),
      Eth::Util.zpad_int(number, 8),
      Eth::Util.zpad_int(base_fee, 32),
      Eth::Util.zpad_int(blob_base_fee, 32),
      hash,
      batcher_hash,
      Eth::Util.zpad_int(fct_mint_period_l1_data_gas, 16),
      Eth::Util.zpad_int(fct_mint_rate, 16)
    ].join
    
    ByteString.from_bin(packed_data)
  end
  
  sig { params(calldata: ByteString).returns(T::Hash[Symbol, T.untyped]) }
  def decode(calldata)
    data = calldata.to_bin
  
    # Remove the function selector
    data = data[4..-1]
    
    # Unpack the data
    base_fee_scalar = data[0...4].unpack1('N')
    blob_base_fee_scalar = data[4...8].unpack1('N')
    sequence_number = data[8...16].unpack1('Q>')
    timestamp = data[16...24].unpack1('Q>')
    number = data[24...32].unpack1('Q>')
    base_fee = data[32...64].unpack1('H*').to_i(16)
    blob_base_fee = data[64...96].unpack1('H*').to_i(16)
    hash = data[96...128].unpack1('H*')
    batcher_hash = data[128...160].unpack1('H*')
    fct_mint_period_l1_data_gas = data[160...176].unpack1('H*').to_i(16)
    fct_mint_rate = data[176...192].unpack1('H*').to_i(16)
    
    {
      timestamp: timestamp,
      number: number,
      base_fee: base_fee,
      blob_base_fee: blob_base_fee,
      hash: Hash32.from_hex("0x#{hash}"),
      batcher_hash: Hash32.from_hex("0x#{batcher_hash}"),
      sequence_number: sequence_number,
      blob_base_fee_scalar: blob_base_fee_scalar,
      base_fee_scalar: base_fee_scalar,
      fct_mint_rate: fct_mint_rate,
      fct_mint_period_l1_data_gas: fct_mint_period_l1_data_gas
    }.with_indifferent_access
  end
end
