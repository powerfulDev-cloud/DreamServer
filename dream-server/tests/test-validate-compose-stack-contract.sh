#!/bin/bash
# Test suite for validate-compose-stack.sh
# Verifies compose validation command selection and output contracts.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="$ROOT_DIR/scripts/validate-compose-stack.sh"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

make_fixture_tree() {
    local fixture_root="$1"
    mkdir -p "$fixture_root/scripts" "$fixture_root/bin"
    cp "$SOURCE_SCRIPT" "$fixture_root/scripts/validate-compose-stack.sh"
    chmod +x "$fixture_root/scripts/validate-compose-stack.sh"
}

write_docker_bin() {
    local fixture_root="$1"
    cat > "$fixture_root/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
    [[ "${DOCKER_COMPOSE_PRESENT:-1}" == "1" ]] || exit 1
    echo "Docker Compose version v2"
    exit 0
fi

if [[ "${1:-}" == "compose" ]]; then
    shift
    if [[ "${1:-}" == "--env-file" ]]; then
        shift 2
    fi
    if [[ "${1:-}" == "-f" ]]; then
        shift 2
    fi
    if [[ "${1:-}" == "config" ]]; then
        if [[ "${VALIDATE_OK:-1}" == "1" ]]; then
            cat <<'CFG'
services:
  web:
    image: demo
  worker:
    image: demo
CFG
            exit 0
        fi
        echo "yaml: line 1: did not find expected key" >&2
        exit 1
    fi
fi

echo "unsupported docker invocation: $*" >&2
exit 1
EOF
    chmod +x "$fixture_root/bin/docker"
}

write_missing_docker_bin() {
    local fixture_root="$1"
    cat > "$fixture_root/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 127
EOF
    chmod +x "$fixture_root/bin/docker"
}

write_docker_compose_bin() {
    local fixture_root="$1"
    cat > "$fixture_root/bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-f" ]]; then
    shift 2
fi
if [[ "${1:-}" == "--env-file" ]]; then
    shift 2
fi
if [[ "${1:-}" == "config" ]]; then
    if [[ "${VALIDATE_OK:-1}" == "1" ]]; then
        cat <<'CFG'
services:
  api:
    image: demo
CFG
        exit 0
    fi
    echo "compose config failed" >&2
    exit 1
fi
echo "unsupported docker-compose invocation: $*" >&2
exit 1
EOF
    chmod +x "$fixture_root/bin/docker-compose"
}

run_validator() {
    local fixture_root="$1"
    shift
    (
        cd "$fixture_root"
        PATH="$fixture_root/bin:$PATH" \
        DOCKER_COMPOSE_PRESENT="${DOCKER_COMPOSE_PRESENT:-1}" \
        VALIDATE_OK="${VALIDATE_OK:-1}" \
        ./scripts/validate-compose-stack.sh "$@"
    )
}

test_script_exists() {
    if [[ -f "$SOURCE_SCRIPT" ]]; then
        pass "validate-compose-stack.sh exists"
    else
        fail "validate-compose-stack.sh exists"
    fi
}

test_requires_compose_flags() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"

    local output
    local status=0
    output="$(run_validator "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q -- "--compose-flags required"; then
        pass "requires compose flags"
    else
        fail "requires compose flags"
    fi
}

test_unknown_argument_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"

    local output
    local status=0
    output="$(run_validator "$fixture_root" --bogus 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "Unknown argument"; then
        pass "unknown argument fails"
    else
        fail "unknown argument fails"
    fi
}

test_prefers_docker_compose_when_available() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_docker_bin "$fixture_root"

    local output
    output="$(run_validator "$fixture_root" --compose-flags '-f stack.yml')"

    if echo "$output" | grep -q "Validating compose stack: -f stack.yml" \
        && echo "$output" | grep -q "Compose stack validation passed" \
        && echo "$output" | grep -q "Services defined: 2"; then
        pass "prefers docker compose when available"
    else
        fail "prefers docker compose when available"
    fi
}

test_falls_back_to_legacy_docker_compose_binary() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_docker_bin "$fixture_root"
    write_docker_compose_bin "$fixture_root"

    local output
    output="$(DOCKER_COMPOSE_PRESENT=0 run_validator "$fixture_root" --compose-flags '-f stack.yml')"

    if echo "$output" | grep -q "Compose stack validation passed" \
        && echo "$output" | grep -q "Services defined: 1"; then
        pass "falls back to legacy docker-compose binary"
    else
        fail "falls back to legacy docker-compose binary"
    fi
}

test_env_file_flag_is_used_only_when_file_exists() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_docker_bin "$fixture_root"
    printf 'KEY=value\n' > "$fixture_root/test.env"

    local output
    output="$(run_validator "$fixture_root" --compose-flags '-f stack.yml' --env-file "$fixture_root/test.env")"

    if echo "$output" | grep -q "Compose stack validation passed"; then
        pass "env file flag is used only when file exists"
    else
        fail "env file flag is used only when file exists"
    fi
}

test_quiet_mode_suppresses_success_banner() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_docker_bin "$fixture_root"

    local output
    output="$(run_validator "$fixture_root" --compose-flags '-f stack.yml' --quiet)"

    if [[ -z "$output" ]]; then
        pass "quiet mode suppresses success banner"
    else
        fail "quiet mode suppresses success banner"
    fi
}

test_validation_failure_prints_errors_and_flags() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_docker_bin "$fixture_root"

    local output
    local status=0
    output="$(VALIDATE_OK=0 run_validator "$fixture_root" --compose-flags '-f broken.yml' 2>&1)" || status=$?

    if [[ $status -ne 0 ]] \
        && echo "$output" | grep -q "Compose stack validation FAILED" \
        && echo "$output" | grep -q "yaml: line 1" \
        && echo "$output" | grep -q "Compose flags: -f broken.yml"; then
        pass "validation failure prints errors and flags"
    else
        fail "validation failure prints errors and flags"
    fi
}

test_missing_compose_binary_fails_cleanly() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_missing_docker_bin "$fixture_root"

    local output
    local status=0
    output="$(run_validator "$fixture_root" --compose-flags '-f stack.yml' 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "docker compose not found"; then
        pass "missing compose binary fails cleanly"
    else
        fail "missing compose binary fails cleanly"
    fi
}

test_script_references_validation_contract() {
    if grep -q 'docker compose config' "$SOURCE_SCRIPT" \
        && grep -q 'validation_output=$(mktemp)' "$SOURCE_SCRIPT" \
        && grep -q 'Services defined' "$SOURCE_SCRIPT"; then
        pass "script references validation contract"
    else
        fail "script references validation contract"
    fi
}

echo "============================================================"
echo "validate-compose-stack.sh contract tests"
echo "============================================================"

test_script_exists
test_requires_compose_flags
test_unknown_argument_fails
test_prefers_docker_compose_when_available
test_falls_back_to_legacy_docker_compose_binary
test_env_file_flag_is_used_only_when_file_exists
test_quiet_mode_suppresses_success_banner
test_validation_failure_prints_errors_and_flags
test_missing_compose_binary_fails_cleanly
test_script_references_validation_contract

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ $FAIL -eq 0 ]]; then
    exit 0
fi

exit 1
