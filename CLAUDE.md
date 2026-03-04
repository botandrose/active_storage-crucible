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
- **`Transformer`** (`lib/active_storage/crucible/transformer.rb`) — Inherits from `ActiveStorage::AsyncVariants::Transformer`. Creates a placeholder output blob, generates presigned GET/PUT URLs, then POSTs to Crucible's `/image/variant` or `/video/variant` endpoint. Crucible processes asynchronously and calls back when done.
- **`PreviewExtension`** (`lib/active_storage/crucible/preview_extension.rb`) — Prepended onto `ActiveStorage::Preview`. For video blobs on S3, creates placeholder blobs and POSTs to `/video/preview`. Returns the original blob URL as fallback while processing.
- **`BlobExtension`** (`lib/active_storage/crucible/blob_extension.rb`) — Prepended onto `ActiveStorage::Blob`. Makes videos report as `variable?` and `previewable?` when Crucible is configured.
- **`Client`** (`lib/active_storage/crucible/client.rb`) — Simple `Net::HTTP` wrapper that POSTs JSON to Crucible
- **`PresignedUrl`** (`lib/active_storage/crucible/presigned_url.rb`) — Generates presigned S3 URLs for GET/PUT access to blobs

### Processing Flow

1. Variant defined with `transformer: ActiveStorage::Crucible::Transformer`
2. `async_variants` enqueues a `ProcessJob` which calls `Transformer#initiate`
3. Transformer creates placeholder blob, gets presigned URLs, POSTs to Crucible
4. Crucible processes the file and POSTs back to the callback URL
5. `async_variants` callback controller marks variant as processed

## Test Setup

- RSpec with `rspec-rails`, SQLite3 in-memory database
- Dummy Rails app in `spec/dummy/` with a `User` model having `avatar` and `video` attachments
- Test schema defined in `spec/support/active_record.rb`
- Tests mock `Client.post` and `PresignedUrl.for` to avoid real HTTP/S3 calls
