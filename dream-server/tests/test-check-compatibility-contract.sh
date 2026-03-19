#!/bin/bash
# Test suite for check-compatibility.sh
# Validates manifest compatibility contract checks with fixture manifests.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="$ROOT_DIR/scripts/check-compatibility.sh"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

make_fixture_tree() {
    local fixture_root="$1"
    mkdir -p "$fixture_root/scripts" "$fixture_root/docs" "$fixture_root/contracts" "$fixture_root/workflows" "$fixture_root/schemas" "$fixture_root/bin"
    cp "$SOURCE_SCRIPT" "$fixture_root/scripts/check-compatibility.sh"
    chmod +x "$fixture_root/scripts/check-compatibility.sh"

    cat > "$fixture_root/bin/jq" <<'EOF'
#!/usr/bin/env python3
import json
import sys

args = sys.argv[1:]
raw = False
exit_mode = False
while args and args[0].startswith("-"):
    flag = args.pop(0)
    if flag == "-r":
        raw = True
    elif flag == "-e":
        exit_mode = True

expr = args[0]
path = args[1]
data = json.load(open(path, "r", encoding="utf-8"))

def emit(value):
    if exit_mode:
        ok = bool(value)
        if raw and isinstance(value, str):
            print(value)
        elif raw and value is not None and not isinstance(value, bool):
            print(value)
        elif not isinstance(value, bool) and value is not None:
            print(json.dumps(value))
        raise SystemExit(0 if ok else 1)
    if raw and isinstance(value, str):
        print(value)
    else:
        print(json.dumps(value) if not isinstance(value, str) else value)

if expr == '.manifestVersion and .release.version and .compatibility and .contracts':
    emit(bool(data.get("manifestVersion") and data.get("release", {}).get("version") and data.get("compatibility") and data.get("contracts")))
elif expr == '.contracts.compose.canonical[]':
    for item in data["contracts"]["compose"]["canonical"]:
        print(item)
elif expr == '.contracts.workflowCatalog.canonicalPath':
    emit(data["contracts"]["workflowCatalog"]["canonicalPath"])
elif expr == '.contracts.extensions.serviceManifestSchema':
    emit(data["contracts"]["extensions"]["serviceManifestSchema"])
elif expr == '.contracts.ports.canonicalPath':
    emit(data["contracts"]["ports"]["canonicalPath"])
elif expr == '.version and (.ports | type=="array" and length>0)':
    emit(bool(data.get("version") and isinstance(data.get("ports"), list) and len(data.get("ports")) > 0))
elif expr == '.compatibility.os.macos.supported == false':
    emit(data.get("compatibility", {}).get("os", {}).get("macos", {}).get("supported") is False)
else:
    raise SystemExit(f"unsupported jq expression: {expr}")
EOF
    chmod +x "$fixture_root/bin/jq"
}

write_valid_manifest() {
    local fixture_root="$1"

    cat > "$fixture_root/manifest.json" <<'EOF'
{
  "manifestVersion": 1,
  "release": { "version": "2.0.0" },
  "compatibility": {
    "os": {
      "linux": { "supported": true },
      "windows_wsl2": { "supported": true },
      "macos": { "supported": true },
      "windows_native": { "supported": false }
    }
  },
  "contracts": {
    "compose": {
      "canonical": [
        "contracts/docker-compose.base.yml",
        "contracts/docker-compose.nvidia.yml"
      ]
    },
    "workflowCatalog": { "canonicalPath": "workflows/catalog.json" },
    "extensions": { "serviceManifestSchema": "schemas/service-manifest.schema.json" },
    "ports": { "canonicalPath": "contracts/ports.json" }
  }
}
EOF

    mkdir -p "$fixture_root/contracts"
    printf 'services:\n  app:\n    image: test\n' > "$fixture_root/contracts/docker-compose.base.yml"
    printf 'services:\n  gpu:\n    image: test\n' > "$fixture_root/contracts/docker-compose.nvidia.yml"
    printf '{"workflows":[]}\n' > "$fixture_root/workflows/catalog.json"
    printf '{"type":"object"}\n' > "$fixture_root/schemas/service-manifest.schema.json"
    printf '{"version":"1","ports":[{"id":"webui","port":3000}]}\n' > "$fixture_root/contracts/ports.json"

    cat > "$fixture_root/docs/SUPPORT-MATRIX.md" <<'EOF'
Linux Tier A
Windows (Docker Desktop + WSL2) Tier B
macOS (Apple Silicon) Tier B
install.ps1
EOF

    cat > "$fixture_root/docs/PLATFORM-TRUTH-TABLE.md" <<'EOF'
Windows (Docker Desktop + WSL2) Tier B
macOS Apple Silicon Tier B
Not safe to claim now
EOF
}

