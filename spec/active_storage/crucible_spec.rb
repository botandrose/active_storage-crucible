# frozen_string_literal: true

RSpec.describe "ActiveStorage::Crucible" do
  before do
    @user = User.create!
    @user.avatar.attach(
      io: File.open("spec/support/fixtures/image.png"),
      filename: "photo.png",
      content_type: "image/png",
    )
    @crucible_calls = []
    allow_any_instance_of(ActiveStorage::Crucible::Client).to receive(:post) do |_client, url, body|
      @crucible_calls << { url: url, body: body }
    end
    allow(ActiveStorage::Crucible::PresignedUrl).to receive(:for) do |_blob, method:|
      case method
      when :get then "https://presigned.example.com/source"
      when :put then "https://presigned.example.com/output"
      end
    end
  end

  describe "image variant transformer" do
    it "posts to Crucible image/variant endpoint with correct params" do
      ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :avatar, :thumb)

      expect(@crucible_calls.size).to eq(1)
      call = @crucible_calls.first
      expect(call[:url]).to eq("https://crucible.example.com/image/variant")
      expect(call[:body][:blob_url]).to eq("https://presigned.example.com/source")
      expect(call[:body][:variant_url]).to eq("https://presigned.example.com/output")
      expect(call[:body][:dimensions]).to eq("100x100")
      expect(call[:body][:rotation]).to eq(0)
      expect(call[:body][:format]).to eq("webp")
      expect(call[:body][:callback_url]).to include("/active_storage/async_variants/callbacks/")
    end

    it "reads rotation from blob metadata" do
      @user.avatar.blob.update!(metadata: @user.avatar.blob.metadata.merge("rotation" => 90))
      ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :avatar, :thumb)

      call = @crucible_calls.first
      expect(call[:body][:rotation]).to eq(90)
    end

    it "attaches a placeholder output blob to the variant record" do
      ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :avatar, :thumb)

      variant = @user.avatar.variant(:thumb)
      record = @user.avatar.blob.variant_records.find_by(variation_digest: variant.variation.digest)
      expect(record).to be_present
      expect(record.image).to be_attached
      expect(record.image.blob.byte_size).to eq(0)
    end

    it "sets variant to processing state" do
      ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :avatar, :thumb)

      variant = @user.avatar.variant(:thumb)
      expect(variant.processing?).to be true
    end
  end

  describe "video variant transformer" do
    before do
      @user.video.attach(
        io: File.open("spec/support/fixtures/image.png"),
        filename: "clip.mp4",
        content_type: "video/mp4",
        identify: false,
      )
    end

    it "posts to Crucible video/preview for video with non-video output format" do
      ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :video, :thumb)

      expect(@crucible_calls.size).to eq(1)
      call = @crucible_calls.first
      expect(call[:url]).to eq("https://crucible.example.com/video/preview")
      expect(call[:body][:dimensions]).to eq("640x480")
      expect(call[:body][:preview_image_url]).to eq("https://presigned.example.com/output")
      expect(call[:body][:preview_image_variant_url]).to eq("https://presigned.example.com/output")
    end

    it "posts to Crucible video/variant for video with video output format" do
      ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :video, :transcoded)

      expect(@crucible_calls.size).to eq(1)
      call = @crucible_calls.first
      expect(call[:url]).to eq("https://crucible.example.com/video/variant")
      expect(call[:body][:dimensions]).to eq("1280x720")
      expect(call[:body][:format]).to eq("mp4")
      expect(call[:body][:content_type]).to eq("video/mp4")
    end

    it "uses explicit video format over video_format from blob metadata" do
      @user.video.blob.update!(metadata: @user.video.blob.metadata.merge("video_format" => "webm"))
      ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :video, :transcoded)

      call = @crucible_calls.first
      expect(call[:body][:format]).to eq("mp4")
    end

    it "falls back to video_format from blob metadata when variant has no video format" do
      @user.video.blob.update!(metadata: @user.video.blob.metadata.merge("video_format" => "webm"))
      ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :video, :unformatted)

      call = @crucible_calls.first
      expect(call[:url]).to eq("https://crucible.example.com/video/variant")
      expect(call[:body][:format]).to eq("webm")
    end

    it "raises when variant has no video format and no video_format in blob metadata" do
      expect {
        ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :video, :unformatted)
      }.to raise_error(ArgumentError, "No video format specified for video variant and no video_format in blob metadata")
    end

    it "reads rotation from blob metadata" do
      @user.video.blob.update!(metadata: @user.video.blob.metadata.merge("rotation" => 180))
      ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :video, :transcoded)

      call = @crucible_calls.first
      expect(call[:body][:rotation]).to eq(180)
    end
  end

  describe "BlobExtension#representation" do
    before do
      @user.video.attach(
        io: File.open("spec/support/fixtures/image.png"),
        filename: "clip.mp4",
        content_type: "video/mp4",
        identify: false,
      )
    end

    it "returns a variant for video output formats" do
      blob = @user.video.blob
      result = blob.representation(format: :mp4, resize_to_limit: [1280, 720])
      expect(result).to be_a(ActiveStorage::VariantWithRecord)
    end

    it "returns a preview for non-video output formats" do
      blob = @user.video.blob
      allow(blob).to receive(:previewable?).and_return(true)
      result = blob.representation(format: :webp, resize_to_limit: [100, 100])
      expect(result).to be_a(ActiveStorage::Preview)
    end
  end

  describe "configure" do
    it "yields self for block-style configuration" do
      ActiveStorage::Crucible.configure do |config|
        expect(config).to eq(ActiveStorage::Crucible)
      end
    end
  end

  describe "output_content_type" do
    subject(:transformer) { ActiveStorage::Crucible::Transformer.new }

    it "returns image/png for png format" do
      expect(transformer.send(:output_content_type, { format: :png })).to eq("image/png")
    end

    it "returns image/jpeg for jpg format" do
      expect(transformer.send(:output_content_type, { format: :jpg })).to eq("image/jpeg")
    end

    it "returns image/jpeg for jpeg format" do
      expect(transformer.send(:output_content_type, { format: "jpeg" })).to eq("image/jpeg")
    end

    it "returns image/gif for gif format" do
      expect(transformer.send(:output_content_type, { format: :gif })).to eq("image/gif")
    end

    it "returns video/mp4 for mp4 format" do
      expect(transformer.send(:output_content_type, { format: :mp4 })).to eq("video/mp4")
    end

    it "returns video/webm for webm format" do
      expect(transformer.send(:output_content_type, { format: :webm })).to eq("video/webm")
    end

    it "returns application/octet-stream for unknown format" do
      expect(transformer.send(:output_content_type, { format: :unknown })).to eq("application/octet-stream")
    end
  end

  describe "process_preview" do
    before do
      @user.video.attach(
        io: File.open("spec/support/fixtures/image.png"),
        filename: "clip.mp4",
        content_type: "video/mp4",
        identify: false,
      )
    end

    it "posts to Crucible video/preview endpoint" do
      blob = @user.video.blob
      variation = @user.video.variant(:thumb).variation
      ActiveStorage::Crucible::Transformer.new.process_preview(blob: blob, variation: variation)

      expect(@crucible_calls.size).to eq(1)
      call = @crucible_calls.first
      expect(call[:url]).to eq("https://crucible.example.com/video/preview")
      expect(call[:body][:blob_url]).to eq("https://presigned.example.com/source")
      expect(call[:body][:preview_image_url]).to eq("https://presigned.example.com/output")
      expect(call[:body][:preview_image_variant_url]).to eq("https://presigned.example.com/output")
    end

    it "attaches a preview image blob to the video blob" do
      blob = @user.video.blob
      variation = @user.video.variant(:thumb).variation
      ActiveStorage::Crucible::Transformer.new.process_preview(blob: blob, variation: variation)

      expect(blob.preview_image).to be_attached
      expect(blob.preview_image.blob.content_type).to eq("image/jpeg")
    end

    it "creates a variant record in processing state" do
      blob = @user.video.blob
      variation = @user.video.variant(:thumb).variation
      ActiveStorage::Crucible::Transformer.new.process_preview(blob: blob, variation: variation)

      preview_blob = blob.preview_image.blob
      record = preview_blob.variant_records.find_by(variation_digest: variation.digest)
      expect(record).to be_present
      expect(record.state).to eq("processing")
      expect(record.image).to be_attached
    end

    it "does not re-process when already processing" do
      blob = @user.video.blob
      variation = @user.video.variant(:thumb).variation
      ActiveStorage::Crucible::Transformer.new.process_preview(blob: blob, variation: variation)
      @crucible_calls.clear

      ActiveStorage::Crucible::Transformer.new.process_preview(blob: blob, variation: variation)
      expect(@crucible_calls).to be_empty
    end
  end
