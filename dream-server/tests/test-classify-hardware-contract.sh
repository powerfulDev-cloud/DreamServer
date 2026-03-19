#!/bin/bash
# Test suite for classify-hardware.sh
# Verifies known GPU matching, heuristic fallback, and env-mode exports.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="$ROOT_DIR/scripts/classify-hardware.sh"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

make_fixture_tree() {
    local fixture_root="$1"
    mkdir -p "$fixture_root/scripts" "$fixture_root/config" "$fixture_root/lib"
    cp "$SOURCE_SCRIPT" "$fixture_root/scripts/classify-hardware.sh"
    chmod +x "$fixture_root/scripts/classify-hardware.sh"

    cat > "$fixture_root/lib/python-cmd.sh" <<'EOF'
#!/usr/bin/env bash
ds_detect_python_cmd() {
    echo "python3"
}
EOF
}

write_gpu_db() {
    local fixture_root="$1"

    cat > "$fixture_root/config/gpu-database.json" <<'EOF'
{
  "known_gpus": [
    {
      "id": "nvidia_prosumer",
      "match": {
        "device_ids": ["10de:2704"],
        "name_patterns": ["RTX 4090"]
      },
      "specs": {
        "label": "RTX 4090",
        "bandwidth_gbps": 1008,
        "memory_source": "vram"
      },
      "recommended": {
        "backend": "nvidia",
        "tier": "T3"
      }
    },
    {
      "id": "strix_halo_large",
      "match": {
        "name_patterns": ["Strix Halo", "Ryzen AI MAX+ 395"]
      },
      "specs": {
        "label": "Strix Halo 90+",
        "bandwidth_gbps": 256,
        "memory_source": "ram"
      },
      "recommended": {
        "backend": "amd",
        "tier": "SH_LARGE"
      }
    }
  ],
  "heuristic_classes": [
    {
      "id": "amd_unified_mid",
      "match": {
        "vendor": "amd",
        "memory_type": "unified",
        "min_ram_mb": 32768
      },
      "recommended": {
        "backend": "amd",
        "tier": "SH_COMPACT"
      }
    },
    {
      "id": "nvidia_entry",
      "match": {
        "vendor": "nvidia",
        "memory_type": "discrete",
        "min_vram_mb": 8192
      },
      "recommended": {
        "backend": "nvidia",
        "tier": "T2"
      }
    }
  ],
  "known_gpu_bandwidth": {
    "amd": {
      "Radeon 780M": 120
    }
  },
  "defaults": {
    "bandwidth_gbps": {
      "cuda": 200,
      "rocm": 150,
      "metal": 120,
      "cpu_x86": 50
    }
  }
}
EOF
}

run_classifier() {
    local fixture_root="$1"
    shift
    (cd "$fixture_root" && ./scripts/classify-hardware.sh --db "$fixture_root/config/gpu-database.json" "$@")
}

test_script_exists() {
    if [[ -f "$SOURCE_SCRIPT" ]]; then
        pass "classify-hardware.sh exists"
    else
        fail "classify-hardware.sh exists"
    fi
}

test_missing_db_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"

    local output
    local status=0
    output="$(cd "$fixture_root" && ./scripts/classify-hardware.sh --db "$fixture_root/config/missing.json" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "GPU database not found"; then
        pass "missing db fails"
    else
        fail "missing db fails"
    fi
}

test_known_gpu_match_prefers_device_id_and_name() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_gpu_db "$fixture_root"

    local output
    output="$(run_classifier "$fixture_root" \
        --platform-id linux \
        --gpu-vendor nvidia \
        --memory-type discrete \
        --vram-mb 24576 \
        --device-id 10de:2704 \
        --gpu-name "RTX 4090" \
        --cpu-name "Ryzen 9")"

    if echo "$output" | grep -q '"id": "nvidia_prosumer"' \
        && echo "$output" | grep -q '"tier": "T3"' \
        && echo "$output" | grep -q '"bandwidth_gbps": 1008'; then
        pass "known GPU match prefers device id and name"
    else
        fail "known GPU match prefers device id and name"
    fi
}

