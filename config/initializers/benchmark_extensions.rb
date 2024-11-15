module BenchmarkExtensions
  def msr(message = "Execution time")
    return yield unless message
    
    result = nil
    elapsed_time = Benchmark.ms { result = yield }
    puts "#{message.as_json}: #{elapsed_time.round(3)} ms"
    result
  end
end

module Benchmark
  extend BenchmarkExtensions
end
