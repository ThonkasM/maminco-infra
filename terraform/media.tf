# -----------------------------------------------------------------------------
# Object storage (optional): ONE private S3 bucket, two top-level prefixes.
#
#   products/  Product images (WebP variants, content-addressed keys). Served to
#              browsers through CloudFront (OAC) with a 1-year immutable cache.
#   reports/   Documents of the admin repository (closing reports, uploads).
#              NEVER reachable through CloudFront: the bucket policy below only
#              grants CloudFront read access to products/*. The backend hands
#              out short-lived (5 min) presigned S3 URLs, so downloads go
#              straight from S3 to the browser.
#
# The backend (STORAGE_DRIVER=s3) uses the EC2 instance role; no access keys.
# -----------------------------------------------------------------------------
resource "random_id" "media_suffix" {
  count       = var.enable_media_bucket ? 1 : 0
  byte_length = 4
}

resource "aws_s3_bucket" "media" {
  count         = var.enable_media_bucket ? 1 : 0
  bucket        = "${var.project_name}-${var.environment}-media-${random_id.media_suffix[0].hex}"
  force_destroy = true

  tags = { Name = "${var.project_name}-${var.environment}-media" }
}

resource "aws_s3_bucket_ownership_controls" "media" {
  count  = var.enable_media_bucket ? 1 : 0
  bucket = aws_s3_bucket.media[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "media" {
  count                   = var.enable_media_bucket ? 1 : 0
  bucket                  = aws_s3_bucket.media[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  count  = var.enable_media_bucket ? 1 : 0
  bucket = aws_s3_bucket.media[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "media" {
  count  = var.enable_media_bucket ? 1 : 0
  bucket = aws_s3_bucket.media[0].id

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  count = var.enable_media_bucket ? 1 : 0
  name  = "Managed-CachingOptimized"
}

resource "aws_cloudfront_origin_access_control" "media" {
  count                             = var.enable_media_bucket ? 1 : 0
  name                              = "${var.project_name}-${var.environment}-media-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "media" {
  count           = var.enable_media_bucket ? 1 : 0
  enabled         = true
  http_version    = "http2and3"
  is_ipv6_enabled = true
  comment         = "${var.project_name}-${var.environment} product images"
  price_class     = var.cloudfront_price_class
  aliases         = local.media_on_dns ? [local.media_domain] : []

  origin {
    domain_name              = aws_s3_bucket.media[0].bucket_regional_domain_name
    origin_id                = "s3-${aws_s3_bucket.media[0].id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.media[0].id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-${aws_s3_bucket.media[0].id}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.media_on_dns ? null : true
    acm_certificate_arn            = local.media_on_dns ? aws_acm_certificate_validation.media[0].certificate_arn : null
    ssl_support_method             = local.media_on_dns ? "sni-only" : null
    minimum_protocol_version       = local.media_on_dns ? "TLSv1.2_2021" : null
  }

  tags = { Name = "${var.project_name}-${var.environment}-media-cdn" }
}

resource "aws_s3_bucket_policy" "media" {
  count  = var.enable_media_bucket ? 1 : 0
  bucket = aws_s3_bucket.media[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontReadProductImagesOnly"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.media[0].arn}/products/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.media[0].arn
        }
      }
    }]
  })
}

# The backend runs on the EC2 instance. Least privilege per prefix:
#   products/*  write + delete (image variants)
#   reports/*   read + write + delete (repository documents; reads are used to
#               presign download URLs and to stream when needed)
resource "aws_iam_role_policy" "media_write" {
  count = var.enable_media_bucket ? 1 : 0
  name  = "${var.project_name}-${var.environment}-media-write"
  role  = aws_iam_role.ssm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ProductImages"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.media[0].arn}/products/*"
      },
      {
        Sid      = "RepositoryDocuments"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.media[0].arn}/reports/*"
      },
      {
        Sid      = "ListOwnPrefixes"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.media[0].arn
        Condition = {
          StringLike = { "s3:prefix" = ["products/*", "reports/*"] }
        }
      }
    ]
  })
}
