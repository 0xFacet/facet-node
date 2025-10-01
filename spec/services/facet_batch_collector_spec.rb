require 'rails_helper'

RSpec.describe FacetBatchCollector do
  let(:block_number) { 12345 }
  let(:eth_block) do
    {
      'number' => "0x#{block_number.to_s(16)}",
      'hash' => '0x' + 'a' * 64,
      'transactions' => transactions
    }
  end
  
  let(:transactions) { [] }
  let(:receipts) { [] }
  let(:blob_provider) { BlobProvider.new }
  
  let(:collector) do
    described_class.new(
      eth_block: eth_block,
      receipts: receipts,
      blob_provider: blob_provider
    )
  end
  
  before do
    allow(SysConfig).to receive(:facet_batch_v2_enabled?).and_return(true)
  end
  
  describe '#call' do
    context 'with V1 calldata transaction' do
      let(:transactions) do
        [{
          'hash' => '0x' + 'b' * 64,
          'transactionIndex' => '0x0',
          'to' => EthTransaction::FACET_INBOX_ADDRESS.to_hex,
          'input' => create_v1_tx_payload
        }]
      end
      
      let(:receipts) do
        [{
          'transactionHash' => transactions[0]['hash'],
          'status' => '0x1',
          'logs' => []
        }]
      end
      
      it 'collects V1 single transaction' do
        result = collector.call
        
        expect(result.single_txs.length).to eq(1)
        expect(result.batches).to be_empty
        
        single = result.single_txs.first
        expect(single[:source]).to eq('calldata')
        expect(single[:tx_hash]).to eq(transactions[0]['hash'])
      end
    end
    
    context 'with V1 event transaction' do
      let(:transactions) do
        [{
          'hash' => '0x' + 'c' * 64,
          'transactionIndex' => '0x0',
          'to' => '0x' + 'd' * 40,
          'input' => '0x'
        }]
      end
      
      let(:receipts) do
        [{
          'transactionHash' => transactions[0]['hash'],
          'status' => '0x1',
          'logs' => [{
            'removed' => false,
            'topics' => [EthTransaction::FacetLogInboxEventSig.to_hex],
            'data' => create_v1_tx_payload,
            'address' => '0x' + 'e' * 40,
            'logIndex' => '0x0'
          }]
        }]
      end
      
      it 'collects V1 event transaction' do
        result = collector.call
        
        expect(result.single_txs.length).to eq(1)
        expect(result.batches).to be_empty
        
        single = result.single_txs.first
        expect(single[:source]).to eq('events')
        expect(single[:events].length).to eq(1)
      end
    end
    
    context 'with batch in calldata' do
      let(:batch_payload) { create_batch_payload }
      
      let(:transactions) do
        [{
          'hash' => '0x' + 'f' * 64,
          'transactionIndex' => '0x0',
          'to' => '0x' + '1' * 40,
          'input' => batch_payload.to_hex
        }]
      end
      
      let(:receipts) do
        [{
          'transactionHash' => transactions[0]['hash'],
          'status' => '0x1',
          'logs' => []
        }]
      end
      
      it 'collects batch from calldata' do
        result = collector.call
        
        expect(result.single_txs).to be_empty
        expect(result.batches.length).to eq(1)
        
        batch = result.batches.first
        expect(batch.source).to eq(FacetBatchConstants::Source::CALLDATA)
        expect(batch.l1_tx_index).to eq(0)
      end
    end
    
    context 'with batch in event' do
      let(:batch_payload) { create_batch_payload }
      
      let(:transactions) do
        [{
          'hash' => '0x' + '2' * 64,
          'transactionIndex' => '0x0',
          'to' => '0x' + '3' * 40,
          'input' => '0x'
        }]
      end
      
      let(:receipts) do
        [{
          'transactionHash' => transactions[0]['hash'],
          'status' => '0x1',
          'logs' => [{
            'removed' => false,
            'topics' => [EthTransaction::FacetLogInboxEventSig.to_hex],
            'data' => batch_payload.to_hex,
            'address' => '0x' + '4' * 40,
            'logIndex' => '0x0'
          }]
        }]
      end
      
      it 'does not collect batch from event (batches not supported in events)' do
        result = collector.call
        
        # V2 batches are NOT supported in events - only calldata and blobs
        expect(result.single_txs).to be_empty
        expect(result.batches).to be_empty
      end
    end
    
    context 'with duplicate batches across calldata' do
      let(:batch_payload) { create_batch_payload }
      
      let(:transactions) do
        [
          {
            'hash' => '0x' + '5' * 64,
            'transactionIndex' => '0x0',
            'to' => '0x' + '6' * 40,
            'input' => batch_payload.to_hex  # Batch in calldata
          },
          {
            'hash' => '0x' + '7' * 64,
            'transactionIndex' => '0x1',
            'to' => '0x' + '8' * 40,
            'input' => batch_payload.to_hex  # Same batch in calldata again
          }
        ]
      end
      
      let(:receipts) do
        [
          {
            'transactionHash' => transactions[0]['hash'],
            'status' => '0x1',
            'logs' => []
          },
          {
            'transactionHash' => transactions[1]['hash'],
            'status' => '0x1',
            'logs' => []
          }
        ]
      end
      
      it 'deduplicates by content hash, keeping earliest' do
        result = collector.call
        
        expect(result.batches.length).to eq(1)
        
        # Should keep the one from tx index 0 (first occurrence)
        batch = result.batches.first
        expect(batch.l1_tx_index).to eq(0)
        expect(batch.source).to eq(FacetBatchConstants::Source::CALLDATA)
        
        expect(result.stats[:deduped_batches]).to eq(1)
      end
    end
    
    context 'with mixed V1 and batch transactions' do
      let(:batch_payload) { create_batch_payload }
      let(:v1_payload) { create_v1_tx_payload }
      
      let(:transactions) do
        [
          {
            'hash' => '0x' + 'a' * 64,
            'transactionIndex' => '0x0',
            'to' => EthTransaction::FACET_INBOX_ADDRESS.to_hex,
            'input' => v1_payload  # V1 transaction
          },
          {
            'hash' => '0x' + 'b' * 64,
            'transactionIndex' => '0x1',
            'to' => '0x' + 'c' * 40,
            'input' => batch_payload.to_hex  # Batch
          }
        ]
      end
      
      let(:receipts) do
        transactions.map do |tx|
          {
            'transactionHash' => tx['hash'],
            'status' => '0x1',
            'logs' => []
          }
        end
      end
      
      it 'collects both V1 and batch transactions' do
        result = collector.call
        
        expect(result.single_txs.length).to eq(1)
        expect(result.batches.length).to eq(1)
        
        expect(result.stats[:single_txs_calldata]).to eq(1)
        expect(result.stats[:batches_calldata]).to eq(1)
      end
    end
  end
  
  private
  
  def create_v1_tx_payload
    # Create a valid V1 Facet transaction payload
    tx_type = [FacetTransaction::FACET_TX_TYPE].pack('C')
    rlp_data = Eth::Rlp.encode(['', '', '', '', '', ''])
    '0x' + (tx_type + rlp_data).unpack1('H*')
  end
  
  def create_batch_payload
    # Create a valid batch in new wire format
    chain_id = ChainIdManager.current_l2_chain_id

    # Create empty transaction list
    rlp_tx_list = Eth::Rlp.encode([])

    # Construct wire format: [MAGIC:#{FacetBatchConstants::MAGIC_SIZE}][CHAIN_ID:8][VERSION:1][ROLE:1][LENGTH:4][RLP_TX_LIST]
    magic = FacetBatchConstants::MAGIC_PREFIX.to_bin
    chain_id_bytes = [chain_id].pack('Q>')  # uint64 big-endian
    version_byte = [FacetBatchConstants::VERSION].pack('C')  # uint8
    role_byte = [FacetBatchConstants::Role::PERMISSIONLESS].pack('C')  # uint8
    length_bytes = [rlp_tx_list.length].pack('N')  # uint32 big-endian

    ByteString.from_bin(magic + chain_id_bytes + version_byte + role_byte + length_bytes + rlp_tx_list)
  end
end
