# frozen_string_literal: true

require_relative "crucible/version"
require_relative "crucible/client"
require_relative "crucible/presigned_url"
require_relative "crucible/transformer"
require_relative "crucible/blob_extension"

module ActiveStorage
  module Crucible
    mattr_accessor :endpoint

    def self.configure
      yield self
    end

    class Engine < ::Rails::Engine
      config.after_initialize do
        ActiveStorage::Blob.prepend(
          ActiveStorage::Crucible::BlobExtension
        )
      end
    end
  end
end
