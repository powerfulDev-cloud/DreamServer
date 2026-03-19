#!/bin/bash
# Test suite for check-release-claims.sh
# Verifies release claim guardrails against fixture docs and manifest data.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="$ROOT_DIR/scripts/check-release-claims.sh"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

make_fixture_tree() {
    local fixture_root="$1"
    mkdir -p "$fixture_root/scripts" "$fixture_root/docs" "$fixture_root/bin"
    cp "$SOURCE_SCRIPT" "$fixture_root/scripts/check-release-claims.sh"
    chmod +x "$fixture_root/scripts/check-release-claims.sh"

    cat > "$fixture_root/bin/jq" <<'EOF'
#!/usr/bin/env python3
import json
import sys

args = sys.argv[1:]
raw = False
while args and args[0].startswith("-"):
    flag = args.pop(0)
    if flag == "-r":
        raw = True

expr = args[0]
path = args[1]
data = json.load(open(path, "r", encoding="utf-8"))

lookup = {
    '.compatibility.os.linux.supported': data["compatibility"]["os"]["linux"]["supported"],
    '.compatibility.os.windows_wsl2.supported': data["compatibility"]["os"]["windows_wsl2"]["supported"],
    '.compatibility.os.macos.supported': data["compatibility"]["os"]["macos"]["supported"],
    '.compatibility.os.windows_native.supported': data["compatibility"]["os"]["windows_native"]["supported"],
}

value = lookup[expr]
if isinstance(value, bool):
    print("true" if value else "false")
elif raw:
    print(value)
else:
    print(json.dumps(value))
EOF
    chmod +x "$fixture_root/bin/jq"
}

write_valid_docs() {
    local fixture_root="$1"

    cat > "$fixture_root/manifest.json" <<'EOF'
{
  "compatibility": {
    "os": {
      "linux": { "supported": true },
      "windows_wsl2": { "supported": true },
      "macos": { "supported": true },
      "windows_native": { "supported": false }
    }
  }
}
EOF

    cat > "$fixture_root/docs/SUPPORT-MATRIX.md" <<'EOF'
Windows (Docker Desktop + WSL2) Tier B
macOS (Apple Silicon) Tier B
Use install.ps1 for Windows setup.
EOF

    cat > "$fixture_root/docs/PLATFORM-TRUTH-TABLE.md" <<'EOF'
Windows (Docker Desktop + WSL2) Tier B
macOS Apple Silicon Tier B
Not safe to claim now
EOF
}

run_gate() {
    local fixture_root="$1"
    (cd "$fixture_root" && PATH="$fixture_root/bin:$PATH" ./scripts/check-release-claims.sh)
}

test_script_exists() {
    if [[ -f "$SOURCE_SCRIPT" ]]; then
        pass "check-release-claims.sh exists"
    else
        fail "check-release-claims.sh exists"
    fi
}

test_valid_claims_pass() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_valid_docs "$fixture_root"

    local output
    output="$(run_gate "$fixture_root")"

    if echo "$output" | grep -q "release claim gates"; then
        pass "valid claims pass"
    else
        fail "valid claims pass"
    fi
}

test_missing_manifest_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    mkdir -p "$fixture_root/docs"
    printf 'placeholder\n' > "$fixture_root/docs/SUPPORT-MATRIX.md"
    printf 'placeholder\n' > "$fixture_root/docs/PLATFORM-TRUTH-TABLE.md"

    local output
    local status=0
    output="$(run_gate "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "manifest.json missing"; then
        pass "missing manifest fails"
    else
        fail "missing manifest fails"
    fi
}

test_missing_support_matrix_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_valid_docs "$fixture_root"
    rm -f "$fixture_root/docs/SUPPORT-MATRIX.md"

    local output
    local status=0
    output="$(run_gate "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "docs/SUPPORT-MATRIX.md missing"; then
        pass "missing support matrix fails"
    else
        fail "missing support matrix fails"
    fi
}

test_manifest_linux_guard_fails_when_false() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_valid_docs "$fixture_root"
    python3 - <<'PY' "$fixture_root/manifest.json"
import json, sys
path = sys.argv[1]
data = json.load(open(path, 'r', encoding='utf-8'))
data["compatibility"]["os"]["linux"]["supported"] = False
json.dump(data, open(path, 'w', encoding='utf-8'), indent=2)
PY

    local output
    local status=0
    output="$(run_gate "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "manifest must mark linux supported"; then
        pass "manifest linux guard fails when false"
    else
        fail "manifest linux guard fails when false"
    fi
}

test_missing_windows_claim_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_valid_docs "$fixture_root"
    printf 'macOS (Apple Silicon) Tier B\ninstall.ps1\n' > "$fixture_root/docs/SUPPORT-MATRIX.md"

    local output
    local status=0
    output="$(run_gate "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "support matrix missing Windows Tier B claim"; then
        pass "missing windows claim fails"
    else
        fail "missing windows claim fails"
    fi
}

test_missing_macos_truth_table_claim_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_valid_docs "$fixture_root"
    printf 'Windows (Docker Desktop + WSL2) Tier B\nNot safe to claim now\n' > "$fixture_root/docs/PLATFORM-TRUTH-TABLE.md"

    local output
    local status=0
    output="$(run_gate "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "truth table missing macOS Tier B"; then
        pass "missing macOS truth table claim fails"
    else
        fail "missing macOS truth table claim fails"
    fi
}

test_missing_guardrails_section_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_valid_docs "$fixture_root"
    printf 'Windows (Docker Desktop + WSL2) Tier B\nmacOS Apple Silicon Tier B\n' > "$fixture_root/docs/PLATFORM-TRUTH-TABLE.md"

    local output
    local status=0
    output="$(run_gate "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "truth table missing launch guardrails section"; then
        pass "missing guardrails section fails"
    else
        fail "missing guardrails section fails"
    fi
}

test_script_references_all_release_claim_gates() {
    if grep -q 'wsl_supported' "$SOURCE_SCRIPT" \
        && grep -q 'macos_supported' "$SOURCE_SCRIPT" \
        && grep -q 'Windows installer reference' "$SOURCE_SCRIPT" \
        && grep -q 'Not safe to claim now' "$SOURCE_SCRIPT"; then
        pass "script references all release claim gates"
    else
        fail "script references all release claim gates"
    fi
}

test_fixture_uses_portable_jq_stub() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN
    make_fixture_tree "$fixture_root"
    write_valid_docs "$fixture_root"

    if [[ "$("$fixture_root/bin/jq" -r '.compatibility.os.macos.supported' "$fixture_root/manifest.json")" == "true" ]]; then
        pass "fixture uses portable jq stub"
    else
        fail "fixture uses portable jq stub"
    fi
}

echo "============================================================"
echo "check-release-claims.sh contract tests"
echo "============================================================"

test_script_exists
test_valid_claims_pass
test_missing_manifest_fails
test_missing_support_matrix_fails
test_manifest_linux_guard_fails_when_false
test_missing_windows_claim_fails
test_missing_macos_truth_table_claim_fails
test_missing_guardrails_section_fails
test_script_references_all_release_claim_gates
test_fixture_uses_portable_jq_stub

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ $FAIL -eq 0 ]]; then
    exit 0
fi

exit 1
