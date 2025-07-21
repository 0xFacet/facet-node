module L1AttributesTxCalldata
  extend self
  
  FUNCTION_SELECTOR = Eth::Util.keccak256('setL1BlockValuesEcotone()').first(4)
  
  sig { params(facet_block: FacetBlock).returns(ByteString) }
  def build(facet_block)
    base_fee_scalar = 0
    blob_base_fee_scalar = 1 # TODO: use real values
    blob_base_fee = 1
    batcher_hash = "\x00" * 32
    
    if SysConfig.is_bluebird?(facet_block)
      unless facet_block.fct_mint_period_l1_data_gas.nil?
        raise "fct_mint_period_l1_data_gas not used after fork"
      end
      
      facet_block.fct_mint_period_l1_data_gas = 0
    end
    
    packed_data = [
      FUNCTION_SELECTOR,
      Eth::Util.zpad_int(base_fee_scalar, 4),
      Eth::Util.zpad_int(blob_base_fee_scalar, 4),
      Eth::Util.zpad_int(facet_block.sequence_number, 8),
      Eth::Util.zpad_int(facet_block.eth_block_timestamp, 8),
      Eth::Util.zpad_int(facet_block.eth_block_number, 8),
      Eth::Util.zpad_int(facet_block.eth_block_base_fee_per_gas, 32),
      Eth::Util.zpad_int(blob_base_fee, 32),
      facet_block.eth_block_hash.to_bin,
      batcher_hash,
      Eth::Util.zpad_int(facet_block.fct_mint_period_l1_data_gas, 16),
      Eth::Util.zpad_int(facet_block.fct_mint_rate, 16)
    ]
    
    # Bluebird fork introduces extra FCT-related fields that must be packed.
    # Layout for each 32-byte word (big-endian):
    #   word 1 (offset 160): [fct_mint_period_l1_data_gas(16B)] [fct_mint_rate(16B)]
    #   word 2 (offset 192): [fct_period_start_block(16B)]      [fct_total_minted(16B)]
    #   word 3 (offset 224): [reserved / 0(16B)]                 [fct_period_minted(16B)]
    if SysConfig.is_bluebird?(facet_block)
      %i[fct_total_minted fct_period_start_block fct_period_minted].each do |field|
        raise "#{field} required after fork" if facet_block.send(field).nil?
      end

      # word 2
      packed_data << Eth::Util.zpad_int(facet_block.fct_period_start_block, 16)
      packed_data << Eth::Util.zpad_int(facet_block.fct_total_minted, 16)

      # word 3 (upper 128 bits reserved as zero for now)
      packed_data << Eth::Util.zpad_int(facet_block.fct_period_minted, 32)
    end
    
    ByteString.from_bin(packed_data.join)
  end
  
  sig { params(calldata: ByteString, facet_block_number: Integer).returns(T::Hash[Symbol, T.untyped]) }
  def decode(calldata, facet_block_number)
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
    
    result = {
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
    }
    
    # Only decode fct_total_minted if at or past fork block
    if SysConfig.is_bluebird?(facet_block_number)
      # Pre-fork: 192 bytes (after removing 4-byte selector)
      # Post-fork: 192 + 64 = 256 bytes (3 new fields: 16+16+32)
      raise "Expected exactly 256 bytes of calldata after fork, got #{data.length}" unless data.length == 256
      raise "Invalid data gas" unless fct_mint_period_l1_data_gas.zero?

      # word 2 : offsets 192..224 (32 bytes)
      result[:fct_period_start_block] = data[192...208].unpack1('H*').to_i(16)
      result[:fct_total_minted]  = data[208...224].unpack1('H*').to_i(16)

      # word 3 : offsets 224..256 (32 bytes)
      result[:fct_period_minted] = data[240...256].unpack1('H*').to_i(16)
    end

    result.with_indifferent_access
  end
end