test_name_pattern_match_handles_strix_halo() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_gpu_db "$fixture_root"

    local output
    output="$(run_classifier "$fixture_root" \
        --platform-id linux \
        --gpu-vendor amd \
        --memory-type unified \
        --vram-mb 98304 \
        --gpu-name "AMD Radeon 8060S Graphics" \
        --cpu-name "Ryzen AI MAX+ 395 Strix Halo")"

    if echo "$output" | grep -q '"id": "strix_halo_large"' \
        && echo "$output" | grep -q '"memory_source": "ram"' \
        && echo "$output" | grep -q '"backend": "amd"'; then
        pass "name pattern match handles Strix Halo"
    else
        fail "name pattern match handles Strix Halo"
    fi
}

test_heuristic_fallback_applies_when_known_gpu_missing() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_gpu_db "$fixture_root"

    local output
    output="$(run_classifier "$fixture_root" \
        --platform-id linux \
        --gpu-vendor amd \
        --memory-type unified \
        --vram-mb 16384 \
        --ram-mb 65536 \
        --gpu-name "Radeon 780M" \
        --cpu-name "Ryzen 7")"

    if echo "$output" | grep -q '"id": "amd_unified_mid"' \
        && echo "$output" | grep -q '"tier": "SH_COMPACT"' \
        && echo "$output" | grep -q '"bandwidth_gbps": 120'; then
        pass "heuristic fallback applies when known gpu missing"
    else
        fail "heuristic fallback applies when known gpu missing"
    fi
}

test_unknown_gpu_falls_back_to_cpu_defaults() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_gpu_db "$fixture_root"

    local output
    output="$(run_classifier "$fixture_root" \
        --platform-id linux \
        --gpu-vendor unknown \
        --memory-type none \
        --vram-mb 0 \
        --gpu-name "Mystery Accelerator" \
        --cpu-name "EPYC")"

    if echo "$output" | grep -q '"id": "unknown"' \
        && echo "$output" | grep -q '"backend": "cpu"' \
        && echo "$output" | grep -q '"bandwidth_gbps": 50'; then
        pass "unknown gpu falls back to cpu defaults"
    else
        fail "unknown gpu falls back to cpu defaults"
    fi
}

test_env_mode_exports_hw_variables() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_gpu_db "$fixture_root"

    local output
    output="$(run_classifier "$fixture_root" \
        --platform-id linux \
        --gpu-vendor nvidia \
        --memory-type discrete \
        --vram-mb 24576 \
        --device-id 10de:2704 \
        --gpu-name "RTX 4090" \
        --cpu-name "Ryzen 9" \
        --env)"

    if echo "$output" | grep -q 'HW_CLASS_ID="nvidia_prosumer"' \
        && echo "$output" | grep -q 'HW_REC_BACKEND="nvidia"' \
        && echo "$output" | grep -q 'HW_REC_TIER="T3"' \
        && echo "$output" | grep -q 'HW_GPU_LABEL="RTX 4090"'; then
        pass "env mode exports HW variables"
    else
        fail "env mode exports HW variables"
    fi
}

test_script_references_known_gpu_and_heuristic_passes() {
    if grep -q 'known_gpus' "$SOURCE_SCRIPT" \
        && grep -q 'heuristic_classes' "$SOURCE_SCRIPT" \
        && grep -q 'device_ids' "$SOURCE_SCRIPT" \
        && grep -q 'name_patterns' "$SOURCE_SCRIPT"; then
        pass "script references known GPU and heuristic passes"
    else
        fail "script references known GPU and heuristic passes"
    fi
}

test_script_defines_overlay_map() {
    if grep -q 'OVERLAY_MAP' "$SOURCE_SCRIPT" \
        && grep -q 'docker-compose.nvidia.yml' "$SOURCE_SCRIPT" \
        && grep -q 'docker-compose.apple.yml' "$SOURCE_SCRIPT"; then
        pass "script defines overlay map"
    else
        fail "script defines overlay map"
    fi
}

echo "============================================================"
echo "classify-hardware.sh contract tests"
echo "============================================================"

test_script_exists
test_missing_db_fails
test_known_gpu_match_prefers_device_id_and_name
test_name_pattern_match_handles_strix_halo
test_heuristic_fallback_applies_when_known_gpu_missing
test_unknown_gpu_falls_back_to_cpu_defaults
test_env_mode_exports_hw_variables
test_script_references_known_gpu_and_heuristic_passes
test_script_defines_overlay_map

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ $FAIL -eq 0 ]]; then
    exit 0
fi

exit 1
