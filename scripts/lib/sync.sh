#!/usr/bin/env bash
# Post-deploy sync — agent runtime updates, gateway tool schemas, observability, frontend deploy
enable_observability() {
  # Hash-based skip: only run if resource ARNs changed (resources recreated)
  local hash_file="${HASH_DIR}/observability.sha"
  local runtime_arn gateway_arn memory_arn
  runtime_arn=$(tf_output supervisor_runtime_arn)
  gateway_arn=$(tf_output gateway_arn)
  memory_arn=$(tf_output agentcore_memory_arn)
  local current_hash
  current_hash=$(echo "${runtime_arn}|${gateway_arn}|${memory_arn}" | shasum | cut -d' ' -f1)
  local stored_hash
  stored_hash=$(cat "$hash_file" 2>/dev/null || echo "")
  if [ "$current_hash" = "$stored_hash" ]; then
    info "Observability: unchanged, skipping setup"
    return
  fi

  info "Enabling AgentCore observability..."

  local account_id
  account_id=$(aws sts get-caller-identity --query Account --output text)

  # Step 1: Resource policy for X-Ray → CloudWatch Logs
  local policy_doc
  policy_doc=$(cat <<POLICYEOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TransactionSearchXRayAccess",
      "Effect": "Allow",
      "Principal": { "Service": "xray.amazonaws.com" },
      "Action": "logs:PutLogEvents",
      "Resource": [
        "arn:aws:logs:${AWS_REGION}:${account_id}:log-group:aws/spans:*",
        "arn:aws:logs:${AWS_REGION}:${account_id}:log-group:/aws/application-signals/data:*"
      ],
      "Condition": {
        "ArnLike": { "aws:SourceArn": "arn:aws:xray:${AWS_REGION}:${account_id}:*" },
        "StringEquals": { "aws:SourceAccount": "${account_id}" }
      }
    }
  ]
}
POLICYEOF
)

  aws logs put-resource-policy \
    --region "$AWS_REGION" \
    --policy-name AgentCoreTransactionSearch \
    --policy-document "$policy_doc" 2>/dev/null || true

  # Step 2: Enable Transaction Search
  aws xray update-trace-segment-destination \
    --region "$AWS_REGION" \
    --destination CloudWatchLogs 2>/dev/null || true

  # Step 3: Enable tracing for deployed resources
  _enable_resource_tracing "$runtime_arn" "runtime"
  _enable_resource_tracing "$gateway_arn" "gateway" "/aws/vendedlogs/bedrock-agentcore/gateway/${PROJECT_PREFIX}"
  _enable_resource_tracing "$memory_arn" "memory"

  info "Observability enabled — view at: https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#gen-ai-observability"

  # Save hash on success
  mkdir -p "$HASH_DIR"
  echo "$current_hash" > "$hash_file"
}

