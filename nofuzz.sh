#!/usr/bin/env bash
# simple-dirb.sh — minimal curl-based directory brute forcer
# Usage: ./simple-dirb.sh <base_url> <wordlist_file> [options]
#
# Options:
#   -e, --ext EXT1,EXT2        Extensions to append (skips if word already has that ext)
#   -t, --threads N            Concurrent workers (default 10)
#   -d, --delay SEC            Delay per request (default 0)
#   -T, --timeout SEC          Per-request timeout (default 10)
#   -A, --user-agent STR       Custom User-Agent
#   -X, --method METHOD        HTTP method (default GET)
#   -x, --exclude-status CODES Comma list to hide (e.g. 403,404)
#   -m, --match-status CODES   Comma list to ONLY show (overrides exclude)
#   -L, --follow-redirects     Follow redirects (curl -L)
#   -k, --insecure             Skip TLS verification
#   -s, --sample N             Randomly sample N words instead of running the full list
#
# Example:
#   ./simple-dirb.sh https://name-virt-host.owasp.org/javascript/ wordlist.txt -s 500 -e js
set -uo pipefail

BASE_URL="${1:?Usage: $0 <base_url> <wordlist> [options]}"
WORDLIST="${2:?Usage: $0 <base_url> <wordlist> [options]}"
shift 2

EXTS="" THREADS=10 DELAY=0 TIMEOUT=10 SAMPLE=0
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) curl-dirb/1.4"
METHOD="GET" EXCLUDE_STATUS="" MATCH_STATUS="" FOLLOW_REDIRECTS=0 INSECURE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--ext) EXTS="$2"; shift 2 ;;
        -t|--threads) THREADS="$2"; shift 2 ;;
        -d|--delay) DELAY="$2"; shift 2 ;;
        -T|--timeout) TIMEOUT="$2"; shift 2 ;;
        -A|--user-agent) USER_AGENT="$2"; shift 2 ;;
        -X|--method) METHOD="$2"; shift 2 ;;
        -x|--exclude-status) EXCLUDE_STATUS="$2"; shift 2 ;;
        -m|--match-status) MATCH_STATUS="$2"; shift 2 ;;
        -L|--follow-redirects) FOLLOW_REDIRECTS=1; shift ;;
        -k|--insecure) INSECURE=1; shift ;;
        -s|--sample) SAMPLE="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ "$BASE_URL" != */ ]] && BASE_URL="${BASE_URL}/"
[[ -f "$WORDLIST" ]] || { echo "Wordlist not found: $WORDLIST" >&2; exit 1; }

OUTFILE="dirb_results_$(date +%Y%m%d_%H%M%S).txt"
PROGRESS_FILE=$(mktemp)
echo 0 > "$PROGRESS_FILE"

echo "Target: $BASE_URL"
echo "Wordlist: $WORDLIST ($(wc -l < "$WORDLIST") lines)"
echo "Method: $METHOD | Threads: $THREADS | Delay: ${DELAY}s | Timeout: ${TIMEOUT}s"
[[ "$SAMPLE" -gt 0 ]] && echo "Sampling: $SAMPLE words (first N in file order, not sorted)"
echo "Output: $OUTFILE"
echo "---"

PATHS_FILE=$(mktemp)

# Build paths preserving ORIGINAL file order, deduped via awk associative array
# (no sort -u — that was reordering everything alphabetically, which floated all
# '$'-prefixed entries to the top regardless of their real position in the file)
awk -v exts="$EXTS" '
BEGIN { n = split(exts, e, ",") }
!seen[$0]++ {
    print $0
    for (i = 1; i <= n; i++) {
        ext = "." e[i]
        if (substr($0, length($0)-length(ext)+1) != ext) {
            candidate = $0 ext
            if (!seen[candidate]++) print candidate
        }
    }
}' "$WORDLIST" > "$PATHS_FILE"

TOTAL=$(wc -l < "$PATHS_FILE")

if [[ "$SAMPLE" -gt 0 && "$SAMPLE" -lt "$TOTAL" ]]; then
    head -n "$SAMPLE" "$PATHS_FILE" > "${PATHS_FILE}.sample"
    mv "${PATHS_FILE}.sample" "$PATHS_FILE"
    TOTAL=$SAMPLE
fi
echo "Total requests to send: $TOTAL"
echo "---"

status_in_list() {
    local code="$1" list="$2"
    [[ -z "$list" ]] && return 1
    IFS=',' read -ra arr <<< "$list"
    for c in "${arr[@]}"; do [[ "$code" == "$c" ]] && return 0; done
    return 1
}
export -f status_in_list

check_path() {
    local path="$1" url="${BASE_URL}${1}"
    local -a curl_args=(-s -o /dev/null -w "%{http_code} %{size_download} %{time_total}"
                         --max-time "$TIMEOUT" -A "$USER_AGENT" -X "$METHOD")
    [[ "$FOLLOW_REDIRECTS" == "1" ]] && curl_args+=(-L)
    [[ "$INSECURE" == "1" ]] && curl_args+=(-k)

    local response code size time
    response=$(curl "${curl_args[@]}" "$url" 2>/dev/null)
    read -r code size time <<< "$response"

    {
        flock -x 200
        n=$(<"$PROGRESS_FILE"); n=$((n+1)); echo "$n" > "$PROGRESS_FILE"
        if (( n % 200 == 0 )); then echo ">>> progress: $n / $TOTAL" >&2; fi
    } 200>"$PROGRESS_FILE.lock"

    if [[ -z "$code" || "$code" == "000" ]]; then
        echo "[ERR ] $url (timeout/failed)"
        [[ "$DELAY" != "0" ]] && sleep "$DELAY"
        return
    fi

    if [[ -n "$MATCH_STATUS" ]]; then
        status_in_list "$code" "$MATCH_STATUS" || { [[ "$DELAY" != "0" ]] && sleep "$DELAY"; return; }
    elif status_in_list "$code" "$EXCLUDE_STATUS"; then
        [[ "$DELAY" != "0" ]] && sleep "$DELAY"; return
    fi

    echo "[$code] ${size}B ${time}s $url" | tee -a "$OUTFILE"
    [[ "$DELAY" != "0" ]] && sleep "$DELAY"
}
export -f check_path
export BASE_URL TIMEOUT USER_AGENT METHOD DELAY OUTFILE EXCLUDE_STATUS MATCH_STATUS FOLLOW_REDIRECTS INSECURE PROGRESS_FILE TOTAL

xargs -a "$PATHS_FILE" -P "$THREADS" -I{} bash -c 'check_path "$@"' _ {}

rm -f "$PATHS_FILE" "$PROGRESS_FILE" "$PROGRESS_FILE.lock"
echo "---"
echo "Done. Full results in $OUTFILE"
