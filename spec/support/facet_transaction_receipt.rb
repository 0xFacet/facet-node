class FacetTransactionReceipt < T::Struct
  include Memery
  include AttrAssignable
  
  # Primary schema fields
  prop :transaction_hash, T.nilable(String)
  prop :block_hash, T.nilable(String)
  prop :block_number, T.nilable(Integer)
  prop :contract_address, T.nilable(String)
  prop :legacy_contract_address_map, T.nilable(T::Hash[T.untyped, T.untyped]), default: {}
  prop :cumulative_gas_used, T.nilable(Integer)
  prop :deposit_nonce, T.nilable(String)
  prop :deposit_receipt_version, T.nilable(String)
  prop :effective_gas_price, T.nilable(Integer)
  prop :from_address, T.nilable(String)
  prop :gas_used, T.nilable(Integer)
  prop :logs, T.nilable(T::Array[T.untyped]), default: []
  prop :logs_bloom, T.nilable(String)
  prop :status, T.nilable(Integer)
  prop :to_address, T.nilable(String)
  prop :transaction_index, T.nilable(Integer)
  prop :tx_type, T.nilable(String)

  # Association-like fields
  prop :facet_transaction, T.nilable(T.untyped)
  prop :facet_block, T.nilable(T.untyped)
  
  def trace
    # t = process_trace(GethDriver.trace_transaction(transaction_hash))
    # t = test_trace
    t = GethDriver.trace_transaction(transaction_hash)
    
    decoder = TransactionDecoder.new(t)
    decoder.decode_trace
  end
  
  def process_trace(trace)
    trace['calls'].each do |call|
      process_call(call)
    end
  end
  
  class TransactionDecoder
    def initialize(trace)
      @trace = trace
    end
  
    def decode_trace
      return @trace unless @trace['calls']
      
      decode_calls(@trace['calls'])
    end
  
    private
  
    def decode_function_input(call, abi)
      input_data = call["input"]
      output_data = call["output"]
      function_signature = input_data[0, 10] if input_data
      function_abi = abi.find { |f| f["type"] == "function" && Eth::Util.keccak256(f["name"] + "(" + f["inputs"].map { |i| i["type"] }.join(",") + ")").bytes_to_hex[0, 10] == function_signature } if function_signature
  
      if function_abi
        decoded_inputs = Eth::Abi.decode(function_abi["inputs"].map { |i| i["type"] }, input_data[10..-1])
        decoded_data_inputs = {}
        function_abi["inputs"].each_with_index do |input, index|
          decoded_data_inputs[input['name']] = decoded_inputs[index]
        end
  
        decoded_data_outputs = nil
        if output_data
          if is_error_output?(output_data, abi)
            decoded_data_outputs = decode_error_output(output_data, abi)
          elsif function_abi["outputs"]
            decoded_outputs = Eth::Abi.decode(function_abi["outputs"].map { |o| o["type"] }, output_data)
            decoded_data_outputs = {}
            function_abi["outputs"].each_with_index do |output, index|
              decoded_data_outputs[output['name']] = decoded_outputs[index]
            end
          end
        end
  
        [function_abi["name"], decoded_data_inputs, decoded_data_outputs]
      else
        puts "Function ABI not found for signature: #{function_signature}"
        [nil, {}, nil]
      end
    end
  
    def function_signature(input_data)
      input_data[0, 10] if input_data
    end
  
    def is_error_output?(output_data, abi)
      # Generate error signatures from the ABI
      error_signatures = abi.select { |e| e["type"] == "error" }.map do |error|
        Eth::Util.keccak256(error["name"] + "(" + error["inputs"].map { |i| i["type"] }.join(",") + ")").bytes_to_hex[0, 10]
      end
      error_signatures.include?(output_data[0, 10])
    end
  
    def decode_error_output(output_data, abi)
      # Decode the error output based on the error definitions in the ABI
      error_abi = abi.find { |e| e["type"] == "error" && Eth::Util.keccak256(e["name"] + "(" + e["inputs"].map { |i| i["type"] }.join(",") + ")").bytes_to_hex[0, 10] == output_data[0, 10] }
      if error_abi
        decoded_error = Eth::Abi.decode(error_abi["inputs"].map { |i| i["type"] }, output_data[10..-1])
        decoded_data_error = { "error_name" => error_abi["name"] }
        error_abi["inputs"].each_with_index do |input, index|
          decoded_data_error[input['name']] = decoded_error[index]
        end
        decoded_data_error
      else
        puts "Error ABI not found for signature: #{output_data[0, 10]}"
        nil
      end
    end
  
    def reorder_keys(call)
      reordered_call = call.slice("from", "gas", "gasUsed", "to", "value", "type", "function_name", "input", "inputs", "outputs", "output", "error")
      reordered_call["calls"] = call["calls"] if call["calls"]
      call.replace(reordered_call)
    end
  end
end
