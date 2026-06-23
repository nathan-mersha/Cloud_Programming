output "cloudfront_url" {
  description = "My portfolio website"
  value       = "https://${aws_cloudfront_distribution.cdn.domain_name}"
}