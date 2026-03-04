# frozen_string_literal: true

module ActiveStorage
  module Crucible
    module PreviewExtension
      def process
        if blob.video? && s3_service?
          process_via_crucible unless blob.preview_image.attached?
          self
        else
          super
        end
      end

      def url(*args, **kwargs)
        if blob.video? && s3_service?
          if preview_variant_processed?
            super
          else
            blob.url(*args, **kwargs)
          end
        else
          super
        end
      end

      private

      def process_via_crucible
        preview_image_blob = ActiveStorage::Blob.create_before_direct_upload!(
          filename: "#{blob.filename.base}.jpg",
          content_type: "image/jpeg",
          service_name: blob.service_name,
          byte_size: 0,
          checksum: "0",
        )
        preview_image_blob.metadata[:analyzed] = true
        blob.preview_image.attach(preview_image_blob)

        variant_variation = variation.default_to(preview_image_blob.send(:default_variant_transformations))
        variant_record = preview_image_blob.variant_records.create!(variation_digest: variant_variation.digest)
        variant_record.update!(state: "processing")

        variant_blob = ActiveStorage::Blob.create_before_direct_upload!(
          filename: "#{blob.filename.base}.#{variant_variation.format}",
          content_type: variant_variation.content_type,
          service_name: blob.service_name,
          byte_size: 0,
          checksum: "0",
        )
        variant_blob.metadata[:analyzed] = true
        variant_record.image.attach(variant_blob)

        source_url = PresignedUrl.for(blob, method: :get)
        preview_image_url = PresignedUrl.for(preview_image_blob, method: :put)
        preview_image_variant_url = PresignedUrl.for(variant_blob, method: :put)

        dimensions = extract_dimensions(variation.transformations)
        rotation = variation.transformations.fetch(:rotate, 0)

        callback_url = AsyncVariants.callback_url_for(variant_record)

        endpoint = "#{ActiveStorage::Crucible.endpoint}/video/preview"
        Client.new.post(endpoint, {
          blob_url: source_url,
          dimensions: dimensions,
          rotation: rotation,
          preview_image_url: preview_image_url,
          preview_image_variant_url: preview_image_variant_url,
          callback_url: callback_url,
        })
      end

      def preview_variant_processed?
        return false unless blob.preview_image.attached?
        preview_image_blob = blob.preview_image.blob
        variant_variation = variation.default_to(preview_image_blob.send(:default_variant_transformations))
        record = preview_image_blob.variant_records.find_by(variation_digest: variant_variation.digest)
        record&.state == "processed"
      end

      def s3_service?
        blob.service.respond_to?(:bucket)
      end

      def extract_dimensions(transformations)
        resize = transformations[:resize_to_limit] || transformations[:resize_to_fit] || transformations[:resize_to_fill]
        return nil unless resize
        width, height = resize
        "#{width}x#{height}"
      end
    end
  end
end
