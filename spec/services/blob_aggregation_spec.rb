require 'rails_helper'
require 'support/blob_test_helper'

RSpec.describe 'Blob Aggregation Scenarios' do
  include BlobTestHelper
  
  describe 'DA Builder aggregation patterns' do
    let(:parser) { FacetBatchParser.new }
    
    it 'finds Facet batch at start of aggregated blob' do
      blob = create_test_blob_with_facet_data(position: :start)
      batches = extract_facet_batches_from_blob(blob)
      
      expect(batches.length).to eq(1)
      expect(batches.first.transactions).not_to be_empty
    end
    
    it 'finds Facet batch in middle of aggregated blob' do
      blob = create_test_blob_with_facet_data(position: :middle)
      batches = extract_facet_batches_from_blob(blob)
      
      expect(batches.length).to eq(1)
      expect(batches.first.source).to eq(FacetBatchConstants::Source::BLOB)
    end
    
    it 'finds Facet batch at end of aggregated blob' do
      blob = create_test_blob_with_facet_data(position: :end)
      batches = extract_facet_batches_from_blob(blob)
      
      expect(batches.length).to eq(1)
    end
    
    it 'finds multiple Facet batches in single blob' do
      blob = create_test_blob_with_facet_data(position: :multiple)
      batches = extract_facet_batches_from_blob(blob)
      
      expect(batches.length).to eq(2)
      # Should be in order they appear in blob
      expect(batches[0].l1_tx_index).to eq(0)
      expect(batches[1].l1_tx_index).to eq(0)
    end
    
    it 'handles blob with no Facet data' do
      # Simulate other rollup's data only
      blob = ByteString.from_bin("\xDE\xAD\xBE\xEF".b * 32_768)  # 128KB of non-Facet data
      batches = extract_facet_batches_from_blob(blob)
      
      expect(batches).to be_empty
    end
    
    it 'handles corrupted magic prefix' do
      # Create blob with almost-correct magic
      bad_magic = "\x00\x00\x00\x00\x00\x01\x23\x46".b  # One byte off
      blob_data = bad_magic + [100].pack('N') + ("\x00".b * 100)
      blob_data += "\x00".b * (131_072 - blob_data.length)
      
      blob = ByteString.from_bin(blob_data)
      batches = extract_facet_batches_from_blob(blob)
      
      expect(batches).to be_empty
    end
    
    it 'handles batch that claims size beyond blob boundary' do
      # Create batch that claims to be huge
      magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
      huge_size = [200_000].pack('N')  # Claims 200KB but blob is only 128KB
      
      blob_data = magic + huge_size + ("\x00".b * 100)
      blob_data += "\x00".b * (131_072 - blob_data.length)
      
      blob = ByteString.from_bin(blob_data)
      batches = extract_facet_batches_from_blob(blob)
      
      expect(batches).to be_empty  # Should reject invalid size
    end
  end
  
  describe 'Round-trip encoding' do
    it 'survives encode -> blob -> parse cycle' do
      # Create test transactions
      transactions = 3.times.map do |i|
        create_test_transaction(nonce: i, value: 1000 * (i + 1))
      end
      
      # Create batch
      batch = ParsedBatch.new(
        role: FacetBatchConstants::Role::FORCED,
        signer: nil,
        target_l1_block: 12345,
        l1_tx_index: 0,
        source: FacetBatchConstants::Source::BLOB,
        source_details: {},
        transactions: transactions,
        content_hash: Hash32.from_bin(Eth::Util.keccak256("test")),
        chain_id: ChainIdManager.current_l2_chain_id,
        extra_data: ByteString.from_bin("".b)
      )
      
      # Encode for blob
      batch_data = [
        Eth::Util.serialize_int_to_big_endian(1),
        Eth::Util.serialize_int_to_big_endian(batch.chain_id),
        Eth::Util.serialize_int_to_big_endian(batch.role),
        Eth::Util.serialize_int_to_big_endian(batch.target_l1_block),
        batch.transactions.map(&:to_bin),
        ''
      ]
      
      facet_batch = [batch_data, '']
      rlp_encoded = Eth::Rlp.encode(facet_batch)
      
      # Add wire format
      payload = FacetBatchConstants::MAGIC_PREFIX.to_bin
      payload += [rlp_encoded.length].pack('N')
      payload += rlp_encoded
      
      # Embed in blob
      blob_data = payload + ("\x00".b * (131_072 - payload.length))
      blob = ByteString.from_bin(blob_data)
      
      # Parse back
      parser = FacetBatchParser.new
      parsed_batches = parser.parse_payload(
        blob,
        batch.target_l1_block,
        0,
        FacetBatchConstants::Source::BLOB
      )
      
      expect(parsed_batches.length).to eq(1)
      parsed = parsed_batches.first
      
      expect(parsed.role).to eq(batch.role)
      expect(parsed.target_l1_block).to eq(batch.target_l1_block)
      expect(parsed.transactions.length).to eq(3)
      expect(parsed.transactions.map(&:to_bin)).to eq(transactions.map(&:to_bin))
    end
  end
  
  describe 'Property tests' do
    it 'handles random payloads up to 128KB' do
      100.times do
        # Generate random size
        size = rand(100..120_000)
        
        # Generate random transactions
        tx_count = rand(1..10)
        transactions = tx_count.times.map do |i|
          create_test_transaction(nonce: i, value: rand(0..10000))
        end
        
        # Create batch with random data
        batch_data = create_test_batch_data(transactions)
        
        # Add to blob with random position
        position = [:start, :middle, :end].sample
        blob = create_test_blob_with_facet_data(
          transactions: transactions,
          position: position
        )
        
        # Should be able to extract
        batches = extract_facet_batches_from_blob(blob)
        
        expect(batches).not_to be_empty
        expect(batches.first.transactions.length).to eq(transactions.length)
      end
    end
    
    it 'correctly handles maximum blob utilization' do
      # Try to pack as much as possible into a blob
      transactions = []
      total_size = 0
      
      # Keep adding transactions until we approach the limit
      while total_size < 100_000  # Leave room for encoding overhead
        tx = create_test_transaction(nonce: transactions.length)
        tx_size = tx.to_bin.length
        
        break if total_size + tx_size + 100 > 120_000  # Safety margin
        
        transactions << tx
        total_size += tx_size
      end
      
      # Create blob with maximum transactions
      blob = create_test_blob_with_facet_data(transactions: transactions)
      
      # Should successfully extract all transactions
      batches = extract_facet_batches_from_blob(blob)
      
      expect(batches.length).to eq(1)
      expect(batches.first.transactions.length).to eq(transactions.length)
    end
  end
  
  describe 'Beacon API response handling' do
    it 'parses beacon blob sidecar format' do
      # Create test blob
      blob_data = create_test_blob_with_facet_data
      
      # Create beacon API response
      sidecar = create_beacon_blob_sidecar_response(blob_data, slot: 5000)
      
      # Extract blob data from sidecar
      decoded_blob = Base64.decode64(sidecar["blob"])
      
      expect(decoded_blob.length).to eq(131_072)  # Full blob size
      
      # Should find Facet data
      blob = ByteString.from_bin(decoded_blob)
      batches = extract_facet_batches_from_blob(blob)
      
      expect(batches).not_to be_empty
    end
  end
end