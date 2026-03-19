#!/bin/bash
# Test suite for build-capability-profile.sh
# Verifies capability profile generation with stubbed hardware contracts.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="$ROOT_DIR/scripts/build-capability-profile.sh"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

make_fixture_tree() {
    local fixture_root="$1"
    mkdir -p "$fixture_root/scripts" "$fixture_root/lib"
    cp "$SOURCE_SCRIPT" "$fixture_root/scripts/build-capability-profile.sh"
    chmod +x "$fixture_root/scripts/build-capability-profile.sh"
}

write_common_libs() {
    local fixture_root="$1"

    cat > "$fixture_root/lib/safe-env.sh" <<'EOF'
#!/usr/bin/env bash
load_env_from_output() {
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local key="${line%%=*}"
        local value="${line#*=}"
        value="${value#\"}"
        value="${value%\"}"
        export "$key=$value"
    done
}
EOF

    cat > "$fixture_root/lib/python-cmd.sh" <<'EOF'
#!/usr/bin/env bash
ds_detect_python_cmd() {
    echo "python3"
}
EOF

    cat > "$fixture_root/lib/service-registry.sh" <<'EOF'
#!/usr/bin/env bash
declare -Ag SERVICE_PORTS
declare -Ag SERVICE_HEALTH
sr_load() {
    SERVICE_PORTS[llama-server]=18080
    SERVICE_HEALTH[llama-server]="/readyz"
}
EOF
}

write_detector() {
    local fixture_root="$1"
    local os_name="$2"
    local gpu_vendor="$3"
    local memory_type="$4"
    local vram_mb="$5"
    local tier="$6"
    local gpu_name="$7"
    local cpu_name="$8"

    cat > "$fixture_root/scripts/detect-hardware.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" != "--json" ]]; then
    echo "expected --json" >&2
    exit 1
fi
cat <<'JSON'
{"os":"$os_name","cpu":"$cpu_name","ram_gb":64,"tier":"$tier","gpu":{"type":"$gpu_vendor","memory_type":"$memory_type","vram_mb":$vram_mb,"device_id":"10de:2704","name":"$gpu_name"}}
JSON
EOF
    chmod +x "$fixture_root/scripts/detect-hardware.sh"
}

write_classifier() {
    local fixture_root="$1"
    local backend="$2"
    local tier="$3"
    local label="$4"
    local hw_id="$5"
    local overlays="$6"

    cat > "$fixture_root/scripts/classify-hardware.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "--env" ]] || [[ " \$* " == *" --env "* ]]; then
    cat <<'ENV'
HW_CLASS_ID="$hw_id"
HW_CLASS_LABEL="$label"
HW_REC_BACKEND="$backend"
HW_REC_TIER="$tier"
HW_REC_COMPOSE_OVERLAYS="$overlays"
ENV
else
    echo '{"id":"$hw_id"}'
fi
EOF
    chmod +x "$fixture_root/scripts/classify-hardware.sh"
}

run_profile() {
    local fixture_root="$1"
    shift
    (cd "$fixture_root" && ./scripts/build-capability-profile.sh "$@")
}

test_script_exists() {
    if [[ -f "$SOURCE_SCRIPT" ]]; then
        pass "build-capability-profile.sh exists"
    else
        fail "build-capability-profile.sh exists"
    fi
}

test_generates_default_json_profile() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_common_libs "$fixture_root"
    write_detector "$fixture_root" "linux" "nvidia" "discrete" "24576" "T3" "RTX 4090" "Ryzen 9"
    write_classifier "$fixture_root" "nvidia" "T3" "Prosumer NVIDIA" "nvidia_t3" "docker-compose.base.yml,docker-compose.nvidia.yml"

    run_profile "$fixture_root"

    if [[ -f "$fixture_root/.capabilities.json" ]] && python3 - "$fixture_root/.capabilities.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], 'r', encoding='utf-8'))
assert data["platform"]["id"] == "linux"
assert data["gpu"]["vendor"] == "nvidia"
assert data["runtime"]["llm_backend"] == "nvidia"
assert data["runtime"]["llm_api_port"] == 18080
assert data["runtime"]["llm_health_url"] == "http://localhost:18080/readyz"
assert data["tier"]["recommended"] == "T3"
assert data["hardware_class"]["id"] == "nvidia_t3"
PY
    then
        pass "generates default JSON profile"
    else
        fail "generates default JSON profile"
    fi
}

