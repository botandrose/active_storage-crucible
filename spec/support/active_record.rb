# frozen_string_literal: true

def silence_stream(stream)
  old_stream = stream.dup
  stream.reopen(IO::NULL)
  stream.sync = true
  yield
ensure
  stream.reopen(old_stream)
  old_stream.close
end

RSpec.configure do |config|
  config.before(:all) do
    ActiveRecord::Base.establish_connection adapter: "sqlite3", database: ":memory:"

    silence_stream(STDOUT) do
      ActiveRecord::Base.include GlobalID::Identification

      ActiveRecord::Schema.define do
        create_table :active_storage_blobs do |t|
          t.string :key, null: false
          t.string :filename, null: false
          t.string :content_type
          t.text :metadata
          t.string :service_name, null: false
          t.bigint :byte_size, null: false
          t.string :checksum
          t.datetime :created_at, null: false
          t.index [:key], unique: true
        end

        create_table :active_storage_attachments do |t|
          t.string :name, null: false
          t.references :record, null: false, polymorphic: true, index: false
          t.references :blob, null: false
          t.datetime :created_at, null: false
          t.index [:record_type, :record_id, :name, :blob_id], name: "index_active_storage_attachments_uniqueness", unique: true
          t.foreign_key :active_storage_blobs, column: :blob_id
        end

        create_table :active_storage_variant_records do |t|
          t.belongs_to :blob, null: false, index: false
          t.string :variation_digest, null: false
          t.string :state, default: "pending"
          t.text :error
          t.integer :attempts, default: 0
          t.index [:blob_id, :variation_digest], name: "index_active_storage_variant_records_uniqueness", unique: true
          t.foreign_key :active_storage_blobs, column: :blob_id
        end

        create_table :users do |t|
          t.timestamps
        end
      end
    end

    class User < ActiveRecord::Base
      has_one_attached :avatar do |attachable|
        attachable.variant :thumb,
          resize_to_limit: [100, 100],
          format: :webp,
          transformer: ActiveStorage::Crucible::Transformer,
          fallback: :original
      end

      has_one_attached :video do |attachable|
        attachable.variant :thumb,
          resize_to_limit: [640, 480],
          format: :webp,
          transformer: ActiveStorage::Crucible::Transformer,
          fallback: :original
        attachable.variant :transcoded,
          resize_to_limit: [1280, 720],
          format: :mp4,
          transformer: ActiveStorage::Crucible::Transformer,
          fallback: :original
        attachable.variant :unformatted,
          resize_to_limit: [1280, 720],
          transformer: ActiveStorage::Crucible::Transformer,
          fallback: :original
      end
    end
  end

  config.after do
    User.delete_all
    ActiveStorage::Attachment.delete_all
    ActiveStorage::VariantRecord.delete_all
    ActiveStorage::Blob.delete_all
  end
end

def create_variant_record(variant, state: "pending", error: nil)
  blob = variant.blob
  blob.variant_records.create!(
    variation_digest: variant.variation.digest,
    state: state,
    error: error,
  )
end

def simulate_processed_variant(variant)
  record = create_variant_record(variant, state: "processed")
  record.image.attach(
    io: File.open("spec/support/fixtures/image.png"),
    filename: "thumb.webp",
    content_type: "image/webp",
    service_name: "test",
  )
  record
end
