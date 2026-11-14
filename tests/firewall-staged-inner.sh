#!/bin/sh
# The native nftables integration now exercises staged changes and rollback.
set -eu
exec sh /src/tests/nft-backend-inner.sh
