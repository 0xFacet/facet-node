# Represents a parsed and validated Facet batch
class ParsedBatch < T::Struct
  extend T::Sig

  const :role, Integer                           # PERMISSIONLESS or PRIORITY
  const :signer, T.nilable(Address20)           # Signer address (nil if not verified or permissionless)
  const :l1_tx_index, Integer                   # Transaction index in L1 block
  const :source, String                         # Where batch came from (calldata/blob)
  const :source_details, T::Hash[Symbol, T.untyped]  # Additional source info (tx_hash, blob_index, etc.)
  const :transactions, T::Array[ByteString]     # Array of EIP-2718 typed transaction bytes
  const :content_hash, Hash32                   # Keccak256 of RLP_TX_LIST for deduplication
  const :chain_id, Integer                      # Chain ID from batch header
  
  sig { returns(T::Boolean) }
  def is_priority?
    role == FacetBatchConstants::Role::PRIORITY
  end
  
  sig { returns(T::Boolean) }
  def is_permissionless?
    role == FacetBatchConstants::Role::PERMISSIONLESS
  end
  
  sig { returns(Integer) }
  def transaction_count
    transactions.length
  end
  
  sig { returns(T::Boolean) }
  def has_signature?
    !signer.nil?
  end
  
  sig { returns(String) }
  def source_description
    case source
    when FacetBatchConstants::Source::CALLDATA
      "calldata from tx #{source_details[:tx_hash]}"
    when FacetBatchConstants::Source::BLOB
      "blob #{source_details[:blob_index]} from tx #{source_details[:tx_hash]}"
    else
      source
    end
  end
  
  # Calculate total gas limit for all transactions in batch
  sig { returns(Integer) }
  def total_gas_limit
    # This will be calculated when we parse the actual transaction objects
    # For now, return a placeholder
    transactions.length * 21000  # Minimum gas per tx
  end
end