#!/bin/bash

# Exercise the launcher as a process owner, using a fake Neovim command so the
# test can control exit statuses and project-switch signals deterministically.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
launcher="$repo_root/scripts/launch-nvim-pi.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/nvim-pi-launcher-test.XXXXXX")"
fake_nvim="$test_root/nvim"
log_file="$test_root/launches"
trap 'rm -rf "$test_root"' EXIT

# Each fake launch records the picker mode and parent launcher PID. On its first
# pass it can request a replacement Neovim by signaling that parent with USR1.
cat >"$fake_nvim" <<'FAKE'
#!/bin/bash

printf '%s:%s\n' "$NVIM_PI_PICK_PROJECT" "$NVIM_PI_LAUNCHER_PID" >>"$FAKE_LAUNCH_LOG"
launch_count="$(wc -l <"$FAKE_LAUNCH_LOG" | tr -d ' ')"
if [[ "$FAKE_RESTART_ONCE" == "1" && "$launch_count" == "1" ]]; then
  kill -USR1 "$NVIM_PI_LAUNCHER_PID"
  exit 0
fi
exit "$FAKE_FINAL_STATUS"
FAKE
chmod +x "$fake_nvim"

# A project-switch signal should produce a second launch in picker mode while
# retaining the same Bash launcher PID, then return the final Neovim status.
set +e
FAKE_LAUNCH_LOG="$log_file" FAKE_RESTART_ONCE=1 FAKE_FINAL_STATUS=7 \
  NVIM_PI_NVIM_BIN="$fake_nvim" "$launcher" "$test_root"
status=$?
set -e

[[ "$status" == "7" ]]
[[ "$(wc -l <"$log_file" | tr -d ' ')" == "2" ]]
[[ "$(cut -d: -f1 "$log_file" | uniq)" == "1" ]]
[[ "$(cut -d: -f2 "$log_file" | uniq | wc -l | tr -d ' ')" == "1" ]]

# Without USR1, a normal Neovim exit should end the launcher after one pass.
: >"$log_file"
set +e
FAKE_LAUNCH_LOG="$log_file" FAKE_RESTART_ONCE=0 FAKE_FINAL_STATUS=3 \
  NVIM_PI_NVIM_BIN="$fake_nvim" "$launcher" "$test_root"
status=$?
set -e

[[ "$status" == "3" ]]
[[ "$(wc -l <"$log_file" | tr -d ' ')" == "1" ]]
printf 'nvim-pi-launcher-spec-ok\n'
