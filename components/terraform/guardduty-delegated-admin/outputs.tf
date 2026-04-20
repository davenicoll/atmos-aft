output "detector_id" {
  description = "Detector ID in the delegated-admin account."
  value       = try(module.guardduty.guardduty_detector.id, null)
}

output "detector_arn" {
  description = "Detector ARN."
  value       = try(module.guardduty.guardduty_detector.arn, null)
}
