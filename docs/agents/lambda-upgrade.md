# Lambda Runtime Upgrade Agent

Discovers Lambda functions running on deprecated or end-of-life runtimes,
analyzes their source code for compatibility issues with newer runtimes,
and provides step-by-step migration guidance with concrete code changes.

**Representative prompts:**
- "Which of my Lambda functions are on deprecated runtimes?"
- "Analyze my-function for upgrading from Python 3.8 to 3.12"
- "Generate a runtime upgrade report"
- "How do I migrate my Node.js 16 Lambda to Node.js 20?"

## User Interaction Flow

The agent follows a **region-selection-first** workflow. For full reports it
prefers the one-shot `generate_upgrade_analysis` tool, which runs steps 3-5
server-side in a single call. Steps 1-2 still happen first, so the user picks the regions.

1. **Region Discovery** — Scans all enabled AWS regions in parallel to find
   which have Lambda functions and how many are deprecated/EOL.
2. **Region Selection** — Presents a summary table and asks the user which
   regions to include in the report.
3. **Multi-Region Scan** — Scans selected regions in parallel for deprecated
   functions using `get_deprecated_functions_multi_region`.
4. **Code Analysis** — Downloads code for the top 5 CRITICAL/HIGH priority
   functions only (speed optimization).
5. **Report Generation** — Produces a structured report with executive summary,
   region inventory, code analysis, and migration playbook.

**Target report generation time: 5-10 minutes** (achieved via parallel region
scanning, selective code download, and knowledge-base-driven guidance for
lower-priority functions).

## Supported runtimes

| Family | Versions tracked | Key migration concerns |
|--------|-----------------|----------------------|
| Python | 3.8 → 3.13 | Removed stdlib modules (3.12), boto3 bundling |
| Node.js | 14.x → 22.x | AWS SDK v2→v3, CommonJS→ESM, OpenSSL 3.0 |
| Java | 8 → 21 | JPMS modules, javax.* removal, SDK v1→v2 |
| .NET | 6 → 8 | AOT compilation, System.Text.Json changes |
| Ruby | 3.2 → 3.3 | Minimal breaking changes |
| Custom | provided.al2 → al2023 | glibc 2.34+, OpenSSL 3.0, recompile natives |

## Tools (8)

| Tool | Purpose | Performance |
|------|---------|-------------|
| `generate_upgrade_analysis` | One-shot: discover/scan regions in parallel, enrich with effort bucket + idle days, download code for the top functions, run breaking-change detection, return a pre-analyzed dataset + `report_markdown` | Single call; replaces the multi-tool chain |
| `discover_lambda_regions` | Find all regions with Lambda functions | ~15-30s (parallel scan) |
| `list_functions_by_runtime` | List functions filtered by runtime/region | ~5-10s per region |
| `get_function_configuration` | Detailed function config | ~1-2s per function |
| `get_function_code` | Download source for analysis | ~3-10s per function |
| `get_runtime_support_status` | All runtimes with dates | Instant (static data) |
| `get_deprecated_functions` | Deprecated functions in one region | ~5-10s per region |
| `get_deprecated_functions_multi_region` | Deprecated functions across regions (parallel) | ~15-30s total |

## Deploy modes

In every mode the same read-only tool Lambda (`src/lambda/mcp/lambda-runtime/`) does
the work behind the platform's AgentCore Gateway (MCP, `AWS_IAM` auth). The modes
differ in what calls it.

