#!/usr/bin/env bash
# Verify sync_devops_agent_mcp / cleanup_devops_agent_mcp against a stub boto3.
#
# The sync registers the gateway as a SigV4 MCP server in AWS DevOps Agent,
# allowlists the gateway's tools in an Agent Space, and uploads the matching
# skill. It must be idempotent across deploys, page every list call (boto3 does
# not follow nextToken), never fail the deploy, and clean up on disable/destroy.
#
# boto3 is replaced by a stub that keeps DevOps Agent state in a JSON file and
# logs every call, so behaviour is asserted without touching AWS. The real
# tools.json and skills/lambda-runtime-upgrade are used, so the allowlist and
# skill zip are checked against what actually ships.
#
# Run from project root:
#   bash tests/scripts/test_sync_devops_agent_mcp.sh
set -u
TESTS_RUN=0
TESTS_FAILED=0
assert_eq() {
  local actual="$1" expected="$2" name="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$actual" = "$expected" ]; then
    printf "  PASS  %s\n" "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "  FAIL  %s\n        expected: %q\n        actual:   %q\n" \
      "$name" "$expected" "$actual"
  fi
}
assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    printf "  PASS  %s\n" "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "  FAIL  %s\n        expected to contain: %q\n        actual: %q\n" \
      "$name" "$needle" "$haystack"
  fi
}
assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "  FAIL  %s\n        expected NOT to contain: %q\n        actual: %q\n" \
      "$name" "$needle" "$haystack"
  else
    printf "  PASS  %s\n" "$name"
  fi
}
assert_file() {
  local path="$1" want="$2" name="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if { [ "$want" = present ] && [ -f "$path" ]; } || { [ "$want" = absent ] && [ ! -f "$path" ]; }; then
    printf "  PASS  %s\n" "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "  FAIL  %s (expected %s: %s)\n" "$name" "$want" "$path"
  fi
}
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
REPO="$SANDBOX/repo"
mkdir -p "$REPO/scripts/lib" "$REPO/.venv/bin" "$REPO/src/lambda/mcp" \
  "$REPO/.lambda-hashes" "$REPO/fakelib" "$REPO/skills"
cp "$PROJECT_ROOT/scripts/lib"/{common,sync,teardown}.sh "$REPO/scripts/lib/"
cp "$PROJECT_ROOT/src/lambda/mcp/tools.json" "$REPO/src/lambda/mcp/"
cp -R "$PROJECT_ROOT/skills/lambda-runtime-upgrade" "$REPO/skills/"
ln -sf "$PROJECT_ROOT/.venv/bin/python" "$REPO/.venv/bin/python"

# --- boto3 stub -------------------------------------------------------------
# State: $FAKE_STATE ({"services": [...], "associations": [...], "assets": [...]}).
# Every list call serves one item per page with a nextToken, so a caller that
# ignores the token sees only the first item. $FAKE_FAIL names one operation
# to raise; $FAKE_FLAKY_REGISTER makes register_service fail once with an STS
# validation error (IAM propagation). Calls are logged to $FAKE_CALL_LOG.
cat > "$REPO/fakelib/boto3.py" <<'PYEOF'
"""boto3 stand-in for sync_devops_agent_mcp tests (devops-agent client only)."""
import base64
import io
import json
import os
import zipfile


class FakeError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.response = {"Error": {"Code": code, "Message": message}}


def _load():
    with open(os.environ["FAKE_STATE"]) as handle:
        return json.load(handle)


def _save(state):
    with open(os.environ["FAKE_STATE"], "w") as handle:
        json.dump(state, handle)


def _log(call, **payload):
    with open(os.environ["FAKE_CALL_LOG"], "a") as handle:
        handle.write(json.dumps({"call": call, **payload}, sort_keys=True) + "\n")


def _page(items, kwargs, key):
    index = int(kwargs.get("nextToken") or 0)
    resp = {key: items[index:index + 1]}
    if index + 1 < len(items):
        resp["nextToken"] = str(index + 1)
    return resp


