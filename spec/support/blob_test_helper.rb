# Helper methods for testing blob functionality
require 'blob_utils'

module BlobTestHelper
  # Create a test blob with Facet batch data embedded using proper EIP-4844 encoding
  def create_test_blob_with_facet_data(transactions: [], position: :start)
    # Create RLP transaction list
    rlp_tx_list = create_test_batch_data(transactions)

    # Build complete wire format
    chain_id = ChainIdManager.current_l2_chain_id
    facet_payload = FacetBatchConstants::MAGIC_PREFIX.to_bin
    facet_payload += [chain_id].pack('Q>')  # uint64 big-endian
    facet_payload += [FacetBatchConstants::VERSION].pack('C')
    facet_payload += [FacetBatchConstants::Role::PERMISSIONLESS].pack('C')
    facet_payload += [rlp_tx_list.length].pack('N')
    facet_payload += rlp_tx_list
    
    # Create aggregated data based on position
    aggregated_data = case position
    when :start
      # Facet data at beginning
      facet_payload + ("\x00".b * 1000)  # Some padding
    when :middle
      # Facet data in middle (simulating aggregation with other users)
      padding_before = "\xFF".b * 5_000  # Other user's data
      padding_after = "\xEE".b * 2_000
      padding_before + facet_payload + padding_after
    when :end
      # Facet data at end
      padding = "\xAB".b * 10_000
      padding + facet_payload
    when :multiple
      # Multiple Facet batches in same blob
      second_rlp_tx_list = create_test_batch_data([create_test_transaction])

      # Build complete wire format for second batch
      second_payload = FacetBatchConstants::MAGIC_PREFIX.to_bin
      second_payload += [chain_id].pack('Q>')  # uint64 big-endian
      second_payload += [FacetBatchConstants::VERSION].pack('C')
      second_payload += [FacetBatchConstants::Role::PERMISSIONLESS].pack('C')
      second_payload += [second_rlp_tx_list.length].pack('N')
      second_payload += second_rlp_tx_list
      
      # Put both batches with padding between
      first_part = facet_payload
      padding = "\xCD".b * 1_000
      second_part = second_payload
      
      first_part + padding + second_part
    else
      raise "Unknown position: #{position}"
    end
    
    # Use BlobUtils to properly encode into EIP-4844 blob format
    blobs = BlobUtils.to_blobs(data: aggregated_data)
    
    # Return the first blob as ByteString (should only need one for our test data)
    ByteString.from_hex(blobs.first)
  end
  
  # Create test batch data (RLP-encoded transaction list)
  def create_test_batch_data(transactions = [])
    # Default to one test transaction if none provided
    if transactions.empty?
      transactions = [create_test_transaction]
    end

    # Return RLP-encoded transaction list
    Eth::Rlp.encode(transactions.map(&:to_bin))
  end
  
  # Create a test EIP-1559 transaction
  def create_test_transaction(to: nil, value: 0, nonce: 0)
    to_address = to || ("0x" + "1" * 40)
    
    # Create minimal EIP-1559 transaction
    tx_data = [
      Eth::Util.serialize_int_to_big_endian(ChainIdManager.current_l2_chain_id),
      Eth::Util.serialize_int_to_big_endian(nonce),
      Eth::Util.serialize_int_to_big_endian(1_000_000_000),  # maxPriorityFee
      Eth::Util.serialize_int_to_big_endian(2_000_000_000),  # maxFee
      Eth::Util.serialize_int_to_big_endian(21_000),  # gasLimit
      Eth::Util.hex_to_bin(to_address),  # to
      Eth::Util.serialize_int_to_big_endian(value),  # value
      '',  # data
      [],  # accessList
      Eth::Util.serialize_int_to_big_endian(0),  # v
      "\x00".b * 31 + "\x01".b,  # r (dummy)
      "\x00".b * 31 + "\x02".b   # s (dummy)
    ]
    
    # Prefix with type byte for EIP-1559
    ByteString.from_bin("\x02".b + Eth::Rlp.encode(tx_data))
  end
  
  # Stub beacon client responses
  def stub_beacon_blob_response(versioned_hash, blob_data)
    beacon_provider = instance_double(BlobProvider)
    
    allow(beacon_provider).to receive(:get_blob).with(versioned_hash, anything) do
      blob_data
    end
    
    allow(beacon_provider).to receive(:list_carriers).and_return([
      {
        tx_hash: "0x" + "a" * 64,
        tx_index: 0,
        versioned_hashes: [versioned_hash]
      }
    ])
    
    beacon_provider
  end
  
  # Create a mock beacon API response
  def create_beacon_blob_sidecar_response(blob_data, slot: 1000, index: 0)
    # Ensure blob is properly sized
    blob_bytes = blob_data.to_bin
    if blob_bytes.length != BlobUtils::BYTES_PER_BLOB
      # Encode to proper blob if not already
      blobs = BlobUtils.to_blobs(data: blob_bytes)
      blob_bytes = [blobs.first.sub(/^0x/, '')].pack('H*')
    end
    
    # Beacon API blob sidecar format
    {
      "index" => index.to_s,
      "blob" => Base64.encode64(blob_bytes),
      "kzg_commitment" => "0x" + "b" * 96,  # Dummy KZG commitment
      "kzg_proof" => "0x" + "c" * 96,  # Dummy KZG proof
      "signed_block_header" => {
        "message" => {
          "slot" => slot.to_s,
          "proposer_index" => "12345",
          "parent_root" => "0x" + "d" * 64,
          "state_root" => "0x" + "e" * 64,
          "body_root" => "0x" + "f" * 64
        }
      },
      "kzg_commitment_inclusion_proof" => ["0x" + "0" * 64] * 17
    }
  end
  
  # Simulate blob aggregation scenario (multiple rollups in one blob)
  def create_aggregated_blob(rollup_payloads)
    # Simulate how DA Builder would aggregate multiple rollups
    combined_data = ""
    
    rollup_payloads.each_with_index do |payload, i|
      # Add some padding between payloads to simulate real aggregation
      combined_data += ("\xEE".b * rand(100..500)) if i > 0
      combined_data += payload.is_a?(ByteString) ? payload.to_bin : payload
    end
    
    # Use BlobUtils to create proper EIP-4844 blob
    blobs = BlobUtils.to_blobs(data: combined_data)
    ByteString.from_hex(blobs.first)
  end
  
  # Helper to verify batch extraction from blob
  def extract_facet_batches_from_blob(blob_data)
    # First decode from EIP-4844 blob format if it's a properly encoded blob
    decoded_data = if blob_data.to_bin.length == BlobUtils::BYTES_PER_BLOB
      # This is a full blob, decode it
      BlobUtils.from_blobs(blobs: [blob_data.to_hex])
    else
      # Raw data, use as-is
      blob_data
    end
    
    parser = FacetBatchParser.new
    parser.parse_payload(
      decoded_data.is_a?(String) ? ByteString.from_hex(decoded_data) : decoded_data,
      0,      # l1_tx_index
      FacetBatchConstants::Source::BLOB,
      { versioned_hash: "0x" + "a" * 64 }
    )
  end
  
  # Create test blob commitment (not cryptographically valid)
  def create_test_blob_commitment(blob_data)
    # WARNING: This is NOT a real KZG commitment
    # For testing only - real implementation needs ckzg library
    hash = Eth::Util.keccak256(blob_data.to_bin)
    "0x01" + hash[2..63]  # Version prefix + truncated hash
  end
end