| Mode | What you deploy | How |
|------|-----------------|-----|
| **1. Platform** | Full stack. `lambda-upgrade-agent` is a worker under `ops-excellence-agent`. | `make deploy-auto` |
| **2. Gateway only** | Gateway + tool Lambda, for Kiro, Claude Code or another MCP client | `DEPLOY_MODE=gateway-only DEPLOY_TOOLS=lambda-runtime make deploy-auto` with a fresh `PROJECT_PREFIX` |
| **3. AWS DevOps Agent** | Mode 1 or 2 with `DEVOPS_AGENT_MCP_ENABLED=true`: the deploy registers the gateway in DevOps Agent, allowlists the tools and uploads the skill | [Use with AWS DevOps Agent](#use-with-aws-devops-agent) |

In Mode 3, the skill matters as much as the tools. DevOps Agent has no shell,
so it can't open the presigned URL `lambda:GetFunction` returns. The skill tells it
to read source from the tool response's `source_files` instead, and to say so when the
tools aren't in its tool list. The skill ships with
`reference/runtime-migration-kb.md`, which it checks deprecation dates and
breaking changes against.

## Prerequisites

No special setup beyond the deploy itself. The tool Lambda's role needs:
- `lambda:ListFunctions`: enumerate functions
- `lambda:GetFunction`: download the deployment package
- `lambda:GetFunctionConfiguration`: read runtime/layer/handler config
- `ec2:DescribeRegions`: discover enabled regions
- `cloudwatch:GetMetricData`: days since last invocation (deletion-candidate detection)

For cross-account scanning, create a role with the permissions above in the target
account, then set `CROSS_ACCOUNT_ROLE_ARN` via `make configure`.

## Speed Optimizations

The agent targets 5-10 minute report generation through:

1. **Parallel region discovery** — All regions scanned concurrently (10 threads)
2. **Multi-region deprecated scan** — Single tool call scans all selected regions in parallel
3. **Selective code analysis** — Only top 5 CRITICAL/HIGH functions get code downloaded
4. **Knowledge-base guidance** — MEDIUM/LOW functions get migration advice from the
   embedded runtime knowledge base without code download
5. **Reduced report sections** — 3 sections (down from 5) with only one dependency chain

## Data model

### Tool: `discover_lambda_regions`

```json
{
  "regions_with_functions": [
    {
      "region": "us-east-1",
      "total_functions": 45,
      "deprecated_count": 8,
      "eol_count": 3,
      "needs_attention": 11,
      "runtimes": {"python3.8": 3, "nodejs16.x": 5, "python3.12": 37}
    }
  ],
  "total_regions": 5,
  "total_functions": 120,
  "total_deprecated": 15,
  "total_eol": 5,
  "total_needing_attention": 20
}
```

### Tool: `get_deprecated_functions_multi_region`

```json
{
  "results_by_region": [
    {
      "region": "us-east-1",
      "functions": [
        {
          "function_name": "my-api-handler",
          "runtime": "python3.8",
          "runtime_status": "end_of_life",
          "upgrade_target": "python3.12",
          "handler": "handler.lambda_handler",
          "last_modified": "2024-03-15T10:30:00Z",
          "code_size_bytes": 45000
        }
      ],
      "count": 8
    }
  ],
  "total_functions": 15,
  "regions_scanned": 3,
  "by_runtime": {
    "python3.8": {"count": 5, "status": "end_of_life", "upgrade_target": "python3.12"},
    "nodejs16.x": {"count": 10, "status": "deprecated", "upgrade_target": "nodejs20.x"}
  },
  "by_priority": {"end_of_life": 5, "deprecated": 10, "approaching": 0}
}
```

## Known gotchas

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `discover_lambda_regions` slow | Many enabled regions with functions | Normal — scanning 15+ regions takes ~30s |
| `get_function_code` returns empty files | Function uses container image packaging (`PackageType: Image`) | Container images can't be downloaded via GetFunction. Check `package_type` in config first. |
| Code extraction hits size limit | Large deployment package with bundled deps | Use `include_patterns` param to target specific files, or increase `max_file_size_kb`. |
| Cross-account functions not listed | Missing IAM permissions in target account | Ensure the cross-account role has `lambda:ListFunctions` + `lambda:GetFunction` + `ec2:DescribeRegions`. |
| Runtime shows "unknown" | New runtime not yet in the support data table | Update `RUNTIME_SUPPORT_DATA` in the handler. |
| DevOps Agent says it can't download or unzip source | MCP tools not allowlisted in the Agent Space, or the skill isn't loaded | See [DevOps Agent troubleshooting](#devops-agent-troubleshooting). |
| Report takes >10 min | Too many CRITICAL/HIGH functions triggering code download | The agent limits to top 5; if you have more, run a second pass. |

## Use with AWS DevOps Agent

AWS DevOps Agent can call the `lambda-runtime` tools on the platform's own
AgentCore Gateway and load the `lambda-runtime-upgrade` skill. One flag turns
it on, and the normal `make` flow does the rest:

```
AWS DevOps Agent (Agent Space)
  ├── skill: lambda-runtime-upgrade         uploaded from skills/lambda-runtime-upgrade/
  └── MCP:   <project>-<env>-gateway        8 lambda-runtime___* tools allowlisted
        │  SigV4, assumes <project>-devops-agent-gateway-invoke
        ▼
AgentCore Gateway (AWS_IAM) ──▶ lambda-runtime tool Lambda (read-only)
```

DevOps Agent has no shell, so it can't open the presigned URL that
`lambda:GetFunction` returns or unzip a deployment package. The tool Lambda
does that server-side and returns source as text, and the skill keeps the
agent on that path.

### What `make deploy-auto` does when it's enabled

| Step | Where | Result |
|------|-------|--------|
| IAM role | Terraform, `modules/core/agentcore-gateway` | `<project>-devops-agent-gateway-invoke`, trusted by `aidevops.amazonaws.com` with `aws:SourceAccount` = the deploy account, allowed only `bedrock-agentcore:InvokeGateway` on this gateway. Output: `devops_agent_gateway_role_arn`. |
| Registration | post-apply, `sync_devops_agent_mcp` in `scripts/lib/sync.sh` | Gateway registered as a SigV4 MCP server named `<project>-<env>-gateway` (service `bedrock-agentcore`). Reused on later deploys; replaced if the endpoint or role changes. |
| Tool allowlist | same | Every tool of every target in `DEVOPS_AGENT_MCP_TOOLS` that is deployed on the gateway, as `<target>___<tool>`, associated with the Agent Space. Rewritten only when the list changes. |
| Skill | same | `skills/lambda-runtime-upgrade/` (`SKILL.md` + `reference/`) uploaded as a `skill` asset for all agent types. Skipped while `.lambda-hashes/devops-agent-skill.sha` matches. |

The AWS Terraform provider has no DevOps Agent resources, so registration
runs after apply, the same way gateway tool schemas are synced. A DevOps
Agent failure prints a warning and never fails the deploy; the next deploy
retries. `make destroy` and `make destroy-all` disassociate and deregister
the gateway before Terraform removes the role. Turning the flag off and
redeploying does the same. The uploaded skill stays in the Agent Space in
both cases, because it may have been edited there.

Settings (shared keys, stored in SSM like the other `DEVOPS_AGENT_*` keys):

| Key | Default | Meaning |
|-----|---------|---------|
| `DEVOPS_AGENT_MCP_ENABLED` | `false` | Create the role and run the sync. Requires `GATEWAY_AUTH=iam`. |
| `DEVOPS_AGENT_MCP_TOOLS` | `lambda-runtime` | Comma-separated `tools.json` target keys to allowlist. |
| `DEVOPS_AGENT_SPACE_ID` | (none) | Agent Space to attach to. Required when enabled. Shared with the investigation integration. |
| `DEVOPS_AGENT_SPACE_REGION` | platform Region | Region of the Agent Space. |

The Agent Space must be in the deploy account. The person deploying needs
DevOps Agent permissions (`aidevops:ListServices`, `RegisterService`,
`DeregisterService`, `ListAssociations`, `AssociateService`,
`DisassociateService`, `ListAssets`, `CreateAsset`, `UpdateAsset`) and
`iam:PassRole` on the invoke role, on top of the usual deploy permissions.

### Path 1: the platform is already deployed

```bash
make reconfigure-shared   # "Expose gateway tools to DevOps Agent?" → y, Agent Space ID, tools
make deploy-auto
```

The gateway keeps all its other targets. Only the targets in
`DEVOPS_AGENT_MCP_TOOLS` are allowlisted for DevOps Agent.

### Path 2: no platform, just the gateway and this tool

Use a fresh `PROJECT_PREFIX` in `.env`, then:

```bash
make setup
make configure            # Expose gateway tools to DevOps Agent? → y, Agent Space ID
DEPLOY_MODE=gateway-only DEPLOY_TOOLS=lambda-runtime make deploy-auto
```

To skip `make configure`, pass the keys per invocation instead:
`DEVOPS_AGENT_MCP_ENABLED=true DEVOPS_AGENT_SPACE_ID=<space-id>` before the
same command. Per-invocation values are not saved to `config.auto.tfvars.json`,
so pass them on every deploy, or the next deploy turns the feature off again.

> **Warning: don't run `DEPLOY_TOOLS=<subset>` against an existing stack with
> the same prefix.** Terraform deploys exactly the listed tools, so it destroys
> every other tool Lambda (and tables such as the health-events table) in that
> stack. Path 2 needs its own `PROJECT_PREFIX`.

### Verify

```bash
aws devops-agent list-services --region <space-region> \
  --filter-service-type mcpserversigv4        # shows <project>-<env>-gateway
aws devops-agent list-assets --region <space-region> \
  --agent-space-id <space-id> --asset-type skill   # shows lambda-runtime-upgrade
```

Then ask DevOps Agent in the Agent Space: "Find Lambda functions on deprecated
runtimes in us-east-1 and generate a migration report." It should call
`lambda-runtime___generate_upgrade_analysis` and answer with real function
data. If it talks about shells, `curl`, `unzip` or presigned URLs, the tools
aren't in its tool list: check `list-associations` for the Agent Space.

### Console fallback

If you can't run the sync (for example, no DevOps Agent permissions for the
deployer), deploy with the flag on to get the role, then in the DevOps Agent
console:

1. **Capability Providers → MCP Server → Register**. Endpoint: `terraform output -raw gateway_endpoint`. Authorization: **AWS SigV4**, role `terraform output -raw devops_agent_gateway_role_arn`, Region = gateway Region, service `bedrock-agentcore`.
2. **Agent Space → Capabilities → MCP Servers → Add**, select the server, allow the `lambda-runtime___*` tools.
3. **Knowledge → Skills → Upload skill**: a zip of `skills/lambda-runtime-upgrade/` (`SKILL.md` + `reference/`).

The sync deregisters only registrations it can find by its own name, so give
a manual registration the name `<project>-<env>-gateway` if you want
`make destroy` to clean it up.

### DevOps Agent troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Invalid STS role configuration for session sigv4McpServerSession` | IAM propagation right after the role was created, or the Agent Space is in another account | The sync retries for about 90 s. If it still fails, check the Agent Space is in the deploy account and redeploy. |
| `DevOps Agent MCP sync failed (non-fatal)` with `AccessDeniedException` | Deployer lacks `aidevops:*` permissions or `iam:PassRole` on the invoke role | Add the permissions listed above, then `make deploy-auto`. |
| `cannot create a devops-agent client` | boto3 in `.venv` predates the DevOps Agent API | `make setup` to update dependencies. |
| `<target>: not deployed on this gateway` | A target in `DEVOPS_AGENT_MCP_TOOLS` isn't in this deploy's tool selection | Add it to `DEPLOY_TOOLS` or remove it from `DEVOPS_AGENT_MCP_TOOLS`. |
| Terraform: `devops_agent_mcp_enabled requires gateway_auth = "iam"` | The gateway uses the OAuth authorizer, which rejects SigV4 | Use `GATEWAY_AUTH=iam` for this stack. |
| Skill changes don't show up | Upload skipped by hash | `rm .lambda-hashes/devops-agent-skill.sha` and redeploy. |
