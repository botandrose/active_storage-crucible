# frozen_string_literal: true

require "active_storage/async_variants/transformer"

module ActiveStorage
  module Crucible
    class Transformer < ActiveStorage::AsyncVariants::Transformer
      # The variant_record's blob tells us which graph we're in:
      #
      # - a frame placeholder attached as a video's preview_image -> the stock
      #   preview path. Crucible extracts the frame (persisted as preview_image)
      #   and the resized variant in one /video/preview call.
      # - a video blob -> the "video is variable" transcode path (/video/variant).
      # - a plain image -> /image/variant.
      def initiate(source_url:, callback_url:, variant_record_id:, **options)
        variant_record = ActiveStorage::VariantRecord.find(variant_record_id)
        blob = variant_record.blob

        if (video = preview_source_video(blob))
          initiate_video_preview(video, blob, variant_record, options, callback_url)
        elsif blob.video?
          initiate_video_variant(blob, variant_record, options, callback_url)
        else
          initiate_image_variant(blob, variant_record, options, callback_url)
        end
      end

      private

      # When +blob+ is the extracted-frame placeholder (the video's preview_image),
      # returns the source video blob; otherwise nil.
      def preview_source_video(blob)
        attachment = ActiveStorage::Attachment.find_by(
          name: "preview_image",
          record_type: "ActiveStorage::Blob",
          blob_id: blob.id,
        )
        attachment && ActiveStorage::Blob.find_by(id: attachment.record_id)
      end

      # Crucible writes the full frame to the preview_image placeholder and the
      # resized variant to the output blob in a single call; the success callback
      # reconciles both (byte_size/checksum for the variant, preview_image_* for
      # the frame).
      def initiate_video_preview(video, frame_blob, variant_record, options, callback_url)
        output_blob = output_blob_for(video, variant_record, options)

        # Pass the requested variant format so Crucible writes the right file
        # extension via vips and PUTs with a Content-Type that matches what we
        # signed the variant URL for (anything else gives 403
        # SignatureDoesNotMatch). Crucible derives the Content-Type from `format`
        # via Marcel so there's a single source of truth.
        Client.new.post("#{endpoint}/video/preview", {
          blob_url: PresignedUrl.for(video, method: :get),
          dimensions: extract_dimensions(options),
          rotation: video.metadata["rotation"].to_i,
          format: options[:format]&.to_s,
          preview_image_url: PresignedUrl.for(frame_blob, method: :put),
          preview_image_variant_url: PresignedUrl.for(output_blob, method: :put),
          callback_url: callback_url,
        })
      end

      def initiate_video_variant(blob, variant_record, options, callback_url)
        format = blob.metadata["video_format"] || options[:format].to_s
        output_blob = output_blob_for(blob, variant_record, options.merge(format: format))

        # Only pass `format` -- Crucible derives Content-Type from it via the same
        # canonical mapping output_content_type uses on this side, so the PUT
        # header always matches what the URL was signed for.
        Client.new.post("#{endpoint}/video/variant", {
          blob_url: PresignedUrl.for(blob, method: :get),
          variant_url: PresignedUrl.for(output_blob, method: :put),
          dimensions: extract_dimensions(options),
          rotation: blob.metadata["rotation"].to_i,
          format: format,
          callback_url: callback_url,
        })
      end

      def initiate_image_variant(blob, variant_record, options, callback_url)
        output_blob = output_blob_for(blob, variant_record, options)

        Client.new.post("#{endpoint}/image/variant", {
          blob_url: PresignedUrl.for(blob, method: :get),
          variant_url: PresignedUrl.for(output_blob, method: :put),
          dimensions: extract_dimensions(options),
          rotation: blob.metadata["rotation"].to_i,
          format: options[:format]&.to_s,
          callback_url: callback_url,
        })
      end

      # A fresh blob would purge this one before an in-flight run writes to it, orphaning the file.
      def output_blob_for(blob, variant_record, options)
        existing = variant_record.image.blob
        return existing if existing&.content_type == output_content_type(options)
        create_output_blob(blob, variant_record, options)
      end

      def create_output_blob(blob, variant_record, options)
        output_blob = ActiveStorage::Blob.create_before_direct_upload!(
          filename: "#{blob.filename.base}.#{options[:format] || blob.filename.extension}",
          content_type: output_content_type(options),
          service_name: blob.service_name,
          byte_size: 0,
          checksum: "0",
        )
        output_blob.metadata[:analyzed] = true
        variant_record.image.attach(output_blob)
        output_blob
      end

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
    end
  end
end
