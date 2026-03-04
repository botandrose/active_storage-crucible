# frozen_string_literal: true

require "net/http"
require "json"

module ActiveStorage
  module Crucible
    class Client
      def post(url, body)
        uri = URI.parse(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        request = Net::HTTP::Post.new(uri.request_uri, "Content-Type": "application/json")
        request.body = body.to_json
        response = http.request(request)
        unless response.code.start_with?("2")
          raise "Crucible request failed: #{response.code} #{response.body}"
        end
        response
      end
    end
  end
end
