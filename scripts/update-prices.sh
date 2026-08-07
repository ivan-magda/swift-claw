#!/usr/bin/env bash
# Source:      https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json
# License:     MIT — LiteLLM by BerriAI (https://github.com/BerriAI/litellm)
# Regenerate:  scripts/update-prices.sh  (from the repo root)
# Generated:   2026-06-22

set -euo pipefail

SOURCE_URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
OUTPUT="Sources/ClawLLM/Pricing/Prices.json"

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT")"

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
' > "$OUTPUT"

MODEL_COUNT=$(jq 'length' "$OUTPUT")
FILE_SIZE=$(wc -c < "$OUTPUT")
FILE_SIZE_KB=$(echo "scale=1; $FILE_SIZE / 1024" | bc)

echo "Done."
echo "  Models: $MODEL_COUNT"
echo "  Output: $OUTPUT ($FILE_SIZE_KB KB)"
