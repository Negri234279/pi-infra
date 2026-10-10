#!/usr/bin/env bash
#
# Cloudflare edge hardening for the public Faro RUM collector
# (otlp.coreforge-conveyor-filters.negri.es/collect).
#
# The RUM endpoint is public by design — any visitor's browser POSTs telemetry
# to it — so it can't be authenticated. This adds two edge rules via the
# Cloudflare Rulesets API to bound abuse BEFORE it reaches the Pi:
#
#   1. WAF custom rule    — only POST/OPTIONS to exactly /collect on that host;
#                           everything else is blocked.
#   2. Rate limiting rule — 100 req/min per IP to /collect, then block 10 min.
#
# These complement the origin-side limits (Alloy faro.receiver: 512KiB payload
# cap + 50 rps global rate limit; NPM: method/body limits) — see
# infra/prod/docker-compose.yml and infra/observability/alloy/config.alloy.
#
# Secret handling: the API token is passed as a PARAMETER, never baked in and
# never exported to the environment. It lives only for this run and, to keep it
# out of `ps` and shell history, it is written to a mode-600 temp curl config
# file (removed on exit) instead of being passed on curl's command line. Prefer
# --token-file / stdin over --token (a token on argv is visible in `ps`).
#
# Idempotency: re-running ADDS duplicate rules (the Rulesets API has no upsert
# by description). Run once; use the listing/delete output to inspect or remove.
# Review before running — it mutates your Cloudflare zone.
#
# Requires: curl, jq.

set -euo pipefail

usage() {
    cat <<'EOF'
Cloudflare edge hardening for the public Faro RUM collector.

Usage:
  cloudflare-rum-rules.sh --token-file <PATH|->  [--zone <ZONE>] [--host <HOST>]
  cloudflare-rum-rules.sh --token      <TOKEN>   [--zone <ZONE>] [--host <HOST>]

Options:
  -t, --token <TOKEN>       Cloudflare API token (Zone.Rulesets Edit + Zone.Zone
                            Read). WARNING: a token on the command line is
                            visible in `ps` and shell history — prefer -T/stdin.
  -T, --token-file <PATH>   Read the token from a file; '-' reads it from stdin.
  -z, --zone <ZONE>         DNS zone (default: negri.es).
  -H, --host <HOST>         RUM collector hostname
                            (default: otlp.coreforge-conveyor-filters.negri.es).
  -h, --help                Show this help.

Examples:
  # Safest: pipe the token via stdin (nothing lands in argv/history/env)
  pass cloudflare/coreforge-token | ./cloudflare-rum-rules.sh --token-file -

  # From a mode-600 file
  ./cloudflare-rum-rules.sh --token-file ~/.secrets/cf-token
EOF
}

TOKEN=""
TOKEN_FILE=""
ZONE="negri.es"
HOST="otlp.coreforge-conveyor-filters.negri.es"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--token)      TOKEN="${2:-}"; shift 2 ;;
        -T|--token-file) TOKEN_FILE="${2:-}"; shift 2 ;;
        -z|--zone)       ZONE="${2:-}"; shift 2 ;;
        -H|--host)       HOST="${2:-}"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "error: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

for bin in curl jq; do
    command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' is required" >&2; exit 1; }
done

# Resolve the token: --token-file ('-' = stdin) wins, then --token. Never env.
if [[ -n "$TOKEN_FILE" ]]; then
    if [[ "$TOKEN_FILE" == "-" ]]; then
        IFS= read -r TOKEN || true
    else
        [[ -r "$TOKEN_FILE" ]] || { echo "error: cannot read token file '$TOKEN_FILE'" >&2; exit 1; }
        IFS= read -r TOKEN < "$TOKEN_FILE" || true
    fi
fi
if [[ -z "$TOKEN" ]]; then
    echo "error: no API token given (use --token-file <path|-> or --token <token>)" >&2
    usage >&2
    exit 1
fi

API="https://api.cloudflare.com/client/v4"

# Keep the token out of argv and the environment: write a mode-600 curl config
# file holding the Authorization header, then drop the plaintext from memory.
# Every request uses `curl --config "$CF_CFG"`, so `ps` only ever shows the path.
CF_CFG="$(mktemp)"
chmod 600 "$CF_CFG"
trap 'rm -f "$CF_CFG"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$CF_CFG"
TOKEN=""
unset TOKEN