class _Client:
    def __init__(self, service, region):
        _log("client", service=service, region=region)

    def _maybe_fail(self, op):
        if os.environ.get("FAKE_FAIL") == op:
            raise FakeError("InternalServerException", f"injected {op} failure")

    def list_services(self, **kwargs):
        _log("list_services", nextToken=kwargs.get("nextToken"), filter=kwargs.get("filterServiceType"))
        return _page(_load()["services"], kwargs, "services")

    def register_service(self, **kwargs):
        self._maybe_fail("register_service")
        flaky = os.environ.get("FAKE_FLAKY_REGISTER")
        if flaky and not os.path.exists(flaky):
            open(flaky, "w").close()
            _log("register_service_rejected")
            raise FakeError("ValidationException", "Invalid STS role configuration for session sigv4McpServerSession")
        details = kwargs["serviceDetails"]["mcpserversigv4"]
        auth = details["authorizationConfig"]
        _log("register_service", service=kwargs["service"], name=kwargs.get("name"),
             details_name=details["name"], endpoint=details["endpoint"],
             region=auth["region"], sigv4_service=auth["service"],
             mcpRoleArn=auth.get("mcpRoleArn"), roleArn=auth.get("roleArn"))
        state = _load()
        sid = "svc-%d" % (len(state["services"]) + 100)
        state["services"].append({
            "serviceId": sid, "serviceType": "mcpserversigv4", "name": kwargs.get("name"),
            "additionalServiceDetails": {"mcpserversigv4": {
                "name": details["name"], "endpoint": details["endpoint"],
                "region": auth["region"], "service": auth["service"],
                "roleArn": auth.get("mcpRoleArn"), "mcpRoleArn": auth.get("mcpRoleArn"),
            }},
        })
        _save(state)
        return {"serviceId": sid}

    def deregister_service(self, **kwargs):
        _log("deregister_service", serviceId=kwargs["serviceId"])
        state = _load()
        state["services"] = [s for s in state["services"] if s["serviceId"] != kwargs["serviceId"]]
        _save(state)
        return {}

    def list_associations(self, **kwargs):
        _log("list_associations", nextToken=kwargs.get("nextToken"), agentSpaceId=kwargs["agentSpaceId"])
        items = [a for a in _load()["associations"] if a["agentSpaceId"] == kwargs["agentSpaceId"]]
        return _page(items, kwargs, "associations")

    def associate_service(self, **kwargs):
        self._maybe_fail("associate_service")
        tools = kwargs["configuration"]["mcpserversigv4"]["tools"]
        _log("associate_service", serviceId=kwargs["serviceId"], agentSpaceId=kwargs["agentSpaceId"], tools=tools)
        state = _load()
        state["associations"] = [a for a in state["associations"]
                                 if not (a["serviceId"] == kwargs["serviceId"] and a["agentSpaceId"] == kwargs["agentSpaceId"])]
        state["associations"].append({
            "associationId": "assoc-" + kwargs["serviceId"], "agentSpaceId": kwargs["agentSpaceId"],
            "serviceId": kwargs["serviceId"], "configuration": {"mcpserversigv4": {"tools": tools}},
        })
        _save(state)
        return {"association": state["associations"][-1]}

    def disassociate_service(self, **kwargs):
        _log("disassociate_service", associationId=kwargs["associationId"])
        state = _load()
        state["associations"] = [a for a in state["associations"] if a["associationId"] != kwargs["associationId"]]
        _save(state)
        return {}

    def list_assets(self, **kwargs):
        _log("list_assets", nextToken=kwargs.get("nextToken"), assetType=kwargs.get("assetType"))
        return _page(_load()["assets"], kwargs, "items")

    def _zip_names(self, content):
        data = content["zip"]["zipFile"]
        return sorted(zipfile.ZipFile(io.BytesIO(data)).namelist())

    def create_asset(self, **kwargs):
        _log("create_asset", assetType=kwargs["assetType"], metadata=kwargs.get("metadata"),
             files=self._zip_names(kwargs["content"]), clientToken=kwargs.get("clientToken"))
        state = _load()
        state["assets"].append({"assetId": "ki-%d" % len(state["assets"]), "assetType": "skill",
                                "metadata": {"name": "lambda-runtime-upgrade"}})
        _save(state)
        return {"asset": state["assets"][-1]}

    def update_asset(self, **kwargs):
        _log("update_asset", assetId=kwargs["assetId"], has_metadata="metadata" in kwargs,
             files=self._zip_names(kwargs["content"]))
        return {"asset": {"assetId": kwargs["assetId"]}}


