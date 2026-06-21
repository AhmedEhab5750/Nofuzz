#!/usr/bin/env bash
# nofuzz.sh — minimal, transparent curl-based directory/file brute forcer
#
# No hidden matcher/filter state: every request and its raw result is visible.
# Built for cases where wordlist-based fuzzers silently return zero results
# even though the same paths are clearly live when tested manually.
#
# Usage:
#   ./nofuzz.sh <base_url> <wordlist_file> [options]
#   ./nofuzz.sh -h | --help
#
# Run with -h for the full option list.
set -uo pipefail

print_help() {
    cat <<'EOF'
nofuzz.sh — minimal curl-based directory/file brute forcer

USAGE
    ./nofuzz.sh <base_url> <wordlist_file> [options]
    ./nofuzz.sh -h | --help

ARGUMENTS
    base_url                   Target base URL (trailing slash optional)
    wordlist_file               Path to wordlist (one entry per line)

OPTIONS
    -e, --ext EXT1,EXT2          Extensions to append (skips if word already has that ext)
    -t, --threads N               Concurrent workers (default 10)
    -d, --delay SEC                Delay per request, applied per worker (default 0)
    -T, --timeout SEC              Per-request timeout in seconds (default 10)
    -A, --user-agent STR           Custom User-Agent
    -X, --method METHOD            HTTP method (default GET)
    -x, --exclude-status CODES    Comma list of HTTP status codes to hide (e.g. 403,404)
    -m, --match-status CODES       Comma list of HTTP status codes to ONLY show (overrides -x)
    -L, --follow-redirects         Follow redirects (curl -L)
    -k, --insecure                  Skip TLS certificate verification
    -s, --sample N                  Only send the first N words from the (built) path list

    -E, --hide-errors               Don't print connection-error lines to the terminal
    -W, --hide-timeouts             Don't print timeout lines to the terminal
                                     (errors/timeouts are ALWAYS written to the retry file,
                                     regardless of -E/-W — those flags only affect what's printed)

    -R, --retest                    Retest mode: treat <wordlist_file> as a previously saved
                                     retry file (paths only, one per line). Skips extension
                                     building/dedup and requests exactly those paths again.
                                     (Use this in a separate, later run.)

    -r, --auto-retest [N]           After the main wordlist finishes, automatically retest
                                     whatever errored or timed out, IN THIS SAME RUN — no
                                     need to run again with -R. Repeats up to N passes,
                                     stopping early once a pass has zero failures. N
                                     defaults to 1 if omitted (e.g. just "-r"). Each pass
                                     only re-checks what failed in the pass before it, so
                                     a target recovering mid-scan converges quickly.

    -h, --help                      Show this help and exit

OUTPUT FILES (written to the current directory)
    nofuzz_results_<timestamp>.txt   Every request that passed your -x/-m filter, with status,
                                      size and timing. This is the "real" results file.
    nofuzz_retry_<timestamp>.txt     Paths that errored or timed out. Empty file is deleted
                                      automatically if nothing failed.

RETESTING FAILED REQUESTS
    A normal run always logs failed paths to a retry file, win or lose. Once it's done, point
    nofuzz back at that file with -R to only re-check what failed (handy on flaky targets,
    rate-limited targets, or after raising -T):

        ./nofuzz.sh https://target.com wordlist.txt -e php,bak
        ...
        Retry file: nofuzz_retry_20260622_153000.txt (37 entries)

        ./nofuzz.sh https://target.com nofuzz_retry_20260622_153000.txt -R -T 20

EXAMPLES
    # Basic scan with two extensions, 20 threads
    ./nofuzz.sh https://target.com wordlist.txt -e php,bak -t 20

    # Only show 200s and 500s, follow redirects, hide error/timeout noise on screen
    ./nofuzz.sh https://target.com wordlist.txt -m 200,500 -L -E -W

    # Sample 500 random-order words from a huge wordlist, skip TLS verification
    ./nofuzz.sh https://internal.local wordlist.txt -s 500 -k

    # Retest everything that failed last run, with a longer timeout
    ./nofuzz.sh https://target.com nofuzz_retry_20260622_153000.txt -R -T 20
EOF
}

# Allow -h/--help (or no args at all) before requiring positional args
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_help
    exit 0
fi
if [[ $# -eq 0 ]]; then
    print_help
    exit 1
fi

BASE_URL="${1:?Usage: $0 <base_url> <wordlist> [options]   (-h for help)}"
WORDLIST="${2:?Usage: $0 <base_url> <wordlist> [options]   (-h for help)}"
shift 2

EXTS="" THREADS=10 DELAY=0 TIMEOUT=10 SAMPLE=0
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) curl-nofuzz/1.5"
METHOD="GET" EXCLUDE_STATUS="" MATCH_STATUS="" FOLLOW_REDIRECTS=0 INSECURE=0
HIDE_ERRORS=0 HIDE_TIMEOUTS=0 RETEST_MODE=0 AUTO_RETEST_PASSES=0

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
        -E|--hide-errors) HIDE_ERRORS=1; shift ;;
        -W|--hide-timeouts) HIDE_TIMEOUTS=1; shift ;;
        -R|--retest) RETEST_MODE=1; shift ;;
        -r|--auto-retest)
            if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
                AUTO_RETEST_PASSES="$2"; shift 2
            else
                AUTO_RETEST_PASSES=1; shift
            fi
            ;;
        -h|--help) print_help; exit 0 ;;
        *) echo "Unknown option: $1" >&2; echo "Run with -h for usage." >&2; exit 1 ;;
    esac
done

# Light sanity checks so a typo doesn't silently break threading/timeouts
for pair in "THREADS:$THREADS" "TIMEOUT:$TIMEOUT" "SAMPLE:$SAMPLE"; do
    name="${pair%%:*}"; val="${pair#*:}"
    [[ "$val" =~ ^[0-9]+$ ]] || { echo "Error: $name must be a non-negative integer, got '$val'" >&2; exit 1; }
