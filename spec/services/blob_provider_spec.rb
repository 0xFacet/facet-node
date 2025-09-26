require 'rails_helper'
require 'support/blob_test_helper'

RSpec.describe BlobProvider do
  include BlobTestHelper
  
  describe 'blob fetching' do
    let(:provider) { described_class.new }
    let(:versioned_hash) { "0x01" + "a" * 62 }
    
    describe '#get_blob' do
      context 'when blob contains Facet data' do
        let(:test_transactions) { [create_test_transaction(value: 1000)] }
        let(:blob_data) { create_test_blob_with_facet_data(transactions: test_transactions, position: :middle) }
        
        before do
          # Stub beacon API response
          allow(provider).to receive(:fetch_blob_from_beacon).with(versioned_hash, block_number: 12345).and_return(blob_data)
        end
        
        it 'returns the decoded data from the blob' do
          result = provider.get_blob(versioned_hash, block_number: 12345)
          
          # The provider returns decoded data, not the raw blob
          # Decode the test blob to compare
          decoded_test_data = BlobUtils.from_blobs(blobs: [blob_data.to_hex])
          expected = ByteString.from_hex(decoded_test_data)
          
          expect(result).to eq(expected)
        end
        
      end
      
      context 'when blob does not contain Facet data' do
        let(:non_facet_data) { "\xFF".b * 10_000 }  # Some non-Facet data
        let(:blob_data) do
          # Encode the non-Facet data into a proper blob
          blobs = BlobUtils.to_blobs(data: non_facet_data)
          ByteString.from_hex(blobs.first)
        end
        
        before do
          allow(provider).to receive(:fetch_blob_from_beacon).with(versioned_hash, block_number: 12345).and_return(blob_data)
        end
        
        it 'still returns the decoded data (provider is content-agnostic)' do
          result = provider.get_blob(versioned_hash, block_number: 12345)
          
          # The provider should return the decoded data regardless of content
          decoded_test_data = BlobUtils.from_blobs(blobs: [blob_data.to_hex])
          expected = ByteString.from_hex(decoded_test_data)
          
          expect(result).to eq(expected)
          expect(result).not_to be_nil
        end
      end
      
      context 'when beacon API is unavailable' do
        before do
          allow(provider).to receive(:fetch_blob_from_beacon).with(anything, anything).and_raise(Net::HTTPError.new("Connection failed", nil))
        end
        
        it 'returns nil' do
          result = provider.get_blob(versioned_hash, block_number: 12345)
          expect(result).to be_nil
        end
      end
    end
    
    describe '#list_carriers' do
      let(:block_number) { 12345 }
      let(:ethereum_client) { instance_double(EthRpcClient) }
      
      before do
        allow(provider).to receive(:ethereum_client).and_return(ethereum_client)
      end
      
      context 'with blob transactions in block' do
        let(:block_result) do
          {
            'number' => "0x#{block_number.to_s(16)}",
            'transactions' => [
              {
                'hash' => '0x' + '1' * 64,
                'transactionIndex' => '0x0',
                'type' => '0x03',  # EIP-4844 type
                'blobVersionedHashes' => ['0x01' + 'a' * 62, '0x01' + 'b' * 62]
              },
              {
                'hash' => '0x' + '2' * 64,
                'transactionIndex' => '0x1',
                'type' => '0x02'  # Regular EIP-1559 - no blobs
              },
              {
                'hash' => '0x' + '3' * 64,
                'transactionIndex' => '0x2',
                'type' => '0x03',  # Another blob tx
                'blobVersionedHashes' => ['0x01' + 'c' * 62]
              }
            ]
          }
        end
        
        before do
          allow(ethereum_client).to receive(:get_block).with(block_number, true).and_return(block_result)
        end
        
        it 'returns carriers with blob versioned hashes' do
          carriers = provider.list_carriers(block_number)
          
          expect(carriers.length).to eq(2)  # Only blob transactions
          
          expect(carriers[0]).to eq({
            tx_hash: '0x' + '1' * 64,
            tx_index: 0,
            versioned_hashes: ['0x01' + 'a' * 62, '0x01' + 'b' * 62]
          })
          
          expect(carriers[1]).to eq({
            tx_hash: '0x' + '3' * 64,
            tx_index: 2,
            versioned_hashes: ['0x01' + 'c' * 62]
          })
        end
      end
      
      context 'with no blob transactions' do
        let(:block_result) do
          {
            'number' => "0x#{block_number.to_s(16)}",
            'transactions' => [
              { 'hash' => '0x' + '1' * 64, 'type' => '0x02' }
            ]
          }
        end
        
        before do
          allow(ethereum_client).to receive(:get_block).with(block_number, true).and_return(block_result)
        end
        
        it 'returns empty array' do
          carriers = provider.list_carriers(block_number)
          expect(carriers).to be_empty
        end
      end
    end
  end
  
  describe 'Integration with FacetBatchCollector' do
    include BlobTestHelper
    
    let(:block_number) { 12345 }
    let(:versioned_hash) { "0x01" + "f" * 62 }
    
    xit 'successfully extracts Facet batches from aggregated blob (TODO: fix integration test)' do
      # Create a blob with Facet data in the middle (simulating DA Builder aggregation)
      aggregated_blob = create_test_blob_with_facet_data(position: :middle)
      
      # Stub the beacon provider
      beacon_provider = stub_beacon_blob_response(versioned_hash, aggregated_blob)
      
      # Set up a transaction that carries a blob
      tx_hash = '0x' + 'a' * 64
      
      # Create a blob transaction (type 3)
      blob_tx = {
        'hash' => tx_hash,
        'transactionIndex' => '0x0',
        'type' => '0x3',  # Blob transaction
        'from' => '0x' + 'b' * 40,
        'to' => '0x' + 'c' * 40,
        'input' => '0x'
      }
      
      # Create receipt with blob versioned hashes
      receipt = {
        'transactionHash' => tx_hash,
        'transactionIndex' => '0x0',
        'status' => '0x1',  # Success
        'blobVersionedHashes' => [versioned_hash],
        'logs' => []
      }
      
      eth_block = {
        'number' => "0x#{block_number.to_s(16)}",
        'transactions' => [blob_tx]
      }
      
      collector = FacetBatchCollector.new(
        eth_block: eth_block,
        receipts: [receipt],
        blob_provider: beacon_provider
      )
      
      # Simulate list_carriers returning our blob
      allow(beacon_provider).to receive(:list_carriers).with(block_number).and_return([
        {
          tx_hash: tx_hash,
          tx_index: 0,
          versioned_hashes: [versioned_hash]
        }
      ])
      
      # Collect should find our batch
      result = collector.call
      
      expect(result.batches).not_to be_empty
      expect(result.stats[:batches_blobs]).to eq(1)
    end
    
    it 'handles multiple Facet batches in single blob' do
      blob_data = create_test_blob_with_facet_data(position: :multiple)
      
      # Extract batches using parser
      batches = extract_facet_batches_from_blob(blob_data)
      
      expect(batches.length).to eq(2)
      expect(batches.all? { |b| b.is_a?(ParsedBatch) }).to be true
    end
    
    it 'handles missing blobs gracefully' do
      beacon_provider = stub_beacon_blob_response(versioned_hash, nil)  # Blob not found
      
      eth_block = {
        'number' => "0x#{block_number.to_s(16)}",
        'transactions' => []
      }
      
      collector = FacetBatchCollector.new(
        eth_block: eth_block,
        receipts: [],
        blob_provider: beacon_provider
      )
      
      allow(beacon_provider).to receive(:list_carriers).with(block_number).and_return([
        {
          tx_hash: '0x' + 'a' * 64,
          tx_index: 0,
          versioned_hashes: [versioned_hash]
        }
      ])
      
      result = collector.call
      
      expect(result.batches).to be_empty
      expect(result.stats[:missing_blobs]).to eq(1)
    end
  end
end