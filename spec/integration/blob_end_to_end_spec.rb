require 'rails_helper'
require 'support/blob_test_helper'

RSpec.describe 'Blob End-to-End Integration' do
  include BlobTestHelper
  include GethTestHelper
  
  let(:collector) { FacetBatchCollector.new }
  let(:parser) { FacetBatchParser.new }
  let(:builder) { FacetBlockBuilder.new }
  
  describe 'Full blob processing pipeline' do
    it 'creates, encodes, and parses a blob with Facet batch data' do
      # Step 1: Create test transactions
      puts "\n=== Creating test transactions ==="
      transactions = [
        create_test_transaction(to: "0x" + "1" * 40, value: 1000, nonce: 0),
        create_test_transaction(to: "0x" + "2" * 40, value: 2000, nonce: 1),
        create_test_transaction(to: "0x" + "3" * 40, value: 3000, nonce: 2)
      ]
      
      transactions.each_with_index do |tx, i|
        puts "  Transaction #{i}: to=#{tx.to_hex[0..10]}... value=#{i * 1000 + 1000}"
      end
      
      # Step 2: Create a Facet batch
      puts "\n=== Creating Facet batch ==="
      batch_data = create_test_batch_data(transactions)
      puts "  Batch size: #{batch_data.bytesize} bytes"
      puts "  Batch contains #{transactions.length} transactions"
      
      # Step 3: Create blob with Facet data (simulating DA Builder aggregation)
      puts "\n=== Encoding to EIP-4844 blob ==="
      
      # Add magic prefix and length header
      facet_payload = FacetBatchConstants::MAGIC_PREFIX.to_bin
      facet_payload += [batch_data.length].pack('N')
      facet_payload += batch_data
      
      # Simulate aggregation with other data
      other_rollup_data = "\xDE\xAD\xBE\xEF".b * 1000  # 4KB of other data
      aggregated = other_rollup_data + facet_payload + ("\xCA\xFE".b * 500)
      
      puts "  Total aggregated data: #{aggregated.bytesize} bytes"
      puts "  Facet data starts at offset: #{other_rollup_data.bytesize}"
      
      # Encode to blob
      blobs = BlobUtils.to_blobs(data: aggregated)
      puts "  Created #{blobs.length} blob(s)"
      puts "  Blob size: #{blobs.first.length / 2 - 1} bytes (hex: #{blobs.first.length} chars)"
      
      # Step 4: Simulate beacon provider returning the blob
      puts "\n=== Simulating beacon provider ==="
      versioned_hash = "0x01" + ("a" * 62)
      blob_bytes = ByteString.from_hex(blobs.first)
      
      beacon_provider = stub_beacon_blob_response(versioned_hash, blob_bytes)
      puts "  Stubbed beacon provider with versioned hash: #{versioned_hash[0..10]}..."
      
      # Step 5: Fetch and decode the blob
      puts "\n=== Fetching and decoding blob ==="
      fetched_blob = beacon_provider.get_blob(versioned_hash, block_number: 12345)
      expect(fetched_blob).not_to be_nil
      puts "  Successfully fetched blob"
      
      # Step 6: Parse Facet batches from the decoded blob
      puts "\n=== Parsing Facet batches from blob ==="
      
      # Decode from EIP-4844 format
      decoded_data = BlobUtils.from_blobs(blobs: [fetched_blob.to_hex])
      decoded_bytes = ByteString.from_hex(decoded_data)
      puts "  Decoded data size: #{decoded_bytes.to_bin.bytesize} bytes"
      
      # Parse batches
      parsed_batches = parser.parse_payload(
        decoded_bytes,
        12345,  # l1_block_number
        0,      # l1_tx_index
        FacetBatchConstants::Source::BLOB,
        { versioned_hash: versioned_hash }
      )
      
      puts "  Found #{parsed_batches.length} Facet batch(es)"
      
      # Step 7: Verify the parsed batch
      puts "\n=== Verifying parsed batch ==="
      expect(parsed_batches.length).to eq(1)
      
      batch = parsed_batches.first
      expect(batch.transactions.length).to eq(3)
      expect(batch.source).to eq(FacetBatchConstants::Source::BLOB)
      expect(batch.role).to eq(FacetBatchConstants::Role::FORCED)
      
      puts "  ✓ Batch role: #{batch.role == 1 ? 'FORCED' : 'SEQUENCER'}"
      puts "  ✓ Transaction count: #{batch.transactions.length}"
      puts "  ✓ Source: #{batch.source_description}"
      puts "  ✓ Target L1 block: #{batch.target_l1_block}"
      
      # Verify transaction details
      batch.transactions.each_with_index do |tx, i|
        expected_value = (i + 1) * 1000
        actual_value = Eth::Rlp.decode(tx.to_bin[1..-1])[6]
        actual_value = actual_value.empty? ? 0 : Eth::Util.deserialize_big_endian_to_int(actual_value)
        
        puts "  ✓ Transaction #{i}: value=#{actual_value} (expected #{expected_value})"
        expect(actual_value).to eq(expected_value)
      end
      
      puts "\n=== ✅ All tests passed! ==="
    end
    
    it 'handles multiple Facet batches in a single blob' do
      puts "\n=== Testing multiple batches in one blob ==="
      
      # Create two separate batches
      batch1_txs = [create_test_transaction(value: 100, nonce: 0)]
      batch2_txs = [create_test_transaction(value: 200, nonce: 1)]
      
      batch1_data = create_test_batch_data(batch1_txs)
      batch2_data = create_test_batch_data(batch2_txs)
      
      # Create payloads with magic prefix
      payload1 = FacetBatchConstants::MAGIC_PREFIX.to_bin + [batch1_data.length].pack('N') + batch1_data
      payload2 = FacetBatchConstants::MAGIC_PREFIX.to_bin + [batch2_data.length].pack('N') + batch2_data
      
      # Aggregate with padding
      aggregated = payload1 + ("\x00".b * 1000) + payload2
      
      # Encode to blob
      blobs = BlobUtils.to_blobs(data: aggregated)
      
      # Decode and parse
      decoded = BlobUtils.from_blobs(blobs: blobs)
      decoded_bytes = ByteString.from_hex(decoded)
      
      parsed_batches = parser.parse_payload(
        decoded_bytes,
        12345,
        0,
        FacetBatchConstants::Source::BLOB
      )
      
      expect(parsed_batches.length).to eq(2)
      puts "  ✓ Found #{parsed_batches.length} batches"
      
      expect(parsed_batches[0].transactions.length).to eq(1)
      expect(parsed_batches[1].transactions.length).to eq(1)
      puts "  ✓ Each batch has correct transaction count"
    end
    
    it 'correctly handles blob size limits' do
      puts "\n=== Testing blob size limits ==="
      
      # Create maximum size data (just under limit)
      max_size = BlobUtils::MAX_BYTES_PER_TRANSACTION - 1000
      large_data = "A" * max_size
      
      # Should succeed
      blobs = BlobUtils.to_blobs(data: large_data)
      expect(blobs.length).to be >= 1
      puts "  ✓ Successfully encoded #{max_size} bytes into #{blobs.length} blob(s)"
      
      # Test oversized data
      oversized = "B" * (BlobUtils::MAX_BYTES_PER_TRANSACTION + 1)
      
      expect {
        BlobUtils.to_blobs(data: oversized)
      }.to raise_error(BlobUtils::BlobSizeTooLargeError)
      puts "  ✓ Correctly rejected oversized data"
    end
    
    it 'preserves data integrity through encode/decode cycle' do
      puts "\n=== Testing data integrity ==="
      
      # Test various data patterns
      test_cases = [
        { name: "Binary data", data: "\x00\x01\x02\x80\xFF".b * 100 },
        { name: "Text data", data: "Hello, Facet! " * 1000 },
        { name: "Hex string", data: "0x" + ("deadbeefcafe" * 100) },
        { name: "Mixed content", data: "Text\x00Binary\x80\xFFMore".b }
      ]
      
      test_cases.each do |test_case|
        puts "\n  Testing: #{test_case[:name]}"
        
        # Encode
        blobs = BlobUtils.to_blobs(data: test_case[:data])
        puts "    Encoded to #{blobs.length} blob(s)"
        
        # Decode
        decoded = BlobUtils.from_blobs(blobs: blobs)
        
        # Compare (accounting for hex conversion)
        if test_case[:data].start_with?("0x")
          expect(decoded).to eq(test_case[:data])
        else
          expect(decoded).to eq("0x" + test_case[:data].unpack1('H*'))
        end
        
        puts "    ✓ Data integrity preserved"
      end
    end
  end
  
  describe 'Error handling' do
    it 'handles corrupted magic prefix gracefully' do
      bad_magic = "\x00\x00\x00\x00\x00\x01\x23\x46".b  # Wrong last byte
      payload = bad_magic + [100].pack('N') + ("X".b * 100)
      
      blobs = BlobUtils.to_blobs(data: payload)
      decoded = BlobUtils.from_blobs(blobs: blobs)
      decoded_bytes = ByteString.from_hex(decoded)
      
      batches = parser.parse_payload(decoded_bytes, 12345, 0, FacetBatchConstants::Source::BLOB)
      
      expect(batches).to be_empty
      puts "  ✓ Correctly ignored batch with bad magic"
    end
    
    it 'handles empty blobs' do
      expect {
        BlobUtils.to_blobs(data: "")
      }.to raise_error(BlobUtils::EmptyBlobError)
      
      expect {
        BlobUtils.to_blobs(data: "0x")
      }.to raise_error(BlobUtils::EmptyBlobError)
      
      puts "  ✓ Correctly rejected empty blobs"
    end
  end
end