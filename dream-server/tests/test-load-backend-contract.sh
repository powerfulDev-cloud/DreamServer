#!/bin/bash
# Test suite for load-backend-contract.sh
# Verifies JSON and env contract loading for backend definitions.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="$ROOT_DIR/scripts/load-backend-contract.sh"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

make_fixture_tree() {
    local fixture_root="$1"
    mkdir -p "$fixture_root/scripts" "$fixture_root/config/backends" "$fixture_root/lib"
    cp "$SOURCE_SCRIPT" "$fixture_root/scripts/load-backend-contract.sh"
    chmod +x "$fixture_root/scripts/load-backend-contract.sh"

    cat > "$fixture_root/lib/python-cmd.sh" <<'EOF'
#!/usr/bin/env bash
ds_detect_python_cmd() {
    echo "python3"
}
EOF
}

write_backend_contract() {
    local fixture_root="$1"
    local backend_id="$2"
    local engine="$3"
    local service_name="$4"
    local port="$5"
    local health_url="$6"
    local provider_name="$7"
    local provider_url="$8"

    python3 - "$fixture_root/config/backends/${backend_id}.json" "$backend_id" "$engine" "$service_name" "$port" "$health_url" "$provider_name" "$provider_url" <<'PY'
import json
import sys

path, backend_id, engine, service_name, port, health_url, provider_name, provider_url = sys.argv[1:]
payload = {
    "id": backend_id,
    "llm_engine": engine,
    "service_name": service_name,
    "public_api_port": int(port),
    "public_health_url": health_url,
    "provider_name": provider_name,
    "provider_url": provider_url,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
}

run_loader() {
    local fixture_root="$1"
    shift
    (cd "$fixture_root" && ./scripts/load-backend-contract.sh "$@")
}

test_script_exists() {
    if [[ -f "$SOURCE_SCRIPT" ]]; then
        pass "load-backend-contract.sh exists"
    else
        fail "load-backend-contract.sh exists"
    fi
}

test_requires_backend_argument() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"

    local output
    local status=0
    output="$(run_loader "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "Missing required argument: --backend"; then
        pass "requires backend argument"
    else
        fail "requires backend argument"
    fi
}

test_rejects_unknown_argument() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"

    local output
    local status=0
    output="$(run_loader "$fixture_root" --bogus 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "Unknown argument"; then
        pass "rejects unknown argument"
    else
        fail "rejects unknown argument"
    fi
}

test_missing_backend_file_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"

    local output
    local status=0
    output="$(run_loader "$fixture_root" --backend cloud 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "Backend contract not found"; then
        pass "missing backend file fails"
    else
        fail "missing backend file fails"
    fi
}

test_prints_raw_json_contract() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_backend_contract "$fixture_root" "cloud" "litellm" "litellm" "4000" "/health" "Together" "https://api.together.xyz"

    local output
    output="$(run_loader "$fixture_root" --backend cloud)"

    if echo "$output" | grep -q '"id": "cloud"' \
        && echo "$output" | grep -q '"service_name": "litellm"' \
        && echo "$output" | grep -q '"public_api_port": 4000'; then
        pass "prints raw JSON contract"
    else
        fail "prints raw JSON contract"
    fi
}

test_env_mode_exports_expected_keys() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_backend_contract "$fixture_root" "local" "llama.cpp" "llama-server" "8080" "/health" "Local" "http://localhost:8080"

    local output
    output="$(run_loader "$fixture_root" --backend local --env)"

    if echo "$output" | grep -q 'BACKEND_CONTRACT_ID="local"' \
        && echo "$output" | grep -q 'BACKEND_LLM_ENGINE="llama.cpp"' \
        && echo "$output" | grep -q 'BACKEND_SERVICE_NAME="llama-server"' \
        && echo "$output" | grep -q 'BACKEND_PUBLIC_API_PORT="8080"' \
        && echo "$output" | grep -q 'BACKEND_PROVIDER_URL="http://localhost:8080"'; then
        pass "env mode exports expected keys"
    else
        fail "env mode exports expected keys"
    fi
}

test_env_mode_preserves_quotes_safely() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_backend_contract "$fixture_root" "quoted" "vllm" "quoted-service" "9000" "/ready" 'Acme "Cloud"' 'https://example.com/query?x="1"'

    local output
    output="$(run_loader "$fixture_root" --backend quoted --env)"

    if echo "$output" | grep -q 'BACKEND_PROVIDER_NAME="Acme \\"Cloud\\""' \
        && echo "$output" | grep -q 'BACKEND_PROVIDER_URL="https://example.com/query?x=\\"1\\""'; then
        pass "env mode preserves quotes safely"
    else
        fail "env mode preserves quotes safely"
    fi
}

test_prefers_python_cmd_helper_when_present() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_backend_contract "$fixture_root" "hybrid" "router" "litellm" "4000" "/healthz" "Hybrid" "http://litellm:4000"

    local output
    output="$(run_loader "$fixture_root" --backend hybrid --env)"

    if echo "$output" | grep -q 'BACKEND_CONTRACT_FILE='.*/config/backends/hybrid.json; then
        pass "prefers python cmd helper when present"
    else
        fail "prefers python cmd helper when present"
    fi
}

test_script_references_expected_fields() {
    if grep -q 'BACKEND_LLM_ENGINE' "$SOURCE_SCRIPT" \
        && grep -q 'BACKEND_PUBLIC_HEALTH_URL' "$SOURCE_SCRIPT" \
        && grep -q 'BACKEND_PROVIDER_URL' "$SOURCE_SCRIPT"; then
        pass "script references expected fields"
    else
        fail "script references expected fields"
    fi
}

test_script_supports_env_mode_switch() {
    if grep -q -- '--env' "$SOURCE_SCRIPT" && grep -q 'ENV_MODE="true"' "$SOURCE_SCRIPT"; then
        pass "script supports env mode switch"
    else
        fail "script supports env mode switch"
    fi
}

echo "============================================================"
echo "load-backend-contract.sh contract tests"
echo "============================================================"

test_script_exists
test_requires_backend_argument
test_rejects_unknown_argument
test_missing_backend_file_fails
test_prints_raw_json_contract
test_env_mode_exports_expected_keys
test_env_mode_preserves_quotes_safely
test_prefers_python_cmd_helper_when_present
test_script_references_expected_fields
test_script_supports_env_mode_switch

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ $FAIL -eq 0 ]]; then
    exit 0
fi

exit 1
