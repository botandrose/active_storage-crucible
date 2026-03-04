# frozen_string_literal: true

module ActiveStorage
  module Crucible
    module PresignedUrl
      def self.for(blob, method: :put, expires_in: 1.hour)
        case method
        when :get
          blob.url(expires_in: expires_in)
        when :put
          service = blob.service
          object = service.send(:object_for, blob.key)
          object.presigned_url(:put, expires_in: expires_in.to_i)
        end
      end
    end
  end
end
