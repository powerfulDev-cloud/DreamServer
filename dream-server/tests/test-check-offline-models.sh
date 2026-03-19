#!/bin/bash
# Test suite for check-offline-models.sh
# Verifies offline asset detection across model directories.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="$ROOT_DIR/scripts/check-offline-models.sh"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

make_fixture_tree() {
    local fixture_root="$1"
    mkdir -p "$fixture_root/scripts" "$fixture_root/data"
    cp "$SOURCE_SCRIPT" "$fixture_root/scripts/check-offline-models.sh"
    chmod +x "$fixture_root/scripts/check-offline-models.sh"
}

run_check() {
    local fixture_root="$1"
    (cd "$fixture_root" && ./scripts/check-offline-models.sh)
}

test_script_exists() {
    if [[ -f "$SOURCE_SCRIPT" ]]; then
        pass "check-offline-models.sh exists"
    else
        fail "check-offline-models.sh exists"
    fi
}

test_missing_everything_fails() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"

    local output
    local status=0
    output="$(run_check "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] \
        && echo "$output" | grep -q "LLM model (GGUF) - MISSING" \
        && echo "$output" | grep -q "Whisper base - MISSING" \
        && echo "$output" | grep -q "Missing models: 4"; then
        pass "missing everything fails"
    else
        fail "missing everything fails"
    fi
}

test_detects_gguf_model() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    mkdir -p "$fixture_root/data/models"
    printf 'gguf\n' > "$fixture_root/data/models/Qwen3-8B-Q4_K_M.gguf"

    local output
    local status=0
    output="$(run_check "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] \
        && echo "$output" | grep -q "LLM model: Qwen3-8B-Q4_K_M.gguf" \
        && echo "$output" | grep -q "Whisper base - MISSING"; then
        pass "detects gguf model"
    else
        fail "detects gguf model"
    fi
}

test_detects_primary_whisper_layout() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    mkdir -p "$fixture_root/data/models" "$fixture_root/data/whisper/faster-whisper-base"
    printf 'gguf\n' > "$fixture_root/data/models/model.gguf"

    local output
    local status=0
    output="$(run_check "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "Whisper base (STT)"; then
        pass "detects primary whisper layout"
    else
        fail "detects primary whisper layout"
    fi
}

test_detects_huggingface_whisper_layout() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    mkdir -p "$fixture_root/data/models" "$fixture_root/data/whisper/models--Systran--faster-whisper-base"
    printf 'gguf\n' > "$fixture_root/data/models/model.gguf"

    local output
    local status=0
    output="$(run_check "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "Whisper base (STT)"; then
        pass "detects huggingface whisper layout"
    else
        fail "detects huggingface whisper layout"
    fi
}

test_detects_kokoro_voice_file() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    mkdir -p "$fixture_root/data/models" "$fixture_root/data/kokoro/voices"
    printf 'gguf\n' > "$fixture_root/data/models/model.gguf"
    printf 'voice\n' > "$fixture_root/data/kokoro/voices/af_heart.pt"

    local output
    local status=0
    output="$(run_check "$fixture_root" 2>&1)" || status=$?

    if [[ $status -ne 0 ]] && echo "$output" | grep -q "Kokoro voice af_heart (TTS)"; then
        pass "detects kokoro voice file"
    else
        fail "detects kokoro voice file"
    fi
}

test_detects_both_embedding_layouts() {
    local fixture_root_one
    fixture_root_one="$(mktemp -d)"
    trap 'rm -rf "$fixture_root_one"' RETURN

    make_fixture_tree "$fixture_root_one"
    mkdir -p "$fixture_root_one/data/models" "$fixture_root_one/data/embeddings/BAAI/bge-base-en-v1.5"
    printf 'gguf\n' > "$fixture_root_one/data/models/model.gguf"
    local output_one
    local status_one=0
    output_one="$(run_check "$fixture_root_one" 2>&1)" || status_one=$?

    local fixture_root_two
    fixture_root_two="$(mktemp -d)"
    trap 'rm -rf "$fixture_root_one" "$fixture_root_two"' RETURN

    make_fixture_tree "$fixture_root_two"
    mkdir -p "$fixture_root_two/data/models" "$fixture_root_two/data/embeddings/models--BAAI--bge-base-en-v1.5"
    printf 'gguf\n' > "$fixture_root_two/data/models/model.gguf"
    local output_two
    local status_two=0
    output_two="$(run_check "$fixture_root_two" 2>&1)" || status_two=$?

    if [[ $status_one -ne 0 && $status_two -ne 0 ]] \
        && echo "$output_one" | grep -q "BGE base embeddings (RAG)" \
        && echo "$output_two" | grep -q "BGE base embeddings (RAG)"; then
        pass "detects both embedding layouts"
    else
        fail "detects both embedding layouts"
    fi
}

test_all_assets_present_returns_ready() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    trap 'rm -rf "$fixture_root"' RETURN

    make_fixture_tree "$fixture_root"
    mkdir -p \
        "$fixture_root/data/models" \
        "$fixture_root/data/whisper/faster-whisper-base" \
        "$fixture_root/data/kokoro/voices" \
        "$fixture_root/data/embeddings/BAAI/bge-base-en-v1.5"
    printf 'gguf\n' > "$fixture_root/data/models/Qwen3-8B-Q4_K_M.gguf"
    printf 'voice\n' > "$fixture_root/data/kokoro/voices/af_heart.pt"

    local output
    output="$(run_check "$fixture_root")"

    if echo "$output" | grep -q "All models present. Ready for offline mode"; then
        pass "all assets present returns ready"
    else
        fail "all assets present returns ready"
    fi
}

test_script_lists_manual_download_ids() {
    if grep -q 'gguf-model' "$SOURCE_SCRIPT" \
        && grep -q 'whisper-base' "$SOURCE_SCRIPT" \
        && grep -q 'kokoro-af_heart' "$SOURCE_SCRIPT" \
        && grep -q 'bge-base-en-v1.5' "$SOURCE_SCRIPT"; then
        pass "script lists manual download ids"
    else
        fail "script lists manual download ids"
    fi
}

test_script_checks_expected_paths() {
    if grep -q 'data/models/\*.gguf' "$SOURCE_SCRIPT" \
        && grep -q 'data/whisper/faster-whisper-base' "$SOURCE_SCRIPT" \
        && grep -q 'data/kokoro/voices/af_heart.pt' "$SOURCE_SCRIPT" \
        && grep -q 'data/embeddings/BAAI/bge-base-en-v1.5' "$SOURCE_SCRIPT"; then
        pass "script checks expected paths"
    else
        fail "script checks expected paths"
    fi
}

echo "============================================================"
echo "check-offline-models.sh contract tests"
echo "============================================================"

test_script_exists
test_missing_everything_fails
test_detects_gguf_model
test_detects_primary_whisper_layout
test_detects_huggingface_whisper_layout
test_detects_kokoro_voice_file
test_detects_both_embedding_layouts
test_all_assets_present_returns_ready
test_script_lists_manual_download_ids
test_script_checks_expected_paths

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ $FAIL -eq 0 ]]; then
    exit 0
fi

exit 1
