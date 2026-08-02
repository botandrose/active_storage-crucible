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
        request = Net::HTTP::Post.new(uri.request_uri, headers)
        request.body = body.to_json
        response = http.request(request)
        unless response.code.start_with?("2")
          raise "Crucible request failed: #{response.code} #{response.body}"
        end
        response
      end

      private

      def headers
        headers = { "Content-Type": "application/json" }
        token = Crucible.api_token
        headers[:Authorization] = "Bearer #{token}" if token.present?
        headers
      end
    end
  end
end
