# ActiveStorage::Crucible

An Active Storage transformer that sends image and video variant processing to the [Crucible](https://github.com/botandrose/crucible) web service. Built on top of [active_storage-async_variants](https://github.com/botandrose/active_storage-async_variants).

## The Problem

Processing image variants and video previews on your Rails server ties up workers and requires installing tools like `vips` and `ffmpeg` in production. Crucible is an external service that handles these transformations -- but you need a bridge between Active Storage's variant system and Crucible's HTTP API.

This gem provides that bridge. It implements the `async_variants` external transformer interface, delegating all image/video processing to Crucible via presigned S3 URLs.

## Installation

```ruby
gem "active_storage-crucible"
```

Requires an S3-compatible storage service (the gem generates presigned URLs for Crucible to read source files and write results).

### Configuration

```ruby
# config/initializers/crucible.rb
ActiveStorage::Crucible.endpoint = "https://crucible.example.com"
ActiveStorage::Crucible.api_token = "..."
```

Or with a block:

```ruby
ActiveStorage::Crucible.configure do |config|
  config.endpoint = ENV["CRUCIBLE_ENDPOINT"]
  config.api_token = ENV["CRUCIBLE_API_TOKEN"]
end
```

Crucible requires the token on every request and answers `401` without it, so
`api_token` must be set to the value in that Crucible deployment's encrypted
credentials. It belongs with the endpoint: each deployment has its own token, so
an app that talks to more than one (staging vs. production, say) must set the
pair together.

## Usage

### Image and Video Variants

Use `ActiveStorage::Crucible::Transformer` as the transformer for any variant:

```ruby
class User < ApplicationRecord
  has_one_attached :avatar do |attachable|
    attachable.variant :thumb,
      resize_to_limit: [100, 100],
      format: :webp,
      transformer: ActiveStorage::Crucible::Transformer,
      fallback: :original
  end

  has_one_attached :video do |attachable|
    attachable.variant :web,
      resize_to_limit: [1280, 720],
      format: :webp,
      transformer: ActiveStorage::Crucible::Transformer,
      fallback: :original
  end
end
```

The transformer auto-detects image vs. video based on the blob's content type and calls the appropriate Crucible endpoint (`/image/variant` or `/video/variant`).

In views, use standard Active Storage helpers:

```erb
<%= image_tag user.avatar.variant(:thumb).url %>
```

While the variant is processing, this serves the original file. Once Crucible finishes and calls back, it serves the processed variant.

### Video Previews

The gem also extends `ActiveStorage::Preview` to process video previews through Crucible. This happens automatically for video blobs on S3-compatible services -- no extra configuration needed.

```erb
<%= image_tag user.video.preview(resize_to_limit: [640, 480], format: :webp).url %>
```

While the preview is processing, the original video URL is served as a fallback.

## How It Works

### Variant flow

1. A file is attached to a model with a Crucible-backed variant defined
2. `async_variants` enqueues a background job for the variant
3. The job calls `Crucible::Transformer#initiate`, which:
   - Creates a placeholder output blob in the database
   - Attaches it to the variant record
   - Generates presigned GET/PUT URLs for the source and output blobs
   - POSTs to Crucible with the URLs, dimensions, format, and a signed callback URL
4. Crucible processes the image/video, uploads the result to the presigned PUT URL
5. Crucible POSTs to the callback URL with `{"status": "success"}`
6. The `async_variants` callback controller marks the variant record as processed

### Preview flow

An image-format variant of a video is a stock `Preview`: the extracted frame is the video blob's `preview_image`, and the variant record hangs off that frame blob.

1. `ProcessJob` resolves the attachment's `representation`, attaches a frame placeholder as the video's `preview_image` if none exists, and creates the variant record on the frame blob
2. The transformer sees the record's blob is a video's `preview_image` and creates a placeholder output blob for the resized still
3. POSTs to Crucible's `/video/preview` endpoint with presigned PUT URLs for both the frame and the still, the dimensions, format, rotation, and a signed callback URL
4. Crucible extracts a frame, resizes it, and uploads both the frame and the still
5. Crucible POSTs to the callback URL; `async_variants` reconciles both placeholders and marks the record processed

Video-format variants of a video (transcodes) stay on the video blob and go through `/video/variant`.

### What gets sent to Crucible

**Variant requests** (`POST /image/variant` or `/video/variant`):

```json
{
  "blob_url": "https://s3.example.com/source?presigned...",
  "variant_url": "https://s3.example.com/output?presigned...",
  "dimensions": "100x100",
  "rotation": 0,
  "format": "webp",
  "callback_url": "https://app.example.com/active_storage/async_variants/callbacks/signed-token"
}
```

**Preview requests** (`POST /video/preview`):

```json
{
  "blob_url": "https://s3.example.com/source?presigned...",
  "preview_image_url": "https://s3.example.com/preview?presigned...",
  "preview_image_variant_url": "https://s3.example.com/variant?presigned...",
  "dimensions": "640x480",
  "rotation": 0,
  "format": "webp",
  "callback_url": "https://app.example.com/active_storage/async_variants/callbacks/signed-token"
}
```

## Callbacks

Callbacks are handled by `active_storage-async_variants`, not this gem. The callback endpoint is auto-mounted at:

```
POST /active_storage/async_variants/callbacks/:token
```

Crucible must POST `{"status": "success"}` or `{"status": "failed", "error": "..."}` to this URL after processing. The token is signed -- no authentication headers are needed. The endpoint must be publicly reachable by the Crucible service.

## License

MIT
