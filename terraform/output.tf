output "cloudfront_url" {
  description = "My portfolio website"
  value       = "https://${aws_cloudfront_distribution.cloudfront_cdn.domain_name}"
}