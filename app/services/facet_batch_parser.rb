# Parser for Facet batch format v2
# Scans payloads for magic prefix, validates, and extracts transactions
class FacetBatchParser
  
  class ParseError < StandardError; end
  class ValidationError < StandardError; end
  
  attr_reader :chain_id, :logger
  
  def initialize(chain_id: ChainIdManager.current_l2_chain_id, logger: Rails.logger)
    @chain_id = chain_id
    @logger = logger
  end
  
  # Parse a payload (calldata, event data, or blob) for batches
  # Returns array of ParsedBatch objects
  def parse_payload(payload, l1_block_number, l1_tx_index, source, source_details = {})
    return [] unless payload
    
    # logger.debug "FacetBatchParser: Parsing payload of length #{payload.is_a?(ByteString) ? payload.to_bin.length : payload.length} for block #{l1_block_number}"
    
    batches = []
    data = payload.is_a?(ByteString) ? payload.to_bin : payload
    
    # Scan for magic prefix at any offset
    offset = 0
    magic_len = FacetBatchConstants::MAGIC_PREFIX.to_bin.length
    
    while (index = data.index(FacetBatchConstants::MAGIC_PREFIX.to_bin, offset))
      logger.debug "FacetBatchParser: Found magic prefix at offset #{index}"
      begin
        # Read length field to know how much to skip
        length_pos = index + magic_len
        if length_pos + 4 <= data.length
          length = data[length_pos, 4].unpack1('N')
          
          batch = parse_batch_at_offset(data, index, l1_block_number, l1_tx_index, source, source_details)
          batches << batch if batch
          
          # Enforce max batches per payload
          if batches.length >= FacetBatchConstants::MAX_BATCHES_PER_PAYLOAD
            logger.warn "Max batches per payload reached (#{FacetBatchConstants::MAX_BATCHES_PER_PAYLOAD})"
            break
          end
          
          # Move past this entire batch (magic + length field + batch data)
          offset = index + magic_len + 4 + length
        else
          # Not enough data for length field
          break
        end
      rescue ParseError, ValidationError => e
        logger.debug "Failed to parse batch at offset #{index}: #{e.message}"
        # If we got a valid length, skip past the entire claimed batch to avoid O(N²) scanning
        if length_pos + 4 <= data.length
          length = data[length_pos, 4].unpack1('N')
          if length > 0 && length <= FacetBatchConstants::MAX_BATCH_BYTES
            # Skip past the entire malformed batch
            offset = index + magic_len + 4 + length
          else
            # Invalid length, just skip past magic
            offset = index + 1
          end
        else
          offset = index + 1
        end
      end
    end
    
    batches
  end
  
  private
  
  def parse_batch_at_offset(data, offset, l1_block_number, l1_tx_index, source, source_details)
    # Skip magic prefix
    pos = offset + FacetBatchConstants::MAGIC_PREFIX.to_bin.length
    
    # Read length field (uint32)
    return nil if pos + 4 > data.length
    length = data[pos, 4].unpack1('N')  # Network byte order (big-endian)
    pos += 4
    
    # Bounds check
    if length > FacetBatchConstants::MAX_BATCH_BYTES
      raise ParseError, "Batch too large: #{length} > #{FacetBatchConstants::MAX_BATCH_BYTES}"
    end
    
    if pos + length > data.length
      raise ParseError, "Batch extends beyond payload: need #{length} bytes, have #{data.length - pos}"
    end
    
    # Extract batch data
    batch_data = data[pos, length]
    
    # Decode RLP-encoded FacetBatch
    decoded = decode_facet_batch_rlp(batch_data)
    
    # Validate batch
    validate_batch(decoded, l1_block_number)
    
    # Verify signature if enabled and priority batch
    signer = nil
    if decoded[:role] == FacetBatchConstants::Role::PRIORITY
      if SysConfig.enable_sig_verify?
        signer = verify_signature(decoded[:batch_data], decoded[:signature])
        raise ValidationError, "Invalid signature for priority batch" unless signer
      else
        # For testing without signatures
        logger.debug "Signature verification disabled for priority batch"
      end
    end
    
    # Create ParsedBatch
    ParsedBatch.new(
      role: decoded[:role],
      signer: signer,
      target_l1_block: decoded[:target_l1_block],
      l1_tx_index: l1_tx_index,
      source: source,
      source_details: source_details,
      transactions: decoded[:transactions],
      content_hash: decoded[:content_hash],
      chain_id: decoded[:chain_id],
      extra_data: decoded[:extra_data]
    )
  end
  
  def decode_facet_batch_rlp(data)
    # RLP decode: [FacetBatchData, signature?]
    # FacetBatchData = [version, chainId, role, targetL1Block, transactions[], extraData]
    
    decoded = Eth::Rlp.decode(data)
    
    unless decoded.is_a?(Array) && (decoded.length == 1 || decoded.length == 2)
      raise ParseError, "Invalid batch structure: expected [FacetBatchData] or [FacetBatchData, signature]"
    end
    
    batch_data_rlp = decoded[0]
    # For forced batches, signature can be omitted (length=1) or empty string (length=2)
    signature = decoded.length == 2 ? decoded[1] : ''
    
    unless batch_data_rlp.is_a?(Array) && batch_data_rlp.length == 6
      raise ParseError, "Invalid FacetBatchData: expected 6 fields, got #{batch_data_rlp.length}"
    end
    
    # Parse FacetBatchData fields
    version = deserialize_rlp_int(batch_data_rlp[0])
    chain_id = deserialize_rlp_int(batch_data_rlp[1])
    role = deserialize_rlp_int(batch_data_rlp[2])
    target_l1_block = deserialize_rlp_int(batch_data_rlp[3])
    
    # Transactions array - each element is raw EIP-2718 typed tx bytes
    unless batch_data_rlp[4].is_a?(Array)
      raise ParseError, "Invalid transactions field: expected array"
    end
    transactions = batch_data_rlp[4].map { |tx| ByteString.from_bin(tx) }
    
    # Extra data
    extra_data = batch_data_rlp[5].empty? ? nil : ByteString.from_bin(batch_data_rlp[5])
    
    # Calculate content hash from FacetBatchData only (excluding signature)
    batch_data_encoded = Eth::Rlp.encode(batch_data_rlp)
    content_hash = Hash32.from_bin(Eth::Util.keccak256(batch_data_encoded))
    
    {
      version: version,
      chain_id: chain_id,
      role: role,
      target_l1_block: target_l1_block,
      transactions: transactions,
      extra_data: extra_data,
      content_hash: content_hash,
      batch_data: batch_data_rlp,  # Keep for signature verification
      signature: signature ? ByteString.from_bin(signature.b) : nil
    }
  rescue => e
    raise ParseError, "Failed to decode RLP batch: #{e.message}"
  end
  
  # Deserialize RLP integer with same logic as FacetTransaction
  def deserialize_rlp_int(data)
    return 0 if data.empty?
    
    # Check for leading zeros (invalid in RLP)
    if data.length > 1 && data[0] == "\x00"
      raise ParseError, "Invalid RLP integer: leading zeros"
    end
    
    data.unpack1('H*').to_i(16)
  end
  
  def validate_batch(decoded, l1_block_number)
    # Check version
    if decoded[:version] != FacetBatchConstants::VERSION
      raise ValidationError, "Invalid batch version: #{decoded[:version]} != #{FacetBatchConstants::VERSION}"
    end
    
    # Check chain ID
    if decoded[:chain_id] != chain_id
      raise ValidationError, "Invalid chain ID: #{decoded[:chain_id]} != #{chain_id}"
    end
    
    # TODO: make work or discard
    # Check target block
    # if decoded[:target_l1_block] != l1_block_number
    #   raise ValidationError, "Invalid target block: #{decoded[:target_l1_block]} != #{l1_block_number}"
    # end
    
    # Check transaction count
    if decoded[:transactions].length > FacetBatchConstants::MAX_TXS_PER_BATCH
      raise ValidationError, "Too many transactions: #{decoded[:transactions].length} > #{FacetBatchConstants::MAX_TXS_PER_BATCH}"
    end
    
    # Check role
    unless [FacetBatchConstants::Role::FORCED, FacetBatchConstants::Role::PRIORITY].include?(decoded[:role])
      raise ValidationError, "Invalid role: #{decoded[:role]}"
    end
  end
  
  def verify_signature(data, signature)
    # TODO: Implement EIP-712 signature verification
    # For now, return nil (signature not verified)
    nil
  end
end
