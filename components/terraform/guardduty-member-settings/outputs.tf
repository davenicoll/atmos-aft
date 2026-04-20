output "detector_id" {
  description = "Detector ID in this member account."
  value       = try(module.guardduty_member.guardduty_detector.id, null)
}

output "detector_arn" {
  description = "Detector ARN."
  value       = try(module.guardduty_member.guardduty_detector.arn, null)
}