_enable_resource_tracing() {
  local resource_arn="$1"
  local resource_type="$2"
  local log_group_name="${3:-}"

  if [ -z "$resource_arn" ] || [ "$resource_arn" = "None" ] || [ "$resource_arn" = "" ]; then
    return 0
  fi

  local resource_id
  resource_id=$(echo "$resource_arn" | rev | cut -d'/' -f1 | rev)

  info "  Enabling tracing for $resource_type ($resource_id)..."

  # Traces → X-Ray
  aws logs put-delivery-source \
    --region "$AWS_REGION" \
    --name "${PROJECT_PREFIX}-${resource_type}-traces" \
    --log-type "TRACES" \
    --resource-arn "$resource_arn" 2>/dev/null || true

  aws logs put-delivery-destination \
    --region "$AWS_REGION" \
    --name "${PROJECT_PREFIX}-${resource_type}-traces-dest" \
    --delivery-destination-type "XRAY" 2>/dev/null || true

  local dest_arn
  dest_arn=$(aws logs describe-delivery-destinations \
    --region "$AWS_REGION" \
    --query "deliveryDestinations[?name=='${PROJECT_PREFIX}-${resource_type}-traces-dest'].arn" \
    --output text 2>/dev/null || echo "")

  if [ -n "$dest_arn" ] && [ "$dest_arn" != "None" ]; then
    aws logs create-delivery \
      --region "$AWS_REGION" \
      --delivery-source-name "${PROJECT_PREFIX}-${resource_type}-traces" \
      --delivery-destination-arn "$dest_arn" 2>/dev/null || true
  fi

  # APPLICATION_LOGS → CloudWatch Logs (for gateway/memory)
  if [ -n "$log_group_name" ]; then
    local log_group_arn="arn:aws:logs:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):log-group:${log_group_name}"

    aws logs create-log-group --region "$AWS_REGION" --log-group-name "$log_group_name" 2>/dev/null || true

    aws logs put-delivery-source \
      --region "$AWS_REGION" \
      --name "${PROJECT_PREFIX}-${resource_type}-logs" \
      --log-type "APPLICATION_LOGS" \
      --resource-arn "$resource_arn" 2>/dev/null || true

    aws logs put-delivery-destination \
      --region "$AWS_REGION" \
      --name "${PROJECT_PREFIX}-${resource_type}-logs-dest" \
      --delivery-destination-type "CWL" \
      --delivery-destination-configuration "destinationResourceArn=${log_group_arn}" 2>/dev/null || true

    local logs_dest_arn
    logs_dest_arn=$(aws logs describe-delivery-destinations \
      --region "$AWS_REGION" \
      --query "deliveryDestinations[?name=='${PROJECT_PREFIX}-${resource_type}-logs-dest'].arn" \
      --output text 2>/dev/null || echo "")

    if [ -n "$logs_dest_arn" ] && [ "$logs_dest_arn" != "None" ]; then
      aws logs create-delivery \
        --region "$AWS_REGION" \
        --delivery-source-name "${PROJECT_PREFIX}-${resource_type}-logs" \
        --delivery-destination-arn "$logs_dest_arn" 2>/dev/null || true
    fi
  fi
}
# ---------------------------------------------------------------------------
# Per-Agent Sync Helper — force update, sync env vars, sync endpoint version
# Replaces the old single-agent force_runtime_update, sync_runtime_env_vars,
# and sync_endpoint_version functions with a generalized per-agent helper.
# ---------------------------------------------------------------------------
_sync_agent() {
  local agent_name="$1"
  local runtime_id="$2"
  local endpoint_name="$3"

  if [ -z "$runtime_id" ]; then
    return
  fi

  local agent_changed
  agent_changed=$(get_agent_changed "$agent_name")

  # --- For unchanged non-frontend agents, skip the full sync ---
  # The frontend agent always runs the full sync so its runtime env vars
  # (registry table, gateway endpoint, memory ID — some known only after
  # apply) are guaranteed current. Other agents only need sync when their
  # image changed.
  if [ "$agent_changed" != "true" ] && [ "$agent_name" != "$FRONTEND_AGENT" ]; then
    info "${agent_name}: unchanged, skipping sync"
    return
  fi

  # --- Force update if image changed ---
  if [ "$agent_changed" = "true" ]; then
    info "Forcing ${agent_name} runtime to pull latest image..."
    .venv/bin/python -c "
import boto3
client = boto3.client('bedrock-agentcore-control', region_name='${AWS_REGION}')
rt = client.get_agent_runtime(agentRuntimeId='${runtime_id}')
kwargs = dict(
    agentRuntimeId='${runtime_id}',
    agentRuntimeArtifact=rt['agentRuntimeArtifact'],
    roleArn=rt['roleArn'],
    networkConfiguration=rt['networkConfiguration'],
    environmentVariables=rt.get('environmentVariables', {}),
)
if rt.get('authorizerConfiguration'):
    kwargs['authorizerConfiguration'] = rt['authorizerConfiguration']
# Preserve the protocol Terraform set (AGUI for the frontend, HTTP for
# others) — update_agent_runtime is not partial, so omitting it resets it.
if rt.get('protocolConfiguration'):
    kwargs['protocolConfiguration'] = rt['protocolConfiguration']
# Preserve the request-header allowlist Terraform set (Authorization forwarding
# on the supervisor) — same non-partial-update reason as protocol above.
if rt.get('requestHeaderConfiguration'):
    kwargs['requestHeaderConfiguration'] = rt['requestHeaderConfiguration']
resp = client.update_agent_runtime(**kwargs)
print(f'${agent_name} updated — version: {resp.get(\"agentRuntimeVersion\", \"unknown\")}')
" 2>&1 || warn "${agent_name} force update failed (non-fatal)"
  fi

  # --- Sync environment variables (read-modify-write) ---
  local registry_table
  registry_table=$(tf_output agent_registry_table_name)
  local gateway_endpoint
  gateway_endpoint=$(tf_output gateway_endpoint)
  local memory_id
  memory_id=$(tf_output agentcore_memory_id)

  # Determine if this is a mid-level agent (gets memory env var)
  local is_mid="false"
  for mid in $MID_LEVEL_AGENTS; do
    if [ "$mid" = "$agent_name" ]; then
      is_mid="true"
      break
    fi
  done

  # Determine domain for OTEL attributes
  local domain="$agent_name"
  if [ "$agent_name" = "$FRONTEND_AGENT" ]; then
    domain="$FRONTEND_AGENT"
  else
    local parent
    parent=$(get_agent_parent "$agent_name")
    if [ -z "$parent" ]; then
      parent="$FRONTEND_AGENT"
    fi
    if [ "$parent" = "$FRONTEND_AGENT" ]; then
      # Mid-level agent — domain is its own name without -agent suffix
      domain=$(echo "$agent_name" | sed 's/-agent$//')
    else
      # Leaf agent — domain is the parent's name without -agent suffix
      domain=$(echo "$parent" | sed 's/-agent$//')
    fi
  fi

  info "Syncing ${agent_name} runtime environment variables..."
  .venv/bin/python -c "
import boto3
client = boto3.client('bedrock-agentcore-control', region_name='${AWS_REGION}')
rt = client.get_agent_runtime(agentRuntimeId='${runtime_id}')
current_env = rt.get('environmentVariables', {})
# Merge: start with existing env vars, overlay desired values
desired_updates = {
    'AGENT_REGISTRY_TABLE': '${registry_table}',
    'AGENTCORE_GATEWAY_ENDPOINT': '${gateway_endpoint}',
    'AWS_REGION': '${AWS_REGION}',
    'AWS_DEFAULT_REGION': '${AWS_REGION}',
}
# Mid-level agents and frontend agent get memory ID
if '${is_mid}' == 'true' or '${agent_name}' == '${FRONTEND_AGENT}':
    desired_updates['AGENTCORE_MEMORY_ID'] = '${memory_id}'
merged_env = {**current_env, **desired_updates}
if current_env == merged_env:
    print('${agent_name} env vars already up to date')
else:
    kwargs = dict(
        agentRuntimeId='${runtime_id}',
        agentRuntimeArtifact=rt['agentRuntimeArtifact'],
        roleArn=rt['roleArn'],
        networkConfiguration=rt['networkConfiguration'],
        environmentVariables=merged_env,
    )
    if rt.get('authorizerConfiguration'):
        kwargs['authorizerConfiguration'] = rt['authorizerConfiguration']
    # Preserve the protocol Terraform set (AGUI for the frontend, HTTP for
    # others) — update_agent_runtime is not partial, so omitting it resets it.
    if rt.get('protocolConfiguration'):
        kwargs['protocolConfiguration'] = rt['protocolConfiguration']
    # Preserve the request-header allowlist Terraform set (Authorization
    # forwarding on the supervisor) — same non-partial-update reason.
    if rt.get('requestHeaderConfiguration'):
        kwargs['requestHeaderConfiguration'] = rt['requestHeaderConfiguration']
    client.update_agent_runtime(**kwargs)
    print('${agent_name} env vars updated')
" 2>&1 || warn "${agent_name} env var sync failed (non-fatal)"

  # --- Wait for READY ---
  info "Waiting for ${agent_name} runtime to be READY..."
  local max_wait=300
  local waited=0
  while [ $waited -lt $max_wait ]; do
    local status
    status=$(.venv/bin/python -c "
import boto3
client = boto3.client('bedrock-agentcore-control', region_name='${AWS_REGION}')
rt = client.get_agent_runtime(agentRuntimeId='${runtime_id}')
print(rt.get('status', 'UNKNOWN'))
" 2>/dev/null || echo "UNKNOWN")

    if [ "$status" = "READY" ]; then
      break
    elif [ "$status" = "FAILED" ]; then
      warn "${agent_name} runtime is in FAILED state"
      return
    fi
    sleep 10
    waited=$((waited + 10))
    info "  ${agent_name} status: $status (waited ${waited}s)"
  done

  if [ $waited -ge $max_wait ]; then
    warn "${agent_name} timed out waiting for READY (${max_wait}s)"
    return
  fi

  # --- Sync endpoint version ---
  local runtime_version endpoint_version
  runtime_version=$(.venv/bin/python -c "
import boto3
client = boto3.client('bedrock-agentcore-control', region_name='${AWS_REGION}')
rt = client.get_agent_runtime(agentRuntimeId='${runtime_id}')
print(rt.get('agentRuntimeVersion', ''))
" 2>/dev/null || echo "")

  endpoint_version=$(.venv/bin/python -c "
import boto3
client = boto3.client('bedrock-agentcore-control', region_name='${AWS_REGION}')
ep = client.get_agent_runtime_endpoint(agentRuntimeId='${runtime_id}', endpointName='${endpoint_name}')
print(ep.get('liveVersion', ''))
" 2>/dev/null || echo "")

  if [ -n "$runtime_version" ] && [ -n "$endpoint_version" ] && [ "$runtime_version" != "$endpoint_version" ]; then
    info "${agent_name} endpoint version ($endpoint_version) behind runtime ($runtime_version), updating..."
    .venv/bin/python -c "
import boto3
client = boto3.client('bedrock-agentcore-control', region_name='${AWS_REGION}')
client.update_agent_runtime_endpoint(
    agentRuntimeId='${runtime_id}',
    endpointName='${endpoint_name}',
    agentRuntimeVersion='${runtime_version}'
)
print('${agent_name} endpoint updated to version ${runtime_version}')
" 2>&1 || warn "${agent_name} endpoint update failed (non-fatal)"
  else
    info "${agent_name} endpoint version matches runtime"
  fi
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Registry Cleanup — remove stale entries not in hierarchy.json
# ---------------------------------------------------------------------------
sync_agent_registry() {
  local registry_table
  registry_table=$(tf_output agent_registry_table_name)
  if [ -z "$registry_table" ]; then
    return
  fi

  info "Reconciling agent registry with hierarchy.json..."
  .venv/bin/python -c "
import boto3, json
with open('src/agents/hierarchy.json') as f:
    hierarchy = json.load(f)
valid_agents = set(hierarchy.keys())
ddb = boto3.client('dynamodb', region_name='${AWS_REGION}')
resp = ddb.scan(TableName='${registry_table}', ProjectionExpression='agent_name')
stale = []
for item in resp.get('Items', []):
    name = item.get('agent_name', {}).get('S', '')
    if name and name not in valid_agents:
        stale.append(name)
if stale:
    for name in stale:
        ddb.delete_item(TableName='${registry_table}', Key={'agent_name': {'S': name}})
        print(f'  Removed stale registry entry: {name}')
    print(f'Cleaned {len(stale)} stale agent(s) from registry')
else:
    print('Agent registry is clean — no stale entries')
" 2>&1 || warn "Registry cleanup failed (non-fatal)"
}

# ---------------------------------------------------------------------------
# Post-Deploy Sync Loop — iterate over all deployed agents
# ---------------------------------------------------------------------------
# sync_runtime_log_retention — apply explicit retention to AgentCore's
# auto-created runtime log groups. AgentCore creates
# `/aws/bedrock-agentcore/runtimes/<runtime>-DEFAULT` and `-<endpoint>` groups
# at runtime with NO retention (infinite). Terraform never sees them (they're
# created by the service, not us), so they escape the retention set on the
# vended log groups. These groups hold agent prompts/responses — exactly the
# user data that must not accumulate indefinitely. Sweep them every deploy.
sync_runtime_log_retention() {
  local retention
  # Read the value Terraform actually applied (config.auto.tfvars.json →
  # var.log_retention_days), NOT the SSM cache captured at deploy startup.
  # `_SHARED_CFG` is imported from SSM once at the start of the run, but the
  # shared_config module re-writes SSM from the tfvar DURING apply — so the
  # cached SSM value can be stale by the time this sweep runs. The tfvars file
  # is the source of truth for the deploy that just happened.
  retention=$(shared_config_get_tfvars log_retention_days 2>/dev/null || echo "")
  [ -z "$retention" ] && retention=$(shared_config_get OBSERVABILITY_LOG_RETENTION_DAYS 30)
  # Guard against an empty/zero value sneaking in.
  case "$retention" in
    ''|0|*[!0-9]*) retention=30 ;;
  esac
  info "Applying ${retention}-day retention to AgentCore runtime log groups..."
  local prefix="/aws/bedrock-agentcore/runtimes/$(echo "${PROJECT_PREFIX}" | tr '-' '_')"
  # Target every group whose retention differs from the desired value — not
  # just null ones. A group with a stale non-null retention (e.g. from an
  # earlier policy) must also be corrected.
  local groups
  groups=$(aws logs describe-log-groups \
    --region "$AWS_REGION" \
    --log-group-name-prefix "$prefix" \
    --query "logGroups[?retentionInDays!=\`${retention}\`].logGroupName" \
    --output text 2>/dev/null | tr '\t' '\n' || echo "")
  local count=0
  for lg in $groups; do
    [ -z "$lg" ] && continue
    aws logs put-retention-policy \
      --region "$AWS_REGION" \
      --log-group-name "$lg" \
      --retention-in-days "$retention" 2>/dev/null && count=$((count + 1))
  done
  info "  set retention on ${count} runtime log group(s)"
}

post_deploy_sync() {
  # Clean up stale registry entries first (e.g. renamed/removed agents)
  sync_agent_registry
  # Frontend agent first (uses the agentcore_runtime module outputs)
  local fe_runtime_id fe_endpoint_name
  fe_runtime_id=$(tf_output agentcore_runtime_id)
  fe_endpoint_name=$(tf_output endpoint_name)
  _sync_agent "$FRONTEND_AGENT" "$fe_runtime_id" "$fe_endpoint_name"

  # Then all other agents — read from the map outputs
  local runtime_ids_json endpoint_names_json
  runtime_ids_json=$(terraform -chdir="$TERRAFORM_DIR" output -no-color -json agent_runtime_ids 2>/dev/null | sed '/^Warning:/d; /^│/d; /^╷/d; /^╵/d; /^The parameter/d; /instead\./d; /^$/d' || echo "{}")
  endpoint_names_json=$(terraform -chdir="$TERRAFORM_DIR" output -no-color -json agent_endpoint_names 2>/dev/null | sed '/^Warning:/d; /^│/d; /^╷/d; /^╵/d; /^The parameter/d; /instead\./d; /^$/d' || echo "{}")

  for agent in ${SELECTED_AGENTS[@]+"${SELECTED_AGENTS[@]}"}; do
    if [ "$agent" = "$FRONTEND_AGENT" ]; then
      continue
    fi
    local runtime_id endpoint_name
    runtime_id=$(echo "$runtime_ids_json" | .venv/bin/python -c "import json,sys; d=json.load(sys.stdin); print(d.get('$agent',''))" 2>/dev/null || echo "")
    endpoint_name=$(echo "$endpoint_names_json" | .venv/bin/python -c "import json,sys; d=json.load(sys.stdin); print(d.get('$agent',''))" 2>/dev/null || echo "")
    _sync_agent "$agent" "$runtime_id" "$endpoint_name"
  done

  # Apply retention to AgentCore's auto-created runtime log groups (not
  # Terraform-managed). Runs last so it picks up groups created by the
  # agents that just synced.
  sync_runtime_log_retention
}

deploy_frontend_to_s3() {
  local bucket
  bucket=$(tf_output frontend_bucket)
  local dist_id
  dist_id=$(tf_output cloudfront_distribution_id)

  if [ -z "$bucket" ]; then
    warn "Frontend bucket not found in Terraform outputs, skipping S3 sync"
    return
  fi

  # Always regenerate config.json (Terraform outputs may have changed)
  local supervisor_url
  supervisor_url=$(tf_output supervisor_url)
  if [ -z "$supervisor_url" ]; then
    supervisor_url="http://localhost:9000/invoke"
  fi
  local cognito_domain=""
  local cognito_client_id=""
  if [ "$IDP_TYPE" != "none" ]; then
    cognito_domain=$(tf_output cognito_domain)
    cognito_client_id=$(tf_output cognito_app_client_id)
  fi
  local cloudfront_url
  cloudfront_url=$(tf_output cloudfront_url)
  local frontend_api_url
  frontend_api_url=$(tf_output frontend_api_url)

  mkdir -p "$FRONTEND_DIR/out"
  cat > "$FRONTEND_DIR/out/config.json" <<CFGEOF
{
  "SUPERVISOR_URL": "${supervisor_url}",
  "AUTH_PROVIDER": "${IDP_TYPE}",
  "COGNITO_DOMAIN": "${cognito_domain}",
  "COGNITO_CLIENT_ID": "${cognito_client_id}",
  "APP_URL": "${cloudfront_url}",
  "FRONTEND_API_URL": "${frontend_api_url}"
}
CFGEOF

  info "Syncing frontend to s3://$bucket..."
  aws s3 sync "$FRONTEND_DIR/out" "s3://$bucket" --delete --region "$AWS_REGION"

  if [ -n "$dist_id" ]; then
    info "Invalidating CloudFront cache..."
    aws cloudfront create-invalidation --distribution-id "$dist_id" --paths "/*" > /dev/null
  fi

  info "Frontend deployed to $cloudfront_url"
}

# ---------------------------------------------------------------------------
# Sync Gateway Tool Schemas — update targets with multi-tool schemas from tools.json
# ---------------------------------------------------------------------------
sync_gateway_tools() {
  local gateway_id
  gateway_id=$(tf_output gateway_id)
  if [ -z "$gateway_id" ]; then
    warn "Gateway ID not found, skipping tool schema sync"
    return
  fi

  # Hash-based skip: only sync if tools.json changed
  local hash_file="${HASH_DIR}/gateway-tools.sha"
  local current_hash
  current_hash=$(shasum src/lambda/mcp/tools.json 2>/dev/null | cut -d' ' -f1 || echo "unknown")
  local stored_hash
  stored_hash=$(cat "$hash_file" 2>/dev/null || echo "")
  if [ "$current_hash" = "$stored_hash" ]; then
    info "Gateway tool schemas: unchanged, skipping sync"
    return
  fi

  info "Syncing gateway tool schemas..."
  if .venv/bin/python -c "
import boto3, json, sys

gateway_id = '${gateway_id}'
region = '${AWS_REGION}'
client = boto3.client('bedrock-agentcore-control', region_name=region)

def sanitize_schema(schema):
    \"\"\"Keep only JSON Schema fields supported by AgentCore gateway targets.\"\"\"
    if not isinstance(schema, dict):
        return {}

    sanitized = {}
    for key in ('type', 'description', 'required'):
        if key in schema:
            sanitized[key] = schema[key]

    properties = schema.get('properties')
    if isinstance(properties, dict):
        sanitized['properties'] = {
            name: sanitize_schema(value)
            for name, value in properties.items()
        }

    items = schema.get('items')
    if isinstance(items, dict):
        sanitized['items'] = sanitize_schema(items)

    return sanitized

# Load tools.json
with open('src/lambda/mcp/tools.json') as f:
    tools_config = json.load(f)

# Get existing targets. This has to page: the API returns a bounded page and
# boto3 does not follow nextToken on its own, so a single call silently drops
# the newest targets once the gateway holds more than one page of them — and a
# dropped target reads as 'not found', which fails the sync for a target that
# is actually present.
existing = {}
try:
    next_token = None
    while True:
        kwargs = {'gatewayIdentifier': gateway_id, 'maxResults': 100}
        if next_token:
            kwargs['nextToken'] = next_token
        resp = client.list_gateway_targets(**kwargs)
        for t in resp.get('items', []):
            existing[t['name']] = t['targetId']
        next_token = resp.get('nextToken')
        if not next_token:
            break
except Exception as e:
    print(f'Failed to list targets: {e}')
    sys.exit(1)

# For each tool config that has a 'tools' array, update the target
sync_failed = False
for target_name, config in tools_config.items():
    tool_schemas = config.get('tools', [])
    if not tool_schemas:
        continue  # No multi-tool schemas defined, skip

    target_id = existing.get(target_name)
    if not target_id:
        print(f'  {target_name}: target not found in gateway, skipping')
        sync_failed = True
        continue

    # Build inline tool schemas
    inline_tools = []
    for tool in tool_schemas:
        inline_tool = {
            'name': tool['name'],
            'description': tool.get('description', f'Tool: {tool[\"name\"]}'),
            'inputSchema': {'type': 'object'},
        }
        schema = tool.get('input_schema', {})
        if schema.get('properties'):
            inline_tool['inputSchema'] = sanitize_schema(schema)
        inline_tools.append(inline_tool)

    # Get current target to preserve Lambda ARN
    try:
        target = client.get_gateway_target(gatewayIdentifier=gateway_id, targetId=target_id)
        lambda_arn = target['targetConfiguration']['mcp']['lambda']['lambdaArn']

        # Update target with new tool schemas
        client.update_gateway_target(
            gatewayIdentifier=gateway_id,
            targetId=target_id,
            name=target_name,
            credentialProviderConfigurations=[{
                'credentialProviderType': 'GATEWAY_IAM_ROLE',
            }],
            targetConfiguration={
                'mcp': {
                    'lambda': {
                        'lambdaArn': lambda_arn,
                        'toolSchema': {
                            'inlinePayload': inline_tools,
                        },
                    },
                },
            },
        )
        print(f'  {target_name}: updated with {len(inline_tools)} tool schemas')
    except Exception as e:
        print(f'  {target_name}: update failed — {e}')
        sync_failed = True

if sync_failed:
    sys.exit(1)
" 2>&1; then
    echo "$current_hash" > "$hash_file"
  else
    warn "Gateway tool schema sync failed (non-fatal)"
    rm -f "$hash_file"
  fi
}

# ---------------------------------------------------------------------------
# AWS DevOps Agent MCP access — register the gateway as a SigV4 MCP server,
# allowlist the selected tools in an Agent Space, upload the matching skill.
#
# Opt-in via devops_agent_mcp_enabled. Terraform creates only the IAM role
# DevOps Agent assumes (agentcore-gateway module); the AWS provider has no
# DevOps Agent resources, so the rest runs here post-apply, like the schema
# sync above. Inputs come from the `devops_agent_mcp` Terraform output, which
# is null when the feature is off.
#
# Idempotent: an existing registration with the same name is reused when its
# endpoint/role match (replaced when they don't), the association is only
# rewritten when the tool list changed, and the skill upload is hash-skipped
# via .lambda-hashes/devops-agent-skill.sha. Every failure is a warning — a
# DevOps Agent problem must never fail the platform deploy.
#
# .lambda-hashes/devops-agent-mcp.json records what this workstation
# registered, so turning the feature off (or a destroy without Terraform
# outputs) can still deregister it.
# ---------------------------------------------------------------------------
_devops_agent_mcp_py() {
  # $1 = sync | cleanup, $2 = JSON config. Values reach Python through the
  # environment and a quoted heredoc, never by interpolation into code.
  DEVOPS_MCP_CONFIG="$2" \
  DEVOPS_MCP_TOOLS_JSON="src/lambda/mcp/tools.json" \
  DEVOPS_MCP_SKILLS_DIR="skills" \
  DEVOPS_MCP_SKILL_HASH_FILE="${HASH_DIR}/devops-agent-skill.sha" \
  DEVOPS_MCP_STATE_FILE="${HASH_DIR}/devops-agent-mcp.json" \
  .venv/bin/python - "$1" <<'PY'
import hashlib
import io
import json
import os
import re
import sys
import time
import zipfile

import boto3

MODE = sys.argv[1]
CFG = json.loads(os.environ["DEVOPS_MCP_CONFIG"])
SERVICE_TYPE = "mcpserversigv4"
SIGV4_SERVICE = "bedrock-agentcore"
# tools.json target -> skill folder under skills/ uploaded with its tools.
TARGET_SKILLS = {"lambda-runtime": "lambda-runtime-upgrade"}
# DevOps Agent skill zips carry SKILL.md plus these optional folders; a
# scripts/ folder is rejected by the service, so it is never packaged.
SKILL_DIRS = ("reference", "references", "assets")
MAX_SKILL_BYTES = 6 * 1024 * 1024


def say(message):
    print(f"  {message}", flush=True)


def paged(call, key, **kwargs):
    # boto3 does not follow nextToken for these operations; drain it.
    token = None
    while True:
        if token:
            kwargs["nextToken"] = token
        resp = call(**kwargs)
        yield from resp.get(key) or []
        token = resp.get("nextToken")
        if not token:
            return


def error_code(exc):
    return (getattr(exc, "response", None) or {}).get("Error", {}).get("Code", "")


try:
    client = boto3.client("devops-agent", region_name=CFG["space_region"])
except Exception as exc:  # e.g. botocore too old to know the service
    say(f"cannot create a devops-agent client ({exc}); run `make setup` to update boto3")
    sys.exit(1)


def find_services(name):
    found = []
    for svc in paged(client.list_services, "services", filterServiceType=SERVICE_TYPE):
        if svc.get("serviceType") != SERVICE_TYPE:
            continue
        details = (svc.get("additionalServiceDetails") or {}).get(SERVICE_TYPE) or {}
        if name in (svc.get("name"), details.get("name")):
            found.append((svc["serviceId"], details))
    return found


def associations_for(service_id):
    return [
        a
        for a in paged(
            client.list_associations,
            "associations",
            agentSpaceId=CFG["space_id"],
            filterServiceTypes=SERVICE_TYPE,
        )
        if a.get("serviceId") == service_id
    ]


def remove_service(service_id):
    for assoc in associations_for(service_id):
        client.disassociate_service(
            agentSpaceId=CFG["space_id"], associationId=assoc["associationId"]
        )
        say(f"disassociated {service_id} from Agent Space {CFG['space_id']}")
    client.deregister_service(serviceId=service_id)
    say(f"deregistered {service_id}")


def registration_matches(details):
    role = details.get("mcpRoleArn") or details.get("roleArn")
    return (
        details.get("endpoint") == CFG["gateway_endpoint"]
        and details.get("region") == CFG["gateway_region"]
        and details.get("service") == SIGV4_SERVICE
        and role == CFG["role_arn"]
    )


def register():
    name = CFG["service_name"]
    details = {
        "name": name,
        "endpoint": CFG["gateway_endpoint"],
        "description": f"CloudOps AgentCore gateway {name} (SigV4)",
        "authorizationConfig": {
            "region": CFG["gateway_region"],
            "service": SIGV4_SERVICE,
            # roleArn is deprecated in the DevOps Agent API; mcpRoleArn replaces it.
            "mcpRoleArn": CFG["role_arn"],
        },
    }
    # DevOps Agent assumes the role and calls tools/list while registering.
    # The role is seconds old after `terraform apply`, so give IAM time.
    delays = [
        int(d)
        for d in os.environ.get("DEVOPS_MCP_RETRY_DELAYS", "15,30,45").split(",")
        if d.strip()
    ]
    for attempt in range(len(delays) + 1):
        try:
            return client.register_service(
                service=SERVICE_TYPE, name=name, serviceDetails={SERVICE_TYPE: details}
            )
        except Exception as exc:
            retriable = error_code(exc) in (
                "ValidationException",
                "InvalidParameterException",
                "AccessDeniedException",
            ) and re.search(r"sts|role|assume", str(exc), re.I)
            if not retriable or attempt == len(delays):
                raise
            say(f"registration not ready yet ({error_code(exc)}), retrying in {delays[attempt]}s")
            time.sleep(delays[attempt])


def wanted_tool_names():
    with open(os.environ["DEVOPS_MCP_TOOLS_JSON"]) as handle:
        tools_cfg = json.load(handle)
    for target in CFG.get("missing_tools") or []:
        say(f"{target}: not deployed on this gateway, not exposed (include it in DEPLOY_TOOLS)")
    names, targets = [], []
    for target in CFG.get("tools") or []:
        schemas = (tools_cfg.get(target) or {}).get("tools") or []
        if not schemas:
            say(f"{target}: no tool schemas in tools.json, skipping")
            continue
        targets.append(target)
        # The gateway exposes each tool as <target>___<tool name>.
        names.extend(f"{target}___{tool['name']}" for tool in schemas)
    return targets, names


def skill_bundle(folder):
    root = os.path.join(os.environ["DEVOPS_MCP_SKILLS_DIR"], folder)
    skill_md = os.path.join(root, "SKILL.md")
    with open(skill_md) as handle:
        match = re.search(r"^name:\s*[\"']?([a-z0-9-]+)", handle.read(), re.M)
    if not match:
        raise ValueError(f"{skill_md} has no frontmatter name")
    files = [("SKILL.md", skill_md)]
    for sub in SKILL_DIRS:
        for dirpath, dirnames, filenames in os.walk(os.path.join(root, sub)):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d != "__pycache__")
            for fname in sorted(filenames):
                if not fname.startswith("."):
                    full = os.path.join(dirpath, fname)
                    files.append((os.path.relpath(full, root).replace(os.sep, "/"), full))
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as archive:
        for rel, full in sorted(files):
            # Fixed timestamp + mode keep the zip, and so its hash, reproducible.
            info = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with open(full, "rb") as handle:
                archive.writestr(info, handle.read())
    data = buf.getvalue()
    if len(data) > MAX_SKILL_BYTES:
        raise ValueError(f"{folder} skill zip is {len(data)} bytes, over the 6 MB limit")
    return match.group(1), data


def sync_skills(targets):
    bundles = [skill_bundle(TARGET_SKILLS[t]) for t in targets if t in TARGET_SKILLS]
    if not bundles:
        return
    digest = hashlib.sha256(CFG["space_id"].encode())
    for name, data in bundles:
        digest.update(name.encode() + b"\0" + data)
    current = digest.hexdigest()
    hash_file = os.environ["DEVOPS_MCP_SKILL_HASH_FILE"]
    try:
        with open(hash_file) as handle:
            if handle.read().strip() == current:
                say("skills unchanged, skipping upload")
                return
    except FileNotFoundError:
        pass
    existing = {
        (asset.get("metadata") or {}).get("name"): asset["assetId"]
        for asset in paged(
            client.list_assets, "items", agentSpaceId=CFG["space_id"], assetType="skill"
        )
    }
    for name, data in bundles:
        token = f"{name}-{hashlib.sha256(data).hexdigest()[:40]}"
        content = {"zip": {"zipFile": data}}
        if name in existing:
            # No metadata: PATCH semantics keep the status and agent types a
            # user may have changed in the Agent Space.
            client.update_asset(
                agentSpaceId=CFG["space_id"], assetId=existing[name], content=content, clientToken=token
            )
            say(f"skill {name}: updated")
        else:
            client.create_asset(
                agentSpaceId=CFG["space_id"],
                assetType="skill",
                # name/description come from the SKILL.md frontmatter for zips.
                metadata={"agent_types": ["GENERIC"]},
                content=content,
                clientToken=token,
            )
            say(f"skill {name}: created")
    with open(hash_file, "w") as handle:
        handle.write(current + "\n")


def write_state():
    state = {k: CFG[k] for k in ("service_name", "space_id", "space_region")}
    with open(os.environ["DEVOPS_MCP_STATE_FILE"], "w") as handle:
        json.dump(state, handle, sort_keys=True)


def sync():
    targets, names = wanted_tool_names()
    if not names:
        say("no tools to expose; nothing registered")
        return 1

    service_id = None
    found = find_services(CFG["service_name"])
    for candidate, details in found:
        if service_id is None and registration_matches(details):
            service_id = candidate
            say(f"registration {CFG['service_name']}: unchanged ({candidate})")
        elif service_id is None:
            say(f"registration {candidate}: endpoint or role changed, replacing")
            remove_service(candidate)
        else:
            say(f"registration {candidate}: duplicate name, removing")
            remove_service(candidate)
    if service_id is None:
        resp = register()
        service_id = resp["serviceId"]
        say(f"registration {CFG['service_name']}: created ({service_id})")
        step = resp.get("additionalStep")
        if step:
            write_state()
            say(f"ACTION REQUIRED to finish registration: {json.dumps(step)}")
            say("re-run `make deploy-auto` afterwards to attach the tools")
            return 0
    write_state()

    assoc = associations_for(service_id)
    current = None
    if assoc:
        current = ((assoc[0].get("configuration") or {}).get(SERVICE_TYPE) or {}).get("tools")
    if current is not None and sorted(current) == sorted(names):
        say(f"association: unchanged ({len(names)} tools)")
    else:
        # AssociateService overwrites any existing association of this service.
        client.associate_service(
            agentSpaceId=CFG["space_id"],
            serviceId=service_id,
            configuration={SERVICE_TYPE: {"tools": names}},
        )
        say(f"association: {len(names)} tools allowed in Agent Space {CFG['space_id']}")

    sync_skills(targets)
    return 0


def cleanup():
    found = find_services(CFG["service_name"])
    if not found:
        say(f"no DevOps Agent registration named {CFG['service_name']}")
        return 0
    for service_id, _ in found:
        remove_service(service_id)
    say("uploaded skills are left in the Agent Space (they may have been edited there)")
    return 0


try:
    sys.exit(sync() if MODE == "sync" else cleanup())
except Exception as exc:
    say(f"DevOps Agent {MODE} failed: {error_code(exc) or type(exc).__name__}: {exc}")
    sys.exit(1)
PY
}

sync_devops_agent_mcp() {
  local state_file="${HASH_DIR}/devops-agent-mcp.json"
  local skill_hash_file="${HASH_DIR}/devops-agent-skill.sha"
  local config
  config=$(tf_output_json devops_agent_mcp)

  if [ -z "$config" ]; then
    # Feature off. If this workstation registered the gateway earlier, the
    # apply that just ran removed the role DevOps Agent assumes, so remove the
    # registration too instead of leaving it pointing at a deleted role.
    if [ -f "$state_file" ]; then
      info "DevOps Agent MCP access is off; removing the earlier registration..."
      if _devops_agent_mcp_py cleanup "$(cat "$state_file")" 2>&1; then
        rm -f "$state_file" "$skill_hash_file"
      else
        warn "DevOps Agent MCP cleanup failed (non-fatal)"
      fi
    fi
    return 0
  fi

  mkdir -p "$HASH_DIR"
  info "Syncing gateway tools to AWS DevOps Agent..."
  if ! _devops_agent_mcp_py sync "$config" 2>&1; then
    warn "DevOps Agent MCP sync failed (non-fatal)"
    rm -f "$skill_hash_file"
  fi
}
