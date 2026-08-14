#!/bin/bash

# Exercise the launcher with a fake Neovim command so the test can verify its
# working directory, environment, and exit status without opening the editor.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
launcher="$repo_root/scripts/launch-nvim-pi.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/nvim-pi-launcher-test.XXXXXX")"
fake_nvim="$test_root/nvim"
launch_log="$test_root/launch"
expected_root="$(cd "$test_root" && pwd)"
trap 'rm -rf "$test_root"' EXIT

cat >"$fake_nvim" <<'FAKE'
#!/bin/bash
printf '%s\n' "$PWD" >"$FAKE_LAUNCH_LOG"
printf '%s:%s\n' "${NVIM_PI_PICK_PROJECT-unset}" "${NVIM_PI_LAUNCHER_PID-unset}" >>"$FAKE_LAUNCH_LOG"
exit "$FAKE_FINAL_STATUS"
FAKE
chmod +x "$fake_nvim"

set +e
env -u NVIM_PI_PICK_PROJECT -u NVIM_PI_LAUNCHER_PID \
  FAKE_LAUNCH_LOG="$launch_log" FAKE_FINAL_STATUS=7 \
  NVIM_PI_NVIM_BIN="$fake_nvim" "$launcher" "$test_root"
status=$?
set -e

[[ "$status" == "7" ]]
[[ "$(sed -n '1p' "$launch_log")" == "$expected_root" ]]
[[ "$(sed -n '2p' "$launch_log")" == "unset:unset" ]]
printf 'nvim-pi-launcher-spec-ok\n'
