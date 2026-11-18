# =============================================================================
# Maminco infra — main Terraform configuration
# =============================================================================
# A single low-cost EC2 instance (Amazon Linux 2023) that runs the whole
# docker compose stack (postgres + backend + ai + frontend + nginx).
#
# Cost notes (approx., us-east-1, on-demand):
#   - t4g.small  ~ $0.0168/h  (~$12.3/mo)   <- default
#   - t3.micro   ~ free tier / ~$0.0104/h (~$7.6/mo)
#   - 2 x 20 GiB gp3 (root + data) ~ $3.2/mo
#   - Public IPv4 (Elastic IP or auto-assigned) $0.005/h (~$3.65/mo) since 2024
#   - EBS snapshots (DLM, 7 daily, incremental) ~ $0.5-1/mo for a small DB
#   - S3 + CloudFront (optional) usage-based; PriceClass_100 is cheapest
#   - Route 53 (optional): hosted zone monthly fee + per-query charges
# This is a student-budget setup: one host, no ALB/RDS/NAT gateway. CloudFront
# and Route 53 (cdn.tf) sit in front of it; CloudFront is not a load balancer.
#
# State: local by default. For remote state copy backend.tf.example to
# backend.tf (see docs/DEPLOYMENT.md).
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# -----------------------------------------------------------------------------
# Networking — one dedicated VPC with a single public subnet.
# Avoids depending on a pre-existing default VPC.
# -----------------------------------------------------------------------------
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-${var.instance_architecture}"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_vpc" "main" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-${var.environment}-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-${var.environment}-public" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project_name}-${var.environment}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project_name}-${var.environment}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Security group — 80/443 in, SSH only when allowed_ssh_cidr is set (prefer SSM).
# -----------------------------------------------------------------------------
resource "aws_security_group" "instance" {
  name        = "${var.project_name}-${var.environment}-sg"
  description = "Maminco single-host stack: HTTP, HTTPS and optional SSH"
  vpc_id      = aws_vpc.main.id

  dynamic "ingress" {
    for_each = var.allowed_ssh_cidr == null ? [] : [var.allowed_ssh_cidr]
    content {
      description = "SSH (restricted)"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  ingress {
    description = "HTTP (redirects to HTTPS, ACME challenges)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = var.enable_cdn_and_dns ? [] : [1]
    content {
      description = "HTTPS (open to the world only while CloudFront is not enabled; see cdn.tf)"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    description = "All outbound (package installs, image pulls, ACME)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-${var.environment}-sg" }
}

# -----------------------------------------------------------------------------
# IAM — SSM Session Manager so you can get a shell without SSH keys (free).
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ssm" {
  name = "${var.project_name}-${var.environment}-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.project_name}-${var.environment}-ssm-profile"
  role = aws_iam_role.ssm.name
}

# -----------------------------------------------------------------------------
# EC2 instance
# -----------------------------------------------------------------------------
locals {
  compose_sha256 = var.instance_architecture == "arm64" ? var.compose_sha256_aarch64 : var.compose_sha256_x86_64
  data_device    = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.data.id, "-", "")}"
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.instance.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm.name
  key_name                    = var.key_name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user_data.sh", {
    project_name   = var.project_name
    repo_base_url  = var.repo_base_url
    git_branch     = var.git_branch
    compose_ver    = var.compose_version
    compose_sha256 = local.compose_sha256
    data_device    = local.data_device
    swap_size_mb   = var.swap_size_mb
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "${var.project_name}-${var.environment}-app" }

  lifecycle {
    # user_data only runs on first boot and a newer AMI must never recreate the
    # host: application state lives on the separate data volume, and rolling a
    # new image is a deliberate, manual act (terraform apply -replace).
    ignore_changes = [ami, user_data]

    precondition {
      condition = !(
        can(regex("^t4g", var.instance_type)) && var.instance_architecture != "arm64"
        ) && !(
        can(regex("^t[23]\\.", var.instance_type)) && var.instance_architecture != "x86_64"
      )
      error_message = "instance_architecture must be arm64 for t4g.* instances and x86_64 for t2.*/t3.* instances."
    }
  }
}

