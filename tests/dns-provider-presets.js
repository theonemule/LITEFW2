#!/usr/bin/env node
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const presetsSource = fs.readFileSync('www/dns-presets.js', 'utf8');
const app = fs.readFileSync('www/app.js', 'utf8');
const helper = app.slice(app.indexOf('function dnsResolverMatch('), app.indexOf('// ---------- DNS\nfunction dnsmasqPanel()'));
assert(helper.length > 1500);
const ctx = vm.createContext({});
vm.runInContext(presetsSource + '\n' + helper, ctx);
const evaluate = expression => vm.runInContext(expression, ctx);
const presets = JSON.parse(evaluate('JSON.stringify(DNS_RESOLVER_PRESETS)'));
assert.equal(presets.length, 15);
assert.equal(new Set(presets.map(p=>p.id)).size, presets.length);
for (const p of presets) {
  assert.equal(p.ips.length, 2, p.id);
  assert(p.ips.every(ip => /^\d{1,3}(\.\d{1,3}){3}$/.test(ip)), p.id);
  assert(p.provider && p.name && p.level && p.details && p.docs.startsWith('https://'));
  assert.equal(evaluate('dnsResolverMatch(' + JSON.stringify(p.ips) + ',"direct")'), p.id);
  assert.equal(evaluate('dnsResolverMatch(' + JSON.stringify([...p.ips].reverse()) + ',"direct")'), p.id);
  assert.equal(evaluate('JSON.stringify(dnsResolverIPs({resolverChoice:"' + p.id + '"}))'), JSON.stringify(p.ips));
  assert.equal(evaluate('dnsResolverIsFiltered({resolverChoice:"' + p.id + '"})'), p.filters);
}
for (const id of ['cloudflare-family','opendns-family','quad9-secure','cleanbrowsing-family','adguard-family']) {
  assert(evaluate('dnsResolverIsFiltered({resolverChoice:"' + id + '"})'));
}
assert(!evaluate('dnsResolverIsFiltered({resolverChoice:"google-standard"})'));
assert(!evaluate('dnsResolverIsFiltered({resolverChoice:"opendns-standard"})'));
assert(!evaluate('dnsResolverIsFiltered({resolverChoice:"opendns-sandbox"})'));
assert.equal(evaluate('dnsResolverMatch([],"automatic")'),'automatic');
assert.equal(evaluate('dnsResolverMatch(["10.0.1.1"],"direct")'),'custom');
assert.equal(evaluate('JSON.stringify(dnsResolverIPs({resolverChoice:"custom",customResolvers:["10.0.1.1"]}))'),'["10.0.1.1"]');
assert.equal(evaluate('JSON.stringify(dnsResolverIPs({resolverChoice:"automatic"}))'),'[]');
assert.equal(evaluate('JSON.stringify(dnsResolverIPs({resolverChoice:"direct"}))'),'[]');
assert.throws(()=>evaluate('dnsResolverIPs({resolverChoice:"custom",customResolvers:[]})'),/Enter at least one custom/);
assert.throws(()=>evaluate('dnsResolverIPs({resolverChoice:"pretend"})'),/Select an upstream/);
assert.match(evaluate('dnsResolverSummary(["1.1.1.3","1.0.0.3"],"")'),/Cloudflare/);
console.log('PASS: 15 presets, IP matching, custom mode, filtering flags and descriptions');
assert(app.includes("forwardMode:dnsResolverIsFiltered(v) ? 'only'"),'Filtered BIND provider must be forward only');
assert(app.includes('decorate:dnsResolverDetails'),'Provider preview missing');
assert(fs.readFileSync('www/index.html','utf8').includes('<script src="/dns-presets.js?v=2.2.23"></script>'));
console.log('PASS: BIND filter fail-closed and catalog loaded');
