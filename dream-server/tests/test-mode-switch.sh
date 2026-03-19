#!/bin/bash
# Test suite for mode-switch.sh
# Verifies Dream Server mode transitions and .env mutations.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="$ROOT_DIR/scripts/mode-switch.sh"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

make_fixture_tree() {
    local fixture_root="$1"
    mkdir -p "$fixture_root/scripts" "$fixture_root/extensions/services/litellm"
    cp "$SOURCE_SCRIPT" "$fixture_root/scripts/mode-switch.sh"
    chmod +x "$fixture_root/scripts/mode-switch.sh"
}

write_env_file() {
    local fixture_root="$1"
    cat > "$fixture_root/.env" <<'EOF'
DREAM_MODE=local
LLM_API_URL=http://llama-server:8080
EOF
}

run_switch() {
    local fixture_root="$1"
    shift
    (cd "$fixture_root" && ./scripts/mode-switch.sh "$@")
}

test_script_exists() {
    if [[ -f "$SOURCE_SCRIPT" ]]; then
        pass "mode-switch.sh exists"
    else
        fail "mode-switch.sh exists"
    fi
}

test_status_reports_current_mode() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_env_file "$fixture_root"

    local output
    output="$(run_switch "$fixture_root" --status)"

    if echo "$output" | grep -q "Current mode: local" \
        && echo "$output" | grep -q "Available modes"; then
        pass "status reports current mode"
    else
        fail "status reports current mode"
    fi
}

test_help_displays_usage() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"

    local output
    output="$(run_switch "$fixture_root" --help)"

    if echo "$output" | grep -q "Usage: mode-switch.sh"; then
        pass "help displays usage"
    else
        fail "help displays usage"
    fi
}

test_unknown_mode_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_env_file "$fixture_root"

    local output
    local status=0
    output="$(run_switch "$fixture_root" arcade 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "Unknown mode: arcade"; then
        pass "unknown mode fails"
    else
        fail "unknown mode fails"
    fi
}

test_missing_env_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"

    local output
    local status=0
    output="$(run_switch "$fixture_root" local 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q ".env not found"; then
        pass "missing env fails"
    else
        fail "missing env fails"
    fi
}

test_switch_to_cloud_updates_env_and_enables_litellm() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_env_file "$fixture_root"
    printf 'services:\n  litellm:\n    image: test\n' > "$fixture_root/extensions/services/litellm/compose.yaml.disabled"

    local output
    output="$(run_switch "$fixture_root" cloud)"

    if grep -q '^DREAM_MODE=cloud$' "$fixture_root/.env" \
        && grep -q '^LLM_API_URL=http://litellm:4000$' "$fixture_root/.env" \
        && [[ -f "$fixture_root/extensions/services/litellm/compose.yaml" ]] \
        && echo "$output" | grep -q "Auto-enabled litellm for cloud mode"; then
        pass "switch to cloud updates env and enables litellm"
    else
        fail "switch to cloud updates env and enables litellm"
    fi
}

test_switch_to_hybrid_uses_litellm_url() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_env_file "$fixture_root"

    local output
    output="$(run_switch "$fixture_root" hybrid)"

    if grep -q '^DREAM_MODE=hybrid$' "$fixture_root/.env" \
        && grep -q '^LLM_API_URL=http://litellm:4000$' "$fixture_root/.env" \
        && echo "$output" | grep -q "Switched to hybrid mode"; then
        pass "switch to hybrid uses litellm url"
    else
        fail "switch to hybrid uses litellm url"
    fi
}

test_switch_to_local_restores_llama_server_url() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    cat > "$fixture_root/.env" <<'EOF'
DREAM_MODE=cloud
LLM_API_URL=http://litellm:4000
EOF

    local output
    output="$(run_switch "$fixture_root" local)"

    if grep -q '^DREAM_MODE=local$' "$fixture_root/.env" \
        && grep -q '^LLM_API_URL=http://llama-server:8080$' "$fixture_root/.env" \
        && echo "$output" | grep -q "Switched to local mode"; then
        pass "switch to local restores llama server url"
    else
        fail "switch to local restores llama server url"
    fi
}

test_env_set_appends_missing_keys() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    printf 'DREAM_MODE=local\n' > "$fixture_root/.env"

    run_switch "$fixture_root" cloud >/dev/null

    if grep -q '^LLM_API_URL=http://litellm:4000$' "$fixture_root/.env"; then
        pass "env_set appends missing keys"
    else
        fail "env_set appends missing keys"
    fi
}

test_script_references_expected_modes() {
    if grep -q 'local|cloud|hybrid' "$SOURCE_SCRIPT" \
        && grep -q 'DREAM_MODE' "$SOURCE_SCRIPT" \
        && grep -q 'LLM_API_URL' "$SOURCE_SCRIPT"; then
        pass "script references expected modes"
    else
        fail "script references expected modes"
    fi
}

test_script_uses_awk_based_env_updates() {
    if grep -q 'awk -v k=' "$SOURCE_SCRIPT" && grep -q 'index($0, k "=") == 1' "$SOURCE_SCRIPT"; then
        pass "script uses awk based env updates"
    else
        fail "script uses awk based env updates"
    fi
}

echo "============================================================"
echo "mode-switch.sh contract tests"
echo "============================================================"

test_script_exists
test_status_reports_current_mode
test_help_displays_usage
test_unknown_mode_fails
test_missing_env_fails
test_switch_to_cloud_updates_env_and_enables_litellm
test_switch_to_hybrid_uses_litellm_url
test_switch_to_local_restores_llama_server_url
test_env_set_appends_missing_keys
test_script_references_expected_modes
test_script_uses_awk_based_env_updates

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ $FAIL -eq 0 ]]; then
    exit 0
fi

exit 1
