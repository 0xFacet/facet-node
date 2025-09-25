require 'rails_helper'
require 'l1_rpc_prefetcher'

RSpec.describe L1RpcPrefetcher do
  let(:ethereum_client) { instance_double(EthRpcClient) }
  let(:prefetcher) { described_class.new(ethereum_client: ethereum_client, ahead: 5, threads: 2) }
  
  before do
    allow(ethereum_client).to receive(:base_url).and_return('http://test.com')
    allow(Rails.logger).to receive(:debug)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:error)
  end
  
  describe '#fetch' do
    let(:block_data) { { 'number' => '0x1', 'hash' => '0x123' } }
    let(:receipts_data) { [] }
    
    before do
      allow(ethereum_client).to receive(:get_block).and_return(block_data)
      allow(ethereum_client).to receive(:get_transaction_receipts).and_return(receipts_data)
      allow(EthBlock).to receive(:from_rpc_result).and_return(instance_double(EthBlock, number: 1))
      allow(FacetBlock).to receive(:from_eth_block).and_return(instance_double(FacetBlock))
      allow(EthTransaction).to receive(:facet_txs_from_rpc_results).and_return([])
    end
    
    it 'fetches a block successfully' do
      result = prefetcher.fetch(1)
      expect(result).to have_key(:eth_block)
      expect(result).to have_key(:facet_block)
      expect(result).to have_key(:facet_txs)
    end
    
    it 'uses the shared client instance' do
      expect(ethereum_client).to receive(:get_block).with(1, true).and_return(block_data)
      expect(ethereum_client).to receive(:get_transaction_receipts).with(1).and_return(receipts_data)
      prefetcher.fetch(1)
    end
  end
  
  describe '#stats' do
    it 'returns comprehensive statistics' do
      stats = prefetcher.stats
      expect(stats).to have_key(:promises_total)
      expect(stats).to have_key(:promises_fulfilled)
      expect(stats).to have_key(:promises_pending)
      expect(stats).to have_key(:threads_active)
      expect(stats).to have_key(:threads_queued)
    end
  end
  
  describe '#shutdown' do
    it 'shuts down gracefully' do
      expect { prefetcher.shutdown }.not_to raise_error
    end
  end
end