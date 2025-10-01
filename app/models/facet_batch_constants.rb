# Constants for Facet Batch V2 protocol
module FacetBatchConstants
  # Magic prefix ("unstoppable sequencing" ASCII -> hex)
  MAGIC_PREFIX = ByteString.from_hex("0x756e73746f707061626c652073657175656e63696e67")

  # Protocol version
  VERSION = 1

  # Wire format header sizes (in bytes)
  MAGIC_SIZE = MAGIC_PREFIX.to_bin.bytesize
  CHAIN_ID_SIZE = 8    # uint64
  VERSION_SIZE = 1     # uint8
  ROLE_SIZE = 1        # uint8
  LENGTH_SIZE = 4      # uint32
  HEADER_SIZE = MAGIC_SIZE + CHAIN_ID_SIZE + VERSION_SIZE + ROLE_SIZE + LENGTH_SIZE  # 36 bytes
  SIGNATURE_SIZE = 65  # secp256k1: r(32) + s(32) + v(1)

  # Wire format offsets
  MAGIC_OFFSET = 0
  CHAIN_ID_OFFSET = MAGIC_SIZE
  VERSION_OFFSET = CHAIN_ID_OFFSET + CHAIN_ID_SIZE
  ROLE_OFFSET = VERSION_OFFSET + VERSION_SIZE
  LENGTH_OFFSET = ROLE_OFFSET + ROLE_SIZE
  RLP_OFFSET = HEADER_SIZE

  # Size limits
  MAX_BATCH_BYTES = Integer(ENV.fetch('MAX_BATCH_BYTES', 131_072))  # 128KB default
  MAX_TXS_PER_BATCH = Integer(ENV.fetch('MAX_TXS_PER_BATCH', 1000))
  MAX_BATCHES_PER_PAYLOAD = Integer(ENV.fetch('MAX_BATCHES_PER_PAYLOAD', 10))

  # Batch roles
  module Role
    PERMISSIONLESS = 0x00  # Anyone can post, no signature required (formerly FORCED)
    PRIORITY = 0x01        # Requires authorized signature
  end

  # Source types for tracking where batch came from
  module Source
    CALLDATA = 'calldata'
    BLOB = 'blob'
  end
end
