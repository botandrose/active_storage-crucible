# frozen_string_literal: true

require "active_storage/async_variants/transformer"

module ActiveStorage
  module Crucible
    class Transformer < ActiveStorage::AsyncVariants::Transformer
      def initiate(source_url:, callback_url:, variant_record_id:, **options)
        variant_record = ActiveStorage::VariantRecord.find(variant_record_id)
        blob = variant_record.blob

        output_blob = ActiveStorage::Blob.create_before_direct_upload!(
          filename: "#{blob.filename.base}.#{options[:format] || blob.filename.extension}",
          content_type: output_content_type(options),
          service_name: blob.service_name,
          byte_size: 0,
          checksum: "0",
        )
        output_blob.metadata[:analyzed] = true
        variant_record.image.attach(output_blob)

        source_url = PresignedUrl.for(blob, method: :get)
        variant_url = PresignedUrl.for(output_blob, method: :put)

        path = blob.video? ? "video/variant" : "image/variant"
        endpoint = "#{ActiveStorage::Crucible.endpoint}/#{path}"

        dimensions = extract_dimensions(options)
        rotation = options.fetch(:rotate, 0)
        format = options[:format]&.to_s

        Client.new.post(endpoint, {
          blob_url: source_url,
          variant_url: variant_url,
          dimensions: dimensions,
          rotation: rotation,
          format: format,
          callback_url: callback_url,
        })
      end

      private

      def extract_dimensions(options)
        resize = options[:resize_to_limit] || options[:resize_to_fit] || options[:resize_to_fill]
        return nil unless resize
        width, height = resize
        "#{width}x#{height}"
      end

      def output_content_type(options)
        case options[:format]&.to_s
        when "webp" then "image/webp"
        when "png" then "image/png"
        when "jpg", "jpeg" then "image/jpeg"
        when "gif" then "image/gif"
        else "application/octet-stream"
        end
      end
    end
  end
end