run_check() {
    local fixture_root="$1"
    shift
    (cd "$fixture_root" && PATH="$fixture_root/bin:$PATH" ./scripts/check-compatibility.sh "$@")
}

test_script_exists() {
    if [[ -f "$SOURCE_SCRIPT" ]]; then
        pass "check-compatibility.sh exists"
    else
        fail "check-compatibility.sh exists"
    fi
}

test_valid_fixture_passes() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_valid_manifest "$fixture_root"

    local output
    output="$(run_check "$fixture_root")"

    if echo "$output" | grep -q "manifest structure" \
        && echo "$output" | grep -q "ports contract" \
        && echo "$output" | grep -q "compatibility check complete"; then
        pass "valid fixture passes"
    else
        fail "valid fixture passes"
    fi
}

test_missing_manifest_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    mkdir -p "$fixture_root/docs"

    local output
    local status=0
    output="$(run_check "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "manifest.json not found"; then
        pass "missing manifest fails"
    else
        fail "missing manifest fails"
    fi
}

test_missing_compose_contract_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_valid_manifest "$fixture_root"
    rm -f "$fixture_root/contracts/docker-compose.nvidia.yml"

    local output
    local status=0
    output="$(run_check "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "missing compose contract file"; then
        pass "missing compose contract fails"
    else
        fail "missing compose contract fails"
    fi
}

test_invalid_ports_structure_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_valid_manifest "$fixture_root"
    printf '{"version":"1","ports":[]}\n' > "$fixture_root/contracts/ports.json"

    local output
    local status=0
    output="$(run_check "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "invalid ports contract structure"; then
        pass "invalid ports structure fails"
    else
        fail "invalid ports structure fails"
    fi
}

test_missing_workflow_catalog_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_valid_manifest "$fixture_root"
    rm -f "$fixture_root/workflows/catalog.json"

    local output
    local status=0
    output="$(run_check "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "missing canonical workflow catalog"; then
        pass "missing workflow catalog fails"
    else
        fail "missing workflow catalog fails"
    fi
}

test_warns_when_docs_claims_look_stale() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_valid_manifest "$fixture_root"
    python3 - <<'PY' "$fixture_root/manifest.json"
import json, sys
path = sys.argv[1]
data = json.load(open(path, 'r', encoding='utf-8'))
data["compatibility"]["os"]["macos"]["supported"] = False
json.dump(data, open(path, 'w', encoding='utf-8'), indent=2)
PY
    printf 'Linux only\n' > "$fixture_root/docs/SUPPORT-MATRIX.md"

    local output
    output="$(run_check "$fixture_root")"

    if echo "$output" | grep -q "\[WARN\]" && echo "$output" | grep -q "compatibility check complete"; then
        pass "warns when docs claims look stale"
    else
        fail "warns when docs claims look stale"
    fi
}

test_script_references_all_expected_contracts() {
    if grep -q 'workflowCatalog.canonicalPath' "$SOURCE_SCRIPT" \
        && grep -q 'serviceManifestSchema' "$SOURCE_SCRIPT" \
        && grep -q 'contracts.compose.canonical' "$SOURCE_SCRIPT" \
        && grep -q 'contracts.ports.canonicalPath' "$SOURCE_SCRIPT"; then
        pass "script references all expected contracts"
    else
        fail "script references all expected contracts"
    fi
}

test_script_has_guard_for_jq() {
    if grep -q 'jq is required' "$SOURCE_SCRIPT"; then
        pass "script has guard for jq"
    else
        fail "script has guard for jq"
    fi
}

test_fixture_provides_portable_jq_stub() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    write_valid_manifest "$fixture_root"

    if "$fixture_root/bin/jq" -r '.contracts.workflowCatalog.canonicalPath' "$fixture_root/manifest.json" | grep -q 'workflows/catalog.json'; then
        pass "fixture provides portable jq stub"
    else
        fail "fixture provides portable jq stub"
    fi
}

echo "============================================================"
echo "check-compatibility.sh contract tests"
echo "============================================================"

test_script_exists
test_valid_fixture_passes
test_missing_manifest_fails
test_missing_compose_contract_fails
test_invalid_ports_structure_fails
test_missing_workflow_catalog_fails
test_warns_when_docs_claims_look_stale
test_script_references_all_expected_contracts
test_script_has_guard_for_jq
test_fixture_provides_portable_jq_stub

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ $FAIL -eq 0 ]]; then
    exit 0
fi

exit 1
