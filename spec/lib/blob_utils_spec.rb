require 'rails_helper'
require 'blob_utils'

RSpec.describe BlobUtils do
  describe '.to_blobs' do
    it 'encodes small data into single blob' do
      data = "Hello, Facet!"
      blobs = BlobUtils.to_blobs(data: data)
      
      expect(blobs.length).to eq(1)
      expect(blobs.first).to start_with('0x')
      expect(blobs.first.length).to eq(2 + BlobUtils::BYTES_PER_BLOB * 2)  # 0x + hex chars
    end
    
    it 'encodes hex string data' do
      data = "0xdeadbeef"
      blobs = BlobUtils.to_blobs(data: data)
      
      expect(blobs.length).to eq(1)
      
      # Should be able to decode back
      decoded = BlobUtils.from_blobs(blobs: blobs)
      expect(decoded).to eq(data)
    end
    
    it 'handles maximum size data' do
      # Create data just under the max
      max_data_size = BlobUtils::BYTES_PER_BLOB - 1 - BlobUtils::FIELD_ELEMENTS_PER_BLOB
      data = "A" * max_data_size
      
      blobs = BlobUtils.to_blobs(data: data)
      expect(blobs.length).to eq(1)
    end
    
    it 'splits large data across multiple blobs' do
      # Create data that requires 2 blobs
      data = "B" * (BlobUtils::BYTES_PER_BLOB - 1000)  # Just over 1 blob
      
      blobs = BlobUtils.to_blobs(data: data)
      expect(blobs.length).to eq(2)
    end
    
    it 'raises error for empty data' do
      expect { BlobUtils.to_blobs(data: '') }.to raise_error(BlobUtils::EmptyBlobError)
      expect { BlobUtils.to_blobs(data: '0x') }.to raise_error(BlobUtils::EmptyBlobError)
    end
    
    it 'raises error for data exceeding max transaction size' do
      oversized = "C" * (BlobUtils::MAX_BYTES_PER_TRANSACTION + 1)
      expect { BlobUtils.to_blobs(data: oversized) }.to raise_error(BlobUtils::BlobSizeTooLargeError)
    end
  end
  
  describe '.from_blobs' do
    it 'decodes single blob back to original data' do
      original = "Test data for Facet batches"
      blobs = BlobUtils.to_blobs(data: original)
      decoded = BlobUtils.from_blobs(blobs: blobs)
      
      expect(decoded).to eq("0x" + original.unpack1('H*'))  # Hex output for string input
    end
    
    it 'decodes multiple blobs' do
      original = "X" * 100_000  # Large enough for multiple blobs
      blobs = BlobUtils.to_blobs(data: original)
      decoded = BlobUtils.from_blobs(blobs: blobs)
      
      expect(decoded).to eq("0x" + original.unpack1('H*'))
    end
    
    it 'handles hex input and output' do
      original = "0xfacefacefacefa"  # Even-length hex string
      blobs = BlobUtils.to_blobs(data: original)
      decoded = BlobUtils.from_blobs(blobs: blobs)
      
      expect(decoded).to eq(original)
    end
    
    it 'handles terminator byte correctly' do
      # Data with 0x80 byte in it
      data_with_80 = "\x12\x34\x80\x56\x78".b
      blobs = BlobUtils.to_blobs(data: data_with_80)
      decoded = BlobUtils.from_blobs(blobs: blobs)
      
      # Should preserve the 0x80 in the data
      expect(decoded).to eq("0x" + data_with_80.unpack1('H*'))
    end
  end
  
  describe 'round-trip encoding with Facet batch data' do
    it 'preserves Facet batch through blob encoding' do
      # Create a Facet batch payload
      magic = "\x00\x00\x00\x00\x00\x01\x23\x45"
      batch_data = "test_batch_data"
      length = [batch_data.length].pack('N')
      
      facet_payload = magic + length + batch_data
      
      # Encode to blob
      blobs = BlobUtils.to_blobs(data: facet_payload)
      
      # Decode back
      decoded = BlobUtils.from_blobs(blobs: blobs)
      decoded_bytes = [decoded.sub(/^0x/, '')].pack('H*')
      
      # Should preserve the exact payload
      expect(decoded_bytes).to eq(facet_payload)
      
      # Should be able to find magic prefix
      expect(decoded_bytes).to include(magic)
    end
    
    it 'handles aggregated data with multiple rollups' do
      # Simulate DA Builder aggregation
      rollup1_data = "ROLLUP_ONE_DATA"
      facet_magic = "\x00\x00\x00\x00\x00\x01\x23\x45"
      facet_data = "FACET_BATCH"
      facet_payload = facet_magic + [facet_data.length].pack('N') + facet_data
      rollup2_data = "ROLLUP_TWO_DATA"
      
      # Aggregate all data
      aggregated = rollup1_data + facet_payload + rollup2_data
      
      # Encode to blob
      blobs = BlobUtils.to_blobs(data: aggregated)
      
      # Decode back
      decoded = BlobUtils.from_blobs(blobs: blobs)
      decoded_bytes = [decoded.sub(/^0x/, '')].pack('H*')
      
      # Should find Facet data in the aggregated blob
      expect(decoded_bytes).to include(facet_magic)
      expect(decoded_bytes).to include(facet_data)
      
      # Should preserve order
      facet_index = decoded_bytes.index(facet_magic)
      rollup1_index = decoded_bytes.index(rollup1_data)
      rollup2_index = decoded_bytes.index(rollup2_data)
      
      expect(rollup1_index).to be < facet_index
      expect(facet_index).to be < rollup2_index
    end
  end
  
  describe 'field element constraints' do
    it 'respects 31-byte segments with leading zeros' do
      data = "\xFF".b * 31  # Max bytes per field element
      blobs = BlobUtils.to_blobs(data: data)
      blob_bytes = [blobs.first.sub(/^0x/, '')].pack('H*')
      
      # First byte should be 0x00 (leading zero for field element)
      expect(blob_bytes[0].ord).to eq(0x00)
      
      # Next 31 bytes should be our data
      expect(blob_bytes[1, 31]).to eq(data)
      
      # Then another leading zero for next field element (32nd byte)
      expect(blob_bytes[32].ord).to eq(0x00)
      
      # Then terminator at position 33 (since we only have 31 bytes, the second field element just has the terminator)
      expect(blob_bytes[33].ord).to eq(0x80)
    end
    
    it 'properly pads blob to full size' do
      data = "small"
      blobs = BlobUtils.to_blobs(data: data)
      blob_bytes = [blobs.first.sub(/^0x/, '')].pack('H*')
      
      expect(blob_bytes.length).to eq(BlobUtils::BYTES_PER_BLOB)
      
      # Check padding is zeros
      # Find terminator and verify rest is zeros
      terminator_index = blob_bytes.index("\x80".b)
      expect(terminator_index).not_to be_nil
      
      padding = blob_bytes[(terminator_index + 1)..-1]
      expect(padding.bytes.all? { |b| b == 0 }).to be true
    end
  end
end