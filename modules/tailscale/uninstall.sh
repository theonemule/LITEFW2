#!/bin/sh
set -eu
exec "$(dirname "$0")/module.sh" uninstall
