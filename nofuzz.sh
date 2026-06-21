#!/usr/bin/env bash
# simple-dirb.sh - minimal curl-based directory brute forcer
# Usage: ./simple-dirb.sh <base_url> <wordlist_file> [extensions]
# Example: ./simple-dirb.sh https://name-virt-host.owasp.org/javascript/ /tmp/mini.txt "js,php"

set -uo pipefail

BASE_URL="${1:?Usage: $0 <base_url> <wordlist> [ext1,ext2,...]}"
WORDLIST="${2:?Usage: $0 <base_url> <wordlist> [ext1,ext2,...]}"
EXTS="${3:-}"
THREADS="${THREADS:-10}"          # override with: THREADS=20 ./simple-dirb.sh ...
DELAY="${DELAY:-0}"                # seconds between requests per worker
TIMEOUT="${TIMEOUT:-10}"
USER_AGENT="${USER_AGENT:-Mozilla/5.0 (X11; Linux x86_64) curl-dirb/1.0}"

[[ "$BASE_URL" != */ ]] && BASE_URL="${BASE_URL}/"
[[ -f "$WORDLIST" ]] || { echo "Wordlist not found: $WORDLIST" >&2; exit 1; }

OUTFILE="dirb_results_$(date +%Y%m%d_%H%M%S).txt"
echo "Target: $BASE_URL"
echo "Wordlist: $WORDLIST ($(wc -l < "$WORDLIST") lines)"
echo "Output: $OUTFILE"
echo "---"

# Build the full list of paths to test (with extensions if given)
build_paths() {
    while IFS= read -r word; do
        [[ -z "$word" ]] && continue
        echo "$word"
        if [[ -n "$EXTS" ]]; then
            IFS=',' read -ra EXT_ARR <<< "$EXTS"
            for ext in "${EXT_ARR[@]}"; do
                echo "${word}.${ext}"
            done
        fi
    done < "$WORDLIST"
}

check_path() {
    local path="$1"
    local url="${BASE_URL}${path}"
    local response
    response=$(curl -s -o /dev/null -w "%{http_code} %{size_download} %{time_total}" \
        --max-time "$TIMEOUT" \
        -A "$USER_AGENT" \
        "$url" 2>/dev/null)

    local code size time
    read -r code size time <<< "$response"

    if [[ -z "$code" || "$code" == "000" ]]; then
        echo "[ERR ] $url (connection failed/timeout)"
    else
        echo "[$code] ${size}B ${time}s $url" | tee -a "$OUTFILE"
    fi

    [[ "$DELAY" != "0" ]] && sleep "$DELAY"
}

export -f check_path
export BASE_URL TIMEOUT USER_AGENT DELAY OUTFILE

build_paths | xargs -P "$THREADS" -I{} bash -c 'check_path "$@"' _ {}

echo "---"
echo "Done. Full results in $OUTFILE"