def client(service, region_name=None, **_kwargs):
    return _Client(service, region_name)
PYEOF

cd "$REPO"
export HASH_DIR=".lambda-hashes"
export TERRAFORM_DIR="terraform"
export PYTHONPATH="$REPO/fakelib"
export FAKE_CALL_LOG="$SANDBOX/calls.jsonl"
export FAKE_STATE="$SANDBOX/state.json"
export DEVOPS_MCP_RETRY_DELAYS="0"
# shellcheck disable=SC1091
source scripts/lib/common.sh
# shellcheck disable=SC1091
source scripts/lib/sync.sh
# shellcheck disable=SC1091
source scripts/lib/teardown.sh

ENDPOINT="https://gw-test.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp"
ROLE="arn:aws:iam::111122223333:role/cops-devops-agent-gateway-invoke"
config_json() {  # $1 = endpoint
  printf '{"gateway_endpoint":"%s","gateway_region":"us-east-1","missing_tools":%s,"role_arn":"%s","service_name":"cops-dev-gateway","space_id":"space-test","space_region":"us-east-1","tools":["lambda-runtime"]}' \
    "$1" "${MISSING_TOOLS:-[]}" "$ROLE"
}
TF_CONFIG="$(config_json "$ENDPOINT")"
# Stub the Terraform lookup — no state, no terraform binary needed.
tf_output_json() { printf '%s' "$TF_CONFIG"; }

