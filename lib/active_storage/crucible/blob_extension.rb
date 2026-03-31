# frozen_string_literal: true

module ActiveStorage
  module Crucible
    module BlobExtension
      def variable?
        super || crucible_transformable?
      end

      def representation(transformations)
        variation = ActiveStorage::Variation.wrap(transformations)
        if crucible_transformable? && video_output_format?(variation.transformations[:format])
          variant transformations
        else
          super
        end
      end

      private

      def crucible_transformable?
        video? && ActiveStorage::Crucible.endpoint.present?
      end

      def video_output_format?(format)
        format.to_s.in?(%w[mp4 webm mov avi mkv])
      end
    end
  end
end
