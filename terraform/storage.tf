# =========================================================
# S3: CI/CD report archive (test, coverage, quality and security-scan reports per build).
# Private, encrypted, versioned, TLS-only, objects expire after 30 days to bound cost.
# =========================================================

resource "aws_s3_bucket" "ci_reports" {
  bucket_prefix = "${var.project_name}-ci-reports-"
  force_destroy = true # reports are reproducible build output; allows a clean teardown

  tags = {
    Name = "${var.project_name}-ci-reports"
  }
}

resource "aws_s3_bucket_public_access_block" "ci_reports" {
  bucket                  = aws_s3_bucket.ci_reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "ci_reports" {
  bucket = aws_s3_bucket.ci_reports.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ci_reports" {
  bucket = aws_s3_bucket.ci_reports.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "ci_reports" {
  bucket = aws_s3_bucket.ci_reports.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ci_reports" {
  bucket = aws_s3_bucket.ci_reports.id

  rule {
    id     = "expire-reports"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_policy" "ci_reports_tls_only" {
  bucket = aws_s3_bucket.ci_reports.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.ci_reports.arn, "${aws_s3_bucket.ci_reports.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.ci_reports]
}
