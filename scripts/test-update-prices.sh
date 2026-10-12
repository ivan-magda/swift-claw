#!/usr/bin/env bash
# Exercise regeneration offline through its download boundary.
set -euo pipefail
repository_root=$(cd "$(dirname "$0")/.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/swift-claw-prices-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

fail() {
  printf 'price refresh: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$scratch/bin" "$scratch/Sources/ClawLLM/Pricing"
cat > "$scratch/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${!#}" in
  https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json)
    source_file="$PRICE_TEST_ROOT/litellm.json" ;;
  'https://openrouter.ai/api/v1/models?output_modalities=all')
    source_file="$PRICE_TEST_ROOT/openrouter.json" ;;
  *) exit 99 ;;
esac
cat "$source_file"
# Simulate a transfer that delivers valid JSON but then fails.
[[ "${PRICE_TEST_FAIL:-}" != "$source_file" ]]
STUB
chmod +x "$scratch/bin/curl"
export PATH="$scratch/bin:$PATH"
export PRICE_TEST_ROOT="$scratch"
cd "$scratch"
output=Sources/ClawLLM/Pricing/Prices.json

# given: old OpenRouter rows in both the snapshot and LiteLLM, plus a current Models API feed.
cat > "$output" <<'JSON'
{
  "openrouter/vendor/model": {"inputUSDPerMTok": 1, "outputUSDPerMTok": 2},
  "openrouter/retired": {"inputUSDPerMTok": 1, "outputUSDPerMTok": 2}
}
JSON
cat > litellm.json <<'JSON'
{
  "gpt-4o": {"input_cost_per_token": 0.0000025, "output_cost_per_token": 0.00001},
  "openrouter/vendor/model": {"input_cost_per_token": 1, "output_cost_per_token": 1},
  "openrouter/retired": {"input_cost_per_token": 1, "output_cost_per_token": 1},
  "sample_spec": {"input_cost_per_token": 1, "output_cost_per_token": 1},
  "metadata-only": {"max_tokens": 100}
}
JSON
cat > openrouter.json <<'JSON'
{"total_count": 3, "links": {"next": null}, "data": [
  {"id": "vendor/model", "pricing": {"prompt": "0.0000004", "completion": "0.000003"}},
  {"id": "vendor/free", "pricing": {"prompt": "0", "completion": "0"}},
  {"id": "openrouter/auto", "pricing": {"prompt": "-1", "completion": "-1"}}
]}
JSON

# when: the weekly refresh merges the two sources.
bash "$repository_root/scripts/update-prices.sh" summary.md

# then: OpenRouter owns its namespace, obsolete rows disappear, and free prices remain valid.
jq -e '
  . == {
    "gpt-4o": {inputUSDPerMTok: 2.5, outputUSDPerMTok: 10},
    "openrouter/vendor/model": {inputUSDPerMTok: 0.4, outputUSDPerMTok: 3},
    "openrouter/vendor/free": {inputUSDPerMTok: 0, outputUSDPerMTok: 0}
  }
' "$output" > /dev/null
grep -q -- '- Removed: 1' summary.md
grep -q 'openrouter/retired' summary.md
cp "$output" previous.json
cp summary.md previous-summary.md
cp litellm.json valid-litellm.json
cp openrouter.json valid-openrouter.json

assert_rejected() {
  if bash "$repository_root/scripts/update-prices.sh" summary.md > refresh.log 2>&1; then
    fail "accepted $1"
  fi
  cmp "$output" previous.json
  cmp summary.md previous-summary.md
}

# given/when/then: either failed download must preserve both existing outputs.
for provider in litellm openrouter; do
  export PRICE_TEST_FAIL="$scratch/$provider.json"
  assert_rejected "$provider download failure"
done
unset PRICE_TEST_FAIL

# given/when/then: malformed, empty or structurally invalid feeds cannot publish partial tables.
for provider in litellm openrouter; do
  for invalid in '' '{' '{}' '[]'; do
    printf '%s\n' "$invalid" > "$provider.json"
    assert_rejected "$provider invalid response: $invalid"
  done
  cp "valid-$provider.json" "$provider.json"
done

# given/when/then: distinct API boundary faults must fail before replacing the snapshot.
for mutation in \
  '.data = [] | .total_count = 0' \
  '.data[0].pricing.prompt = "invalid"' \
  '.data[0].pricing.completion = null' \
  '.data[0].pricing.prompt = "1e999"' \
  '.data[0].pricing.prompt = "-2"' \
  '.data[0].id = ""' \
  '.data[1].id = .data[0].id' \
  '.total_count += 1' \
  'del(.total_count)' \
  'del(.links)' \
  'del(.links.next)' \
  '.links.next = "https://openrouter.ai/api/v1/models?offset=3"'; do
  jq "$mutation" valid-openrouter.json > openrouter.json
  assert_rejected "OpenRouter mutation: $mutation"
done
cp valid-openrouter.json openrouter.json

# given/when/then: invalid numeric LiteLLM rates and no usable rates also reject the refresh.
for mutation in \
  '.["gpt-4o"].input_cost_per_token = -1' \
  'del(.["gpt-4o"])'; do
  jq "$mutation" valid-litellm.json > litellm.json
  assert_rejected "LiteLLM mutation: $mutation"
done
printf 'Price refresh checks passed.\n'
