output "assignment_count" {
  description = "Number of assignments rendered."
  value       = length(var.account_assignments)
}
