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

variable "key_name" {
  description = "Existing EC2 key pair name for SSH. Leave null to rely on AWS SSM Session Manager only."
  type        = string
  default     = null
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to reach port 22. Restrict this to your IP (e.g. 203.0.113.5/32), not 0.0.0.0/0."
  type        = string
  default     = "0.0.0.0/0"
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
