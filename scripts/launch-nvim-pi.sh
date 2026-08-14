#!/bin/bash

# Start the standalone Pi Neovim configuration in the launcher's project directory.

export XDG_CONFIG_HOME="$HOME/Documents/projects"
export NVIM_APPNAME="nvim-pi"

nvim_bin="${NVIM_PI_NVIM_BIN:-/opt/homebrew/bin/nvim}"
launch_dir="${1:-$PWD}"
cd "$launch_dir" || exit 1
exec "$nvim_bin"
