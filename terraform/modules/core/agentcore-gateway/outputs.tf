output "gateway_endpoint" {
  description = "Endpoint URL of the AgentCore Gateway"
  value       = aws_bedrockagentcore_gateway.this.gateway_url
}

output "gateway_id" {
  description = "ID of the AgentCore Gateway"
  value       = aws_bedrockagentcore_gateway.this.gateway_id
}

output "gateway_arn" {
  description = "ARN of the AgentCore Gateway"
  value       = aws_bedrockagentcore_gateway.this.gateway_arn
}
output "devops_agent_gateway_role_arn" {
  description = "IAM role AWS DevOps Agent assumes to call this gateway (null when devops_agent_mcp_enabled = false)"
  value       = try(aws_iam_role.devops_agent_invoke[0].arn, null)
}
