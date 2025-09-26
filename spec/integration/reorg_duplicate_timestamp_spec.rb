require 'rails_helper'

RSpec.describe 'Reorg followed by duplicate-timestamp rejection', slow: true do
  # ------------------------------------------------------------------
  # Helper to temporarily patch EthBlockImporter to use the OLD
  # prune-and-return reorg logic, so we can prove that the spec fails
  # against the legacy implementation.
  # ------------------------------------------------------------------
  def with_legacy_reorg_logic
    klass = EthBlockImporter

    # Capture the original method to restore later
    original_method = klass.instance_method(:import_blocks)

    klass.class_eval do
      define_method(:import_blocks) do |block_numbers|
        begin
          original_method.bind_call(self, block_numbers)
        rescue EthBlockImporter::ReorgDetectedError
          parent_eth_block = eth_block_cache[block_numbers.first - 1]

          # OLD behaviour: prune caches and return silently
          if parent_eth_block
            eth_block_cache.delete_if { |n, _| n >= parent_eth_block.number }
            facet_block_cache.delete_if { |_, fb| fb.eth_block_number >= parent_eth_block.number }
          end
          logger.info 'Legacy prune-and-return executed'
          nil
        end
      end
    end

    yield
  ensure
    # restore original method
    klass.class_eval { define_method(:import_blocks, original_method) }
  end

  def build_block(number:, hash:, parent_hash:, timestamp:, parent_beacon_root: nil)
    blk = {
      'number' => "0x#{number.to_s(16)}",
      'hash' => hash,
      'parentHash' => parent_hash,
      'baseFeePerGas' => '0x1',
      'mixHash' => '0x' + '11' * 32,
      'timestamp' => "0x#{timestamp.to_s(16)}",
      'gasLimit' => '0x1',
      'gasUsed' => '0x0',
      'transactions' => [],
      'blobGasUsed' => '0x0',
      'blobGasPrice' => '0x0'
    }
    blk['parentBeaconBlockRoot'] = parent_beacon_root if parent_beacon_root
    blk
  end

  def register_block_payload(storage, block_number, block_data, receipts: [])
    storage[block_number] = {
      block: block_data,
      receipts: receipts
    }
  end

  def build_prefetcher(storage)
    instance_double(L1RpcPrefetcher).tap do |prefetcher|
      allow(prefetcher).to receive(:ensure_prefetched)
      allow(prefetcher).to receive(:clear_older_than)
      allow(prefetcher).to receive(:fetch) do |block_number|
        payload = storage[block_number]
        raise "Missing prefetch payload for block #{block_number}" unless payload

        block = payload[:block]
        receipts = payload[:receipts]

        eth_block = EthBlock.from_rpc_result(block)
        facet_block = FacetBlock.from_eth_block(eth_block)
        facet_txs = EthTransaction.facet_txs_from_rpc_results(block, receipts)

        {
          eth_block: eth_block,
          facet_block: facet_block,
          facet_txs: facet_txs
        }
      end
    end
  end

  def build_importer(latest_l2:, prefetch_store:)
    base_ts = latest_l2['timestamp'].to_i(16)
    head_facet = FacetBlock.from_rpc_result(latest_l2)
    head_facet.assign_attributes(
      sequence_number: 0,
      gas_used: 0,
      base_fee_per_gas: 1,
      eth_block_timestamp: base_ts,
      eth_block_number: 0,
      eth_block_hash: Hash32.from_hex(latest_l2['hash']),
      eth_block_base_fee_per_gas: 1,
      fct_mint_rate: 0,
      fct_mint_period_l1_data_gas: 0
    )

    hash0 = latest_l2['hash']
    zero_root = '0x' + '00' * 32
    
    eth_genesis = EthBlock.from_rpc_result(
      build_block(number: 0, hash: hash0, parent_hash: '0x' + '00' * 32, timestamp: base_ts, parent_beacon_root: zero_root)
    )

    importer = EthBlockImporter.allocate
    importer.logger = Rails.logger
    importer.facet_block_cache = { 0 => head_facet }
    importer.eth_block_cache = { 0 => eth_genesis }
    importer.ethereum_client = double('EthRpcClient')
    importer.geth_driver = GethDriver
    importer.prefetcher = build_prefetcher(prefetch_store)
    
    allow(importer).to receive(:current_block_number).and_return(2)

    importer
  end

  before do
    allow(EthTransaction).to receive(:facet_txs_from_rpc_results).and_return([])
  end

  let(:latest_l2) { GethDriver.client.call('eth_getBlockByNumber', ['latest', false]) }
  let(:base_ts) { latest_l2['timestamp'].to_i(16) }
  let(:hash0) { latest_l2['hash'] }
  let(:zero_root) { '0x' + '00' * 32 }

  let(:hash1a) { '0x' + 'aa' * 32 }
  let(:hash1b) { '0x' + 'bb' * 32 }
  let(:hash2b) { '0x' + 'cc' * 32 }

  let(:block_1a) { build_block(number: 1, hash: hash1a, parent_hash: hash0, timestamp: base_ts + 36, parent_beacon_root: zero_root) }
  let(:block_1b) { build_block(number: 1, hash: hash1b, parent_hash: hash0, timestamp: base_ts + 12, parent_beacon_root: zero_root) }
  let(:block_2b) { build_block(number: 2, hash: hash2b, parent_hash: hash1b, timestamp: base_ts + 24, parent_beacon_root: zero_root) }

  context 'current behaviour' do
    it 'restarts cleanly after a reorg and avoids duplicate timestamps' do
      initial_store = {}
      importer = build_importer(latest_l2: latest_l2, prefetch_store: initial_store)

      register_block_payload(initial_store, 1, block_1a)
      register_block_payload(initial_store, 2, block_2b)

      facet_blocks_1, = importer.import_blocks([1])

      fillers = facet_blocks_1.select { |fb| fb.sequence_number.to_i > 0 }
      expect(fillers.size).to be >= 2
      expect(fillers.last.timestamp).to eq(base_ts + 24)

      expect { importer.import_blocks([2]) }.to raise_error(EthBlockImporter::ReorgDetectedError)

      restart_store = {}
      new_importer = build_importer(latest_l2: latest_l2, prefetch_store: restart_store)
      register_block_payload(restart_store, 1, block_1b)
      register_block_payload(restart_store, 2, block_2b)

      expect { new_importer.import_blocks([1]) }.not_to raise_error
      expect { new_importer.import_blocks([2]) }.not_to raise_error
    end
  end

  context 'legacy behaviour (for regression proof)' do
    it 'fails with duplicate timestamp when old prune logic is used' do
      with_legacy_reorg_logic do
        store = {}
        importer = build_importer(latest_l2: latest_l2, prefetch_store: store)

        register_block_payload(store, 1, block_1a)
        register_block_payload(store, 2, block_2b)

        importer.import_blocks([1])

        # Legacy importer silently prunes and continues
        importer.import_blocks([2])

        register_block_payload(store, 1, block_1b)
        register_block_payload(store, 2, block_2b)

        expect {
          importer.import_blocks([1])
        }.to raise_error(GethClient::ClientError, /invalid timestamp/)
      end
    end
  end
end

