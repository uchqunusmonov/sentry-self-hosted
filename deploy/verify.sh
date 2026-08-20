#!/usr/bin/env bash
#
# Post-install verification. Read-only: inspects state, restarts nothing.
#
# Exit 0 = stack healthy and Sentry answering on the bind address.
#
set -uo pipefail

cd "$(dirname "$0")/.."

fails=0

BIND="$(grep -E '^SENTRY_BIND=' .env.custom 2>/dev/null | tail -1 | cut -d= -f2- || true)"
BIND="${BIND:-0.0.0.0:9000}"

# 0.0.0.0 is a bind address, not a connect address. Probe over loopback.
PROBE="${BIND/#0.0.0.0:/127.0.0.1:}"

# The address to hand to other machines on the internal network.
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)"

echo "== docker compose ps =="
docker compose ps
echo

echo "== Container states =="
states="$(docker compose ps --format '{{.Service}}\t{{.State}}\t{{.Status}}' || true)"
if [[ -z "$states" ]]; then
  echo "  FAIL  no containers at all -- the stack is not up."
  echo "        docker compose up -d"
  fails=$((fails+1))
  bad=""
else
  echo "  $(wc -l <<<"$states") service(s) found."
  # Anything that is not running, and not a one-shot that exited cleanly.
  bad="$(grep -vP '\trunning\t' <<<"$states" || true)"
fi
if [[ -n "$bad" ]]; then
  echo "Not in 'running' state:"
  echo "$bad"
  echo
  echo "NOTE: some services are one-shot jobs and exiting is normal for them."
  echo "For anything else, read the logs before touching it:"
  echo "$bad" | awk -F'\t' '{print "  docker compose logs --tail=200 " $1}'
  fails=$((fails+1))
elif [[ -n "$states" ]]; then
  echo "  All services running."
fi
echo

echo "== Unhealthy healthchecks =="
unhealthy="$(docker compose ps --format '{{.Service}}\t{{.Status}}' | grep -i 'unhealthy' || true)"
if [[ -n "$unhealthy" ]]; then
  echo "$unhealthy"
  echo "Do NOT just restart these. Read the logs and find the root cause:"
  echo "$unhealthy" | awk -F'\t' '{print "  docker compose logs --tail=200 " $1}'
  fails=$((fails+1))
else
  echo "None unhealthy."
fi
echo

echo "== HTTP check: http://${PROBE} =="
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://${PROBE}/auth/login/")" || code="000"
if [[ "$code" == "000" ]]; then
  echo "  FAIL  no response from http://${PROBE}"
  echo "        docker compose logs --tail=200 nginx web"
  fails=$((fails+1))
elif [[ "$code" =~ ^(200|302)$ ]]; then
  echo "  OK    HTTP $code"
else
  echo "  WARN  HTTP $code (expected 200 or 302)"
fi
echo

echo "== Bind scope =="
# This deployment intentionally listens on all interfaces for internal-network
# access (SENTRY_BIND=0.0.0.0:9000). Report what is actually bound so a
# mismatch with .env.custom is visible.
ss -lntH 2>/dev/null | awk '$4 ~ /9000$/ {print "        listening on " $4}'
if ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE '^(0\.0\.0\.0|\*|\[::\]):9000$'; then
  echo "  OK    bound to all interfaces, as configured"
  [[ -n "$LAN_IP" ]] && echo "        internal URL: http://${LAN_IP}:9000"
  echo
  echo "  REMINDER  Traffic is plaintext HTTP: logins, session cookies, DSN keys"
  echo "            and event payloads are readable on the wire. This is fine on a"
  echo "            trusted internal network only. Confirm port 9000 is NOT"
  echo "            reachable from outside it:"
  echo "              sudo ufw status        # or your firewall equivalent"
elif ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE '9000$'; then
  echo "  WARN  port 9000 is bound, but not on all interfaces."
  echo "        .env.custom says SENTRY_BIND=${BIND}. Mismatch?"
else
  echo "  FAIL  nothing is listening on port 9000"
  fails=$((fails+1))
fi

echo
echo "=============================="
if [[ "$fails" -eq 0 ]]; then echo "Verification passed."; else echo "Verification found $fails problem(s)."; fi
echo "=============================="
exit $(( fails > 0 ? 1 : 0 ))
