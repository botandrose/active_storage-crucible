# frozen_string_literal: true

module ActiveStorage
  module Crucible
    module BlobExtension
      def variable?
        super || crucible_transformable?
      end

      private

      def crucible_transformable?
        video? && ActiveStorage::Crucible.endpoint.present?
      end
    end
  end
end
