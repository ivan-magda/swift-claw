#!/usr/bin/env bash
# Sources:     LiteLLM (MIT): https://github.com/BerriAI/litellm
#              OpenRouter Models API: https://openrouter.ai/api/v1/models
# Regenerate:  scripts/update-prices.sh [SUMMARY_FILE]  (from the repo root)
#
# With SUMMARY_FILE, also writes a Markdown summary of the change against the previous table:
# how many entries were added, repriced and removed, with the removed and repriced keys listed.
# A removed entry can leave a configured model without a price, so review removals before merging.

set -euo pipefail

LITELLM_URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
OPENROUTER_URL="https://openrouter.ai/api/v1/models?output_modalities=all"
OUTPUT="Sources/ClawLLM/Pricing/Prices.json"
SUMMARY="${1:-}"
# Longest list the summary prints per section, so a large refresh still fits a pull request body.
LIST_LIMIT=200

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT")"

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
PREVIOUS="$SCRATCH/previous.json"
GENERATED="$SCRATCH/generated.json"
if [ -f "$OUTPUT" ]; then
  cp "$OUTPUT" "$PREVIOUS"
else
  echo '{}' > "$PREVIOUS"
fi

echo "Downloading price data from LiteLLM and OpenRouter..."
curl --fail --silent --show-error --connect-timeout 15 --max-time 60 \
  "$LITELLM_URL" > "$SCRATCH/litellm.json"
# Omitting offset and limit requests the complete catalog; include non-text models too.
curl --fail --silent --show-error --connect-timeout 15 --max-time 60 \
  "$OPENROUTER_URL" > "$SCRATCH/openrouter.json"

jq -n --slurpfile litellm "$SCRATCH/litellm.json" \
  --slurpfile openrouter "$SCRATCH/openrouter.json" '
  def mtok:
    if type != "number" or isinfinite or isnan or . < 0 then
      error("invalid token price")
    else
      (. * 1000000 * 1000000 | round) / 1000000
      | if isinfinite or isnan then error("token price overflow") else . end
    end;
  def router_rate:
    if type != "string" then error("OpenRouter price must be a string") else tonumber end
    | if isinfinite or isnan or (. < 0 and . != -1) then
        error("invalid OpenRouter token price")
      else . end;
  if ($litellm | length) != 1 or ($litellm[0] | type) != "object" then
    error("invalid LiteLLM catalog")
  else $litellm[0] end
  | del(.sample_spec)
  # OpenRouter is authoritative for its namespace, including removals.
  | with_entries(select(.key | startswith("openrouter/") | not))
  | with_entries(select(
      (.value.input_cost_per_token | type) == "number"
      and (.value.output_cost_per_token | type) == "number"
    ))
  | with_entries({key: .key, value: {
      inputUSDPerMTok: (.value.input_cost_per_token | mtok),
      outputUSDPerMTok: (.value.output_cost_per_token | mtok)
    }})
  | if length == 0 then error("empty LiteLLM price table") else . end
  | . as $base
  | if ($openrouter | length) != 1 or ($openrouter[0].data | type) != "array" then
      error("invalid OpenRouter catalog")
    else $openrouter[0] end
  | if (.links | type) != "object" then
      error("missing OpenRouter pagination metadata")
    else . end
  | if (.links | has("next") | not) or .links.next != null
      or .total_count != (.data | length) then
      error("incomplete OpenRouter catalog")
    else .data end
  | map(
      if (.id | type) != "string" or .id == "" then
        error("invalid OpenRouter model id")
      else . end
      | {key: ("openrouter/" + .id), value: {
          inputUSDPerMTok: (.pricing.prompt | router_rate),
          outputUSDPerMTok: (.pricing.completion | router_rate)
        }}
    )
  | if (map(.key) | unique | length) != length then
      error("duplicate OpenRouter model id")
    else . end
  # A -1 rate marks variable pricing, not a usable fixed token price.
  | map(select(.value.inputUSDPerMTok >= 0 and .value.outputUSDPerMTok >= 0))
  | map(.value |= with_entries(.value |= mtok))
  | if length == 0 then error("empty OpenRouter price table") else from_entries end
  | $base + .
  | to_entries | sort_by(.key) | from_entries
' > "$GENERATED"

MODEL_COUNT=$(jq 'length' "$GENERATED")
mv "$GENERATED" "$OUTPUT"

FILE_SIZE=$(wc -c < "$OUTPUT")
FILE_SIZE_KB=$(awk -v bytes="$FILE_SIZE" 'BEGIN { printf "%.1f", bytes / 1024 }')

echo "Done."
echo "  Models: $MODEL_COUNT"
echo "  Output: $OUTPUT ($FILE_SIZE_KB KB)"

if [ -n "$SUMMARY" ]; then
  jq -r -n \
    --slurpfile old "$PREVIOUS" \
    --slurpfile new "$OUTPUT" \
    --argjson limit "$LIST_LIMIT" '
    ($old[0]) as $o
    | ($new[0]) as $n
    | [$n | keys[] | select($o[.] == null)] as $added
    | [$o | keys[] | select($n[.] == null)] as $removed
    | [$n | keys[] | select($o[.] != null and $o[.] != $n[.])] as $repriced
    | def more($list): if ($list | length) > $limit
        then "- and \(($list | length) - $limit) more" else empty end;
    "Regenerated `Sources/ClawLLM/Pricing/Prices.json` from LiteLLM and the OpenRouter Models API.",
    "",
    "- Added: \($added | length)",
    "- Repriced: \($repriced | length)",
    "- Removed: \($removed | length)",
    (if ($removed | length) > 0 then
      "",
      "A route whose model lost its entry falls back to the reference-rate estimate. After merging,"
        + " run `clawd doctor` and check the `spend.primary_price` and `spend.fallback_price` rows.",
      "",
      "<details><summary>Removed entries</summary>",
      "",
      ($removed[:$limit][] | "- `\(.)`"),
      more($removed),
      "",
      "</details>"
    else empty end),
    (if ($repriced | length) > 0 then
      "",
      "<details><summary>Repriced entries (USD per 1M tokens, input/output)</summary>",
      "",
      ($repriced[:$limit][] as $key
        | "- `\($key)`: \($o[$key].inputUSDPerMTok)/\($o[$key].outputUSDPerMTok)"
          + " to \($n[$key].inputUSDPerMTok)/\($n[$key].outputUSDPerMTok)"),
      more($repriced),
      "",
      "</details>"
    else empty end)
  ' > "$SUMMARY"
  echo "  Summary: $SUMMARY"
fi
