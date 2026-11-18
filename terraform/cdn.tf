# -----------------------------------------------------------------------------
# Public edge (optional, enable_cdn_and_dns = true):
#
#   Route 53 (maminco.lat)  ->  CloudFront (app)  ->  EC2 / nginx (origin.<domain>, HTTPS)
#                           ->  CloudFront (media) ->  S3 products/ (OAC)
#
# CloudFront is a CDN/reverse proxy, NOT a load balancer: there is still one
# origin. ACM certificates for CloudFront must live in us-east-1.
# The origin is reachable only through CloudFront: the security group allows
# 443 from the CloudFront origin-facing managed prefix list and nginx requires
# the secret X-Origin-Verify header.
# -----------------------------------------------------------------------------
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

locals {
  cdn_enabled  = var.enable_cdn_and_dns
  media_domain = "media.${var.domain_name}"
  origin_host  = "origin.${var.domain_name}"
  zone_id      = local.cdn_enabled ? (var.create_hosted_zone ? aws_route53_zone.main[0].zone_id : var.hosted_zone_id) : null
  media_on_dns = local.cdn_enabled && var.enable_media_bucket
  origin_ip    = var.enable_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip
}

check "cdn_inputs" {
  assert {
    condition     = !local.cdn_enabled || (var.origin_verify_secret != null && (var.create_hosted_zone || var.hosted_zone_id != null))
    error_message = "enable_cdn_and_dns requires origin_verify_secret and, when create_hosted_zone = false, hosted_zone_id."
  }
}

resource "aws_route53_zone" "main" {
  count   = local.cdn_enabled && var.create_hosted_zone ? 1 : 0
  name    = var.domain_name
  comment = "${var.project_name}-${var.environment} public zone"
}

# --- Certificates (us-east-1, DNS validation) ---------------------------------
resource "aws_acm_certificate" "app" {
  count                     = local.cdn_enabled ? 1 : 0
  provider                  = aws.us_east_1
  domain_name               = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "media" {
  count             = local.media_on_dns ? 1 : 0
  provider          = aws.us_east_1
  domain_name       = local.media_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "app_validation" {
  for_each = local.cdn_enabled ? {
    for o in aws_acm_certificate.app[0].domain_validation_options : o.domain_name => {
      name   = o.resource_record_name
      type   = o.resource_record_type
      record = o.resource_record_value
    }
  } : {}

  zone_id         = local.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_route53_record" "media_validation" {
  for_each = local.media_on_dns ? {
    for o in aws_acm_certificate.media[0].domain_validation_options : o.domain_name => {
      name   = o.resource_record_name
      type   = o.resource_record_type
      record = o.resource_record_value
    }
  } : {}

  zone_id         = local.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "app" {
  count                   = local.cdn_enabled ? 1 : 0
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [for r in aws_route53_record.app_validation : r.fqdn]
}

resource "aws_acm_certificate_validation" "media" {
  count                   = local.media_on_dns ? 1 : 0
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.media[0].arn
  validation_record_fqdns = [for r in aws_route53_record.media_validation : r.fqdn]
}

# --- Origin DNS name (grey cloud: straight to the Elastic IP; Let's Encrypt on nginx) ---
resource "aws_route53_record" "origin" {
  count   = local.cdn_enabled ? 1 : 0
  zone_id = local.zone_id
  name    = local.origin_host
  type    = "A"
  ttl     = 300
  records = [local.origin_ip]
}

# Only CloudFront may reach 443 on the instance.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  count = local.cdn_enabled ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_vpc_security_group_ingress_rule" "https_cloudfront" {
  count             = local.cdn_enabled ? 1 : 0
  security_group_id = aws_security_group.instance.id
  description       = "HTTPS from CloudFront origin-facing prefix list"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront[0].id
}

# --- Policies -------------------------------------------------------------------
data "aws_cloudfront_cache_policy" "caching_disabled" {
  count = local.cdn_enabled ? 1 : 0
  name  = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "app_static" {
  count = local.cdn_enabled ? 1 : 0
  name  = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  count = local.cdn_enabled ? 1 : 0
  name  = "Managed-AllViewer"
}

resource "aws_cloudfront_response_headers_policy" "security" {
  count = local.cdn_enabled ? 1 : 0
  name  = "${var.project_name}-${var.environment}-security-headers"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      override                   = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "SAMEORIGIN"
      override     = false
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = false
    }
  }
}

# --- App distribution -------------------------------------------------------------
resource "aws_cloudfront_distribution" "app" {
  count           = local.cdn_enabled ? 1 : 0
  enabled         = true
  http_version    = "http2and3"
  is_ipv6_enabled = true
  comment         = "${var.project_name}-${var.environment} app (Next.js + API + socket.io)"
  price_class     = var.cloudfront_price_class
  aliases         = [var.domain_name, "www.${var.domain_name}"]

  origin {
    domain_name = local.origin_host
    origin_id   = "ec2-nginx"

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 30
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = var.origin_verify_secret
    }
  }

  default_cache_behavior {
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = "ec2-nginx"
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled[0].id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer[0].id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security[0].id
  }

  ordered_cache_behavior {
    path_pattern               = "/_next/static/*"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = "ec2-nginx"
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.app_static[0].id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security[0].id
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "ec2-nginx"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer[0].id
  }

  # WebSocket upgrades are supported by CloudFront on any behavior with GET and
  # caching disabled; the Upgrade/Connection headers are forwarded by AllViewer.
  ordered_cache_behavior {
    path_pattern             = "/socket.io/*"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "ec2-nginx"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = false
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.app[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = { Name = "${var.project_name}-${var.environment}-app-cdn" }
}

resource "aws_route53_record" "app" {
  for_each = local.cdn_enabled ? {
    "apex-a"    = { name = var.domain_name, type = "A" }
    "apex-aaaa" = { name = var.domain_name, type = "AAAA" }
    "www-a"     = { name = "www.${var.domain_name}", type = "A" }
    "www-aaaa"  = { name = "www.${var.domain_name}", type = "AAAA" }
  } : {}

  zone_id = local.zone_id
  name    = each.value.name
  type    = each.value.type

  alias {
    name                   = aws_cloudfront_distribution.app[0].domain_name
    zone_id                = aws_cloudfront_distribution.app[0].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "media" {
  for_each = local.media_on_dns ? toset(["A", "AAAA"]) : toset([])

  zone_id = local.zone_id
  name    = local.media_domain
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.media[0].domain_name
    zone_id                = aws_cloudfront_distribution.media[0].hosted_zone_id
    evaluate_target_health = false
  }
}
