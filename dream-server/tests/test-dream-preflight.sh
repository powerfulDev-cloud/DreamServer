#!/bin/bash
# Test suite for dream-preflight.sh
# Verifies preflight output paths with stubbed docker/curl dependencies.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="$ROOT_DIR/scripts/dream-preflight.sh"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

make_fixture_tree() {
    local fixture_root="$1"
    mkdir -p "$fixture_root/scripts" "$fixture_root/lib" "$fixture_root/bin"
    cp "$SOURCE_SCRIPT" "$fixture_root/scripts/dream-preflight.sh"
    chmod +x "$fixture_root/scripts/dream-preflight.sh"

    cat > "$fixture_root/lib/service-registry.sh" <<'EOF'
#!/usr/bin/env bash
declare -ag SERVICE_IDS
declare -Ag SERVICE_CATEGORIES
declare -Ag SERVICE_PORTS
declare -Ag SERVICE_HEALTH
declare -Ag SERVICE_CONTAINERS
declare -Ag SERVICE_NAMES
sr_load() {
    SERVICE_IDS=(llama-server open-webui qdrant)
    SERVICE_CATEGORIES[llama-server]="core"
    SERVICE_CATEGORIES[open-webui]="core"
    SERVICE_CATEGORIES[qdrant]="extensions"
    SERVICE_PORTS[llama-server]=11434
    SERVICE_PORTS[open-webui]=3000
    SERVICE_PORTS[qdrant]=6333
    SERVICE_HEALTH[llama-server]="/health"
    SERVICE_HEALTH[open-webui]="/"
    SERVICE_HEALTH[qdrant]="/healthz"
    SERVICE_CONTAINERS[llama-server]="dream-llama-server"
    SERVICE_CONTAINERS[qdrant]="dream-qdrant"
    SERVICE_NAMES[qdrant]="Qdrant"
}
EOF

    cat > "$fixture_root/lib/safe-env.sh" <<'EOF'
#!/usr/bin/env bash
load_env_file() {
    return 0
}
EOF

    cat > "$fixture_root/scripts/resolve-compose-stack.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "--profile test"
EOF
    chmod +x "$fixture_root/scripts/resolve-compose-stack.sh"

    cat > "$fixture_root/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    info)
        [[ "${DOCKER_INFO_OK:-1}" == "1" ]] || exit 1
        echo "Docker is running"
        ;;
    compose)
        shift
        if [[ "${1:-}" == "--profile" ]]; then
            shift 2
        fi
        if [[ "${1:-}" == "ps" ]]; then
            [[ "${DOCKER_PS_OK:-1}" == "1" ]] || exit 1
            cat <<'PS'
NAME                 STATUS
dream-llama-server   running
dream-qdrant         running
PS
        else
            echo "unsupported docker compose invocation" >&2
            exit 1
        fi
        ;;
    exec)
        container="${2:-}"
        cmd="${3:-}"
        if [[ "$container" != "dream-llama-server" ]]; then
            exit 1
        fi
        if [[ "$cmd" == "nvidia-smi" ]]; then
            [[ "${GPU_PRESENT:-0}" == "1" ]] || exit 1
            if [[ "${4:-}" == "--query-gpu=memory.free" ]]; then
                echo "16384"
            else
                echo "GPU 0"
            fi
        else
            exit 1
        fi
        ;;
    *)
        echo "unsupported docker invocation: $*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$fixture_root/bin/docker"

    cat > "$fixture_root/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${*: -1}"
case "$target" in
    *localhost:11434/health)
        [[ "${LLM_HEALTH_OK:-1}" == "1" ]] || exit 22
        echo "ok"
        ;;
    *localhost:3000/)
        [[ "${WEBUI_HEALTH_OK:-1}" == "1" ]] || exit 22
        echo "ok"
        ;;
    *localhost:6333/healthz)
        [[ "${QDRANT_HEALTH_OK:-1}" == "1" ]] || exit 22
        echo "ok"
        ;;
    *)
        exit 22
        ;;
esac
EOF
    chmod +x "$fixture_root/bin/curl"
}

run_preflight() {
    local fixture_root="$1"
    shift
    (
        cd "$fixture_root"
        PATH="$fixture_root/bin:$PATH" \
        DOCKER_INFO_OK="${DOCKER_INFO_OK:-1}" \
        DOCKER_PS_OK="${DOCKER_PS_OK:-1}" \
        LLM_HEALTH_OK="${LLM_HEALTH_OK:-1}" \
        WEBUI_HEALTH_OK="${WEBUI_HEALTH_OK:-1}" \
        QDRANT_HEALTH_OK="${QDRANT_HEALTH_OK:-1}" \
        GPU_PRESENT="${GPU_PRESENT:-0}" \
        ./scripts/dream-preflight.sh "$@"
    )
}

