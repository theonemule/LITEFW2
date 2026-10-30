#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

grep -q "const VIEW_APIS" www/app.js
grep -Fq "overview: ['overview']" www/app.js
! grep -q "fetch('/api/state" www/app.js
grep -q "getResource('modules/'" www/app.js
grep -q "/api/interfaces/" www/app.js
grep -q "/api/firewall/rules/" www/app.js
grep -q "/api/port-forwards/" www/app.js
grep -q "/api/dhcp/" www/app.js
grep -q "/api/dns/set" www/app.js
grep -q "/api/modules/" www/app.js
grep -q "/api/system/" www/app.js

for r in identity overview interfaces segments firewall port-forwards dhcp dns modules system; do
  grep -q "GET:/$r" cgi/api.cgi
done
grep -q 'GET:/modules/\*' cgi/api.cgi

grep -q '^lfw_overview()' bin/lfwctl
grep -q '^lfw_interfaces()' bin/lfwctl
grep -q '^lfw_segments()' bin/lfwctl
grep -q '^lfw_firewall()' bin/lfwctl
grep -q '^lfw_forwards()' bin/lfwctl
grep -q '^lfw_dhcp()' bin/lfwctl
grep -q '^lfw_dns()' bin/lfwctl
grep -q '^lfw_system()' bin/lfwctl
grep -q '^lfw_modules()' bin/lfwctl
grep -q '^lfw_module()' bin/lfwctl
grep -q '^modules_catalog_json()' lib/modules.sh
grep -q '^module_json()' lib/modules.sh

echo "resource API contract ok"
