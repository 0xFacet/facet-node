# typed: strict

class EthCallStruct < T::Struct
  const :call_index, Integer
  const :block_number, Integer
  const :block_hash, String
  const :transaction_hash, String
  const :from_address, String
  const :to_address, T.nilable(String)
  const :gas, Integer
  const :gas_used, Integer
  const :input, String
  const :output, T.nilable(String)
  const :value, T.nilable(Integer)
  const :call_type, String
  const :error, T.nilable(String)
  const :revert_reason, T.nilable(String)
  const :order_in_tx, Integer
end