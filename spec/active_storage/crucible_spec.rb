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
      expect(call[:body][:format]).to eq("webp")
      expect(call[:body][:callback_url]).to include("/active_storage/async_variants/callbacks/")
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

    it "posts to Crucible video/variant endpoint for video blobs" do
      ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :video, :thumb)

      expect(@crucible_calls.size).to eq(1)
      call = @crucible_calls.first
      expect(call[:url]).to eq("https://crucible.example.com/video/variant")
      expect(call[:body][:dimensions]).to eq("640x480")
    end
  end

  describe "video preview" do
    before do
      @user.video.attach(
        io: File.open("spec/support/fixtures/image.png"),
        filename: "clip.mp4",
        content_type: "video/mp4",
        identify: false,
      )
      stub_s3_service
    end

    it "posts to Crucible video/preview endpoint for video blobs on S3" do
      preview = @user.video.preview(resize_to_limit: [640, 480], format: :webp)
      preview.process

      expect(@crucible_calls.size).to eq(1)
      call = @crucible_calls.first
      expect(call[:url]).to eq("https://crucible.example.com/video/preview")
      expect(call[:body][:blob_url]).to eq("https://presigned.example.com/source")
      expect(call[:body][:preview_image_url]).to eq("https://presigned.example.com/output")
      expect(call[:body][:preview_image_variant_url]).to eq("https://presigned.example.com/output")
      expect(@user.video.blob.preview_image).to be_attached
    end

    it "falls back to blob URL when preview is not yet processed" do
      preview = @user.video.preview(resize_to_limit: [640, 480], format: :webp)
      preview.process

      url = preview.url
      expect(url).to be_present
    end

    it "does not re-process when preview_image is already attached" do
      preview = @user.video.preview(resize_to_limit: [640, 480], format: :webp)
      preview.process
      @crucible_calls.clear

      preview.process
      expect(@crucible_calls).to be_empty
    end

    it "falls through to super for non-video blobs" do
      expect {
        @user.avatar.blob.preview(resize_to_limit: [100, 100])
      }.to raise_error(ActiveStorage::UnpreviewableError)
    end
  end

  private

  def stub_s3_service
    allow_any_instance_of(ActiveStorage::Service::DiskService).to receive(:respond_to?).and_call_original
    allow_any_instance_of(ActiveStorage::Service::DiskService).to receive(:respond_to?).with(:bucket).and_return(true)
  end
end
