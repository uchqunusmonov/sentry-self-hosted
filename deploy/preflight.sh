#!/usr/bin/env bash
#
# Read-only pre-install check. Changes NOTHING on the host.
# Run this on the target server before ./install.sh.
#
# Exit 0 = all hard requirements met. Exit 1 = at least one hard FAIL.
#
set -uo pipefail

fails=0
warns=0

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; warns=$((warns+1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails+1)); }

echo "== Host =="
echo "  $(. /etc/os-release && echo "$PRETTY_NAME") / $(uname -m) / kernel $(uname -r)"

echo
echo "== CPU =="
cpu=$(nproc)
# install/_min-requirements.sh: MIN_CPU_HARD=4 for feature-complete, 2 for errors-only
if [[ "$cpu" -ge 4 ]]; then ok "$cpu cores (need >= 4 for feature-complete)"
else fail "$cpu cores, need >= 4 for feature-complete (>= 2 for errors-only)"; fi

echo
echo "== RAM =="
ram_mb=$(free -m | awk '/^Mem:/ {print $2}')
# install/_min-requirements.sh: MIN_RAM_HARD=14000 MB for feature-complete
if [[ "$ram_mb" -ge 14000 ]]; then ok "${ram_mb} MB total (installer hard floor 14000 MB)"
else fail "${ram_mb} MB total, installer hard floor is 14000 MB for feature-complete"; fi
if [[ "$ram_mb" -lt 16000 ]]; then warn "Sentry docs recommend 16 GB; you have ${ram_mb} MB"; fi

echo
echo "== Swap =="
swap_mb=$(free -m | awk '/^Swap:/ {print $2}')
# Not a Sentry requirement. Kafka/ClickHouse spike during migrations; swap
# turns a spike into slowness instead of an OOM kill.
if [[ "$swap_mb" -ge 2048 ]]; then ok "${swap_mb} MB swap"
else warn "${swap_mb} MB swap. Not required by Sentry, but >= 2048 MB is cheap insurance against OOM kills during install/migrations."; fi

echo
echo "== Disk =="
avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [[ "$avail_gb" -ge 50 ]]; then ok "${avail_gb} GB free on /"
else fail "${avail_gb} GB free on /, want >= 50 GB (docs minimum is 20 GB, but events grow fast)"; fi
echo "  docker root: $(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo '?')"

echo
echo "== Kernel params =="
mmc=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
# ClickHouse and Kafka open many memory-mapped files.
if [[ "$mmc" -ge 262144 ]]; then ok "vm.max_map_count = $mmc"
else warn "vm.max_map_count = $mmc. If ClickHouse fails to start, raise it: sysctl -w vm.max_map_count=262144 (persist in /etc/sysctl.d/)"; fi

echo
echo "== Docker =="
if ! command -v docker >/dev/null; then
  fail "docker not installed"
else
  dv=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "")
  if [[ -z "$dv" ]]; then fail "docker daemon not reachable as $(whoami) (add user to the 'docker' group?)"
  else ok "docker $dv (need >= 19.03.6)"; fi
  cv=$(docker compose version --short 2>/dev/null || echo "")
  if [[ -z "$cv" ]]; then fail "'docker compose' plugin missing (need >= 2.32.2)"
  else ok "docker compose $cv (need >= 2.32.2)"; fi
fi

echo
echo "== SSE4.2 (required by ClickHouse) =="
if grep -qc sse4_2 /proc/cpuinfo 2>/dev/null; then ok "sse4_2 present"
else warn "sse4_2 not reported. Under KVM/VMware this can be a false negative; the installer skips the check on KVM."; fi

echo
echo "== Bash =="
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then ok "bash $BASH_VERSION (need >= 4.4.0)"
else fail "bash $BASH_VERSION, need >= 4.4.0"; fi

echo
echo "== Port 9000 =="
if ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE '(^|[:.])9000$'; then
  fail "something already listens on port 9000"
else ok "port 9000 free"; fi

echo
echo "=============================="
echo "FAIL: $fails   WARN: $warns"
[[ "$fails" -eq 0 ]] && echo "Hard requirements met." || echo "Fix the FAILs before running ./install.sh."
echo "=============================="
exit $(( fails > 0 ? 1 : 0 ))
