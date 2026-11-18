# =============================================================================
# Maminco infra — Terraform variables
# =============================================================================

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix used for all resources and tags."
  type        = string
  default     = "maminco"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,24}$", var.project_name))
    error_message = "project_name must be 2-24 chars, lowercase letters, digits or hyphens."
  }
}

variable "environment" {
  description = "Environment/stage name used in tags and resource names."
  type        = string
  default     = "prod"
}

# -----------------------------------------------------------------------------
# Compute (keep it cheap)
# -----------------------------------------------------------------------------
variable "instance_type" {
  description = "EC2 instance type. t4g.small (ARM/Graviton, cheap) is the default; use t3.micro for the free tier (x86_64)."
  type        = string
  default     = "t4g.small"
}

variable "instance_architecture" {
  description = "CPU architecture of the AMI, must match instance_type: arm64 for t4g.*, x86_64 for t3.*/t2.*."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.instance_architecture)
    error_message = "instance_architecture must be either arm64 or x86_64."
  }
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB (gp3)."
  type        = number
  default     = 20
}

variable "data_volume_size" {
  description = "Size in GiB of the separate encrypted gp3 data volume (Postgres data, certificates)."
  type        = number
  default     = 20
}

variable "backup_retention_days" {
  description = "Number of daily EBS snapshots of the data volume to retain (AWS DLM)."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 100
    error_message = "backup_retention_days must be between 1 and 100."
  }
}

variable "swap_size_mb" {
  description = "Swap file size in MiB created at first boot (the 2 GiB host runs close to its memory limits)."
  type        = number
  default     = 1024
}

variable "compose_version" {
  description = "Pinned Docker Compose release installed at first boot."
  type        = string
  default     = "v5.1.0"
}

variable "compose_sha256_aarch64" {
  description = "SHA-256 of docker-compose-linux-aarch64 for compose_version (from the release's .sha256 asset)."
  type        = string
  default     = "da671ae15b4d7c68c38b572a2e9ceba89f09657d2682c2d2e34ad6db828e7442"
}

variable "compose_sha256_x86_64" {
  description = "SHA-256 of docker-compose-linux-x86_64 for compose_version (from the release's .sha256 asset)."
  type        = string
  default     = "5633cb21e06a7c88c7ca48a9334d3d0f7f892e9605ae9e9a45f9a095d4ffceb8"
}

variable "key_name" {
  description = "Existing EC2 key pair name for SSH. Leave null to rely on AWS SSM Session Manager only."
  type        = string
  default     = null
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to reach port 22 (e.g. 203.0.113.5/32). Null (default) creates no SSH rule: use SSM Session Manager."
  type        = string
  default     = null

  validation {
    condition     = var.allowed_ssh_cidr == null ? true : (can(cidrhost(var.allowed_ssh_cidr, 0)) && var.allowed_ssh_cidr != "0.0.0.0/0" && var.allowed_ssh_cidr != "::/0")
    error_message = "allowed_ssh_cidr must be a valid CIDR and must not be open to the world (0.0.0.0/0)."
  }
}

variable "enable_elastic_ip" {
  description = "Allocate and attach an Elastic IP so the public address is stable across reboots."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Bootstrap / repositories
# -----------------------------------------------------------------------------
variable "repo_base_url" {
  description = "Base URL of the Git host used to clone the repos at first boot (e.g. https://github.com/ThonkasM). Leave empty to skip cloning."
  type        = string
  default     = "https://github.com/ThonkasM"
}

variable "git_branch" {
  description = "Git branch to deploy."
  type        = string
  default     = "main"
}

# -----------------------------------------------------------------------------
# Optional static CDN (disabled by default — the app needs a Node server)
# -----------------------------------------------------------------------------
variable "enable_static_cdn" {
  description = "Create an S3 bucket + CloudFront distribution (useful for static assets or backups). Disabled by default."
  type        = bool
  default     = false
}

variable "cloudfront_price_class" {
  description = "CloudFront price class used when enable_static_cdn = true. PriceClass_100 is the cheapest (US/EU only)."
  type        = string
  default     = "PriceClass_100"
}

variable "enable_media_bucket" {
  description = "Create the private S3 bucket (prefixes products/ and reports/) + CloudFront for product images (STORAGE_DRIVER=s3)."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Public domain: Route 53 + CloudFront in front of the EC2/nginx origin
# -----------------------------------------------------------------------------
variable "enable_cdn_and_dns" {
  description = "Put CloudFront (with ACM certificates) and Route 53 records for domain_name in front of the app. Requires domain_name. Off by default so the stack still works on the bare Elastic IP."
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Public apex domain (e.g. maminco.lat). Used when enable_cdn_and_dns = true."
  type        = string
  default     = "maminco.lat"
}

variable "create_hosted_zone" {
  description = "Create the Route 53 public hosted zone for domain_name. Set false to reuse an existing zone (then hosted_zone_id is required)."
  type        = bool
  default     = true
}

variable "hosted_zone_id" {
  description = "Existing Route 53 hosted zone id, used only when create_hosted_zone = false."
  type        = string
  default     = null
}

variable "origin_verify_secret" {
  description = "Secret sent by CloudFront in the X-Origin-Verify header; nginx rejects requests without it. Min. 32 chars. Must equal ORIGIN_VERIFY_SECRET in the host .env."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.origin_verify_secret == null ? true : length(var.origin_verify_secret) >= 32
    error_message = "origin_verify_secret must be at least 32 characters (openssl rand -hex 32)."
  }
}
