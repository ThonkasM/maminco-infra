# =============================================================================
# Maminco infra — main Terraform configuration
# =============================================================================
# A single low-cost EC2 instance (Amazon Linux 2023) that runs the whole
# docker compose stack (postgres + backend + ai + frontend + nginx).
#
# Cost notes (approx., us-east-1, on-demand):
#   - t4g.small  ~ $0.0168/h  (~$12/mo)   <- default
#   - t3.micro   ~ free tier / ~$0.0104/h (~$7.5/mo)
#   - 20 GiB gp3 ~ $1.6/mo
#   - Elastic IP free while attached to a running instance
#   - S3 + CloudFront (optional) usage-based; PriceClass_100 is cheapest
# This is a student-budget setup: one host, no ALB/RDS/NAT gateway.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Optional remote state. For a solo project local state is fine; enable this
  # if you want your state in S3 (bucket must exist beforehand).
  # backend "s3" {
  #   bucket = "my-tf-state-bucket"
  #   key    = "maminco-infra/terraform.tfstate"
  #   region = "us-east-1"
  # }
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
# Security group — 22/80/443 in, everything out.
# -----------------------------------------------------------------------------
resource "aws_security_group" "instance" {
  name        = "${var.project_name}-${var.environment}-sg"
  description = "Maminco single-host stack: SSH, HTTP, HTTPS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
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
resource "aws_instance" "app" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.instance.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm.name
  key_name                    = var.key_name
  associate_public_ip_address = true

  # Install Docker + docker compose and (optionally) clone the repos.
  user_data = templatefile("${path.module}/user_data.sh", {
    project_name  = var.project_name
    repo_base_url = var.repo_base_url
    git_branch    = var.git_branch
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true
  }

  # user_data changes require a rebuild to take effect.
  user_data_replace_on_change = true

  tags = { Name = "${var.project_name}-${var.environment}-app" }

  lifecycle {
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
  force_destroy = true

  tags = { Name = "${var.project_name}-${var.environment}-static" }
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
