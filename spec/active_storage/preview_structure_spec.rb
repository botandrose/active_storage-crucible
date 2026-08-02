# frozen_string_literal: true

# A video image-variant (e.g. :thumb) takes the stock preview path: Crucible
# extracts the frame (persisted as the video's preview_image) and the resized
# variant in one /video/preview call, with the variant record on the frame blob.
RSpec.describe "ActiveStorage::Crucible stock preview structure" do
  before do
    @user = User.create!
    @user.video.attach(
      io: File.open("spec/support/fixtures/image.png"),
      filename: "clip.mp4",
      content_type: "video/mp4",
      identify: false,
    )
    @crucible_calls = []
    @presigned_put_blobs = []
    allow_any_instance_of(ActiveStorage::Crucible::Client).to receive(:post) do |_client, url, body|
      @crucible_calls << { url: url, body: body }
    end
    allow(ActiveStorage::Crucible::PresignedUrl).to receive(:for) do |blob, method:|
      case method
      when :get then "https://presigned.example.com/source"
      when :put
        @presigned_put_blobs << blob
        "https://presigned.example.com/put/#{blob.id}"
      end
    end
  end

  let(:video_blob) { @user.video.blob }

  it "attaches the frame as preview_image and records the variant on the frame blob" do
    ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :video, :thumb)

    expect(video_blob.preview_image).to be_attached
    frame = video_blob.preview_image.blob
    expect(frame.content_type).to eq("image/jpeg")

    expect(video_blob.variant_records.count).to eq(0)
    record = frame.variant_records.sole
    expect(record.state).to eq("processing")
    expect(record.image).to be_attached
    expect(record.image.blob.content_type).to eq("image/jpeg")
  end

  it "posts /video/preview with the frame and variant as the two PUT targets" do
    ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :video, :thumb)

    frame = video_blob.preview_image.blob
    record = frame.variant_records.sole

    call = @crucible_calls.sole
    expect(call[:url]).to eq("https://crucible.example.com/video/preview")
    expect(call[:body][:dimensions]).to eq("150x150")
    expect(@presigned_put_blobs).to contain_exactly(frame, record.image.blob)
  end

  it "reuses the one frame across multiple image variants" do
    ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :video, :thumb)
    ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :video, :web)

    expect(ActiveStorage::Attachment.where(name: "preview_image").count).to eq(1)
    expect(video_blob.preview_image.blob.variant_records.count).to eq(2)
  end

  it "resolves through representation/preview, not variant()" do
    ActiveStorage::AsyncVariants::ProcessJob.perform_now(@user, :video, :thumb)

    expect(@user.video.representation(:thumb)).to be_a(ActiveStorage::Preview)
    expect(@user.video.variant(:thumb).processed?).to be false
  end
end
