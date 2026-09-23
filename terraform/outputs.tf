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
  description = "URL of the deployed application (nginx on port 80)."
  value       = "http://${var.enable_elastic_ip ? aws_eip.app[0].public_ip : aws_instance.app.public_ip}"
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
