resource "aws_s3_bucket" "longhorn_backups" {
  bucket = var.bucket_name

  tags = {
    Name      = var.bucket_name
    ManagedBy = "terraform"
    Purpose   = "longhorn-backups"
  }
}

resource "aws_s3_bucket_public_access_block" "longhorn_backups" {
  bucket = aws_s3_bucket.longhorn_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "longhorn_backups" {
  bucket = aws_s3_bucket.longhorn_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "longhorn_backups" {
  bucket = aws_s3_bucket.longhorn_backups.id

  # Abort incomplete multipart uploads so partially-written backup chunks don't
  # accumulate and incur storage charges.
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
