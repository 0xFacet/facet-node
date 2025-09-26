# Represents an EIP-4844 blob associated with an L1 transaction
class EthBlob < T::Struct
  const :tx_hash, Hash32                    # L1 transaction hash that carried this blob
  const :l1_tx_index, Integer               # Transaction index in L1 block
  const :blob_index, Integer                # Index of blob within the transaction (0-based)
  const :versioned_hash, Hash32             # KZG commitment versioned hash
  const :data, T.nilable(ByteString)        # Raw blob data (nil if not fetched/available)
  const :l1_block_number, Integer           # L1 block number for tracking
  
  sig { params(
    tx_hash: T.any(String, Hash32),
    l1_tx_index: Integer,
    blob_index: Integer,
    versioned_hash: T.any(String, Hash32),
    l1_block_number: Integer,
    data: T.nilable(T.any(String, ByteString))
  ).returns(EthBlob) }
  def self.create(tx_hash:, l1_tx_index:, blob_index:, versioned_hash:, l1_block_number:, data: nil)
    new(
      tx_hash: tx_hash.is_a?(Hash32) ? tx_hash : Hash32.from_hex(tx_hash),
      l1_tx_index: l1_tx_index,
      blob_index: blob_index,
      versioned_hash: versioned_hash.is_a?(Hash32) ? versioned_hash : Hash32.from_hex(versioned_hash),
      l1_block_number: l1_block_number,
      data: data.nil? ? nil : (data.is_a?(ByteString) ? data : ByteString.from_hex(data))
    )
  end
  
  sig { returns(T::Boolean) }
  def has_data?
    !data.nil?
  end
  
  sig { returns(String) }
  def unique_id
    "#{tx_hash.to_hex}-#{blob_index}"
  end
end