done
[[ "$DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Error: --delay must be a number, got '$DELAY'" >&2; exit 1; }

[[ "$BASE_URL" != */ ]] && BASE_URL="${BASE_URL}/"
[[ -f "$WORDLIST" ]] || { echo "Wordlist not found: $WORDLIST" >&2; exit 1; }

# IMPORTANT: read WORDLIST into PATHS_FILE *before* creating/truncating any output
# files below. nofuzz_retry_<timestamp>.txt is meant to be fed back in via -R, and
# if an output file were created first and happened to collide with the WORDLIST
# path (e.g. two runs in the same second, or a user-renamed retry file), truncating
# it early would wipe the very input we're about to read. Building PATHS_FILE first
# means WORDLIST is safely copied out before anything else can touch it.
PATHS_FILE=$(mktemp)

if [[ "$RETEST_MODE" == "1" ]]; then
    # Wordlist is already a flat list of exact paths to re-check — no extension building.
    awk '!seen[$0]++' "$WORDLIST" > "$PATHS_FILE"
else
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
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTFILE="nofuzz_results_${TIMESTAMP}.txt"
RETRY_FILE="nofuzz_retry_${TIMESTAMP}.txt"
: > "$RETRY_FILE"
PROGRESS_FILE=$(mktemp)
echo 0 > "$PROGRESS_FILE"

echo "Target: $BASE_URL"
if [[ "$RETEST_MODE" == "1" ]]; then
    echo "Mode: RETEST (re-checking previously failed paths from $WORDLIST)"
else
    echo "Wordlist: $WORDLIST ($(wc -l < "$WORDLIST") lines)"
fi
echo "Method: $METHOD | Threads: $THREADS | Delay: ${DELAY}s | Timeout: ${TIMEOUT}s"
[[ "$SAMPLE" -gt 0 ]] && echo "Sampling: $SAMPLE words (first N in file order, not sorted)"
echo "Output: $OUTFILE"
echo "Retry log: $RETRY_FILE"
echo "---"

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

    local response curl_exit code size time
    response=$(curl "${curl_args[@]}" "$url" 2>/dev/null)
    curl_exit=$?
    read -r code size time <<< "$response"

    {
        flock -x 200
        n=$(<"$PROGRESS_FILE"); n=$((n+1)); echo "$n" > "$PROGRESS_FILE"
        if (( n % 200 == 0 )); then echo ">>> progress: $n / $TOTAL" >&2; fi
    } 200>"$PROGRESS_FILE.lock"

    if [[ -z "$code" || "$code" == "000" || "$curl_exit" != "0" ]]; then
        {
            flock -x 201
            echo "$path" >> "$RETRY_FILE"
        } 201>"$RETRY_FILE.lock"

        if [[ "$curl_exit" == "28" ]]; then
            [[ "$HIDE_TIMEOUTS" != "1" ]] && echo "[TIMEOUT] $url (exceeded ${TIMEOUT}s)"
        else
            [[ "$HIDE_ERRORS" != "1" ]] && echo "[ERR ] $url (curl exit ${curl_exit:-?})"
        fi
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
export BASE_URL TIMEOUT USER_AGENT METHOD DELAY OUTFILE EXCLUDE_STATUS MATCH_STATUS \
       FOLLOW_REDIRECTS INSECURE PROGRESS_FILE TOTAL HIDE_ERRORS HIDE_TIMEOUTS RETRY_FILE

xargs -a "$PATHS_FILE" -P "$THREADS" -I{} bash -c 'check_path "$@"' _ {}
rm -f "$PATHS_FILE"

PASSES_RUN=0
if [[ "$AUTO_RETEST_PASSES" -gt 0 ]]; then
    while [[ -s "$RETRY_FILE" && "$PASSES_RUN" -lt "$AUTO_RETEST_PASSES" ]]; do
        PASSES_RUN=$((PASSES_RUN+1))
        FAIL_COUNT=$(wc -l < "$RETRY_FILE")
        echo "---"
        echo ">>> Auto-retest pass $PASSES_RUN/$AUTO_RETEST_PASSES: re-checking $FAIL_COUNT failed path(s)"

        RETEST_INPUT=$(mktemp)
        mv "$RETRY_FILE" "$RETEST_INPUT"
        : > "$RETRY_FILE"
        echo 0 > "$PROGRESS_FILE"
        TOTAL=$FAIL_COUNT

        xargs -a "$RETEST_INPUT" -P "$THREADS" -I{} bash -c 'check_path "$@"' _ {}
        rm -f "$RETEST_INPUT"
    done
fi

rm -f "$PROGRESS_FILE" "$PROGRESS_FILE.lock" "$RETRY_FILE.lock"
echo "---"

if [[ -s "$RETRY_FILE" ]]; then
    RETRY_COUNT=$(wc -l < "$RETRY_FILE")
    echo "Done. Full results in $OUTFILE"
    [[ "$PASSES_RUN" -gt 0 ]] && echo "Auto-retest: $PASSES_RUN pass(es) run, $RETRY_COUNT path(s) still failing"
    echo "Retry file: $RETRY_FILE ($RETRY_COUNT entries)"
    echo "Retest later with: $0 $BASE_URL $RETRY_FILE -R"
else
    rm -f "$RETRY_FILE"
    echo "Done. Full results in $OUTFILE"
    if [[ "$PASSES_RUN" -gt 0 ]]; then
        echo "Auto-retest: $PASSES_RUN pass(es) run — all previously failed paths succeeded or got a final status."
    else
        echo "No errors or timeouts — nothing to retest."
    fi
fi
