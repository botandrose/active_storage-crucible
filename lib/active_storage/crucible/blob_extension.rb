# frozen_string_literal: true

module ActiveStorage
  module Crucible
    module BlobExtension
      def variable?
        super || crucible_transformable?
      end

      # Videos are previewable whenever Crucible is configured, regardless of a
      # local ffmpeg. Crucible extracts the frame server-side, so video->image
      # representations deterministically take the stock preview path rather than
      # depending on what's installed on the worker.
      def previewable?
        super || (video? && ActiveStorage::Crucible.endpoint.present?)
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
        (image? || video?) && ActiveStorage::Crucible.endpoint.present?
      end

      def video_output_format?(format)
        format.to_s.in?(%w[mp4 webm mov avi mkv])
      end
    end
  end
end