count_calls() {
  local count
  count=$(grep -c "\"call\": \"$1\"" "$FAKE_CALL_LOG" 2>/dev/null) || count=0
  echo "$count"
}
nth_call() { grep "\"call\": \"$1\"" "$FAKE_CALL_LOG" 2>/dev/null | sed -n "${2}p"; }
reset_log() { : > "$FAKE_CALL_LOG"; }
# Two unrelated registrations ahead of ours, so finding it needs paging.
cat > "$FAKE_STATE" <<'EOF'
{"services": [
  {"serviceId": "svc-1", "serviceType": "mcpserversigv4", "name": "someone-else"},
  {"serviceId": "svc-2", "serviceType": "mcpserversigv4", "name": "another-team"}
], "associations": [], "assets": [
  {"assetId": "ki-other", "assetType": "skill", "metadata": {"name": "unrelated-skill"}}
]}
EOF
EXPECTED_TOOLS=$(.venv/bin/python -c '
import json
cfg = json.load(open("src/lambda/mcp/tools.json"))["lambda-runtime"]["tools"]
print(json.dumps(sorted("lambda-runtime___" + t["name"] for t in cfg)))')

# ---------------------------------------------------------------------------
echo "Test 1: first sync registers, associates all tools, uploads the skill"
reset_log
OUTPUT=$(sync_devops_agent_mcp 2>&1); STATUS=$?
assert_eq "$STATUS" "0" "sync returns 0"
assert_eq "$(count_calls list_services)" "2" "list_services paged through both existing registrations"
assert_eq "$(count_calls register_service)" "1" "registered exactly once"
REG=$(nth_call register_service 1)
assert_contains "$REG" '"service": "mcpserversigv4"' "registered as a SigV4 MCP server"
assert_contains "$REG" '"name": "cops-dev-gateway"' "registered under <project>-<env>-gateway"
assert_contains "$REG" "\"endpoint\": \"$ENDPOINT\"" "endpoint is the gateway URL"
assert_contains "$REG" '"sigv4_service": "bedrock-agentcore"' "SigV4 service name is bedrock-agentcore"
assert_contains "$REG" '"region": "us-east-1"' "SigV4 region is the gateway region"
assert_contains "$REG" "\"mcpRoleArn\": \"$ROLE\"" "role passed as mcpRoleArn"
assert_contains "$REG" '"roleArn": null' "deprecated roleArn not sent"
ASSOC=$(nth_call associate_service 1)
GOT_TOOLS=$(printf '%s' "$ASSOC" | .venv/bin/python -c 'import json,sys; print(json.dumps(sorted(json.loads(sys.stdin.read())["tools"])))')
assert_eq "$GOT_TOOLS" "$EXPECTED_TOOLS" "allowlist is <target>___<tool> for every lambda-runtime tool"
assert_eq "$(printf '%s' "$EXPECTED_TOOLS" | .venv/bin/python -c 'import json,sys; print(len(json.load(sys.stdin)))')" "8" "lambda-runtime exposes 8 tools"
assert_contains "$ASSOC" '"agentSpaceId": "space-test"' "associated with the configured Agent Space"
CREATE=$(nth_call create_asset 1)
assert_contains "$CREATE" '"assetType": "skill"' "skill asset created"
assert_contains "$CREATE" '"agent_types": ["GENERIC"]' "skill available to all agent types"
assert_contains "$CREATE" '"SKILL.md"' "zip contains SKILL.md"
assert_contains "$CREATE" '"reference/runtime-migration-kb.md"' "zip contains the reference KB"
assert_not_contains "$CREATE" '"name":' "zip upload sends no name (read from frontmatter)"
assert_file "$HASH_DIR/devops-agent-skill.sha" present "skill hash stored after success"
assert_file "$HASH_DIR/devops-agent-mcp.json" present "registration recorded for later cleanup"

# ---------------------------------------------------------------------------
echo
echo "Test 2: second sync is a no-op"
reset_log
OUTPUT=$(sync_devops_agent_mcp 2>&1); STATUS=$?
assert_eq "$STATUS" "0" "sync returns 0"
assert_eq "$(count_calls register_service)" "0" "no duplicate registration"
assert_eq "$(count_calls associate_service)" "0" "association left alone when tools are unchanged"
assert_eq "$(count_calls create_asset)$(count_calls update_asset)" "00" "skill upload skipped"
assert_contains "$OUTPUT" "skills unchanged, skipping upload" "skip reported by hash"

# ---------------------------------------------------------------------------
echo
echo "Test 3: a changed skill updates the existing asset in place"
printf '\n<!-- test change -->\n' >> skills/lambda-runtime-upgrade/SKILL.md
reset_log
OUTPUT=$(sync_devops_agent_mcp 2>&1)
assert_eq "$(count_calls create_asset)" "0" "no second skill asset"
assert_eq "$(count_calls update_asset)" "1" "existing skill updated"
assert_contains "$(nth_call update_asset 1)" '"has_metadata": false' "update keeps user-edited metadata (status, agent types)"
assert_contains "$(nth_call update_asset 1)" '"assetId": "ki-1"' "updated the asset matched by skill name"

# ---------------------------------------------------------------------------
echo
echo "Test 4: a changed endpoint replaces the registration"
TF_CONFIG="$(config_json "https://gw-new.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp")"
reset_log
OUTPUT=$(sync_devops_agent_mcp 2>&1)
assert_eq "$(count_calls disassociate_service)" "1" "old association removed"
assert_eq "$(count_calls deregister_service)" "1" "stale registration removed"
assert_eq "$(count_calls register_service)" "1" "new registration created"
assert_eq "$(count_calls associate_service)" "1" "tools re-associated with the new registration"

# ---------------------------------------------------------------------------
echo
echo "Test 5: failures warn but never fail the deploy"
reset_log
rm -f "$FAKE_STATE.bak"; cp "$FAKE_STATE" "$FAKE_STATE.bak"
printf '\n<!-- second change -->\n' >> skills/lambda-runtime-upgrade/SKILL.md
# Force a re-association by registering against yet another endpoint.
TF_CONFIG="$(config_json "https://gw-third.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp")"
OUTPUT=$(FAKE_FAIL=associate_service sync_devops_agent_mcp 2>&1); STATUS=$?
assert_eq "$STATUS" "0" "sync still returns 0"
assert_contains "$OUTPUT" "injected associate_service failure" "failure reason printed"
assert_contains "$OUTPUT" "DevOps Agent MCP sync failed (non-fatal)" "non-fatal warning emitted"
assert_file "$HASH_DIR/devops-agent-skill.sha" absent "skill hash cleared so the next deploy retries"
OUTPUT=$(sync_devops_agent_mcp 2>&1)
assert_contains "$OUTPUT" "association: 8 tools allowed" "next run recovers"

# ---------------------------------------------------------------------------
echo
echo "Test 6: IAM propagation — registration retried after an STS validation error"
TF_CONFIG="$(config_json "https://gw-fourth.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp")"
reset_log
OUTPUT=$(FAKE_FLAKY_REGISTER="$SANDBOX/flaky-once" sync_devops_agent_mcp 2>&1); STATUS=$?
assert_eq "$STATUS" "0" "sync returns 0"
assert_eq "$(count_calls register_service_rejected)" "1" "first attempt rejected"
assert_eq "$(count_calls register_service)" "1" "retry succeeded"
assert_contains "$OUTPUT" "retrying" "retry reported"
assert_not_contains "$OUTPUT" "sync failed" "no failure warning after a successful retry"

# ---------------------------------------------------------------------------
echo
echo "Test 7: requested targets not on the gateway are reported"
reset_log
MISSING_TOOLS='["cost-explorer"]'
TF_CONFIG="$(config_json "https://gw-fourth.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp")"
OUTPUT=$(sync_devops_agent_mcp 2>&1)
assert_contains "$OUTPUT" "cost-explorer: not deployed on this gateway" "missing target warned"
unset MISSING_TOOLS

# ---------------------------------------------------------------------------
echo
echo "Test 8: teardown deregisters before destroy"
reset_log
OUTPUT=$(cleanup_devops_agent_mcp 2>&1); STATUS=$?
assert_eq "$STATUS" "0" "cleanup returns 0"
assert_eq "$(count_calls disassociate_service)" "1" "association removed"
assert_eq "$(count_calls deregister_service)" "1" "registration removed"
assert_eq "$(count_calls create_asset)$(count_calls update_asset)" "00" "skill assets untouched"
assert_contains "$OUTPUT" "skills are left in the Agent Space" "kept skill reported"
assert_file "$HASH_DIR/devops-agent-mcp.json" absent "registration record cleared"
REMAINING=$(.venv/bin/python -c 'import json,os; print(sorted(s["serviceId"] for s in json.load(open(os.environ["FAKE_STATE"]))["services"]))')
assert_eq "$REMAINING" "['svc-1', 'svc-2']" "other teams' registrations untouched"

# ---------------------------------------------------------------------------
echo
echo "Test 9: feature off — no API calls, unless this workstation registered earlier"
TF_CONFIG=""
reset_log
OUTPUT=$(sync_devops_agent_mcp 2>&1); STATUS=$?
assert_eq "$STATUS" "0" "returns 0 when off"
assert_eq "$(count_calls client)" "0" "no DevOps Agent API calls when never enabled"
TF_CONFIG="$(config_json "$ENDPOINT")"
sync_devops_agent_mcp >/dev/null 2>&1
TF_CONFIG=""
reset_log
OUTPUT=$(sync_devops_agent_mcp 2>&1)
assert_eq "$(count_calls deregister_service)" "1" "turning the flag off deregisters the earlier registration"
assert_file "$HASH_DIR/devops-agent-mcp.json" absent "registration record cleared after disable"

echo
echo "----------------------------------------"
echo "Ran $TESTS_RUN tests, $TESTS_FAILED failed."
echo "----------------------------------------"
exit "$TESTS_FAILED"
