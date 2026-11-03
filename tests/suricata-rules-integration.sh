#!/bin/sh
# Real Suricata rules import, rule toggles, validation and rollback in Alpine.
set -eu
cd /workspace
export LFW_SURICATA_RULES_DIR=/tmp/litefw-suri-rules
apk add --no-cache python3 jq suricata >/dev/null
mkdir -p "$LFW_SURICATA_RULES_DIR"
RULE='alert icmp any any -> any any (msg:"LiteFW uploaded test"; sid:9911201; rev:1;)'
jq -n --arg content "$RULE" '{id:"local",name:"Local rules",content:$content}' >/tmp/lfw-rule-upload.json
python3 modules/shared/suricata-rules.py rulesupload /tmp/lfw-rule-upload.json >/tmp/lfw-rule-result.json
jq -e '.saved==true and .activeRules==1' /tmp/lfw-rule-result.json >/dev/null
python3 modules/shared/suricata-rules.py list | jq -e '.rules[0].sid=="9911201" and .rules[0].enabled==true' >/dev/null
test -s "$LFW_SURICATA_RULES_DIR/active.rules"
echo 'PASS custom Suricata rule uploads pass native Suricata validation'
jq -n '{sid:"9911201",enabled:false}' >/tmp/lfw-rule-toggle.json
python3 modules/shared/suricata-rules.py ruleenable /tmp/lfw-rule-toggle.json | jq -e '.activeRules==0' >/dev/null
python3 modules/shared/suricata-rules.py list | jq -e '.rules[0].enabled==false' >/dev/null
jq -n '{sid:"9911201",enabled:true}' >/tmp/lfw-rule-toggle.json
python3 modules/shared/suricata-rules.py ruleenable /tmp/lfw-rule-toggle.json | jq -e '.activeRules==1' >/dev/null
echo 'PASS per-SID enable/disable changes generated rule file'
before=$(sha256sum "$LFW_SURICATA_RULES_DIR/active.rules" | cut -d' ' -f1)
jq -n '{id:"local",name:"Bad rules",content:"totally not valid"}' >/tmp/lfw-rule-invalid.json
if python3 modules/shared/suricata-rules.py rulesupload /tmp/lfw-rule-invalid.json >/dev/null 2>&1; then
  echo 'FAIL invalid signatures accepted' >&2; exit 1
fi
test "$before" = "$(sha256sum "$LFW_SURICATA_RULES_DIR/active.rules" | cut -d' ' -f1)"
echo 'PASS rejected malformed rules preserve active signatures'
jq -n '{id:"local"}' >/tmp/lfw-export.json
python3 modules/shared/suricata-rules.py rulesexport /tmp/lfw-export.json |
  jq -e '.filename=="local.rules" and (.content|contains("9911201"))' >/dev/null
jq -n '{id:"local",enabled:false}' >/tmp/lfw-source-disable.json
python3 modules/shared/suricata-rules.py sourceenable /tmp/lfw-source-disable.json | jq -e '.activeRules==0' >/dev/null
jq -n '{id:"local",enabled:true}' >/tmp/lfw-source-enable.json
python3 modules/shared/suricata-rules.py sourceenable /tmp/lfw-source-enable.json | jq -e '.activeRules==1' >/dev/null
echo 'PASS ruleset-level controls and .rules export'
