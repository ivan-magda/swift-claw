#!/usr/bin/env bash
# Source:      https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json
# License:     MIT — LiteLLM by BerriAI (https://github.com/BerriAI/litellm)
# Regenerate:  scripts/update-prices.sh [SUMMARY_FILE]  (from the repo root)
#
# With SUMMARY_FILE, also writes a Markdown summary of the change against the previous table:
# how many entries were added, repriced and removed, with the removed and repriced keys listed.
# A removed entry can leave a configured model without a price, so review removals before merging.

set -euo pipefail

SOURCE_URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
OUTPUT="Sources/ClawLLM/Pricing/Prices.json"
SUMMARY="${1:-}"
# Longest list the summary prints per section, so a large refresh still fits a pull request body.
LIST_LIMIT=200

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT")"

PREVIOUS="$(mktemp)"
GENERATED="$(mktemp)"
trap 'rm -f "$PREVIOUS" "$GENERATED"' EXIT
if [ -f "$OUTPUT" ]; then
  cp "$OUTPUT" "$PREVIOUS"
else
  echo '{}' > "$PREVIOUS"
fi

echo "Downloading price data from LiteLLM..."
curl --fail --silent --show-error "$SOURCE_URL" | jq '
  # Remove the sample_spec documentation entry
  del(.sample_spec)
  # Keep only entries where both input and output cost per token are numbers
  | with_entries(
      select(
        (.value.input_cost_per_token | type) == "number"
        and (.value.output_cost_per_token | type) == "number"
      )
    )
  # Transform: convert per-token to per-million-tokens, round to 6 decimal places
  | with_entries({
      key: .key,
      value: {
        inputUSDPerMTok:  ((.value.input_cost_per_token  * 1000000 * 1000000 | round) / 1000000),
        outputUSDPerMTok: ((.value.output_cost_per_token * 1000000 * 1000000 | round) / 1000000)
      }
    })
  # Sort keys for stable, diff-friendly output
  | to_entries | sort_by(.key) | from_entries
' > "$GENERATED"

MODEL_COUNT=$(jq 'length' "$GENERATED")
# An upstream format change would filter out every entry; never replace the table with nothing.
if [ "$MODEL_COUNT" -eq 0 ]; then
  echo "error: the regenerated price table is empty; keeping $OUTPUT" >&2
  exit 1
fi
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
    "Regenerated `Sources/ClawLLM/Pricing/Prices.json` from LiteLLM.",
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