test_supports_custom_output_path() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_common_libs "$fixture_root"
    write_detector "$fixture_root" "macos" "apple" "unified" "49152" "T3" "M4 Pro" "Apple M4 Pro"
    write_classifier "$fixture_root" "apple" "T3" "Apple Silicon" "apple_t3" "docker-compose.base.yml,docker-compose.apple.yml"

    local custom_output="$fixture_root/tmp/profile.json"
    run_profile "$fixture_root" --output "$custom_output"

    if [[ -f "$custom_output" ]] && grep -q '"vendor": "apple"' "$custom_output"; then
        pass "supports custom output path"
    else
        fail "supports custom output path"
    fi
}

test_env_mode_exports_expected_contract() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_common_libs "$fixture_root"
    write_detector "$fixture_root" "linux" "amd" "unified" "98304" "SH_LARGE" "Strix Halo" "Ryzen AI MAX+ 395"
    write_classifier "$fixture_root" "amd" "SH_LARGE" "Strix Halo 90+" "strix_halo_large" "docker-compose.base.yml,docker-compose.amd.yml"

    local output
    output="$(run_profile "$fixture_root" --env)"

    if echo "$output" | grep -q 'CAP_LLM_BACKEND="amd"' \
        && echo "$output" | grep -q 'CAP_RECOMMENDED_TIER="SH_LARGE"' \
        && echo "$output" | grep -q 'CAP_HARDWARE_CLASS_ID="strix_halo_large"' \
        && echo "$output" | grep -q 'CAP_COMPOSE_OVERLAYS="docker-compose.base.yml,docker-compose.amd.yml"'; then
        pass "env mode exports expected contract"
    else
        fail "env mode exports expected contract"
    fi
}

test_unknown_argument_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_common_libs "$fixture_root"
    write_detector "$fixture_root" "linux" "nvidia" "discrete" "8192" "T2" "RTX 4060" "Ryzen 7"
    write_classifier "$fixture_root" "nvidia" "T2" "Entry NVIDIA" "nvidia_t2" "docker-compose.base.yml,docker-compose.nvidia.yml"

    local output
    local status=0
    output="$(run_profile "$fixture_root" --bogus 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "Unknown argument"; then
        pass "unknown argument fails"
    else
        fail "unknown argument fails"
    fi
}

test_missing_detector_fails_cleanly() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_common_libs "$fixture_root"
    write_classifier "$fixture_root" "cpu" "T1" "CPU Only" "cpu_t1" "docker-compose.base.yml"

    local output
    local status=0
    output="$(run_profile "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "detect-hardware.sh not found or not executable"; then
        pass "missing detector fails cleanly"
    else
        fail "missing detector fails cleanly"
    fi
}

test_script_declares_expected_contract_keys() {
    if grep -q 'CAP_LLM_HEALTH_URL' "$SOURCE_SCRIPT" \
        && grep -q 'CAP_RECOMMENDED_TIER' "$SOURCE_SCRIPT" \
        && grep -q 'CAP_HARDWARE_CLASS_LABEL' "$SOURCE_SCRIPT"; then
        pass "script declares expected contract keys"
    else
        fail "script declares expected contract keys"
    fi
}

test_script_uses_detect_and_classify_pipeline() {
    if grep -q 'detect-hardware.sh' "$SOURCE_SCRIPT" \
        && grep -q 'classify-hardware.sh' "$SOURCE_SCRIPT" \
        && grep -q 'service-registry.sh' "$SOURCE_SCRIPT"; then
        pass "script uses detect and classify pipeline"
    else
        fail "script uses detect and classify pipeline"
    fi
}

echo "============================================================"
echo "build-capability-profile.sh contract tests"
echo "============================================================"

test_script_exists
test_generates_default_json_profile
test_supports_custom_output_path
test_env_mode_exports_expected_contract
test_unknown_argument_fails
test_missing_detector_fails_cleanly
test_script_declares_expected_contract_keys
test_script_uses_detect_and_classify_pipeline

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ $FAIL -eq 0 ]]; then
    exit 0
fi

exit 1
