data "aws_iam_account_alias" "current" {}
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
locals {
  bucket_prefix         = var.use_account_alias_prefix ? format("%s-", data.aws_iam_account_alias.current.account_alias) : ""
  bucket_id             = "${local.bucket_prefix}${var.bucket}"
  enable_bucket_logging = var.logging_bucket != ""
}

data "aws_iam_policy_document" "supplemental_policy" {

  source_json = var.custom_bucket_policy

  #
  # Enforce SSL/TLS on all transmitted objects
  # We do this by extending the custom_bucket_policy
  #
  statement {
    sid    = "enforce-tls-requests-only"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_id}/*"
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "inventory-and-analytics"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    actions = ["s3:PutObject"]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${local.bucket_id}/*"
    ]
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:s3:::${local.bucket_id}"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket" "private_bucket" {
  bucket = local.bucket_id
  acl    = "private"
  tags   = var.tags
  policy = data.aws_iam_policy_document.supplemental_policy.json

  versioning {
    enabled = true
  }

  lifecycle_rule {
    enabled = true

    abort_incomplete_multipart_upload_days = 14

    expiration {
      expired_object_delete_marker = true
    }

    noncurrent_version_transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      days = 365
    }
  }

  lifecycle_rule {
    enabled = true

    prefix = "_AWSBucketInventory/"

    expiration {
      days = 14
    }
  }

  lifecycle_rule {
    enabled = true

    prefix = "_AWSBucketAnalytics/"

    expiration {
      days = 30
    }
  }

  dynamic "logging" {
    for_each = local.enable_bucket_logging ? [1] : []
    content {
      target_bucket = var.logging_bucket
      target_prefix = "s3/${local.bucket_id}/"
    }
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

resource "aws_s3_bucket_analytics_configuration" "private_analytics_config" {
  count  = var.enable_analytics ? 1 : 0
  bucket = aws_s3_bucket.private_bucket.bucket
  name   = "Analytics"

  storage_class_analysis {
    data_export {
      destination {
        s3_bucket_destination {
          bucket_arn = aws_s3_bucket.private_bucket.arn
          prefix     = "/_AWSBucketAnalytics"
        }
      }
    }
  }
}

resource "aws_s3_bucket_public_access_block" "public_access_block" {
  bucket = aws_s3_bucket.private_bucket.id

  # Block new public ACLs and uploading public objects
  block_public_acls = true

  # Retroactively remove public access granted through public ACLs
  ignore_public_acls = true

  # Block new public bucket policies
  block_public_policy = true

  # Retroactivley block public and cross-account access if bucket has public policies
  restrict_public_buckets = true
}

resource "aws_s3_bucket_inventory" "inventory" {
  count = var.enable_bucket_inventory ? 1 : 0

  bucket = aws_s3_bucket.private_bucket.id
  name   = "BucketInventory"

  included_object_versions = "All"

  schedule {
    frequency = var.schedule_frequency
  }

  destination {
    bucket {
      format     = var.inventory_bucket_format
      bucket_arn = aws_s3_bucket.private_bucket.arn
      prefix     = "_AWSBucketInventory/"
    }
  }

  optional_fields = ["Size", "LastModifiedDate", "StorageClass", "ETag", "IsMultipartUploaded", "ReplicationStatus", "EncryptionStatus",
  "ObjectLockRetainUntilDate", "ObjectLockMode", "ObjectLockLegalHoldStatus", "IntelligentTieringAccessTier"]
}