end

RSpec.describe ActiveStorage::Crucible::Client do
  describe "#post" do
    it "sends JSON POST to the given URL" do
      response = instance_double(Net::HTTPResponse, code: "200", body: "ok")
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).with("example.com", 443).and_return(http)
      allow(http).to receive(:use_ssl=).with(true)
      allow(http).to receive(:request).and_return(response)

      result = described_class.new.post("https://example.com/test", { key: "value" })
      expect(result).to eq(response)
    end

    it "raises on non-2xx response" do
      response = instance_double(Net::HTTPResponse, code: "500", body: "Internal Server Error")
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:request).and_return(response)

      expect {
        described_class.new.post("https://example.com/test", {})
      }.to raise_error("Crucible request failed: 500 Internal Server Error")
    end
  end
end

RSpec.describe ActiveStorage::Crucible::PresignedUrl do
  describe ".for" do
    it "returns blob.url for :get method" do
      blob = instance_double(ActiveStorage::Blob)
      allow(blob).to receive(:url).with(expires_in: 1.hour).and_return("https://example.com/get-url")

      result = described_class.for(blob, method: :get)
      expect(result).to eq("https://example.com/get-url")
    end

    it "returns presigned PUT url for :put method with content_type" do
      object = double("S3Object")
      allow(object).to receive(:presigned_url).with(:put, expires_in: 3600, content_type: "video/mp4").and_return("https://example.com/put-url")
      service = double("S3Service")
      allow(service).to receive(:object_for).and_return(object)
      blob = instance_double(ActiveStorage::Blob, service: service, key: "test-key", content_type: "video/mp4")

      result = described_class.for(blob, method: :put)
      expect(result).to eq("https://example.com/put-url")
    end
  end
end
