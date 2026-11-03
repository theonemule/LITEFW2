#!/bin/sh
set -eu
D=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
exec "$D/shared/controller.sh" frr "$@"
