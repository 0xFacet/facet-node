module RpcErrors
  class HttpError < StandardError
    attr_reader :code, :http_message

    def initialize(code, http_message)
      @code = code
      @http_message = http_message
      super("HTTP error: #{code} #{http_message}")
    end
  end

  class ApiError < StandardError; end
  class MethodRequiredError < StandardError; end
end