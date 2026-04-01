# frozen_string_literal: true

require "active_storage/async_variants/transformer"

module ActiveStorage
  module Crucible
    class Transformer < ActiveStorage::AsyncVariants::Transformer
      def initiate(source_url:, callback_url:, variant_record_id:, **options)
        variant_record = ActiveStorage::VariantRecord.find(variant_record_id)
        blob = variant_record.blob

        rotation = blob.metadata["rotation"].to_i
        video_format = blob.metadata["video_format"]

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
        dimensions = extract_dimensions(options)

        if blob.video? && !video_output_format?(options[:format])
          preview_blob = ActiveStorage::Blob.create_before_direct_upload!(
            filename: "#{blob.filename.base}.jpg",
            content_type: "image/jpeg",
            service_name: blob.service_name,
            byte_size: 0,
            checksum: "0",
          )
          preview_blob.metadata[:analyzed] = true

          Client.new.post("#{endpoint}/video/preview", {
            blob_url: source_url,
            dimensions: dimensions,
            rotation: rotation,
            preview_image_url: PresignedUrl.for(preview_blob, method: :put),
            preview_image_variant_url: variant_url,
            callback_url: callback_url,
          })
        elsif blob.video?
          format = video_format || options[:format].to_s
          Client.new.post("#{endpoint}/video/variant", {
            blob_url: source_url,
            variant_url: variant_url,
            dimensions: dimensions,
            rotation: rotation,
            format: format,
            content_type: output_content_type(format: format),
            callback_url: callback_url,
          })
        else
          Client.new.post("#{endpoint}/image/variant", {
            blob_url: source_url,
            variant_url: variant_url,
            dimensions: dimensions,
            rotation: rotation,
            format: options[:format]&.to_s,
            content_type: output_content_type(options),
            callback_url: callback_url,
          })
        end
      end

      def process_preview(blob:, variation:)
        return if blob.preview_image.attached?

        preview_image_blob = ActiveStorage::Blob.create_before_direct_upload!(
          filename: "#{blob.filename.base}.jpg",
          content_type: "image/jpeg",
          service_name: blob.service_name,
          byte_size: 0,
          checksum: "0",
        )
        preview_image_blob.metadata[:analyzed] = true
        blob.preview_image.attach(preview_image_blob)

        variant_record = preview_image_blob.variant_records.create_or_find_by!(variation_digest: variation.digest)
        return if variant_record.state.in?(%w[processing processed])
        variant_record.update!(state: "processing")

        variant_blob = ActiveStorage::Blob.create_before_direct_upload!(
          filename: "#{blob.filename.base}.#{variation.format}",
          content_type: variation.content_type,
          service_name: blob.service_name,
          byte_size: 0,
          checksum: "0",
        )
        variant_blob.metadata[:analyzed] = true
        variant_record.image.attach(variant_blob)

        rotation = blob.metadata["rotation"].to_i
        callback_url = ActiveStorage::AsyncVariants.callback_url_for(variant_record)
        Client.new.post("#{endpoint}/video/preview", {
          blob_url: PresignedUrl.for(blob, method: :get),
          dimensions: extract_dimensions(variation.transformations),
          rotation: rotation,
          preview_image_url: PresignedUrl.for(preview_image_blob, method: :put),
          preview_image_variant_url: PresignedUrl.for(variant_blob, method: :put),
          callback_url: callback_url,
        })
      end

      private

      def endpoint
        ActiveStorage::Crucible.endpoint
      end

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
        when "mp4" then "video/mp4"
        when "webm" then "video/webm"
        else "application/octet-stream"
        end
      end

      def video_output_format?(format)
        format.to_s.in?(%w[mp4 webm mov avi mkv])
      end
    end
  end
end
