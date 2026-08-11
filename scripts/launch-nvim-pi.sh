#!/bin/bash

# Keep Bash above Neovim so one Ghostty terminal can replace the editor process
# whenever the user switches projects.

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/opt/homebrew/opt/openjdk@17/bin:$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export XDG_CONFIG_HOME="$HOME/Documents/projects"
export NVIM_APPNAME="nvim-pi"

nvim_bin="${NVIM_PI_NVIM_BIN:-/opt/homebrew/bin/nvim}"
launch_dir="${1:-$PWD}"
cd "$launch_dir" || exit 1

# Neovim sends USR1 immediately before a project-switch exit. Bash cannot
# relaunch yet, so the signal handler records what to do after Neovim is gone.
# Reviewed: false.
restart_with_picker=1
request_project_picker() {
  restart_with_picker=1
}
trap request_project_picker USR1

# The first pass opens the initial picker. Before each launch, clear the flag;
# only another project-switch signal makes the loop start fresh Neovim again.
while [[ "$restart_with_picker" == "1" ]]; do
  restart_with_picker=0
  NVIM_PI_LAUNCHER_PID="$$" NVIM_PI_PICK_PROJECT=1 "$nvim_bin"
  nvim_status=$?
done

# A normal Space Q Q sends no signal, so Bash exits and Ghostty closes as it does today.
exit "$nvim_status"