test_script_exists() {
    if [[ -f "$SOURCE_SCRIPT" ]]; then
        pass "dream-preflight.sh exists"
    else
        fail "dream-preflight.sh exists"
    fi
}

test_happy_path_reports_ready_services() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"

    local output
    output="$(GPU_PRESENT=1 run_preflight "$fixture_root")"

    if echo "$output" | grep -q "Docker daemon" \
        && echo "$output" | grep -q "Core containers" \
        && echo "$output" | grep -q "llama-server API (port 11434).*healthy" \
        && echo "$output" | grep -q "Open WebUI (port 3000).*accessible" \
        && echo "$output" | grep -q "Qdrant (port 6333).*ready" \
        && echo "$output" | grep -q "Open http://localhost:3000"; then
        pass "happy path reports ready services"
    else
        fail "happy path reports ready services"
    fi
}

test_docker_not_running_fails_fast() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"

    local output
    local status=0
    output="$(DOCKER_INFO_OK=0 run_preflight "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] \
        && echo "$output" | grep -q "Docker daemon" \
        && echo "$output" | grep -q "Start Docker Desktop"; then
        pass "docker not running fails fast"
    else
        fail "docker not running fails fast"
    fi
}

test_missing_core_container_fails_fast() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"

    local output
    local status=0
    output="$(DOCKER_PS_OK=0 run_preflight "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] \
        && echo "$output" | grep -q "Core containers" \
        && echo "$output" | grep -q "docker compose up -d"; then
        pass "missing core container fails fast"
    else
        fail "missing core container fails fast"
    fi
}

test_llama_server_startup_warning_is_nonfatal() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"

    local output
    output="$(LLM_HEALTH_OK=0 run_preflight "$fixture_root")"

    if echo "$output" | grep -q "llama-server API (port 11434).*starting up" \
        && echo "$output" | grep -q "Wait 1-2 minutes and retry" \
        && echo "$output" | grep -q "Next steps:"; then
        pass "llama server startup warning is nonfatal"
    else
        fail "llama server startup warning is nonfatal"
    fi
}

test_webui_warning_does_not_abort() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"

    local output
    output="$(WEBUI_HEALTH_OK=0 run_preflight "$fixture_root")"

    if echo "$output" | grep -q "Open WebUI (port 3000).*not ready" \
        && echo "$output" | grep -q "Need help? See docs/TROUBLESHOOTING.md"; then
        pass "webui warning does not abort"
    else
        fail "webui warning does not abort"
    fi
}

test_cpu_mode_gpu_warning_is_reported() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"

    local output
    output="$(GPU_PRESENT=0 run_preflight "$fixture_root")"

    if echo "$output" | grep -q "GPU availability" \
        && echo "$output" | grep -q "CPU mode"; then
        pass "cpu mode gpu warning is reported"
    else
        fail "cpu mode gpu warning is reported"
    fi
}

test_script_references_registry_and_compose_resolution() {
    if grep -q 'service-registry.sh' "$SOURCE_SCRIPT" \
        && grep -q 'resolve-compose-stack.sh' "$SOURCE_SCRIPT" \
        && grep -q 'CURL_HEALTH_FLAGS' "$SOURCE_SCRIPT"; then
        pass "script references registry and compose resolution"
    else
        fail "script references registry and compose resolution"
    fi
}

test_script_prints_guided_next_steps() {
    if grep -q 'Next steps:' "$SOURCE_SCRIPT" \
        && grep -q 'What.s 2+2' "$SOURCE_SCRIPT" \
        && grep -q 'docs/TROUBLESHOOTING.md' "$SOURCE_SCRIPT"; then
        pass "script prints guided next steps"
    else
        fail "script prints guided next steps"
    fi
}

echo "============================================================"
echo "dream-preflight.sh contract tests"
echo "============================================================"

test_script_exists
test_happy_path_reports_ready_services
test_docker_not_running_fails_fast
test_missing_core_container_fails_fast
test_llama_server_startup_warning_is_nonfatal
test_webui_warning_does_not_abort
test_cpu_mode_gpu_warning_is_reported
test_script_references_registry_and_compose_resolution
test_script_prints_guided_next_steps

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ $FAIL -eq 0 ]]; then
    exit 0
fi

exit 1
