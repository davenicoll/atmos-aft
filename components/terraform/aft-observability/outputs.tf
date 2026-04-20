output "query_definition_ids" {
  description = "Map of logical name → query definition ID."
  value       = { for k, q in aws_cloudwatch_query_definition.saved : k => q.query_definition_id }
}
