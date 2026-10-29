locals {
  common_tags = {
    project     = var.project_tag
    environment = var.environment_tag
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# IAM Role for AgentCore Gateway
# -----------------------------------------------------------------------------
resource "aws_iam_role" "gateway" {
  name = "${var.project_tag}-agentcore-gateway-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = [
            "bedrock.amazonaws.com",
            "bedrock-agentcore.amazonaws.com"
          ]
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_tag}-agentcore-gateway-role"
  })
}

resource "aws_iam_role_policy" "gateway" {
  name = "${var.project_tag}-agentcore-gateway-policy"
  role = aws_iam_role.gateway.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = "arn:aws:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:function:${var.project_tag}-*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# AgentCore Gateway — supports IAM (default) or OAuth (Cognito JWT) auth
# -----------------------------------------------------------------------------
resource "aws_bedrockagentcore_gateway" "this" {
  name            = "${var.project_tag}-gateway"
  protocol_type   = "MCP"
  authorizer_type = var.gateway_auth == "oauth" ? "CUSTOM_JWT" : "AWS_IAM"
  role_arn        = aws_iam_role.gateway.arn

  dynamic "authorizer_configuration" {
    for_each = var.gateway_auth == "oauth" ? [1] : []
    content {
      custom_jwt_authorizer {
        discovery_url = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${var.cognito_user_pool_id}/.well-known/openid-configuration"
        # Access tokens (Quick) carry the client ID in `client_id`, not `aud`;
        # ID tokens (AG-UI frontend) carry it in `aud`. Validate the claim the
        # incoming token type actually populates, or the gateway 403s.
        allowed_clients  = var.jwt_validation_claim == "client" ? [var.cognito_app_client_id] : null
        allowed_audience = var.jwt_validation_claim == "audience" ? [var.cognito_app_client_id] : null
      }
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_tag}-agentcore-gateway"
  })
}

# -----------------------------------------------------------------------------
# Lambda Tool Targets
# -----------------------------------------------------------------------------
resource "aws_bedrockagentcore_gateway_target" "lambda_tools" {
  for_each = var.lambda_tool_arns

  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  name               = each.key

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = each.value
        tool_schema {
          inline_payload {
            name        = each.key
            description = "Lambda tool: ${each.key}"
            input_schema {
              type = "object"
            }
            output_schema {
              type = "object"
            }
          }
        }
      }
    }
  }
}

# -----------------------------------------------------------------------------
# AWS DevOps Agent access (opt-in) — the role DevOps Agent assumes to SigV4-sign
# MCP calls to this gateway. Trusted only by aidevops.amazonaws.com from this
# account (the Agent Space is assumed to live in the deploy account, as the
# devops-agent-integration module also assumes). Do NOT add an aws:SourceArn
# condition: DevOps Agent's SigV4 MCP registration fails with "Invalid STS role
# configuration for session sigv4McpServerSession" when one is present.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "devops_agent_invoke" {
  count = var.devops_agent_mcp_enabled ? 1 : 0
  name  = "${var.project_tag}-devops-agent-gateway-invoke"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "aidevops.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_tag}-devops-agent-gateway-invoke"
  })
}

resource "aws_iam_role_policy" "devops_agent_invoke" {
  count = var.devops_agent_mcp_enabled ? 1 : 0
  name  = "${var.project_tag}-devops-agent-gateway-invoke"
  role  = aws_iam_role.devops_agent_invoke[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "bedrock-agentcore:InvokeGateway"
        Resource = aws_bedrockagentcore_gateway.this.gateway_arn
      }
    ]
  })
}
