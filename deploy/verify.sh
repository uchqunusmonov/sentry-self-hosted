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
BIND="${BIND:-127.0.0.1:9000}"

echo "== docker compose ps =="
docker compose ps
echo

echo "== Container states =="
# Anything that is not running, and not a one-shot that exited cleanly.
bad="$(docker compose ps --format '{{.Service}}\t{{.State}}\t{{.Status}}' \
  | grep -vP '\trunning\t' || true)"
if [[ -n "$bad" ]]; then
  echo "Not in 'running' state:"
  echo "$bad"
  echo
  echo "NOTE: some services are one-shot jobs and exiting is normal for them."
  echo "For anything else, read the logs before touching it:"
  echo "$bad" | awk -F'\t' '{print "  docker compose logs --tail=200 " $1}'
  fails=$((fails+1))
else
  echo "All services running."
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

echo "== HTTP check: http://${BIND} =="
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://${BIND}/auth/login/" || echo "000")"
if [[ "$code" == "000" ]]; then
  echo "  FAIL  no response from http://${BIND}"
  echo "        docker compose logs --tail=200 nginx web"
  fails=$((fails+1))
elif [[ "$code" =~ ^(200|302)$ ]]; then
  echo "  OK    HTTP $code"
else
  echo "  WARN  HTTP $code (expected 200 or 302)"
fi
echo

echo "== Bind scope =="
# SENTRY_BIND must keep the port off the public interface; the host reverse
# proxy is what should be reachable from outside.
if ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE '^(0\.0\.0\.0|\*|\[::\]):9000$'; then
  echo "  FAIL  port 9000 is published on ALL interfaces. Expected loopback only."
  echo "        Check SENTRY_BIND in .env.custom, then: docker compose up -d"
  fails=$((fails+1))
else
  echo "  OK    port 9000 not on a public interface"
  ss -lntH 2>/dev/null | awk '$4 ~ /9000$/ {print "        listening on " $4}'
fi

echo
echo "=============================="
if [[ "$fails" -eq 0 ]]; then echo "Verification passed."; else echo "Verification found $fails problem(s)."; fi
echo "=============================="
exit $(( fails > 0 ? 1 : 0 ))
