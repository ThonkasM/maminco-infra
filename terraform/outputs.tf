# =============================================================================
# Maminco infra — Terraform outputs
# =============================================================================

output "instance_id" {
  description = "EC2 instance id."
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Public IP of the host (Elastic IP when enable_elastic_ip = true)."
  value       = var.enable_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip
}

output "public_dns" {
  description = "Public DNS name of the host."
  value       = aws_instance.app.public_dns
}

output "app_url" {
  description = "URL of the deployed application: https://<domain_name> when enable_cdn_and_dns = true, otherwise the host IP (HTTPS only after the TLS certificate is issued; see docs/DEPLOYMENT.md)."
  value       = var.enable_cdn_and_dns ? "https://${var.domain_name}" : "https://${var.enable_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}"
}

output "ssh_command" {
  description = "SSH command (requires key_name to be set)."
  value = var.key_name != null ? format(
    "ssh -i <your-key>.pem ec2-user@%s",
    var.enable_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip
  ) : "No key_name set — use SSM instead (see ssm_command)."
}

output "ssm_command" {
  description = "AWS SSM Session Manager start command (no SSH key needed)."
  value = format(
    "aws ssm start-session --target %s --region %s",
    aws_instance.app.id,
    var.aws_region
  )
}

output "static_bucket_name" {
  description = "S3 bucket name for optional static assets (empty when disabled)."
  value       = var.enable_static_cdn ? aws_s3_bucket.static[0].bucket : ""
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain (empty when enable_static_cdn = false)."
  value       = var.enable_static_cdn ? aws_cloudfront_distribution.static[0].domain_name : ""
}

output "data_volume_id" {
  description = "EBS data volume id (Postgres data, certificates). Snapshotted daily by DLM."
  value       = aws_ebs_volume.data.id
}

output "backup_policy_id" {
  description = "DLM lifecycle policy id that snapshots the data volume."
  value       = aws_dlm_lifecycle_policy.data.id
}

output "media_bucket_name" {
  description = "Private S3 bucket holding products/ (via CloudFront) and reports/ (presigned URLs only) (S3_BUCKET). Null when enable_media_bucket = false."
  value       = try(aws_s3_bucket.media[0].id, null)
}

output "media_base_url" {
  description = "CloudFront base URL for product images only (ASSETS_BASE_URL). Documents are never served from here. Null when enable_media_bucket = false."
  value       = var.enable_media_bucket ? (var.enable_cdn_and_dns ? "https://media.${var.domain_name}" : "https://${aws_cloudfront_distribution.media[0].domain_name}") : null
}

output "name_servers" {
  description = "Route 53 name servers to set at the domain registrar (empty unless the zone is created here)."
  value       = var.enable_cdn_and_dns && var.create_hosted_zone ? aws_route53_zone.main[0].name_servers : []
}

output "origin_host" {
  description = "DNS name of the origin (A record to the Elastic IP). Use it as DOMAIN in the host .env: certbot issues the origin certificate for it."
  value       = var.enable_cdn_and_dns ? "origin.${var.domain_name}" : null
}

output "app_certificate_arn" {
  description = "ACM certificate (us-east-1) of the apex and www."
  value       = try(aws_acm_certificate.app[0].arn, null)
}

output "media_certificate_arn" {
  description = "ACM certificate (us-east-1) of media.<domain>."
  value       = try(aws_acm_certificate.media[0].arn, null)
}

output "app_cloudfront_domain_name" {
  description = "CloudFront domain of the app distribution."
  value       = try(aws_cloudfront_distribution.app[0].domain_name, null)
}
