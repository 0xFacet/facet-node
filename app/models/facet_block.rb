class FacetBlock < T::Struct
  include Memery
  include AttrAssignable
  
  # Primary fields derived from schema
  prop :number, T.nilable(Integer)
  prop :block_hash, T.nilable(Hash32)
  prop :eth_block_hash, T.nilable(Hash32)
  prop :eth_block_number, T.nilable(Integer)
  prop :base_fee_per_gas, T.nilable(Integer)
  prop :extra_data, T.nilable(String)
  prop :gas_limit, T.nilable(Integer)
  prop :gas_used, T.nilable(Integer)
  prop :logs_bloom, T.nilable(String)
  prop :parent_beacon_block_root, T.nilable(Hash32)
  prop :parent_hash, T.nilable(Hash32)
  prop :receipts_root, T.nilable(Hash32)
  prop :size, T.nilable(Integer)
  prop :state_root, T.nilable(Hash32)
  prop :timestamp, T.nilable(Integer)
  prop :transactions_root, T.nilable(String)
  prop :prev_randao, T.nilable(Hash32)
  prop :eth_block_timestamp, T.nilable(Integer)
  prop :eth_block_base_fee_per_gas, T.nilable(Integer)
  prop :sequence_number, T.nilable(Integer)
  prop :fct_mint_rate, T.nilable(Integer)
  prop :fct_mint_period_l1_data_gas, T.nilable(Integer)
  prop :total_fct_minted, T.nilable(Integer)
  prop :current_period_fct_minted, T.nilable(Integer)
  prop :current_period_start_block, T.nilable(Integer)

  # Association-like fields
  prop :eth_block, T.nilable(EthBlock)
  prop :facet_transactions, T::Array[T.untyped], default: []
  
  def assign_l1_attributes(l1_attributes)
    assign_attributes(
      sequence_number: l1_attributes.fetch(:sequence_number),
      eth_block_hash: l1_attributes.fetch(:hash),
      eth_block_number: l1_attributes.fetch(:number),
      eth_block_timestamp: l1_attributes.fetch(:timestamp),
      eth_block_base_fee_per_gas: l1_attributes.fetch(:base_fee),
      fct_mint_rate: l1_attributes.fetch(:fct_mint_rate),
      fct_mint_period_l1_data_gas: l1_attributes.fetch(:fct_mint_period_l1_data_gas)
    )
  end
  
  def self.from_eth_block(eth_block)
    FacetBlock.new(
      eth_block_hash: eth_block.block_hash,
      eth_block_number: eth_block.number,
      prev_randao: eth_block.mix_hash,
      eth_block_timestamp: eth_block.timestamp,
      eth_block_base_fee_per_gas: eth_block.base_fee_per_gas,
      parent_beacon_block_root: eth_block.parent_beacon_block_root,
      timestamp: eth_block.timestamp,
      sequence_number: 0,
      eth_block: eth_block,
    )
  end
  
  def self.next_in_sequence_from_facet_block(facet_block)
    FacetBlock.new(
      eth_block_hash: facet_block.eth_block_hash,
      eth_block_number: facet_block.eth_block_number,
      eth_block_timestamp: facet_block.eth_block_timestamp,
      prev_randao: facet_block.prev_randao,
      eth_block_base_fee_per_gas: facet_block.eth_block_base_fee_per_gas,
      parent_beacon_block_root: facet_block.parent_beacon_block_root,
      number: facet_block.number + 1,
      timestamp: facet_block.timestamp + 12,
      sequence_number: facet_block.sequence_number + 1
    )
  end
  
  def attributes_tx
    FacetTransaction.l1_attributes_tx_from_blocks(self)
  end
  
  def self.from_rpc_result(res)
    new(attributes_from_rpc(res))
  end
  
  def from_rpc_response(res)
    assign_attributes(self.class.attributes_from_rpc(res))
  end
  
  def self.attributes_from_rpc(resp)
    attrs = {
      number: (resp['blockNumber'] || resp['number']).to_i(16),
      block_hash: Hash32.from_hex(resp['hash'] || resp['blockHash']),
      parent_hash: Hash32.from_hex(resp['parentHash']),
      state_root: Hash32.from_hex(resp['stateRoot']),
      receipts_root: Hash32.from_hex(resp['receiptsRoot']),
      logs_bloom: resp['logsBloom'],
      gas_limit: resp['gasLimit'].to_i(16),
      gas_used: resp['gasUsed'].to_i(16),
      timestamp: resp['timestamp'].to_i(16),
      base_fee_per_gas: resp['baseFeePerGas'].to_i(16),
      prev_randao: Hash32.from_hex(resp['prevRandao'] || resp['mixHash']),
      extra_data: resp['extraData'],
      facet_transactions: resp['transactions']
    }
    
    if resp['parentBeaconBlockRoot']
      attrs[:parent_beacon_block_root] = Hash32.from_hex(resp['parentBeaconBlockRoot'])
    end
    
    attrs
  end
  
  def calculated_base_fee_per_gas
    return base_fee_per_gas if base_fee_per_gas
    
    TransactionHelper.calculate_next_base_fee(number - 1)
  end
  memoize :calculated_base_fee_per_gas
end