# cf_api METHOD PATH [JSON_BODY] — calls the API, aborts loudly on success:false.
cf_api() {
    local method="$1" path="$2" body="${3:-}"
    local args=(--config "$CF_CFG" -s -X "$method" "${API}${path}" -H "Content-Type: application/json")
    [[ -n "$body" ]] && args+=(--data "$body")

    local resp
    resp="$(curl "${args[@]}")"
    if [[ "$(jq -r '.success' <<<"$resp")" != "true" ]]; then
        echo "Cloudflare API error on ${method} ${path}:" >&2
        jq -r '.errors' <<<"$resp" >&2
        exit 1
    fi
    printf '%s' "$resp"
}

# entrypoint_ruleset PHASE DISPLAY_NAME — returns the zone entrypoint ruleset id
# for a phase, creating an empty one if it does not exist yet.
entrypoint_ruleset() {
    local phase="$1" name="$2" id
    id="$(cf_api GET "/zones/${ZONE_ID}/rulesets/phases/${phase}/entrypoint" | jq -r '.result.id // empty')" || true
    if [[ -z "$id" ]]; then
        id="$(cf_api POST "/zones/${ZONE_ID}/rulesets" \
            "$(jq -nc --arg n "$name" --arg p "$phase" \
                '{name:$n, kind:"zone", phase:$p, rules:[]}')" | jq -r '.result.id')"
    fi
    printf '%s' "$id"
}

# ── Zone ──────────────────────────────────────────────────────────────
ZONE_ID="$(cf_api GET "/zones?name=${ZONE}" | jq -r '.result[0].id // empty')"
[[ -n "$ZONE_ID" ]] || { echo "error: zone '${ZONE}' not found (check token scope)" >&2; exit 1; }
echo "zone ${ZONE} → ${ZONE_ID}"

# ── Rule 1: WAF custom — restrict the host to POST/OPTIONS on /collect ──
CUSTOM_RS="$(entrypoint_ruleset http_request_firewall_custom 'default custom firewall')"
echo "custom firewall ruleset → ${CUSTOM_RS}"

cf_api POST "/zones/${ZONE_ID}/rulesets/${CUSTOM_RS}/rules" "$(jq -nc --arg host "$HOST" '{
    description: "coreforge RUM: \($host) solo POST/OPTIONS a /collect",
    expression: "(http.host eq \"\($host)\") and ((not (http.request.method in {\"POST\" \"OPTIONS\"})) or (http.request.uri.path ne \"/collect\"))",
    action: "block",
    enabled: true
}')" >/dev/null
echo "  ✓ WAF custom rule added"

# ── Rule 2: Rate limiting — 100 req/min per IP to /collect ──────────────
RL_RS="$(entrypoint_ruleset http_ratelimit 'default ratelimit')"
echo "ratelimit ruleset → ${RL_RS}"

cf_api POST "/zones/${ZONE_ID}/rulesets/${RL_RS}/rules" "$(jq -nc --arg host "$HOST" '{
    description: "coreforge RUM: rate-limit /collect por IP",
    expression: "http.host eq \"\($host)\" and http.request.uri.path eq \"/collect\"",
    action: "block",
    ratelimit: {
        characteristics: ["ip.src", "cf.colo.id"],
        period: 60,
        requests_per_period: 100,
        mitigation_timeout: 600
    },
    enabled: true
}')" >/dev/null
echo "  ✓ rate limiting rule added"

echo
echo "Done. Current rules:"
cf_api GET "/zones/${ZONE_ID}/rulesets/${CUSTOM_RS}" | jq -r '.result.rules[]? | "  [custom] \(.id)  \(.action)  \(.description)"'
cf_api GET "/zones/${ZONE_ID}/rulesets/${RL_RS}"     | jq -r '.result.rules[]? | "  [rl]     \(.id)  \(.action)  \(.description)"'

# ── Revert (manual) ─────────────────────────────────────────────────────
# Delete a specific rule (reuse --token-file for the header):
#   curl --config <(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN") \
#     -s -X DELETE "$API/zones/$ZONE_ID/rulesets/<RULESET_ID>/rules/<RULE_ID>" | jq '.success'
#
# Plan notes: Cloudflare Free allows basic rate limiting (1 rule, action=block,
# limited characteristics) and up to 5 WAF custom rules — these two fit. If a
# call fails on plan limits, the error is printed above. cf.colo.id is REQUIRED
# in ratelimit.characteristics. Do NOT use managed_challenge on /collect: RUM
# POSTs are non-interactive and would just fail the challenge.
