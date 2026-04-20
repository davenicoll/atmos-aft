output "provider_arn" {
  description = "OIDC provider ARN."
  value       = try(aws_iam_openid_connect_provider.github[0].arn, null)
}

output "provider_url" {
  description = "OIDC provider issuer URL."
  value       = try(aws_iam_openid_connect_provider.github[0].url, null)
}
