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
  def parse_payload(payload, l1_tx_index, source, source_details = {})
    return [] unless payload

    # logger.debug "FacetBatchParser: Parsing payload of length #{payload.is_a?(ByteString) ? payload.to_bin.length : payload.length}"

    batches = []
    data = payload.is_a?(ByteString) ? payload.to_bin : payload

    # Scan for magic prefix at any offset
    offset = 0

    while (index = data.index(FacetBatchConstants::MAGIC_PREFIX.to_bin, offset))
      logger.debug "FacetBatchParser: Found magic prefix at offset #{index}"
      begin
        # Need at least full header to proceed
        if index + FacetBatchConstants::HEADER_SIZE > data.length
          break
        end

        # Read and validate chain ID early (before expensive RLP parsing)
        chain_id_offset = index + FacetBatchConstants::CHAIN_ID_OFFSET
        wire_chain_id = data[chain_id_offset, FacetBatchConstants::CHAIN_ID_SIZE].unpack1('Q>')  # uint64 big-endian

        # Skip if wrong chain ID
        if wire_chain_id != chain_id
          logger.debug "Skipping batch for chain #{wire_chain_id} (expected #{chain_id})"
          # Read length to skip entire batch efficiently
          length_offset = index + FacetBatchConstants::LENGTH_OFFSET
          length = data[length_offset, FacetBatchConstants::LENGTH_SIZE].unpack1('N')  # uint32 big-endian
          offset = index + FacetBatchConstants::HEADER_SIZE + length
          # Add signature size if priority batch
          role_offset = index + FacetBatchConstants::ROLE_OFFSET
          role = data[role_offset, FacetBatchConstants::ROLE_SIZE].unpack1('C')
          offset += FacetBatchConstants::SIGNATURE_SIZE if role == FacetBatchConstants::Role::PRIORITY
          next
        end

        batch = parse_batch_at_offset(data, index, l1_tx_index, source, source_details)
        batches << batch if batch

        # Enforce max batches per payload
        if batches.length >= FacetBatchConstants::MAX_BATCHES_PER_PAYLOAD
          logger.warn "Max batches per payload reached (#{FacetBatchConstants::MAX_BATCHES_PER_PAYLOAD})"
          break
        end

        # Move past this entire batch
        # Read length to know how much to skip
        length_offset = index + FacetBatchConstants::LENGTH_OFFSET
        length = data[length_offset, FacetBatchConstants::LENGTH_SIZE].unpack1('N')
        offset = index + FacetBatchConstants::HEADER_SIZE + length
        # Add signature size if priority batch
        role_offset = index + FacetBatchConstants::ROLE_OFFSET
        role = data[role_offset, FacetBatchConstants::ROLE_SIZE].unpack1('C')
        offset += FacetBatchConstants::SIGNATURE_SIZE if role == FacetBatchConstants::Role::PRIORITY
      rescue ParseError, ValidationError => e
        logger.debug "Failed to parse batch at offset #{index}: #{e.message}"
        # Try to skip past this batch
        if index + FacetBatchConstants::HEADER_SIZE <= data.length
          length_offset = index + FacetBatchConstants::LENGTH_OFFSET
          length = data[length_offset, FacetBatchConstants::LENGTH_SIZE].unpack1('N')
          if length > 0 && length <= FacetBatchConstants::MAX_BATCH_BYTES
            offset = index + FacetBatchConstants::HEADER_SIZE + length
            # Check for priority batch signature
            role_offset = index + FacetBatchConstants::ROLE_OFFSET
            role = data[role_offset, FacetBatchConstants::ROLE_SIZE].unpack1('C')
            offset += FacetBatchConstants::SIGNATURE_SIZE if role == FacetBatchConstants::Role::PRIORITY
          else
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
  
  def parse_batch_at_offset(data, offset, l1_tx_index, source, source_details)
    # Read the fixed header fields
    # [MAGIC:8][CHAIN_ID:8][VERSION:1][ROLE:1][LENGTH:4]
    pos = offset

    # Magic prefix (already validated by caller)
    pos += FacetBatchConstants::MAGIC_SIZE

    # Chain ID (uint64 big-endian)
    return nil if pos + FacetBatchConstants::CHAIN_ID_SIZE > data.length
    wire_chain_id = data[pos, FacetBatchConstants::CHAIN_ID_SIZE].unpack1('Q>')
    pos += FacetBatchConstants::CHAIN_ID_SIZE

    # Version (uint8)
    return nil if pos + FacetBatchConstants::VERSION_SIZE > data.length
    version = data[pos, FacetBatchConstants::VERSION_SIZE].unpack1('C')
    pos += FacetBatchConstants::VERSION_SIZE

    # Role (uint8)
    return nil if pos + FacetBatchConstants::ROLE_SIZE > data.length
    role = data[pos, FacetBatchConstants::ROLE_SIZE].unpack1('C')
    pos += FacetBatchConstants::ROLE_SIZE

    # Length (uint32 big-endian)
    return nil if pos + FacetBatchConstants::LENGTH_SIZE > data.length
    length = data[pos, FacetBatchConstants::LENGTH_SIZE].unpack1('N')
    pos += FacetBatchConstants::LENGTH_SIZE

    # Validate header fields
    if version != FacetBatchConstants::VERSION
      raise ValidationError, "Invalid batch version: #{version} != #{FacetBatchConstants::VERSION}"
    end

    if wire_chain_id != chain_id
      raise ValidationError, "Invalid chain ID: #{wire_chain_id} != #{chain_id}"
    end

    unless [FacetBatchConstants::Role::PERMISSIONLESS, FacetBatchConstants::Role::PRIORITY].include?(role)
      raise ValidationError, "Invalid role: #{role}"
    end

    if length > FacetBatchConstants::MAX_BATCH_BYTES
      raise ParseError, "Batch too large: #{length} > #{FacetBatchConstants::MAX_BATCH_BYTES}"
    end

    # Read RLP_TX_LIST
    if pos + length > data.length
      raise ParseError, "RLP data extends beyond payload: need #{length} bytes, have #{data.length - pos}"
    end
    rlp_tx_list = data[pos, length]
    pos += length

    # Read signature if priority batch
    signature = nil
    if role == FacetBatchConstants::Role::PRIORITY
      if pos + FacetBatchConstants::SIGNATURE_SIZE > data.length
        raise ParseError, "Signature extends beyond payload for priority batch"
      end
      signature = data[pos, FacetBatchConstants::SIGNATURE_SIZE]
    end

    # Decode RLP transaction list
    transactions = decode_transaction_list(rlp_tx_list)

    # Calculate content hash from CHAIN_ID + VERSION + ROLE + RLP_TX_LIST + SIGNATURE
    # Including signature ensures batches with different signatures (e.g., invalid vs valid) don't deduplicate
    content_data = [wire_chain_id].pack('Q>') + [version].pack('C') + [role].pack('C') + rlp_tx_list
    if signature
      content_data += signature
    end
    content_hash = Hash32.from_bin(Eth::Util.keccak256(content_data))

    # Verify signature if enabled and priority batch
    signer = nil
    if role == FacetBatchConstants::Role::PRIORITY
      if SysConfig.enable_sig_verify?
        # Construct data to sign: [CHAIN_ID:8][VERSION:1][ROLE:1][RLP_TX_LIST]
        signed_data = [wire_chain_id].pack('Q>') + [version].pack('C') + [role].pack('C') + rlp_tx_list
        signer = verify_signature(signed_data, signature)
        raise ValidationError, "Invalid signature for priority batch" unless signer
      else
        # For testing without signatures
        logger.debug "Signature verification disabled for priority batch"
      end
    end

    # Create ParsedBatch
    ParsedBatch.new(
      role: role,
      signer: signer,
      l1_tx_index: l1_tx_index,
      source: source,
      source_details: source_details,
      transactions: transactions,
      content_hash: content_hash,
      chain_id: wire_chain_id
    )
  end
  
  def decode_transaction_list(rlp_data)
    # RLP decode transaction list - expecting an array of raw transaction bytes
    decoded = Eth::Rlp.decode(rlp_data)

    unless decoded.is_a?(Array)
      raise ParseError, "Invalid transaction list: expected RLP array"
    end

    decoded.each_with_index do |tx, index|
      unless tx.is_a?(String)
        raise ParseError, "Invalid transaction entry at index #{index}: expected byte string"
      end
    end

    # Validate transaction count
    if decoded.length > FacetBatchConstants::MAX_TXS_PER_BATCH
      raise ValidationError, "Too many transactions: #{decoded.length} > #{FacetBatchConstants::MAX_TXS_PER_BATCH}"
    end

    # Each element should be raw transaction bytes (already EIP-2718 encoded)
    decoded.map { |tx| ByteString.from_bin(tx) }
  rescue StandardError => e
    raise ParseError, "Failed to decode RLP transaction list: #{e.message}"
  end
  
  def verify_signature(signed_data, signature)
    return nil unless signature

    # Use BatchSignatureVerifier to verify the signature
    verifier = BatchSignatureVerifier.new(chain_id: chain_id)
    verifier.verify_wire_format(signed_data, signature)
  end
end
