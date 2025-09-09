# Constants for Facet Batch V2 protocol
module FacetBatchConstants
  # Magic prefix to identify batch payloads
  MAGIC_PREFIX = ByteString.from_hex("0x0000000000012345")
  
  # Protocol version
  VERSION = 1
  
  # Size limits
  MAX_BATCH_BYTES = Integer(ENV.fetch('MAX_BATCH_BYTES', 131_072))  # 128KB default
  MAX_TXS_PER_BATCH = Integer(ENV.fetch('MAX_TXS_PER_BATCH', 1000))
  MAX_BATCHES_PER_PAYLOAD = Integer(ENV.fetch('MAX_BATCHES_PER_PAYLOAD', 10))
  
  # Batch roles
  module Role
    FORCED = 0x00    # Anyone can post, no signature required
    PRIORITY = 0x01  # Requires authorized signature
  end
  
  # Source types for tracking where batch came from
  module Source
    CALLDATA = 'calldata'
    BLOB = 'blob'
  end
end