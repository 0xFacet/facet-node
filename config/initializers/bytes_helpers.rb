class Array
  # Pack an array of uint8 values into a byte string
  def uint8_array_to_bytes
    self.pack('C*')
  end

  # Unpack a byte string into an array of uint8 values
  def self.uint8_array_from_bytes(byte_string)
    byte_string.unpack('C*')
  end
end

class String
  # Convert a byte string to an array of uint8 values
  def bytes_to_uint8_array
    self.unpack('C*')
  end
  
  def bytes_to_hex
    "0x" + bytes_to_unprefixed_hex
  end
  
  def bytes_to_unprefixed_hex
    self.unpack1('H*')
  end
  
  def hex_to_bytes
    [self.sub(/\A0x/, '')].pack('H*')
  end
  
  def hex_to_bin
    hex_to_bytes
  end
end

class Integer
  def zpad(bytes)
    Eth::Util.zpad_int(self, bytes)
  end
  
  def to_hex_string
    "0x" + to_s(16)
  end
  
  def to_hex_string_no_prefix
    to_s(16)
  end
end