# -----------------------------------------------------------------------------
# Data volume — holds /data (Docker data-root: Postgres volume, certificates).
# Separate from the root disk so the instance can be replaced without data
# loss; protected from accidental `terraform destroy`.
# -----------------------------------------------------------------------------
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_availability_zones.available.names[0]
  type              = "gp3"
  size              = var.data_volume_size
  encrypted         = true

  tags = {
    Name   = "${var.project_name}-${var.environment}-data"
    Backup = "daily"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.data.id
  instance_id  = aws_instance.app.id
  force_detach = false
}

# -----------------------------------------------------------------------------
# Backups — Data Lifecycle Manager snapshots every volume tagged Backup=daily.
# Snapshots are crash-consistent (Postgres replays WAL on restore). Retention
# is var.backup_retention_days daily snapshots.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "dlm" {
  name = "${var.project_name}-${var.environment}-dlm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "data" {
  description        = "${var.project_name}-${var.environment} daily data volume snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Backup = "daily"
    }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["07:00"]
      }

      retain_rule {
        count = var.backup_retention_days
      }

      copy_tags = true
    }
  }
}

resource "aws_eip" "app" {
  count    = var.enable_elastic_ip ? 1 : 0
  domain   = "vpc"
  instance = aws_instance.app.id

  tags = { Name = "${var.project_name}-${var.environment}-eip" }
}

# -----------------------------------------------------------------------------
# Optional static CDN (S3 + CloudFront). Disabled by default.
# The Next.js frontend is SSR and cannot be served statically, but this bucket
# is handy for backups, exports, or a future static marketing site.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "static" {
  count         = var.enable_static_cdn ? 1 : 0
  bucket        = "${var.project_name}-${var.environment}-static-${random_id.bucket_suffix[0].hex}"
  force_destroy = false

  tags = { Name = "${var.project_name}-${var.environment}-static" }
}

resource "aws_s3_bucket_versioning" "static" {
  count  = var.enable_static_cdn ? 1 : 0
  bucket = aws_s3_bucket.static[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "static" {
  count  = var.enable_static_cdn ? 1 : 0
  bucket = aws_s3_bucket.static[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "static" {
  count  = var.enable_static_cdn ? 1 : 0
  bucket = aws_s3_bucket.static[0].id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "random_id" "bucket_suffix" {
  count       = var.enable_static_cdn ? 1 : 0
  byte_length = 4
}

resource "aws_s3_bucket_public_access_block" "static" {
  count                   = var.enable_static_cdn ? 1 : 0
  bucket                  = aws_s3_bucket.static[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "static" {
  count                             = var.enable_static_cdn ? 1 : 0
  name                              = "${var.project_name}-${var.environment}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "static" {
  count   = var.enable_static_cdn ? 1 : 0
  enabled = true
  comment = "${var.project_name}-${var.environment} static CDN"

  origin {
    domain_name              = aws_s3_bucket.static[0].bucket_regional_domain_name
    origin_id                = "s3-${aws_s3_bucket.static[0].id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.static[0].id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-${aws_s3_bucket.static[0].id}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  price_class = var.cloudfront_price_class

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${var.project_name}-${var.environment}-cdn" }
}

resource "aws_s3_bucket_policy" "static" {
  count  = var.enable_static_cdn ? 1 : 0
  bucket = aws_s3_bucket.static[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCloudFrontRead"
      Effect = "Allow"
      Principal = {
        Service = "cloudfront.amazonaws.com"
      }
      Action   = "s3:GetObject"
      Resource = "${aws_s3_bucket.static[0].arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.static[0].arn
        }
      }
    }]
  })
}
