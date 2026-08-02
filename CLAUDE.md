# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Rails gem that bridges Active Storage with the Crucible image/video processing service. Provides an `AsyncVariants` transformer that delegates variant processing to Crucible via HTTP, plus video preview support and presigned S3 URL generation. Depends on `active_storage-async_variants` (from GitHub).

## Commands

```bash
bundle exec rspec                                    # Run all specs
bundle exec rspec spec/active_storage/crucible_spec.rb  # Run specific spec file
bundle exec rake                                     # Default task runs specs
```

## Architecture

The gem is a Rails Engine that prepends extensions onto Active Storage classes:

- **`Crucible` module** (`lib/active_storage/crucible.rb`) — Engine setup, configurable `endpoint` for the Crucible service
- **`Transformer`** (`lib/active_storage/crucible/transformer.rb`) — Inherits from `ActiveStorage::AsyncVariants::Transformer`. `#initiate` reads the variant record's blob to pick one of three routes: an image → `/image/variant`; a video → `/video/variant` (transcode); or a video's extracted-frame placeholder → `/video/preview` (the stock preview graph). It creates the placeholder output blob and generates presigned GET/PUT URLs. Crucible processes asynchronously and calls back when done.
- **`BlobExtension`** (`lib/active_storage/crucible/blob_extension.rb`) — Prepended onto `ActiveStorage::Blob`. Makes videos (and images) report as `variable?`, and videos as `previewable?`, when Crucible is configured — independent of a local ffmpeg, since Crucible extracts frames server-side. `#representation` routes video output formats (mp4/webm/…) to `variant` and everything else to `super`.
- **`Client`** (`lib/active_storage/crucible/client.rb`) — Simple `Net::HTTP` wrapper that POSTs JSON to Crucible
- **`PresignedUrl`** (`lib/active_storage/crucible/presigned_url.rb`) — Generates presigned S3 URLs for GET/PUT access to blobs

### Processing Flow

1. Variant defined with `transformer: ActiveStorage::Crucible::Transformer, async: true`
2. `async_variants`' `ProcessJob` resolves `attachment.representation(name)` and calls `Transformer#initiate`
3. `#initiate` resolves the source/output blobs, gets presigned URLs, POSTs to Crucible
4. Crucible processes the file(s) and POSTs back to the callback URL
5. `async_variants`' callback controller marks the variant processed and reconciles blob metadata

### Video Previews (stock graph)

Because videos are both `previewable?` and `variable?`, an image-format request
(`representation(:thumb)`) resolves to a **preview**, matching stock Active Storage:
the frame is persisted as the video's `preview_image` and the variant record hangs
off the *frame* blob. `#initiate` detects this by finding the `preview_image`
attachment whose blob is the variant record's blob, then POSTs `/video/preview` with
both `preview_image_url` (the frame) and `preview_image_variant_url` (the resized
output). The success callback reconciles both placeholders, so the frame is a
legitimate persisted preview — not an orphan. A video *output* format
(`representation(format: :mp4)`) instead resolves to a `variant` and transcodes via
`/video/variant`, with the record on the video blob.

## Test Setup

- RSpec with `rspec-rails`, SQLite3 in-memory database
- Dummy Rails app in `spec/dummy/` with a `User` model having `avatar` and `video` attachments
- Test schema defined in `spec/support/active_record.rb`
- Tests mock `Client.post` and `PresignedUrl.for` to avoid real HTTP/S3 calls
