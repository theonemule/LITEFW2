'use strict';
// LiteFWM web UI. There is no client-side configuration database. Each view
// reads only the live resource APIs it needs, and every Apply mutates the native
// system through that resource's API before re-reading the active view.

const $ = s => document.querySelector(s);
function h(tag, attrs, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') e.className = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else e.setAttribute(k, v === true ? '' : v);
  }
  for (const c of kids.flat(Infinity)) {
    if (c == null || c === false) continue;
    e.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return e;
}
const badge = (text, cls) => h('span', { class: 'badge ' + (cls || 'text-bg-secondary') }, text);
const btn = (text, onclick, cls) => h('button', { type: 'button', class: 'btn btn-sm ' + (cls || 'btn-outline-secondary'), onclick }, text);
const card = (title, actions, ...body) => h('div', { class: 'card mb-3' },
  h('div', { class: 'card-header' }, title, h('div', { class: 'actions' }, actions || [])), ...body);
const table = (heads, rows, empty) => h('div', { class: 'table-responsive' },
  h('table', { class: 'table table-sm table-hover mb-0' },
    h('thead', {}, h('tr', {}, heads.map(x => h('th', {}, x)))),
    h('tbody', {}, rows.length ? rows : h('tr', {}, h('td', { colspan: heads.length, class: 'text-secondary' }, empty || 'None')))));
const dash = v => (v === '' || v == null) ? '—' : v;

// ------------------------------------------------------------------ API
const emptyState = () => ({
  system: null,
  interfaces: [],
  firewall: { policies: {}, rules: [], forwards: [], masquerade: [] },
  dhcp: { leases: [], reservations: [] },
  dns: { domain: '', upstream: [], hosts: [] },
  modules: []
});
let S = emptyState();
let loadGeneration = 0;

const VIEW_APIS = {
  overview: ['overview'],
  interfaces: ['interfaces'],
  segments: ['segments', 'system'],
  dhcp: ['dhcp'],
  dns: ['dns', 'segments', 'system', 'modules/bind', 'modules/dnsmasq'],
  modules: ['modules', 'segments', 'system'],
  'module-bind': ['segments', 'system', 'modules/bind'],
  'module-dnsmasq': ['dns', 'segments', 'system', 'modules/dnsmasq', 'modules/bind'],
  'module-ddns': ['segments', 'system', 'modules/ddns'],
  'module-openvpn': ['segments', 'system', 'modules/openvpn'],
  'module-ipsec': ['segments', 'system', 'modules/ipsec'],
  firewall: ['firewall', 'port-forwards', 'segments', 'dhcp', 'system'],
  system: ['system', 'segments']
};

function activeView() {
  let v = (location.hash || '#overview').slice(1);
  v = ALIAS[v] || v;
  return views[v] ? v : 'overview';
}
async function getResource(path) {
  const r = await fetch('/api/' + path, { cache: 'no-store', credentials: 'same-origin' });
  let j; try { j = await r.json(); } catch { throw new Error('HTTP ' + r.status); }
  if (!r.ok || j.ok === false) throw new Error(j.error || r.statusText);
  return j;
}
function mergeState(dst, src, replaceModules = false) {
  if (src.system) dst.system = src.system;
  if (src.interfaces) dst.interfaces = src.interfaces;
  if (src.firewall) dst.firewall = Object.assign({}, dst.firewall, src.firewall);
  if (src.dhcp) dst.dhcp = Object.assign({}, dst.dhcp, src.dhcp);
  if (src.dns) dst.dns = Object.assign({}, dst.dns, src.dns);
  if (src.modules) {
    if (replaceModules) dst.modules = src.modules;
    else {
      const byId = new Map(dst.modules.map(m => [m.id, m]));
      src.modules.forEach(m => byId.set(m.id, Object.assign({}, byId.get(m.id) || {}, m)));
      dst.modules = [...byId.values()].sort((x, y) => (x.name || x.id).localeCompare(y.name || y.id));
    }
  }
}
async function loadIdentity() {
  try {
    const x = await getResource('identity');
    $('#hostName').textContent = x.hostname;
    $('#version').textContent = 'LiteFWM ' + x.version;
  } catch {}
}
async function load() {
  const generation = ++loadGeneration;
  const view = activeView();
  $('#view').replaceChildren(h('div', { class: 'p-4 text-secondary' }, 'Loading live ' + view + ' state…'));
  try {
    const next = emptyState();
    const deps = VIEW_APIS[view] || VIEW_APIS.overview;
    const results = await Promise.all(deps.map(async path => [path, await getResource(path)]));
    if (generation !== loadGeneration) return;
    for (const [path, data] of results) mergeState(next, data, path === 'modules');

    if (view === 'modules') {
      const installed = next.modules.filter(m => m.installed);
      const states = await Promise.all(installed.map(m => getResource('modules/' + encodeURIComponent(m.id))));
      if (generation !== loadGeneration) return;
      states.forEach(x => mergeState(next, x));
    }

    S = next;
    if (view === 'firewall' && (!fwDraft || !fwDirty)) initFwDraft(next.firewall);
    if (S.system) {
      $('#hostName').textContent = S.system.hostname;
      $('#version').textContent = 'LiteFWM ' + S.system.version;
    }
    $('#stamp').textContent = 'Live ' + view + ' state · read ' + new Date().toLocaleTimeString();
    $('#statusDot').classList.add('online'); $('#statusText').textContent = 'Connected';
    render();
  } catch (e) {
    if (generation !== loadGeneration) return;
    $('#statusDot').classList.remove('online'); $('#statusText').textContent = 'Error';
    $('#view').replaceChildren(h('div', { class: 'alert alert-danger' }, 'Could not read live state: ' + e.message));
  }
}
function opPath(name, body) {
  const parts = name.split('.'), family = parts[0], action = parts[1];
  if (['iface', 'bridge', 'vlan'].includes(family)) return '/api/interfaces/' + family + '/' + action;
  if (family === 'segment') return '/api/segments/set';
  if (family === 'firewall') return '/api/firewall/' + action;
  if (family === 'rule') return '/api/firewall/rules/' + action;
  if (family === 'forward') return '/api/port-forwards/' + action;
  if (family === 'dhcpd') return '/api/dhcp/server/set';
  if (family === 'reservation') return '/api/dhcp/reservations/' + action;
  if (family === 'dns') return '/api/dns/set';
  if (family === 'module') return '/api/modules/' + encodeURIComponent(body.id) + '/' + action;
  if (['bind', 'openvpn', 'ddns', 'dnsmasq', 'ipsec'].includes(family)) return '/api/modules/' + family + '/' + action;
  if (['suricata','geoip','crowdsec','wireguard','cloudflared','multiwan','mdns','captive','frr'].includes(family))
    return '/api/modules/' + family + '/' + action;
  if (family === 'telemetry') return '/api/system/telemetry';
  if (family === 'upgrade') return '/api/system/updates/' + action;
  if (family === 'packages') return '/api/system/packages/' + action;
  if (family === 'system') return '/api/system/set';
  if (family === 'mgmt') return '/api/system/management';
  if (family === 'logging') return '/api/system/logging';
  if (family === 'password') return '/api/system/password';
  if (family === 'diag') return '/api/system/diagnostics/' + action;
  throw new Error('No resource API route for operation ' + name);
}
async function op(name, body) {
  body = body || {};
  const r = await fetch(opPath(name, body), {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', 'X-LiteFWM': '1' },
    body: JSON.stringify(body)
  });
  let j; try { j = await r.json(); } catch { throw new Error('HTTP ' + r.status); }
  if (!j.ok) throw new Error(j.error || 'operation failed');
  (j.warnings || []).forEach(w => toast(w, 'warning'));
  return j;
}
async function apply(name, body, done) {
  const j = await op(name, body);
  toast(done || 'Applied', 'success');
  await load();
  return j;
}
function toast(msg, kind) {
  const t = h('div', { class: 'toast align-items-center border-0 text-bg-' + (kind || 'secondary') },
    h('div', { class: 'd-flex' }, h('div', { class: 'toast-body' }, msg),
      h('button', { type: 'button', class: 'btn-close btn-close-white me-2 m-auto', 'data-bs-dismiss': 'toast' })));
  $('#toasts').append(t);
  const bt = new bootstrap.Toast(t, { delay: kind === 'warning' ? 9000 : 3000 });
  t.addEventListener('hidden.bs.toast', () => t.remove());
  bt.show();
}

// ------------------------------------------------------------------ dialog
const dlg = () => bootstrap.Modal.getOrCreateInstance($('#dlg'));
// open the dialog; if the previous one is still fading out, open it once that finishes
function showDlg() {
  const el = $('#dlg'), m = dlg();
  if (m._isTransitioning) el.addEventListener('hidden.bs.modal', () => m.show(), { once: true });
  else m.show();
}
let dlgApply = null;
const KEEP = Symbol('keep-dialog-open');
$('#dlgApply').addEventListener('click', async () => {
  if (!dlgApply) return;
  const b = $('#dlgApply'); b.disabled = true; $('#dlgErr').textContent = '';
  try { if (await dlgApply() !== KEEP) dlg().hide(); }
  catch (e) { $('#dlgErr').textContent = e.message; }
  finally { b.disabled = false; }
});

// buildFields(fields, initial) -> { body, vals() }   (vals() returns visible fields only)
// field: {k, label, type: text|number|select|check|multi|list|textarea|password|info, value,
//         options: [[value,label]], help, placeholder, show: vals => bool}
function buildFields(fields, initial) {
  const ctl = {}, wraps = [];
  const body = h('div', {});
  for (const f0 of fields) {
    const f = initial && f0.k in initial && f0.type !== 'info' ? Object.assign({}, f0, { value: initial[f0.k] }) : f0;
    const id = 'f_' + f.k;
    let el;
    if (f.type === 'select') {
      el = h('select', { class: 'form-select', id }, f.options.map(([v, l]) => h('option', { value: v, selected: String(v) === String(f.value ?? '') }, l)));
    } else if (f.type === 'check') {
      el = h('input', { class: 'form-check-input', type: 'checkbox', id, checked: !!f.value });
    } else if (f.type === 'multi') {
      const sel = new Set((f.value || []).map(String));
      el = h('div', { id }, f.options.length ? f.options.map(([v, l]) => h('div', { class: 'form-check form-check-inline' },
        h('input', { class: 'form-check-input', type: 'checkbox', value: v, id: id + v, checked: sel.has(String(v)) }),
        h('label', { class: 'form-check-label', for: id + v }, l))) : h('div', { class: 'text-secondary small' }, 'none available'));
    } else if (f.type === 'textarea') {
      el = h('textarea', { class: 'form-control mono', id, rows: f.rows || 5, placeholder: f.placeholder || '' });
      el.value = f.value ?? '';
    } else if (f.type === 'info') {
      el = h('div', { class: 'form-control-plaintext mono', id }, f.value);
    } else {
      el = h('input', { class: 'form-control', id, type: f.type === 'password' ? 'password' : (f.type === 'number' ? 'number' : 'text'), placeholder: f.placeholder || '' });
      el.value = f.type === 'list' ? (f.value || []).join(', ') : (f.value ?? '');
    }
    ctl[f.k] = { f, el };
    const w = f.type === 'check'
      ? h('div', { class: 'form-check mb-3' }, el, h('label', { class: 'form-check-label', for: id }, f.label), f.help && h('div', { class: 'form-text' }, f.help))
      : h('div', { class: 'mb-3' }, h('label', { class: 'form-label small fw-semibold', for: id }, f.label), el, f.help && h('div', { class: 'form-text' }, f.help));
    wraps.push([f, w]);
    body.append(w);
  }
  const raw = () => {
    const v = {};
    for (const [k, { f, el }] of Object.entries(ctl)) {
      if (f.type === 'info') continue;
      if (f.type === 'check') v[k] = el.checked;
      else if (f.type === 'multi') v[k] = [...el.querySelectorAll('input:checked')].map(i => i.value);
      else if (f.type === 'list') v[k] = el.value.split(/[\s,]+/).filter(Boolean);
      else v[k] = el.value.trim();
    }
    return v;
  };
  const refresh = () => { const v = raw(); for (const [f, w] of wraps) w.classList.toggle('d-none', !!f.show && !f.show(v)); };
  body.addEventListener('change', refresh); body.addEventListener('input', refresh);
  refresh();
  const vals = () => { const v = raw(); for (const [f] of wraps) if (f.show && !f.show(v)) delete v[f.k]; return v; };
  return { body, vals };
}
function dlgChrome(title, applyText, danger) {
  $('#dlgTitle').textContent = title;
  $('#dlgErr').textContent = '';
  $('#dlgBack').classList.add('d-none');
  $('#dlgApply').classList.remove('d-none');
  $('#dlgApply').textContent = applyText || 'Apply';
  $('#dlgApply').className = 'btn ' + (danger ? 'btn-danger' : 'btn-primary');
}
// form(title, fields, onApply(values), {note, noteKind, applyText, danger})
function form(title, fields, onApply, o = {}) {
  const ui = buildFields(fields);
  dlgChrome(title, o.applyText, o.danger);
  $('#dlgBody').replaceChildren(h('div', {}, o.note && h('div', { class: 'alert alert-' + (o.noteKind || 'info') + ' py-2 small' }, o.note), ui.body));
  if (o.decorate) o.decorate(ui.body, ui.vals);
  dlgApply = () => onApply(ui.vals());
  showDlg();
}
const confirmDo = (title, msg, fn, text) => form(title, [], fn, { note: msg, noteKind: 'warning', applyText: text || 'Apply', danger: true });

// ------------------------------------------------------------------ helpers
const ip2int = ip => ip.split('.').reduce((a, o) => a * 256 + (+o), 0);
const inCidr = (ip, cidr) => { const [n, p] = cidr.split('/'); const s = 2 ** (32 - +p); return Math.floor(ip2int(ip) / s) === Math.floor(ip2int(n) / s); };
const int2ip = n => [24, 16, 8, 0].map(b => Math.floor(n / 2 ** b) % 256).join('.');
const I = n => S.interfaces.find(i => i.name === n);
const disp = n => { if (!n) return 'any'; const i = I(n); return i && i.label ? `${n} (${i.label})` : n; };
const l3 = () => S.interfaces.filter(i => ['physical', 'bridge', 'vlan'].includes(i.kind) && !i.master);
const routeIfaces = () => S.interfaces.filter(i => ['physical', 'bridge', 'vlan', 'vpn'].includes(i.kind) && !i.master);
const ifOpts = anyLabel => [['', anyLabel || 'any']].concat(routeIfaces().map(i => [i.name, disp(i.name) + (i.kind === 'vpn' ? ' · VPN' : (i.role !== 'none' ? ' · ' + i.role.toUpperCase() : ''))]));
const wan = () => S.interfaces.find(i => i.role === 'wan');
const segOf = ip => S.interfaces.find(i => i.role === 'lan' && i.addresses.some(c => inCidr(ip, c)));
const roleBadge = r => badge(r === 'none' ? 'unassigned' : r.toUpperCase(), 'role-' + r);
const rel = t => { if (!t) return 'never'; const d = t - Date.now() / 1000; if (d <= 0) return 'expired';
  return d > 86400 ? Math.round(d / 86400) + 'd' : d > 3600 ? Math.round(d / 3600) + 'h' : Math.round(d / 60) + 'm'; };
const clientWarn = n => S.system.management.clientInterface === n
  ? `Your browser session reaches the firewall through ${n}. A wrong change here can disconnect you.` : null;

// ------------------------------------------------------------------ views
const views = {};

views.overview = () => {
  const s = S.system;
  const up = s.uptime, upt = `${Math.floor(up / 86400)}d ${Math.floor(up % 86400 / 3600)}h ${Math.floor(up % 3600 / 60)}m`;
  const memPct = Math.round(100 * (1 - s.memory.availableKb / s.memory.totalKb));
  const stat = (label, value, href) => h('div', { class: 'col-6 col-md-3' }, h('a', { class: 'card card-body text-decoration-none text-body', href },
    h('div', { class: 'small text-secondary' }, label), h('div', { class: 'stat' }, value)));
  const w = wan();
  return [
    h('div', { class: 'row g-3 mb-3' },
      stat('Segments', l3().filter(i => i.role !== 'none').length, '#segments'),
      stat('Active leases', S.dhcp.leases.filter(l => !l.expires || l.expires > Date.now() / 1000).length, '#dhcp'),
      stat('Firewall rules', S.firewall.rules.length, '#firewall'),
      stat('Port forwards', S.firewall.forwards.length, '#firewall')),
    h('div', { class: 'row g-3' },
      h('div', { class: 'col-lg-5' }, card('System', null, h('div', { class: 'card-body' }, h('dl', { class: 'row mb-0 small' },
        [['Hostname', s.hostname], ['LiteFWM', s.version], ['Alpine', s.alpine], ['Kernel', s.kernel], ['Uptime', upt],
         ['Load', s.load], ['Memory used', memPct + '%'], ['Resolvers', s.resolvers.join(', ') || '—'],
         ['IP forwarding', s.ipForward ? 'on' : 'OFF'], ['DNS/DHCP (dnsmasq)', s.services.dnsmasq ? 'running' : 'STOPPED'],
         ['Web UI', 'port ' + s.management.port + ' · LAN only (' + (l3().filter(i => i.role === 'lan').map(i => i.name).join(', ') || 'no LAN configured') + ')'],
         ['SSH', s.ssh.enabled ? 'on, port ' + s.ssh.port : 'off']]
          .map(([k, v]) => [h('dt', { class: 'col-5 text-secondary fw-normal' }, k), h('dd', { class: 'col-7 mb-1' }, v)]))))),
      h('div', { class: 'col-lg-7' }, card('Network segments', [btn('Manage', () => location.hash = '#segments')],
        table(['Segment', 'Interface', 'Role', 'Addresses', 'DHCP server'],
          l3().filter(i => i.role !== 'none').map(i => h('tr', {},
            h('td', {}, i.label || '—'), h('td', { class: 'mono' }, h('span', { class: 'dot ' + (i.carrier ? 'up' : 'down') }), i.name),
            h('td', {}, roleBadge(i.role)), h('td', { class: 'mono' }, i.addresses.join(' ') || (i.mode === 'dhcp' ? 'DHCP…' : '—')),
            h('td', {}, i.dhcpServer.enabled ? `${i.dhcpServer.start} – ${i.dhcpServer.end}` : '—'))),
          'No segments yet. Assign a WAN and LAN on the Segments page.'),
        !w && h('div', { class: 'card-body pt-0' }, h('div', { class: 'alert alert-warning mb-0 small' }, 'No WAN segment is defined: there is no internet access or outbound NAT until one interface has the WAN role.')))))
  ];
};

// ---------- interfaces (layer 2)
function bridgeCandidates(b) { return S.interfaces.filter(i => ['physical', 'vlan'].includes(i.kind) && !i.master && i.name !== b && i.parent !== b); }
function newBridge() {
  form('New bridge', [
    { k: 'name', label: 'Bridge name', value: 'br' + [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].find(n => !I('br' + n)), help: 'Up to 15 characters, e.g. br0.' },
    { k: 'vlanFiltering', label: 'VLAN-aware bridge (802.1Q filtering)', type: 'check', help: 'Required to carry several tagged VLANs over the bridge ports.' },
    { k: 'members', label: 'Ports', type: 'multi', options: bridgeCandidates('').map(i => [i.name, disp(i.name) + (i.addresses.length ? ' · ' + i.addresses.join(' ') : '')]),
      help: 'A port that already has an IP keeps it: the bridge takes over its address, MAC, DHCP client, role, DHCP server and firewall rules.' }
  ], v => apply('bridge.create', v, 'Bridge created'));
}
function newVlan() {
  const parents = S.interfaces.filter(i => ['physical', 'bridge'].includes(i.kind) && !i.master);
  form('New VLAN interface', [
    { k: 'parent', label: 'Parent interface', type: 'select', options: parents.map(i => [i.name, disp(i.name) + (i.kind === 'bridge' ? (i.vlanFiltering ? ' · VLAN-aware bridge' : ' · bridge') : '')]) },
    { k: 'vid', label: 'VLAN ID', type: 'number', placeholder: '1-4094' },
    { k: 'name', label: 'Interface name (optional)', placeholder: 'default: parent.vid' }
  ], v => apply('vlan.create', v, 'VLAN created'), { note: 'On a VLAN-aware bridge the VLAN is added to the bridge and trunked on all its ports automatically.' });
}
function addPort(b) {
  const c = bridgeCandidates(b.name);
  form('Add port to ' + b.name, [
    { k: 'member', label: 'Interface', type: 'select', options: c.map(i => [i.name, disp(i.name) + (i.addresses.length ? ' · ' + i.addresses.join(' ') : '')]) }
  ], v => apply('bridge.addmember', { bridge: b.name, member: v.member }, 'Port added'),
  { note: 'If the interface has an IP configuration and the bridge has none, the bridge takes it over (address, MAC, DHCP client, role, rules).' });
}
function portVlans(b, p) {
  const vl = p.vlans; const pv = vl.find(v => v.pvid);
  form(`VLANs on ${p.port}${p.self ? ' (bridge itself)' : ''}`, [
    { k: 'pvid', label: 'Untagged / PVID', type: 'number', value: pv ? pv.vid : '', help: 'Untagged frames on this port belong to this VLAN. Empty = drop untagged.' },
    { k: 'tagged', label: 'Tagged VLANs', type: 'list', value: vl.filter(v => !v.pvid).map(v => v.vid), placeholder: '20, 30' }
  ], v => apply('bridge.portvlans', { bridge: b.name, port: p.port, pvid: v.pvid, tagged: v.tagged }, 'Port VLANs applied'));
}
views.interfaces = () => {
  const rows = S.interfaces.map(i => {
    let relation = '';
    if (i.master) relation = h('span', {}, 'port of ', h('b', { class: 'mono' }, i.master));
    else if (i.kind === 'vlan') relation = h('span', {}, 'VLAN ', h('b', {}, i.vid), ' on ', h('span', { class: 'mono' }, i.parent));
    else if (i.kind === 'bridge') relation = h('span', {}, i.members.length ? i.members.map(m => h('span', { class: 'badge text-bg-light border me-1 mono' }, m,
      h('a', { href: '#', class: 'ms-1 text-danger text-decoration-none', title: 'remove port', onclick: e => { e.preventDefault();
        confirmDo('Remove port', `Remove ${m} from ${i.name}?`, () => apply('bridge.delmember', { bridge: i.name, member: m }, 'Port removed'), 'Remove'); } }, '×'))) : h('span', { class: 'text-secondary' }, 'no ports'),
      i.vlanFiltering && badge('VLAN-aware', 'text-bg-info'));
    const acts = i.kind === 'vpn' ? [badge('module-owned', 'text-bg-info')] : [btn('MTU', () => form('MTU of ' + i.name, [{ k: 'mtu', label: 'MTU', type: 'number', value: i.mtu }], v => apply('iface.set', { name: i.name, mtu: v.mtu })))];
    if (i.kind === 'bridge') acts.push(btn('+ Port', () => addPort(i)),
      btn(i.vlanFiltering ? 'VLAN filter off' : 'VLAN filter on', () => apply('bridge.set', { name: i.name, vlanFiltering: !i.vlanFiltering })),
      btn('Delete', () => confirmDo('Delete bridge', `Delete ${i.name}? If it has an IP configuration it is handed back to its first Ethernet port.`, () => apply('bridge.delete', { name: i.name }, 'Bridge deleted'), 'Delete'), 'btn-outline-danger'));
    if (i.kind === 'vlan') acts.push(btn('Delete', () => confirmDo('Delete VLAN', `Delete ${i.name}?`, () => apply('vlan.delete', { name: i.name }, 'VLAN deleted'), 'Delete'), 'btn-outline-danger'));
    return h('tr', {},
      h('td', { class: 'mono text-nowrap' }, h('span', { class: 'dot ' + (i.carrier ? 'up' : 'down'), title: i.oper }), i.name),
      h('td', {}, i.kind), h('td', {}, i.master ? '—' : roleBadge(i.role)), h('td', { class: 'mono small' }, i.mac), h('td', {}, i.mtu), h('td', {}, relation),
      h('td', { class: 'mono small' }, i.addresses.join(' ') || '—'), h('td', { class: 'text-end text-nowrap' }, acts));
  });
  const vcards = S.interfaces.filter(i => i.kind === 'bridge' && i.vlanFiltering).map(b =>
    card(`VLAN membership — ${b.name}`, null, table(['Port', 'Untagged (PVID)', 'Tagged', ''],
      b.bridgeVlans.map(p => h('tr', {}, h('td', { class: 'mono' }, p.port, p.self ? ' (bridge / VLAN interfaces)' : ''),
        h('td', {}, dash((p.vlans.find(v => v.pvid) || {}).vid)), h('td', {}, p.vlans.filter(v => !v.pvid).map(v => v.vid).join(', ') || '—'),
        h('td', { class: 'text-end' }, btn('Edit', () => portVlans(b, p))))))));
  return [card('Interfaces (layer 2)', [btn('New bridge', newBridge, 'btn-primary'), btn('New VLAN', newVlan, 'btn-primary')],
    table(['Name', 'Type', 'Edge role', 'MAC', 'MTU', 'Bridge / VLAN', 'IPv4', ''], rows)), vcards];
};

// ---------- segments (layer 3)
function editSegment(i) {
  const w = wan();
  form('Segment on ' + i.name, [
    { k: 'label', label: 'Segment name', value: i.label, placeholder: 'e.g. LAN, DMZ, IoT' },
    { k: 'role', label: 'Role', type: 'select', value: i.role, options: [['lan', 'LAN — internal network (routed through this firewall)'], ['wan', 'WAN — Internet edge (default route, inbound edge, outbound NAT)'], ['none', 'Unassigned']],
      help: w && w.name !== i.name ? `${w.name} is the WAN; there can only be one.` : null },
    { k: 'mode', label: 'Addressing', type: 'select', value: i.mode, options: [['static', 'Static'], ['dhcp', 'DHCP client'], ['none', 'No address']] },
    { k: 'addresses', label: 'Addresses (CIDR)', type: 'list', value: i.mode === 'static' ? i.addresses : [], placeholder: '192.168.10.1/24', show: v => v.mode === 'static' },
    { k: 'gateway', label: 'Default gateway', value: i.mode === 'static' ? i.gateway : '', show: v => v.mode === 'static' && v.role === 'wan' },
    { k: 'dns', label: 'Upstream DNS servers for the firewall', type: 'list', value: i.role === 'wan' && i.mode === 'static' ? S.system.resolvers : [], show: v => v.mode === 'static' && v.role === 'wan',
      help: 'Written to /etc/resolv.conf. With DHCP the provider\'s servers are used.' }
  ], v => apply('segment.set', Object.assign({ interface: i.name }, v), 'Segment applied'),
  { note: clientWarn(i.name), noteKind: 'warning' });
}
views.segments = () => {
  const w = wan();
  const lans = l3().filter(i => i.role === 'lan');
  return [
    h('div', { class: 'row g-3 mb-3' },
      h('div', { class: 'col-lg-6' }, card('WAN / Internet edge', null,
        h('div', { class: 'card-body' },
          w ? h('div', {},
            h('div', { class: 'd-flex align-items-center gap-2 mb-2' }, roleBadge('wan'), h('b', { class: 'mono' }, w.name), h('span', { class: 'text-secondary' }, w.label || 'WAN')),
            h('div', { class: 'small' }, 'Default egress and outbound NAT use this interface. New inbound Internet traffic arrives on this side and is controlled by firewall rules and port forwards.'),
            h('div', { class: 'small text-secondary mt-2' }, 'Gateway: ', dash(w.gateway), ' · Addressing: ', w.mode))
            : h('div', { class: 'alert alert-warning mb-0 small' }, 'No WAN is assigned. The appliance has no defined Internet edge or outbound NAT interface.')))),
      h('div', { class: 'col-lg-6' }, card('LAN / Internal networks', null,
        h('div', { class: 'card-body' },
          h('div', { class: 'small mb-2' }, 'LAN interfaces are internal routed networks. Traffic between LANs, and from a LAN to the Internet, crosses the firewall policy.'),
          lans.length ? h('div', {}, lans.map(i => h('div', { class: 'mb-1' }, roleBadge('lan'), ' ', h('b', { class: 'mono' }, i.name), ' ', i.label || '', h('span', { class: 'text-secondary' }, ' · ' + (i.addresses.join(' ') || i.mode)))))
            : h('div', { class: 'text-secondary small' }, 'No LAN interfaces are assigned yet.'))))),
    card('Network segments (layer 3)', null, table(['Interface', 'Name', 'Role', 'Addressing', 'Addresses', 'Gateway', 'DHCP server', ''],
      l3().map(i => h('tr', {},
        h('td', { class: 'mono' }, h('span', { class: 'dot ' + (i.carrier ? 'up' : 'down') }), i.name, h('div', { class: 'small text-secondary' }, i.kind)),
        h('td', {}, dash(i.label)), h('td', {}, roleBadge(i.role)), h('td', {}, i.mode),
        h('td', { class: 'mono small' }, i.addresses.join(' ') || '—'), h('td', { class: 'mono small' }, dash(i.gateway)),
        h('td', {}, i.dhcpServer.enabled ? `${i.dhcpServer.start} – ${i.dhcpServer.end}` : '—'),
        h('td', { class: 'text-end' }, btn('Edit', () => editSegment(i))))))),
    h('p', { class: 'small text-secondary' }, 'Bridge ports are configured through their bridge. Exactly one interface is the WAN / Internet edge. LAN interfaces are internal routed segments and remain isolated until firewall rules allow traffic.')
  ];
};

// ---------- DHCP
function editDhcpd(i) {
  const d = i.dhcpServer || { enabled: false }, c = i.addresses[0] || '';
  let start = d.start || '', end = d.end || '';
  if (!start && c) {
    const [n, prefix] = c.split('/');
    if (+prefix <= 24) {
      const base = ip2int(n) - ip2int(n) % 256;
      start = int2ip(base + 100);
      end = int2ip(base + 199);
    }
  }
  const own = c ? c.split('/')[0] : '';
  const canEnable = i.role === 'lan' && i.mode === 'static' && !!c;
  form('DHCP options — ' + disp(i.name), [
    { k: 'enabled', label: 'Enable DHCP server on this interface', type: 'check',
      value: !!d.enabled, help: 'OFF by default. Save these options without starting DHCP; enable it only when this segment is ready.' },
    { k: 'start', label: 'Dynamic address pool: first IP', value: start, placeholder: '192.168.10.100',
      help: 'Addresses offered to clients. Static MAC reservations can be outside this range.' },
    { k: 'end', label: 'Dynamic address pool: last IP', value: end, placeholder: '192.168.10.199' },
    { k: 'leaseTime', label: 'Lease duration', value: d.leaseTime || '12h',
      help: 'Examples: 30m, 12h, 1d, 7d. Clients renew automatically.' },
    { k: 'router', label: 'Default gateway handed to clients (option 3)',
      value: d.router && d.router !== own ? d.router : '', placeholder: own || 'LAN interface IP',
      help: 'Leave blank to give clients the firewall address for this subnet.' },
    { k: 'dns', label: 'DNS servers handed to clients (option 6)', type: 'list',
      value: (d.dns || []).length === 1 && d.dns[0] === own ? [] : (d.dns || []),
      placeholder: own || '192.168.10.1',
      help: 'One or more DNS server IPs, separated by commas. Leave blank for the firewall LAN address (including BIND if installed).' },
    { k: 'domain', label: 'DNS domain / suffix (option 15)',
      value: d.domain || '', placeholder: S.dns.domain || 'home.arpa',
      help: 'Domain name clients append to unqualified hostnames, e.g. home.arpa.' },
    { k: 'searchDomains', label: 'Additional DNS search domains (option 119)', type: 'list',
      value: d.searchDomains || [], placeholder: 'home.arpa, office.example',
      help: 'Optional ordered domain suffixes clients may search.' },
    { k: 'ntp', label: 'NTP time servers (option 42)', type: 'list',
      value: d.ntp || [], placeholder: '10.0.1.1',
      help: 'Optional time synchronization server IPs.' },
    { k: 'wins', label: 'WINS / NetBIOS name servers (option 44)', type: 'list',
      value: d.wins || [], placeholder: '10.0.1.10',
      help: 'Optional for legacy Windows environments.' },
    { k: 'bootFile', label: 'Network boot filename (PXE / option 67)',
      value: d.bootFile || '', placeholder: 'pxelinux.0', help: 'Optional PXE boot file; leave blank if not booting devices over the network.' },
    { k: 'nextServer', label: 'Network boot / TFTP server IP (option 66)',
      value: d.nextServer || '', placeholder: own || '10.0.1.10',
      help: 'Optional server hosting the PXE boot image; requires a boot filename.' }
  ], v => {
    if (v.enabled && !d.enabled && !confirm('Enable DHCP on ' + i.name +
      '? This will begin issuing IP leases on this interface.')) return;
    return apply('dhcpd.set', Object.assign({ interface: i.name }, v),
      v.enabled ? 'DHCP enabled on ' + i.name : 'DHCP options saved; DHCP remains OFF on ' + i.name);
  }, { note: canEnable
    ? 'All settings are per-interface. Saving with Enable DHCP unchecked stores the configuration but never starts DHCP.'
    : 'This interface is not a configured static LAN. You can save its DHCP options now, but must configure a static LAN before DHCP can be enabled.' });
}
function reserve(mac, ip, hostname, isEdit) {
  form(isEdit ? 'Edit reservation' : 'Make this address static', [
    { k: 'mac', label: 'MAC address', type: isEdit === 'new' ? 'text' : 'info', value: mac },
    { k: 'ip', label: 'Reserved IP address', value: ip, help: 'Maps this MAC to a fixed IP. Reservations are retained even while DHCP is OFF. For a new address, first configure the corresponding LAN interface/subnet.' },
    { k: 'hostname', label: 'Hostname', value: hostname, help: 'Optional. Resolves as hostname.' + (S.dns.domain || 'lan') + ' on the firewall DNS.' }
  ], v => apply('reservation.add', { mac: v.mac || mac, ip: v.ip, hostname: v.hostname }, 'Reservation applied'),
  { note: isEdit ? null : 'The device keeps its current address. If you choose a different IP it moves when it next renews its lease (or reconnects).' });
}
views.dhcp = () => {
  const now = Date.now() / 1000;
  const segments = l3();
  const leaseByMac = Object.fromEntries(S.dhcp.leases.map(l => [l.mac, l]));
  return [
    card('DHCP by interface', null, [
      h('div', { class: 'card-body py-2 small text-secondary' },
        'Each interface has independent DHCP settings: IP range, gateway, DNS, domain and more. You can save them with DHCP OFF. DNS here means the addresses handed to clients; the DNS page configures the firewall itself.'),
      table(['Interface', 'Role', 'Subnet', 'DHCP server', 'Range / lease', 'Gateway / DNS', ''],
        segments.map(i => { const d = i.dhcpServer || { enabled: false }; return h('tr', {},
          h('td', { class: 'mono' }, disp(i.name)),
          h('td', {}, roleBadge(i.role)),
          h('td', { class: 'mono small' }, i.addresses.join(', ') || 'not configured'),
          h('td', {}, badge(d.enabled ? 'ON' : 'OFF', d.enabled ? 'text-bg-success' : 'text-bg-secondary')),
          h('td', { class: 'mono small' }, d.start ? `${d.start} – ${d.end} · ${d.leaseTime || '12h'}` : 'not configured'),
          h('td', { class: 'mono small' }, d.router || (i.addresses[0] || '').split('/')[0] || 'automatic',
            ' / ', (d.dns || []).join(', ') || 'firewall DNS', !d.enabled && d.start && ' (saved, inactive)'),
          h('td', { class: 'text-end text-nowrap' },
            btn('Edit DHCP options', () => editDhcpd(i)))); }),
        'No routed interfaces. Configure an interface first.')
    ]),
    card('Leases', [btn('Refresh', load)], table(['IP', 'MAC', 'Hostname', 'Segment', 'Expires', 'Status', ''],
      S.dhcp.leases.slice().sort((a, b) => ip2int(a.ip) - ip2int(b.ip)).map(l => { const seg = segOf(l.ip); return h('tr', { class: l.expires && l.expires < now ? 'text-secondary' : '' },
        h('td', { class: 'mono' }, l.ip), h('td', { class: 'mono small' }, l.mac), h('td', {}, dash(l.hostname)),
        h('td', {}, seg ? disp(seg.name) : '—'), h('td', {}, rel(l.expires)),
        h('td', {}, l.reserved ? badge('static → ' + l.reservedIp, 'text-bg-success') : badge('dynamic', 'text-bg-light border')),
        h('td', { class: 'text-end' }, l.reserved ? btn('Edit', () => reserve(l.mac, l.reservedIp, (S.dhcp.reservations.find(r => r.mac === l.mac) || {}).hostname, true))
          : btn('Make static', () => reserve(l.mac, l.ip, l.hostname), 'btn-outline-primary'))); }), 'No leases yet.')),
    card('Static reservations', [btn('Add reservation', () => reserve('', '', '', 'new'), 'btn-primary')],
      table(['MAC', 'IP', 'Hostname', 'Current lease', ''], S.dhcp.reservations.map(r => { const l = leaseByMac[r.mac]; return h('tr', {},
        h('td', { class: 'mono small' }, r.mac), h('td', { class: 'mono' }, r.ip), h('td', {}, dash(r.hostname)),
        h('td', { class: 'small' }, l ? (l.ip === r.ip ? 'on reserved address' : `still on ${l.ip} until renewal`) : '—'),
        h('td', { class: 'text-end text-nowrap' }, btn('Edit', () => reserve(r.mac, r.ip, r.hostname, true)), ' ',
          btn('Delete', () => confirmDo('Delete reservation', `Delete the reservation of ${r.ip} for ${r.mac}?`, () => apply('reservation.delete', { mac: r.mac }, 'Reservation deleted'), 'Delete'), 'btn-outline-danger'))); })))
  ];
};

// Presets contain published IPv4 DNS addresses; native server IPs remain the source of truth.
function dnsResolverMatch(ips, emptyChoice) {
  if (!ips || !ips.length) return emptyChoice;
  const sorted = [...ips].sort().join(',');
  const preset = DNS_RESOLVER_PRESETS.find(p => [...p.ips].sort().join(',') === sorted);
  return preset ? preset.id : 'custom';
}
function dnsResolverFields(ips, emptyChoice, emptyLabel) {
  return [
    { k:'resolverChoice', label:'Upstream DNS provider / protection level', type:'select',
      value:dnsResolverMatch(ips, emptyChoice),
      options:[[emptyChoice,emptyLabel],['custom','Custom DNS servers — enter IPs manually']]
        .concat(DNS_RESOLVER_PRESETS.map(p => [p.id, p.provider + ' — ' + p.name + ' · ' + p.level])),
      help:'Choose a provider and its filtering profile. Never mix filtered and unfiltered DNS resolvers; filtering only works if clients use this resolver.' },
    { k:'customResolvers', label:'Custom upstream DNS IP addresses', type:'list',
      value:ips || [], placeholder:'192.168.1.1, 1.1.1.1',
      show:v => v.resolverChoice === 'custom',
      help:'Enter IPv4 addresses. For family policies, use only resolvers enforcing the same filtering level.' }
  ];
}
function dnsResolverIPs(v) {
  if (v.resolverChoice === 'custom') {
    if (!v.customResolvers || !v.customResolvers.length) throw new Error('Enter at least one custom upstream DNS address.');
    return v.customResolvers;
  }
  if (v.resolverChoice === 'automatic' || v.resolverChoice === 'direct') return [];
  const preset = DNS_RESOLVER_PRESETS.find(p => p.id === v.resolverChoice);
  if (!preset) throw new Error('Select an upstream DNS provider.');
  return [...preset.ips];
}
function dnsResolverIsFiltered(v) {
  const p = DNS_RESOLVER_PRESETS.find(x => x.id === v.resolverChoice);
  return !!p && !!p.filters;
}
function dnsResolverDetails(root, getValues) {
  const select = root.querySelector('#f_resolverChoice');
  if (!select) return;
  const detail = h('div', { class:'alert alert-light border small mb-3' });
  select.closest('.mb-3').after(detail);
  const update = () => {
    const v = getValues(), p = DNS_RESOLVER_PRESETS.find(x => x.id === v.resolverChoice);
    if (!p) {
      detail.textContent = v.resolverChoice === 'custom'
        ? 'Custom DNS — enter upstream IPs. Filtering depends entirely on your servers.'
        : v.resolverChoice === 'automatic'
          ? 'Automatic WAN DNS — uses resolvers supplied by the network; filtering depends on those servers.'
          : 'Direct recursion — BIND resolves via root DNS servers, without an upstream filtering provider.';
      return;
    }
    detail.replaceChildren(
      h('div', { class:'fw-semibold' }, p.provider + ' — ' + p.name),
      h('div', {}, p.details),
      h('div', { class:'mono mt-1' }, p.ips.join('  ·  ')),
      h('div', { class:'mt-1 text-secondary' },
        p.filters ? 'Filtering relies on these upstream resolvers. Clients may bypass it using VPNs or encrypted DNS.' :
          'This profile does not provide a built-in family filtering policy.'),
      h('a', { href:p.docs, target:'_blank', rel:'noopener noreferrer', class:'d-inline-block mt-1' }, 'Provider documentation'));
  };
  select.addEventListener('change', update);
  update();
}
function dnsResolverSummary(ips, emptyLabel) {
  if (!ips || !ips.length) return emptyLabel;
  const p = DNS_RESOLVER_PRESETS.find(x => [...x.ips].sort().join(',') === [...ips].sort().join(','));
  return p ? p.provider + ' — ' + p.name + ' (' + p.level + ') · ' + ips.join(', ') :
    'Custom DNS · ' + ips.join(', ');
}

// ---------- DNS
function dnsmasqPanel() {
  const d = S.dns;
  const edit = () => form('DNS settings', [
    { k: 'domain', label: 'Local domain', value: d.domain || 'lan', help: 'DHCP clients and reservations resolve as name.domain.' },
    ...dnsResolverFields(d.upstream, 'automatic', 'Automatic — use WAN / system DNS resolvers'),
    { k: 'hosts', label: 'Local host records (one per line: name ip)', type: 'textarea', value: d.hosts.map(x => `${x.name} ${x.ip}`).join('\n'), placeholder: 'nas 192.168.10.5' }
  ], v => apply('dns.set', {
    domain:v.domain, upstream:dnsResolverIPs(v),
    hosts:v.hosts.split('\n').map(l => l.trim().split(/\s+/)).filter(x => x[0]).map(([name, ip]) => ({name, ip}))
  }, 'DNS applied'), {
    note: moduleState('bind').running
      ? 'BIND9 owns DNS port 53. The dnsmasq upstream choices here can be saved but will not serve DNS queries until BIND releases the port.'
      : 'Plain DNS forwarding on UDP/TCP port 53. A filtering preset blocks only the categories its provider identifies.',
    decorate:dnsResolverDetails
  });
  const core = card('DNS resolver (dnsmasq)', [btn('Edit', edit, 'btn-primary')], h('div', { class: 'card-body' },
    h('dl', { class: 'row mb-0' },
      h('dt', { class: 'col-sm-3' }, 'Local domain'), h('dd', { class: 'col-sm-9 mono' }, dash(d.domain)),
      h('dt', { class: 'col-sm-3' }, 'Upstream servers'), h('dd', { class: 'col-sm-9 mono' }, dnsResolverSummary(d.upstream, 'WAN resolvers (' + S.system.resolvers.join(', ') + ')')),
      h('dt', { class: 'col-sm-3' }, 'DNS listener'), h('dd', { class: 'col-sm-9' },
        moduleState('bind').running ? 'Disabled — BIND9 currently serves DNS on port 53' : 'dnsmasq (LAN interfaces)'),
      h('dt', { class: 'col-sm-3' }, 'Configured LANs'), h('dd', { class: 'col-sm-9' }, l3().filter(i => i.role === 'lan').map(i => disp(i.name)).join(', ') || 'none'),
      h('dt', { class: 'col-sm-3' }, 'Host records'), h('dd', { class: 'col-sm-9 mono' }, d.hosts.length ? d.hosts.map(x => h('div', {}, `${x.name} → ${x.ip}`)) : '—'))));
  return core;
}
views.dns = () => [
  card('DNS engines', null, h('div', { class:'card-body' },
    h('p', { class:'mb-2 small' },
      moduleState('bind').running ? 'BIND9 is the active DNS listener. DNSMasq still supplies DHCP.' :
        'DNSMasq is the active LAN DNS resolver. BIND9 may be installed for authoritative zones.'),
    h('div', { class:'d-flex gap-2 flex-wrap' },
      btn('DNSMasq settings', () => location.hash = '#module-dnsmasq', 'btn-primary'),
      btn('BIND9 settings & zones', () => location.hash = '#module-bind', 'btn-outline-primary')))),
  card('DNSMasq forwarding', [btn('Manage DNSMasq', () => location.hash = '#module-dnsmasq')],
    h('div', { class:'card-body small' },
      dnsResolverSummary(S.dns.upstream, 'Automatic WAN resolvers'),
      h('div', { class:'mt-1 text-secondary' }, moduleState('bind').running ?
        'DNS listener currently disabled in favor of BIND9; DHCP remains available.' : 'DNS listener enabled on LAN interfaces.')))
];
views['module-dnsmasq'] = () => [
  h('div', { class:'mb-3' }, btn('Back to modules', () => location.hash = '#modules')),
  card('DNSMasq DNS engine', null, h('div', { class:'card-body small' },
    moduleState('bind').running ?
      'BIND9 currently listens on port 53. You can edit DNSMasq forwarders now; they take effect when BIND is stopped. DHCP is unaffected.' :
      'DNSMasq provides DNS on LAN interfaces and DHCP. Choose a filtering provider or custom upstream below.')),
  moduleState('bind').running
    ? card('Make DNSMasq the active DNS resolver',
        [btn('Switch DNS to DNSMasq', () => confirmDo('Switch DNS service',
          'Stop BIND and activate DNSMasq DNS on the LAN? BIND zones stay on disk. DHCP settings and service are unchanged.',
          () => apply('bind.service', {action:'stop'}, 'DNSMasq DNS activated'), 'Switch DNS'),
          'btn-primary')],
        h('div', {class:'card-body small'}, 'Stopping BIND releases port 53 for DNSMasq while preserving its authoritative zones.'))
    : null,
  dnsmasqPanel()
].filter(Boolean);


// ---------- optional modules
const moduleBy = id => (S.modules || []).find(m => m.id === id);
const moduleState = id => {
  const m = moduleBy(id);
  return m && m.installed ? (m.state || {}) : {};
};
const moduleServiceButtons = (opName, running, configured) => [
  running
    ? btn('Stop', () => apply(opName, { action: 'stop' }, 'Service stopped'), 'btn-outline-danger')
    : btn('Start', () => apply(opName, { action: 'start' }, 'Service started'), 'btn-outline-success'),
  configured && btn('Restart', () => apply(opName, { action: 'restart' }, 'Service restarted'))
].filter(Boolean);

async function moduleInstall(m) {
  try {
    await apply('module.install', { id: m.id }, m.name + ' installed and verified');
    location.hash = '#module-' + m.id;
  } catch (e) {
    // Unlike dialog operations, module install buttons do not have a modal
    // error field. Show the actual APK/native-service failure to the operator.
    toast(m.name + ' installation failed: ' + e.message, 'danger');
  }
}
function moduleRemove(m) {
  confirmDo('Remove ' + m.name,
    'Remove ' + m.name + ', its package, and the native configuration created for it? Base firewall configuration is left intact.',
    () => apply('module.remove', { id: m.id }, m.name + ' removed'), 'Remove');
}

function bindSettingsForm() {
  const x = moduleState('bind');
  const lanAddrs = l3().filter(i => i.role === 'lan').flatMap(i => i.addresses.map(a => a.split('/')[0]));
  const lanCidrs = l3().filter(i => i.role === 'lan').flatMap(i => i.addresses);
  form('BIND DNS settings', [
    { k: 'listenAddresses', label: 'Listen addresses', type: 'list', value: x.listenAddresses || lanAddrs, placeholder: '192.168.10.1', help: 'Use 0.0.0.0 to listen on every IPv4 address.' },
    { k: 'allowQuery', label: 'Allow queries from', type: 'list', value: x.allowQuery || ['any'], placeholder: 'any, or CIDR ranges' },
    { k: 'allowTransfer', label: 'Allow zone transfers from', type: 'list', value: x.allowTransfer || [], placeholder: 'empty = none' },
    { k: 'recursion', label: 'Enable recursion', type: 'check', value: !!x.recursion },
    { k: 'recursiveClients', label: 'Recursive clients', type: 'list', value: x.recursiveClients || lanCidrs, placeholder: '192.168.10.0/24', help: 'Required when recursion is enabled. Open recursion is rejected.', show: v => v.recursion },
    ...dnsResolverFields(x.forwarders || [], 'direct', 'Direct recursion — no upstream forwarders'),
    { k: 'forwardMode', label: 'Forwarder policy (custom or unfiltered)', type: 'select', value: x.forwardMode || 'first',
      options: [['first', 'First — try forwarders, then resolve directly if they fail'],
                ['only', 'Only — send recursive queries exclusively to forwarders']],
      show: v => v.recursion && v.resolverChoice !== 'direct' && !dnsResolverIsFiltered(v),
      help:'Filtered presets always use forward-only so a failed upstream cannot silently bypass filtering.' },
    { k: 'dnssecValidation', label: 'DNSSEC validation', type: 'select', value: x.dnssecValidation || 'auto',
      options: [['auto','Automatic (recommended)'], ['yes','Enabled'],['no','Disabled']],
      help: 'Validates signed DNS data. Requires working DNSSEC trust anchors and upstream connectivity.' },
    { k: 'minimalResponses', label: 'Minimal DNS responses', type: 'check', value: x.minimalResponses !== false,
      help: 'Reduce additional DNS answer data and response size.' },
    { k: 'maxCacheTtl', label: 'Maximum positive-answer cache TTL (seconds)', type: 'number', value: x.maxCacheTtl ?? 86400,
      help: 'How long cached positive answers are retained (0–604800 seconds).' },
    { k: 'maxNegativeTtl', label: 'Maximum negative-answer cache TTL (seconds)', type: 'number', value: x.maxNegativeTtl ?? 10800,
      help: 'Maximum caching for NXDOMAIN/no-answer responses (0–604800 seconds).' },
    { k: 'listenIPv6', label: 'Also listen on all IPv6 interfaces', type: 'check', value: !!x.listenIPv6,
      help: 'May expose DNS on WAN IPv6. Use appropriate network/firewall restrictions.' }
  ], v => {
    const ips = dnsResolverIPs(v);
    if (ips.length && !v.recursion &&
        v.resolverChoice !== dnsResolverMatch(x.forwarders || [], 'direct'))
      throw new Error('Enable recursion to activate a new upstream DNS provider.');
    return apply('bind.settings', {
      ...v, forwarders:ips,
      forwardMode:dnsResolverIsFiltered(v) ? 'only' : (v.forwardMode || 'first')
    }, 'BIND settings applied');
  }, {
    note: 'BIND owns DNS port 53. Filtered provider presets automatically use forward-only mode; they never fail over to unfiltered root resolution. DHCP remains unchanged.',
    decorate:dnsResolverDetails
  });
}

function bindAddZone() {
  const x = moduleState('bind');
  const nsAddr = (x.listenAddresses || []).find(a => a !== '127.0.0.1' && a !== '0.0.0.0') || '';
  form('Add authoritative zone', [
    { k: 'name', label: 'Zone', placeholder: 'example.internal' },
    { k: 'primaryNs', label: 'Primary nameserver', placeholder: 'ns1.example.internal' },
    { k: 'primaryNsAddress', label: 'Primary nameserver IPv4 address', value: nsAddr, placeholder: '192.168.10.1', help: 'Required when the primary nameserver is inside this zone.' },
    { k: 'admin', label: 'SOA administrator', placeholder: 'hostmaster.example.internal' },
    { k: 'ttl', label: 'Default TTL', type: 'number', value: 3600 },
    { k: 'refresh', label: 'SOA refresh', type: 'number', value: 3600 },
    { k: 'retry', label: 'SOA retry', type: 'number', value: 600 },
    { k: 'expire', label: 'SOA expire', type: 'number', value: 1209600 },
    { k: 'minimum', label: 'Negative cache TTL', type: 'number', value: 300 }
  ], v => apply('bind.zoneadd', v, 'Zone created'));
}

// Structured DNS editor. BIND compiles the original zone into a canonical
// record table; users never need to understand zone-file syntax.
async function bindManageZoneRecords(zone) {
  const data = (await op('bind.zonerecords', {zone})).result;
  const supported = ['A','AAAA','CNAME','MX','NS','PTR','TXT'];
  const filter = h('input', { class:'form-control form-control-sm mb-3', type:'search',
    placeholder:'Filter records by host, type or value', 'aria-label':'Filter DNS records' });
  const tbody = h('tbody', {});
  const nameOf = r => {
    const suffix = '.' + zone.toLowerCase() + '.';
    const host = r.owner.toLowerCase();
    return host === zone.toLowerCase() + '.' ? '@' :
      host.endsWith(suffix) ? r.owner.slice(0, -suffix.length) : r.owner;
  };
  const edit = r => {
    if (!supported.includes(r.type)) return;
    const parts = r.type === 'MX' ? r.value.split(/\s+/) : [];
    const value = r.type === 'MX' ? parts.slice(1).join(' ') :
      (r.type === 'TXT' && /^".*"$/.test(r.value) ? r.value.slice(1,-1) : r.value);
    form('Edit ' + r.type + ' record — ' + zone, [
      { k:'name', label:'Host / record name', value:nameOf(r), help:'@ is the zone root; names are relative to this zone.' },
      { k:'type', label:'Record type', type:'select', value:r.type, options:supported.map(t => [t,t]) },
      { k:'value', label:'Target / address / text', value },
      { k:'ttl', label:'TTL (seconds)', type:'number', value:r.ttl },
      { k:'priority', label:'MX priority', type:'number', value:r.type === 'MX' ? (parts[0] || 10) : 10,
        show:v => v.type === 'MX' }
    ], v => apply('bind.recordchange', {
      zone, expectedSha:data.sha, index:r.index, action:'replace', ...v
    }, 'DNS record updated'), {
      note:'Changes are checked by BIND and saved with an automatic SOA serial increment and a backup. The native zone file is normalized when editing an imported record.'
    });
  };
  const remove = r => confirmDo('Delete ' + r.type + ' record',
    'Delete ' + r.owner + ' ' + r.type + ' ' + r.value + '? BIND validates the remaining zone before applying.',
    () => apply('bind.recordchange', {
      zone, expectedSha:data.sha, index:r.index, action:'delete'
    }, 'DNS record deleted'), 'Delete');
  const renderRows = () => {
    const term = filter.value.toLowerCase().trim();
    const records = (data.records || []).filter(r =>
      !term || (r.owner+' '+r.type+' '+r.value).toLowerCase().includes(term));
    tbody.replaceChildren(...records.map(r => h('tr', {},
      h('td', { class:'mono small' }, nameOf(r)),
      h('td', {}, badge(r.type, r.type === 'SOA' ? 'text-bg-secondary' : 'text-bg-light border text-dark')),
      h('td', { class:'mono small text-break' }, r.value),
      h('td', { class:'mono small' }, r.ttl),
      h('td', { class:'text-end text-nowrap' }, r.type !== 'SOA' ? [
        supported.includes(r.type) ? btn('Edit', () => edit(r), 'btn-outline-primary') : null,
        ' ', btn('Delete', () => remove(r), 'btn-outline-danger')
      ] : badge('managed')))),
      ...(records.length ? [] : [h('tr', {}, h('td', { colspan:5, class:'text-secondary' }, 'No matching DNS records'))]));
  };
  filter.addEventListener('input', renderRows);
  renderRows();
  dlgChrome('DNS records — ' + zone, 'Close');
  $('#dlgBody').replaceChildren(
    h('div', { class:'alert alert-info py-2 small' },
      'All records (including imported ones) are shown. The SOA is managed automatically. Edits are version checked, validated and backed up.'),
    h('div', { class:'d-flex gap-2 mb-3 flex-wrap' },
      btn('Add record', () => bindAddRecord(zone), 'btn-primary'),
      btn('Advanced: zone file', () => bindZoneFileEditor(zone), 'btn-outline-secondary')),
    filter,
    h('div', { class:'table-responsive' }, h('table', { class:'table table-sm table-hover align-middle' },
      h('thead', {}, h('tr', {}, ['Name','Type','Value','TTL',''].map(x => h('th', {}, x)))), tbody)));
  dlgApply = async () => {};
  showDlg();
}

// Edit the full native zone file. Upload simply inserts local file text into the
// editor; server-side named-checkzone validates before modifying live BIND.
async function bindZoneFileEditor(zoneName = '') {
  let existing = { name:'', source:'', sha:'' };
  if (zoneName) existing = (await op('bind.zoneread', {zone:zoneName})).result;
  const fields = [
    { k:'name', label:'Zone name', type:'info', value:zoneName || 'Choose below' },
    ...(!zoneName ? [{ k:'newName', label:'New zone name', value:'', placeholder:'example.internal' }] : []),
    { k:'source', label:'Zone file text', type:'textarea', rows:18, value:existing.source,
      placeholder:'$TTL 3600\n@ IN SOA ns1.example.internal. hostmaster.example.internal. ( 2026110201 3600 600 1209600 300 )\n@ IN NS ns1.example.internal.',
      help:'BIND master-zone syntax. Include SOA and NS. Increase the SOA serial when editing an existing zone; include files and generate directives are disallowed.' }
  ];
  const ui = buildFields(fields);
  const uploader = h('input', { type:'file', class:'form-control form-control-sm', accept:'.zone,.db,.txt,.dns,text/plain',
    'aria-label':'Upload existing DNS zone file' });
  uploader.addEventListener('change', async () => {
    const file = uploader.files && uploader.files[0]; if (!file) return;
    if (file.size > 65536) { $('#dlgErr').textContent = 'Zone files must be 64 KiB or smaller.'; return; }
    ui.body.querySelector('#f_source').value = await file.text();
    $('#dlgErr').textContent = '';
  });
  dlgChrome(zoneName ? 'Edit zone file: ' + zoneName : 'Create or import a DNS zone', zoneName ? 'Validate and save' : 'Create zone');
  $('#dlgBody').replaceChildren(
    h('div', { class:'alert alert-info py-2 small' },
      'Save validates the complete zone with BIND before replacing anything. Existing zone files are backed up on the firewall.'),
    h('label', { class:'form-label small fw-semibold' }, 'Import text from a zone file on this device'),
    uploader, ui.body);
  dlgApply = async () => {
    const v = ui.vals(); const zone = zoneName || v.newName;
    if (!zone || !v.source || v.source.length < 30) throw new Error('Enter a zone name and complete SOA/NS zone file.');
    return apply('bind.zonewrite', {zone, source:v.source + '\n', expectedSha:existing.sha || '', create:!zoneName},
      zoneName ? 'Zone file validated and updated' : 'New DNS zone created');
  };
  showDlg();
}

function bindAddRecord(zone) {
  form('Add record to ' + zone, [
    { k: 'name', label: 'Name', value: '@', help: '@ means the zone apex. Wildcards such as *.apps are supported.' },
    { k: 'type', label: 'Type', type: 'select', value: 'A', options: [['A','A'],['AAAA','AAAA'],['CNAME','CNAME'],['MX','MX'],['NS','NS'],['PTR','PTR'],['TXT','TXT']] },
    { k: 'value', label: 'Value' },
    { k: 'ttl', label: 'TTL', type: 'number', value: 300 },
    { k: 'priority', label: 'MX priority', type: 'number', value: 10, show: v => v.type === 'MX' }
  ], v => apply('bind.recordadd', Object.assign({ zone }, v), 'Record added'));
}

function bindPanel() {
  const m = moduleBy('bind'); if (!m || !m.installed) return [];
  const x = moduleState('bind'), zones = x.zones || [];
  const zoneRows = zones.map(z => h('tr', {},
    h('td', { class: 'mono' }, z.name),
    h('td', { class: 'mono' }, z.serial || '—'),
    h('td', {}, (z.records || []).length ? (z.records || []).map(r =>
      h('div', { class: 'd-flex gap-2 align-items-center mb-1' },
        h('code', { class: 'flex-grow-1' }, r.text),
        btn('Delete', () => confirmDo('Delete DNS record', 'Delete this record from ' + z.name + '?',
          () => apply('bind.recorddelete', { zone: z.name, id: r.id }, 'Record deleted'), 'Delete'), 'btn-outline-danger')))
      : h('span', { class: 'text-secondary small' }, 'Open records to view imported and managed entries')),
    h('td', { class: 'text-end text-nowrap' },
      btn('Manage records', () => bindManageZoneRecords(z.name), 'btn-primary'), ' ',
      btn('Advanced source', () => bindZoneFileEditor(z.name), 'btn-outline-secondary'), ' ',
      btn('Delete zone', () => confirmDo('Delete zone', 'Delete zone ' + z.name + ' and its zone file?',
        () => apply('bind.zonedelete', { name: z.name }, 'Zone deleted'), 'Delete'), 'btn-outline-danger'))));
  return [
    card('BIND DNS service', [
      btn('Settings', bindSettingsForm, 'btn-primary'),
      ...moduleServiceButtons('bind.service', !!x.running, !!x.configured)
    ], h('div', { class: 'card-body small' },
      x.configured
        ? h('dl', { class: 'row mb-0' },
            h('dt', { class: 'col-sm-3' }, 'Status'), h('dd', { class: 'col-sm-9' }, x.running ? badge('running','text-bg-success') : badge('stopped')),
            h('dt', { class: 'col-sm-3' }, 'Listen'), h('dd', { class: 'col-sm-9 mono' }, (x.listenAddresses || []).join(', ') || '—'),
            h('dt', { class: 'col-sm-3' }, 'Recursion'), h('dd', { class: 'col-sm-9' }, x.recursion ? 'restricted to ' + (x.recursiveClients || []).join(', ') : 'off'),
            h('dt', { class: 'col-sm-3' }, 'Forwarders'), h('dd', { class: 'col-sm-9 mono' },
              dnsResolverSummary(x.forwarders, 'direct recursion / none'),
              x.forwarders && x.forwarders.length ? ' (' + (x.forwardMode || 'first') + ')' : ''),
            h('dt', { class: 'col-sm-3' }, 'DNSSEC / caching'), h('dd', { class: 'col-sm-9' },
              (x.dnssecValidation || 'auto') + ' · max TTL ' + (x.maxCacheTtl ?? 86400) + 's'))
        : 'Installed but not configured. Apply DNS settings before starting the service.')),
    card('BIND authoritative zones', [btn('Add zone', bindAddZone, 'btn-primary'), ' ',
      btn('Create / import zone file', () => bindZoneFileEditor(), 'btn-outline-primary')],
      table(['Zone', 'Serial', 'Records', ''], zoneRows, 'No authoritative zones configured.'))
  ];
}


function openvpnSettingsForm() {
  const x = moduleState('openvpn');
  const inbound = [['wan', 'WAN role']].concat(routeIfaces().filter(i => i.kind !== 'vpn').map(i => [i.name, disp(i.name)]));
  const lanRoutes = l3().filter(i => i.role === 'lan').flatMap(i => i.addresses);
  const lanDns = l3().filter(i => i.role === 'lan').flatMap(i => i.addresses.map(a => a.split('/')[0]));
  form('OpenVPN server', [
    { k: 'publicHost', label: 'Public host or DDNS name', value: x.publicHost || '', placeholder: 'vpn.example.com' },
    { k: 'inboundInterface', label: 'Inbound interface', type: 'select', value: x.inboundInterface || 'wan', options: inbound },
    { k: 'interface', label: 'VPN interface', value: x.interface || 'tun0' },
    { k: 'protocol', label: 'Protocol', type: 'select', value: x.protocol || 'udp', options: [['udp','UDP'],['tcp','TCP']] },
    { k: 'port', label: 'Port', type: 'number', value: x.port || 1194 },
    { k: 'network', label: 'VPN client network', value: x.network || '10.8.0.0/24' },
    { k: 'dns', label: 'DNS servers pushed to clients', type: 'list', value: x.dns || lanDns },
    { k: 'routes', label: 'Routes pushed to clients', type: 'list', value: x.routes || lanRoutes },
    { k: 'redirectGateway', label: 'Route all client traffic through this firewall', type: 'check', value: !!x.redirectGateway },
    { k: 'clientToClient', label: 'Allow VPN clients to talk directly to each other', type: 'check', value: !!x.clientToClient }
  ], v => apply('openvpn.server', v, 'OpenVPN server applied'), {
    note: 'The service port is opened on the selected inbound interface. Traffic from the VPN interface remains default-deny until firewall rules allow it.'
  });
}

function openvpnAddClient() {
  form('Create OpenVPN client', [
    { k: 'name', label: 'Client name', placeholder: 'laptop', help: 'Creates a client certificate and profile.' }
  ], v => apply('openvpn.clientadd', v, 'VPN client created'));
}
async function openvpnGetProfile(name) {
  const j = await op('openvpn.profile', { name });
  const data = new Blob([j.result.profile], { type: 'application/x-openvpn-profile' });
  const u = URL.createObjectURL(data), a = document.createElement('a');
  a.href = u; a.download = name + '.ovpn'; a.click();
  setTimeout(() => URL.revokeObjectURL(u), 1000);
}
function openvpnClientTunnelForm(existing = null) {
  const x = existing || {};
  const current = moduleState('openvpn').clientTunnels || [];
  const used = new Set(current.filter(t => t.id !== x.id).map(t => t.interface));
  const guess = Array.from({length:15},(_,i)=>'tun'+(i+1)).find(i => !used.has(i)) || 'tun1';
  form(existing ? 'Edit OpenVPN client tunnel' : 'New OpenVPN client tunnel', [
    {k:'id',label:'Client tunnel name',value:x.id||'',placeholder:'office',help:'Lowercase letters, numbers and hyphens. Cannot be renamed after creation.'},
    {k:'mode',label:'Tunnel type',type:'select',value:x.mode||'point-to-site',
      options:[['point-to-site','Point-to-site (remote access client)'],['site-to-site','Site-to-site (branch gateway client)']]},
    {k:'interface',label:'Tunnel interface',value:x.interface||guess,help:'Unique tunN device, different from the OpenVPN server.'},
    {k:'localSubnet',label:'Local LAN subnet',value:x.localSubnet||'',placeholder:'10.0.1.0/24',show:v=>v.mode==='site-to-site',
      help:'The peer server must also have this network routed through your client certificate.'},
    {k:'remoteSubnet',label:'Remote network',value:x.remoteSubnet||'',placeholder:'192.168.20.0/24',
      help:'Required for site-to-site; optional for point-to-site.'},
    {k:'profile',label:'Client .ovpn profile (with inline certificates)',type:'textarea',rows:11,value:'',
      placeholder:'client\nproto udp\nremote vpn.example.com 1194\n<ca>\n...\n</ca>\n<cert>\n...\n</cert>\n<key>\n...\n</key>\n<tls-crypt>\n...\n</tls-crypt>',
      help:existing?'Leave empty to keep the current certificate/key profile.':'Paste a certificate-based OpenVPN client profile with inline CA, cert, key and TLS key. Executable script directives are rejected.'}
  ],v=>apply('openvpn.instanceadd',v,'OpenVPN client profile saved; start it explicitly when ready'),{
    note:'Saving does not start the tunnel, change the default route, or modify the existing OpenVPN server. Imported private keys remain on the appliance; they are never returned by the API.',
    applyText:'Validate and save'
  });
}
function openvpnSitePeerForm(existing = null) {
  const x=existing||{};
  form(existing?'Edit site-to-site peer':'Add site-to-site peer',[
    {k:'id',label:'Client certificate name',value:x.id||'',placeholder:'branch-office',
      help:'Create a client certificate below first. Use exactly its name.'},
    {k:'localSubnet',label:'This site LAN subnet',value:x.localSubnet||'',placeholder:'10.0.1.0/24'},
    {k:'remoteSubnet',label:'Peer site LAN subnet',value:x.remoteSubnet||'',placeholder:'10.55.0.0/24'}
  ],v=>apply('openvpn.sitepeeradd',v,'Site-to-site peer routing saved; restart OpenVPN server to apply'),{
    note:'Adds a certificate-bound CCD route and a server route for the remote subnet. Client profile certificate must already exist. Server restart is explicit; existing remote access sessions may disconnect on restart.',
    applyText:'Save peer routes'
  });
}
function ipsecTunnelForm(existing=null) {
  const x=existing||{};
  form(existing?'Edit IPsec site-to-site tunnel':'New IPsec site-to-site tunnel',[
    {k:'id',label:'Tunnel name',value:x.id||'',placeholder:'branch-office',help:'Lowercase letters, numbers and hyphens.'},
    {k:'peer',label:'Remote VPN gateway (IP or DNS)',value:x.peer||'',placeholder:'198.51.100.10'},
    {k:'localId',label:'Local IKE identity',value:x.localId||'',placeholder:'fw.example.net'},
    {k:'remoteId',label:'Remote IKE identity',value:x.remoteId||'',placeholder:'branch.example.net'},
    {k:'localSubnet',label:'Local protected network',value:x.localSubnet||'',placeholder:'10.0.1.0/24'},
    {k:'remoteSubnet',label:'Remote protected network',value:x.remoteSubnet||'',placeholder:'10.44.0.0/24'},
    {k:'psk',label:'IKEv2 pre-shared key',type:'password',value:'',
      help:x.credentialConfigured?'Leave blank to preserve the existing secret.':'At least 20 characters. Prefer a long randomly generated secret.'},
    {k:'enabled',label:'Allow manual initiation of this tunnel',type:'check',value:!!x.enabled}
  ],v=>apply('ipsec.tunnelset',v,'IPsec tunnel saved; use Start to initiate when ready'),{
    note:'IKEv2 site-to-site using strongSwan. Saves protected native swanctl configuration without starting the tunnel. Ensure the peer has matching IDs, subnets, cipher proposals, and PSK.',
    applyText:'Validate and save'
  });
}
function ipsecPanel() {
  const m=moduleBy('ipsec');if(!m)return [];
  if(!m.installed)return [card('IPsec (strongSwan)',
    [btn('Install IPsec',()=>moduleInstall(m),'btn-primary')],
    h('div',{class:'card-body small'},'Optional IPsec module. Installation adds Alpine strongSwan packages but does not enable or start any tunnel.'))];
  const x=moduleState('ipsec'), tunnels=x.tunnels||[];
  return [
    card('IPsec service (IKEv2 / strongSwan)',[
      btn('Add site-to-site tunnel',()=>ipsecTunnelForm(),'btn-primary'),
      ...moduleServiceButtons('ipsec.service',!!x.running,true)
    ], h('div',{class:'card-body small'},
      h('div',{class:'mb-2'},'Status: ',x.running?badge('running','text-bg-success'):badge('stopped')),
      h('p',{class:'mb-0'},'Native swanctl configurations. Save profiles first, then start strongSwan and explicitly initiate a tunnel. Traffic is subject to your existing firewall rules; the IKE ports are opened only while the service runs.'))),
    card('IPsec site-to-site tunnels',
      [btn('Add tunnel',()=>ipsecTunnelForm(),'btn-primary')],
      table(['Tunnel','Gateway','Traffic selectors','Enabled','Actions'],
        tunnels.map(t=>h('tr',{},
          h('td',{class:'mono'},t.id),
          h('td',{class:'mono'},t.peer),
          h('td',{class:'mono small'},t.localSubnet+' ⇄ '+t.remoteSubnet),
          h('td',{},t.established ? badge('connected','text-bg-success') : (t.enabled?'Ready / disconnected':'Disabled')),
          h('td',{class:'text-end'},
            btn('Edit',()=>ipsecTunnelForm(t),'btn-outline-primary'),' ',
            ...(t.enabled&&x.running?[btn('Start',()=>apply('ipsec.tunnelstart',{id:t.id},'IPsec initiation requested'),'btn-primary'),' ',
                btn('Stop',()=>apply('ipsec.tunnelstop',{id:t.id},'IPsec tunnel stopped'),'btn-outline-secondary'),' ']:[]),
            btn('Delete',()=>confirmDo('Delete IPsec tunnel','Remove '+t.id+'? A backup of its native configuration will remain on the firewall.',
              ()=>apply('ipsec.tunneldelete',{id:t.id},'IPsec tunnel deleted'),'Delete'),'btn-outline-danger')))),
        'No site-to-site IPsec tunnels are configured.'))
  ];
}

function openvpnPanel() {
  const m = moduleBy('openvpn'); if (!m || !m.installed) return [];
  const x = moduleState('openvpn'), clients = x.clients || [],
    clientTunnels = x.clientTunnels || [], sitePeers = x.sitePeers || [];
  return [
    card('OpenVPN routed server', [
      btn('Configure', openvpnSettingsForm, 'btn-primary'),
      ...moduleServiceButtons('openvpn.service', !!x.running, !!x.configured)
    ], h('div', { class: 'card-body small' },
      h('dl', { class: 'row mb-0' },
        h('dt', { class: 'col-sm-3' }, 'Status'), h('dd', { class: 'col-sm-9' }, x.running ? badge('running','text-bg-success') : badge('stopped')),
        h('dt', { class: 'col-sm-3' }, 'Endpoint'), h('dd', { class: 'col-sm-9 mono' }, x.configured ? (x.publicHost + ':' + x.port + '/' + x.protocol) : 'not configured'),
        h('dt', { class: 'col-sm-3' }, 'Tunnel'), h('dd', { class: 'col-sm-9 mono' }, x.interface || 'tun0'),
        h('dt', { class: 'col-sm-3' }, 'Client network'), h('dd', { class: 'col-sm-9 mono' }, x.network || '—')),
      h('div', { class: 'alert alert-light border mt-3 mb-0' }, 'OpenVPN owns the TUN interface lifecycle. LiteFWM reads that interface live and exposes it to firewall rules.'))),
    card('OpenVPN client tunnels', [btn('Add client tunnel',()=>openvpnClientTunnelForm(),'btn-primary')],
      h('div',{class:'card-body small'},'Independent point-to-site or site-to-site client connections. Import a certificate-based .ovpn profile; each tunnel uses a separate OpenRC instance and tun interface. Saving never auto-starts the connection.'),
      table(['Tunnel','Type','Endpoint','Device','Status','Actions'],
        clientTunnels.map(t=>h('tr',{},
          h('td',{class:'mono'},t.id),
          h('td',{},t.mode),
          h('td',{class:'mono'},t.remoteHost),
          h('td',{class:'mono'},t.interface),
          h('td',{},t.running?badge('running','text-bg-success'):badge('stopped')),
          h('td',{class:'text-end'},
            btn('Edit',()=>openvpnClientTunnelForm(t),'btn-outline-primary'),' ',
            btn(t.running?'Stop':'Start',()=>apply('openvpn.instanceservice',{id:t.id,action:t.running?'stop':'start'},'Client tunnel service changed'),'btn-primary'),' ',
            btn('Remove',()=>confirmDo('Remove OpenVPN client','Stop and remove client tunnel '+t.id+'? A protected backup is retained.',
              ()=>apply('openvpn.instancedelete',{id:t.id},'Client tunnel removed'),'Remove'),'btn-outline-danger')))),
        'No outbound OpenVPN clients configured.')),
    card('Site-to-site peers (server side)',[btn('Add site peer',()=>openvpnSitePeerForm(),'btn-primary')],
      h('div',{class:'card-body small'},'Certificate-bound OpenVPN CCD routing: each peer gets a remote-site route (iroute) and a pushed local-site route. Restart the server to apply changes.'),
      table(['Certificate','Local LAN','Remote LAN','Actions'],
        sitePeers.map(p=>h('tr',{},
          h('td',{class:'mono'},p.id),
          h('td',{class:'mono'},p.localSubnet),
          h('td',{class:'mono'},p.remoteSubnet),
          h('td',{class:'text-end'},
            btn('Edit',()=>openvpnSitePeerForm(p),'btn-outline-primary'),' ',
            btn('Delete',()=>confirmDo('Remove site peer','Remove server-side site route for '+p.id+'? Restart the server to apply.',
              ()=>apply('openvpn.sitepeerdelete',{id:p.id},'Site peer removed'),'Delete'),'btn-outline-danger')))),
        'No server-side site peers configured.')),
    card('OpenVPN clients', [btn('Add client', openvpnAddClient, 'btn-primary')],
      table(['Client', 'Certificate', 'Profile', ''], clients.map(c => h('tr', {},
        h('td', { class: 'mono' }, c.name),
        h('td', {}, c.status === 'valid' ? badge('valid','text-bg-success') : badge(c.status || 'unknown','text-bg-secondary')),
        h('td', {}, c.profileAvailable ? btn('Download', () => openvpnGetProfile(c.name), 'btn-outline-primary') : '—'),
        h('td', { class: 'text-end' }, c.status === 'valid' ? btn('Revoke', () => confirmDo('Revoke VPN client', 'Revoke ' + c.name + '?', () => apply('openvpn.clientrevoke', { name: c.name }, 'Client revoked'), 'Revoke'), 'btn-outline-danger') : null))), 'No VPN clients.'))
  ];
}

function ddnsSettingsForm() {
  const x = moduleState('ddns'), c = x.custom || {};
  let providers = (x.providers || []).map(p => typeof p === 'string' ? p : (p.id || p.name || '')).filter(Boolean);
  if (!providers.length) providers = ['default@cloudflare.com','default@duckdns.org','default@no-ip.com','default@dyndns.org','default@he.net','default@dynu.com','default@namecheap.com','default@freedns.afraid.org','custom'];
  if (!providers.includes('custom')) providers.push('custom');
  const ifs = [['', 'automatic / default route']].concat(routeIfaces().filter(i => i.kind !== 'vpn').map(i => [i.name, disp(i.name)]));
  form('Dynamic DNS', [
    { k: 'provider', label: 'Provider', type: 'select', value: x.provider || providers[0], options: providers.map(v => [v,v]) },
    { k: 'hostnames', label: 'Hostnames', type: 'list', value: x.hostnames || [], placeholder: 'vpn.example.com' },
    { k: 'username', label: 'Username or token ID', value: x.username || '' },
    { k: 'password', label: 'Credential', type: 'password', value: '', help: x.credentialConfigured ? 'Leave empty to keep the configured credential.' : 'Required on first configuration.' },
    { k: 'period', label: 'Check period (seconds)', type: 'number', value: x.period || 300, help: 'Minimum 60 seconds.' },
    { k: 'interface', label: 'Address source interface', type: 'select', value: x.interface || '', options: ifs },
    { k: 'checkServer', label: 'Custom check-IP server', value: c.checkServer || '', show: v => v.provider === 'custom' },
    { k: 'checkPath', label: 'Custom check-IP path', value: c.checkPath || '/', show: v => v.provider === 'custom' },
    { k: 'updateServer', label: 'Custom update server', value: c.updateServer || '', show: v => v.provider === 'custom' },
    { k: 'updatePath', label: 'Custom update path', value: c.updatePath || '', show: v => v.provider === 'custom' },
    { k: 'ssl', label: 'Use TLS for the custom provider', type: 'check', value: c.ssl !== false, show: v => v.provider === 'custom' }
  ], v => apply('ddns.configure', {
    provider: v.provider, hostnames: v.hostnames, username: v.username, password: v.password,
    period: Number(v.period), interface: v.interface,
    custom: { checkServer: v.checkServer || '', checkPath: v.checkPath || '', updateServer: v.updateServer || '', updatePath: v.updatePath || '', ssl: v.ssl !== false }
  }, 'Dynamic DNS applied'));
}
function cloudflareSettingsForm() {
  const x = moduleState('ddns').cloudflare || {};
  form('Configure Cloudflare Dynamic DNS', [
    { k:'zone', label:'Cloudflare DNS zone', value:x.zone || '', placeholder:'example.net',
      help:'Use an existing Cloudflare zone. This does not create DNS zones.' },
    { k:'hostnames', label:'A records to update', type:'list', value:x.hostnames || [],
      placeholder:'cloud.example.net, home.example.net',
      help:'Only existing A records in this zone are accepted; CNAMEs and other record types are protected.' },
    { k:'email', label:'Cloudflare account email', value:x.email || '', placeholder:'admin@example.net' },
    { k:'apiKey', label:'Cloudflare Global API key', type:'password', value:'',
      help:x.credentialConfigured ? 'Leave empty to keep the existing credential.' :
        'Required on first setup. Prefer a scoped API token for new configurations.' },
    { k:'scheduleMinutes', label:'Check interval', type:'select',
      value:String(x.scheduleMinutes || 15),
      options:[['5','Every 5 minutes'],['15','Every 15 minutes'],['30','Every 30 minutes'],['60','Hourly']] },
    { k:'enabled', label:'Enable scheduled Cloudflare updates', type:'check', value:x.enabled !== false }
  ], v => apply('ddns.cfconfigure', {
    zone:v.zone.toLowerCase(), hostnames:v.hostnames.map(s => s.toLowerCase()),
    email:v.email, apiKey:v.apiKey, scheduleMinutes:Number(v.scheduleMinutes), enabled:v.enabled
  }, 'Cloudflare settings validated and saved'), {
    note:'New settings are checked against Cloudflare before being saved. Credentials remain on the firewall and are not returned to the browser. Last check and detected public IPv4 are read-only status fields.',
    applyText:'Validate and save'
  });
}
function ddnsPanel() {
  const m = moduleBy('ddns'); if (!m || !m.installed) return [];
  const x = moduleState('ddns');
  const actions = [btn('Configure Inadyn provider', ddnsSettingsForm, 'btn-primary')];
  if (x.configured) actions.push(btn('Force Inadyn update', async () => {
    const j = await op('ddns.force', {});
    toast((j.result && j.result.output) || 'Dynamic DNS update completed', 'success');
    await load();
  }, 'btn-outline-primary'));
  actions.push(...moduleServiceButtons('ddns.service', !!x.running, !!x.configured));
  return [card('Dynamic DNS (inadyn)', actions, h('div', { class: 'card-body small' },
    x.configured ? h('dl', { class: 'row mb-0' },
      h('dt', { class: 'col-sm-3' }, 'Status'), h('dd', { class: 'col-sm-9' }, x.running ? badge('running','text-bg-success') : badge('stopped')),
      h('dt', { class: 'col-sm-3' }, 'Provider'), h('dd', { class: 'col-sm-9 mono' }, x.provider),
      h('dt', { class: 'col-sm-3' }, 'Hostnames'), h('dd', { class: 'col-sm-9 mono' }, (x.hostnames || []).join(', ') || '—'),
      h('dt', { class: 'col-sm-3' }, 'Source'), h('dd', { class: 'col-sm-9' }, x.interface || 'automatic'))
    : (x.nativeConfig ? 'Installed but not configured in LiteFW. An existing native inadyn file will be backed up when you configure the module.' : 'Installed but not configured. Choose Configure to set a provider, hostnames and credentials.'))),
    ...(x.cloudflare ? [
      card('Cloudflare DNS (pfSense migration)', [
        btn('Configure', cloudflareSettingsForm, 'btn-primary'),
        ...(x.cloudflare.configured ? [btn('Check records', async () => {
          try {
            const j = await op('ddns.cfcheck', {});
            toast((j.result && j.result.output) || 'Cloudflare records checked', 'success');
            await load();
          } catch (e) { toast('Cloudflare check failed: ' + e.message, 'danger'); }
        }, 'btn-outline-primary'),
        btn('Force refresh', () => confirmDo('Refresh Cloudflare DNS',
          'Update managed Cloudflare A records using the current public IPv4? CNAME aliases and other DNS records will be preserved.',
          () => apply('ddns.cfupdate', {}, 'Cloudflare DNS updated'), 'Refresh'), 'btn-outline-primary')] : [])
      ], h('div', {class:'card-body small'},
        h('p', {class:'mb-2'}, x.cloudflare.configured ?
          'Edit the zone, existing A records, account, credential, and update interval through Configure. Cloudflare status and public IPv4 are detected automatically.' :
          'No Cloudflare profile is configured. Choose Configure to add existing Cloudflare A records.'),
        x.cloudflare.configured ? h('dl', {class:'row mb-0'},
          h('dt', {class:'col-sm-3'}, 'Zone'),
          h('dd', {class:'col-sm-9 mono'}, x.cloudflare.zone || ''),
          h('dt', {class:'col-sm-3'}, 'Records'),
          h('dd', {class:'col-sm-9 mono'}, (x.cloudflare.hostnames || []).join(', ')),
          h('dt', {class:'col-sm-3'}, 'Last check'),
          h('dd', {class:'col-sm-9'}, (x.cloudflare.last || {}).checkedAt || 'Never'),
          h('dt', {class:'col-sm-3'}, 'Public IPv4'),
          h('dd', {class:'col-sm-9 mono'}, (x.cloudflare.last || {}).publicIPv4 || 'Unknown'),
          h('dt', {class:'col-sm-3'}, 'Schedule'),
          h('dd', {class:'col-sm-9'}, x.cloudflare.enabled === false ? 'Disabled' :
            'Every ' + (x.cloudflare.scheduleMinutes || 15) + ' minutes via Alpine cron'),
          h('dt', {class:'col-sm-3'}, 'Credential'),
          h('dd', {class:'col-sm-9'}, x.cloudflare.credentialConfigured ? 'Configured (protected)' : 'Not configured')) : null))
    ] : [])
  ];
}

views.modules = () => {
  const mods = S.modules || [];
  return [
    h('div', { class:'alert alert-light border small' },
      'Optional services install from Alpine packages or verified, pinned vendor releases. Installation is checked against the actual executable and service before displaying Installed. Nothing starts automatically.'),
    h('div', { class:'row g-3' }, mods.map(m => h('div', { class:'col-lg-4' },
      card(m.name, m.installed
        ? [badge(m.core ? 'built in' : 'installed', 'text-bg-success'),
           btn('Configure', () => location.hash = '#module-' + m.id, 'btn-primary'),
           !m.core && btn('Remove', () => moduleRemove(m), 'btn-outline-danger')]
        : [badge('not installed'), btn('Install', () => moduleInstall(m), 'btn-primary')],
        h('div', { class:'card-body small' },
          h('p', {}, m.description),
          h('div', { class:'text-secondary mono' }, (m.installSource ? 'Verified source: '+m.installSource : 'Alpine packages: ' + (m.packages || []).join(', '))))))))
  ];
};
views['module-bind'] = () => [
  h('div', { class:'mb-3' }, btn('Back to modules', () => location.hash = '#modules')),
  ...(moduleBy('bind') && moduleBy('bind').installed ? bindPanel() :
    [card('BIND DNS', null, h('div', { class:'card-body' }, 'BIND9 is not installed. Install it from Modules first.'))])
];
views['module-ddns'] = () => [
  h('div', { class:'mb-3' }, btn('Back to modules', () => location.hash = '#modules')),
  ...(moduleBy('ddns') && moduleBy('ddns').installed ? ddnsPanel() : [
    card('Dynamic DNS (inadyn)',
      moduleBy('ddns') ? [btn('Install Dynamic DNS', () => moduleInstall(moduleBy('ddns')), 'btn-primary')] : null,
      h('div', {class:'card-body small'},
        'Install the optional Dynamic DNS module before choosing a provider, hostnames and credentials.'))
  ])
];
views['module-openvpn'] = () => [
  h('div', { class:'mb-3' }, btn('Back to modules', () => location.hash = '#modules')),
  ...openvpnPanel()
];
views['module-ipsec'] = () => [
  h('div', { class:'mb-3' }, btn('Back to modules', () => location.hash = '#modules')),
  ...ipsecPanel()
];

// Firewall rules editor: ALL edits remain in browser memory until Apply.
let fwDraft = null, fwBaseline = null, fwDirty = false;
function initFwDraft(fw) {
  fwBaseline = {
    rules: fw.rules.map(r => ({id:r.id, chain:r.chain, raw:r.raw, managed:r.managed})),
    forwards: fw.forwards.map(f => ({id:f.id, raw:f.raw, managed:f.managed}))
  };
  fwDraft = {
    rules: fw.rules.map((r, origin) => Object.assign({origin, changed:false}, r)),
    forwards: fw.forwards.map((f, origin) => Object.assign({origin, changed:false}, f))
  };
  fwDirty = false;
}
function markFwDraft() { fwDirty = true; render(); }
window.addEventListener('beforeunload', e => {
  if (fwDirty) { e.preventDefault(); e.returnValue = ''; }
});
async function applyFwDraft() {
  if (!fwDirty) return;
  if (!confirm('Apply ALL staged firewall rules and port forwards? You must confirm the connection within 120 seconds or the firewall will restore its old rules.')) return;
  try {
    const result = await op('firewall.batch', {baseline:fwBaseline, rules:fwDraft.rules, forwards:fwDraft.forwards});
    if (!confirm('The new firewall rules are temporarily active. Is LiteFW still accessible? Press OK to KEEP them, Cancel to let the previous rules return automatically.')) {
      toast('No confirmation received. Old rules will automatically return in up to 120 seconds.', 'warning');
      return;
    }
    await op('firewall.confirm', {token:result.result.token});
    fwDirty = false;
    toast('Firewall changes confirmed and saved', 'success');
    await load();
  } catch(e) {
    toast('Firewall apply/confirmation failed: ' + e.message + '. Automatic recovery remains available.', 'warning');
  }
}
// ---------- firewall
function editRule(r, chain) {
  const isNew = !r; r = r || { chain, action: 'accept', in: '', out: '', src: '', dst: '', proto: 'any', ports: '', description: '' };
  const fields = [
    { k: 'chain', label: 'Traffic', type: 'select', value: r.chain, options: [['forward', 'Through the firewall (between segments / to the internet)'], ['input', 'To the firewall itself']] },
    { k: 'action', label: 'Action', type: 'select', value: r.action, options: [['accept', 'Allow'], ['drop', 'Block (drop silently)'], ['reject', 'Block (reject)']] },
    { k: 'in', label: 'From segment / interface', type: 'select', value: r.in, options: ifOpts('any segment') },
    { k: 'src', label: 'Source address', value: r.src, placeholder: 'any — or 192.168.10.20 or 192.168.10.0/24' },
    { k: 'out', label: 'To segment / interface', type: 'select', value: r.out, options: ifOpts('any segment'), show: v => v.chain === 'forward', help: 'Choose the WAN segment for internet access.' },
    { k: 'dst', label: 'Destination address', value: r.dst, placeholder: 'any — or a host or CIDR' },
    { k: 'proto', label: 'Protocol', type: 'select', value: r.proto, options: [['any', 'any'], ['tcp', 'TCP'], ['udp', 'UDP'], ['icmp', 'ICMP']] },
    { k: 'ports', label: 'Destination ports', value: r.ports, placeholder: '443 or 8000-8100 or 80,443', show: v => v.proto === 'tcp' || v.proto === 'udp' },
    { k: 'description', label: 'Description', value: r.description }
  ];
  if (isNew) fields.push({ k: 'position', label: 'Position', type: 'select', value: '', options: [['', 'Bottom of the list'], ['0', 'Top of the list']] });
  form(isNew ? 'New firewall rule' : 'Edit firewall rule', fields, v => {
    if (v.chain === 'input') delete v.out;
    if (isNew) {
      const item = Object.assign({id:'', origin:-1, changed:true, managed:true}, v);
      const pos = item.position; delete item.position;
      if (pos === '0') {
        const first = fwDraft.rules.findIndex(x => x.chain === item.chain);
        if (first >= 0) fwDraft.rules.splice(first, 0, item);
        else fwDraft.rules.push(item);
      } else fwDraft.rules.push(item);
    } else Object.assign(r, v, {changed:true});
    markFwDraft();
    return Promise.resolve();
  }, { note: 'Rules are evaluated top to bottom; the first match wins. Anything not allowed is dropped. Replies to allowed traffic are allowed automatically.' });
}
function ruleTable(chain) {
  const rs = fwDraft.rules.filter(r => r.chain === chain);
  const acts = { accept: 'text-bg-success', drop: 'text-bg-danger', reject: 'text-bg-warning' };
  const ep = (i, a) => [h('div', {}, disp(i)), a && h('div', { class: 'mono small' }, a)];
  return table(['#', 'Action', 'From', chain === 'forward' ? 'To' : 'Destination', 'Service', 'Description', ''],
    rs.map((r, n) => h('tr', {},
      h('td', { class: 'text-secondary' }, n + 1), h('td', {}, badge(r.action === 'accept' ? 'allow' : r.action, acts[r.action])),
      h('td', {}, ep(r.in, r.src)), h('td', {}, chain === 'forward' ? ep(r.out, r.dst) : (r.dst || 'this firewall')),
      h('td', { class: 'mono small' }, r.proto === 'any' ? 'any' : r.proto + (r.ports ? ' ' + r.ports : '')),
      h('td', {}, r.managed ? dash(r.description) :
        h('span', { class: 'small' }, dash(r.description || 'Imported rule'), h('div', { class: 'text-secondary' }, plainRule(r)),
          h('details', { class: 'mt-1' }, h('summary', { class: 'small text-secondary' }, 'Technical details'), h('code', { class: 'mono' }, r.raw)))),
      h('td', { class: 'text-end text-nowrap' }, ruleActions(r, rs, n, true)))),
    chain === 'forward' ? 'No rules: all traffic between segments and to the internet is blocked.' : 'No rules.');
}
const builtins = () => {
  const w = wan(), s = S.system;
  const lans = l3().filter(i => i.role === 'lan').map(i => disp(i.name)).join(', ') || 'none';
  const implicit = [
    ['allow', 'Replies to allowed connections (established / related)'],
    ['allow', `Web UI tcp/${s.management.port} on LAN interfaces only` + (s.ssh.enabled ? `; SSH tcp/${s.ssh.port} from ` + (s.management.access[0] === 'any' ? 'any interface' : s.management.access.join(', ')) : '')],
    ['allow', `DNS, DHCP and ping to this firewall from LAN segments (${lans})`],
    ['allow', 'Port forwards (see Port forwards)'],
    ['nat', w ? `Outbound NAT (masquerade) on the WAN ${disp(w.name)}` : 'Outbound NAT: no WAN segment defined'],
    ['drop', `Everything else (policy INPUT ${S.firewall.policies.INPUT || '?'}, FORWARD ${S.firewall.policies.FORWARD || '?'})`]
  ];
  return implicit;
};
const advancedFirewall = () => [
  card('Forwarding rules (filter FORWARD) — between segments and to the internet', [btn('Add rule', () => editRule(null, 'forward'), 'btn-primary')], ruleTable('forward')),
  card('Input rules (filter INPUT) — traffic to this firewall', [btn('Add rule', () => editRule(null, 'input'), 'btn-primary')], ruleTable('input')),
  forwardsTable(),
  card('Built-in behaviour', [btn('Management access', () => location.hash = '#system')], table(['', 'Rule'],
    builtins().map(([a, t]) => h('tr', { class: 'implicit' }, h('td', {}, badge(a, a === 'drop' ? 'text-bg-danger' : a === 'nat' ? 'text-bg-info' : 'text-bg-success')), h('td', {}, t)))))
];

// ---------- port forwards
function editForward(f) {
  const isNew = !f; f = f || { in: '', src: '', proto: 'tcp', port: '', to: '', toPort: '', description: '' };
  const w = wan();
  form(isNew ? 'New port forward' : 'Edit port forward', [
    { k: 'in', label: 'Incoming interface', type: 'select', value: f.in === (w && w.name) ? '' : f.in, options: ifOpts(w ? `WAN (${disp(w.name)})` : 'WAN') },
    { k: 'proto', label: 'Protocol', type: 'select', value: f.proto, options: [['tcp', 'TCP'], ['udp', 'UDP'], ['both', 'TCP + UDP']] },
    { k: 'port', label: 'External port', value: f.port, placeholder: '443 or 10000-10100' },
    { k: 'to', label: 'Internal host', value: f.to, placeholder: '192.168.10.20' },
    { k: 'toPort', label: 'Internal port', value: f.toPort, placeholder: 'same as external' },
    { k: 'src', label: 'Allowed sources', value: f.src, placeholder: 'anyone — or an IP / CIDR' },
    { k: 'description', label: 'Description', value: f.description }
  ], v => {
    if (isNew) fwDraft.forwards.push(Object.assign({id:'', origin:-1, managed:true, changed:true}, v));
    else Object.assign(f, v, {changed:true});
    markFwDraft();
    return Promise.resolve();
  },
  { note: 'Forwarded traffic is allowed through the firewall automatically; no extra rule is needed.' });
}
const forwardsTable = () => card('Port forwards (destination NAT, nat PREROUTING)', [btn('Add port forward', () => editForward(null), 'btn-primary')],
  table(['Interface', 'Protocol', 'External port', 'Internal host', 'Sources', 'Description', ''],
    fwDraft.forwards.map(f => h('tr', {},
      h('td', {}, disp(f.in)), h('td', {}, f.proto === 'both' ? 'tcp+udp' : f.proto), h('td', { class: 'mono' }, f.port),
      h('td', { class: 'mono' }, f.to + (f.toPort ? ':' + f.toPort : '')), h('td', { class: 'mono small' }, f.src || 'anyone'),
      h('td', {}, f.managed ? dash(f.description) : h('span', { class: 'mono small text-secondary' }, f.raw)),
      h('td', { class: 'text-end text-nowrap' }, f.managed && [btn('Edit', () => editForward(f)), ' ',
        btn('Delete', () => confirmDo('Delete port forward', `Delete the forward of port ${f.port}?`, () => { fwDraft.forwards.splice(fwDraft.forwards.indexOf(f), 1); markFwDraft(); }, 'Delete'), 'btn-outline-danger')]))),
    'No port forwards.'));

// ---------- firewall: plain-language view + guided rule wizard
let fwAdvanced = false;
const isWan = n => { const w = wan(); return !!w && !!n && n === w.name; };
const segLabel = n => { const i = I(n); return i && i.label ? i.label : n; };
function devices() {
  const m = new Map();
  for (const r of S.dhcp.reservations) m.set(r.ip, { ip: r.ip, mac: r.mac, name: r.hostname, reserved: true });
  for (const l of S.dhcp.leases) if (!m.has(l.ip) && !l.reserved) m.set(l.ip, { ip: l.ip, mac: l.mac, name: l.hostname, reserved: false });
  return [...m.values()].sort((a, b) => ip2int(a.ip) - ip2int(b.ip));
}
const hostText = a => { if (!a) return ''; const d = devices().find(x => x.ip === a); return d && d.name ? `${d.name} (${a})` : a; };
const svcText = (proto, ports) => !proto || proto === 'any' ? 'all traffic' : proto === 'icmp' ? 'ping' : `${proto.toUpperCase()} ${ports || 'all ports'}`;
const where = (iface, addr, anyText) => {
  if (isWan(iface)) return addr ? `${hostText(addr)} on the internet` : 'the internet';
  const seg = iface ? segLabel(iface) : '';
  if (addr) return seg ? `${hostText(addr)} in ${seg}` : hostText(addr);
  return seg || anyText;
};
function ruleSentence(r) {
  const verb = r.action === 'accept' ? 'Allow' : 'Block';
  const from = where(r.in, r.src, 'any segment');
  const to = r.chain === 'input' ? 'this firewall' : where(r.out, r.dst, 'anywhere');
  return `${verb} ${from} → ${to} · ${svcText(r.proto, r.ports)}`;
}
function forwardSentence(f) {
  const proto = f.proto === 'both' ? 'TCP+UDP' : f.proto.toUpperCase();
  const src = f.src ? ` (only from ${f.src})` : '';
  const via = isWan(f.in) ? 'Internet' : `Traffic arriving on ${segLabel(f.in)}`;
  return `${via} → ${proto} ${f.port} on this firewall is forwarded to ${hostText(f.to)}${f.toPort ? ' port ' + f.toPort : ''}${src}`;
}
const actBadge = a => badge(a === 'accept' ? 'allow' : 'block', a === 'accept' ? 'text-bg-success' : 'text-bg-danger');
// Show imported rules as readable policy, without converting their original match semantics.
function isInvertedSourceRule(r) {
  return !!r.raw && /(?:^|\s)!\s+-s\s/.test(r.raw);
}
function plainRule(r) {
  if (isInvertedSourceRule(r)) {
    return 'Block unexpected source addresses on ' + disp(r.in) +
      ': sources outside ' + (r.src || 'the expected subnet') +
      (r.dst ? ' claiming traffic to ' + r.dst : '') + ' · anti-spoofing';
  }
  return ruleSentence(r);
}
function moveRule(r, list, index, step) {
  const next = list[index + step];
  if (!next) return;
  const move = () => {
    const old = fwDraft.rules.indexOf(r), other = fwDraft.rules.indexOf(next);
    fwDraft.rules[old] = next; fwDraft.rules[other] = r;
    markFwDraft();
  };
  if (isInvertedSourceRule(r) || isInvertedSourceRule(next))
    return confirmDo('Move an anti-spoofing rule?',
      'A rule moved past an anti-spoofing rule may expose networks. Continue?',
      move, 'Move rule');
  move();
}
function ruleActions(r, list, n) {
  return [
    btn('↑', () => moveRule(r, list, n, -1), n === 0 ? 'btn-outline-secondary disabled' : null), ' ',
    btn('↓', () => moveRule(r, list, n, 1), n === list.length - 1 ? 'btn-outline-secondary disabled' : null), ' ',
    r.managed && btn('Edit', () => editRule(r)), ' ',
    r.managed && btn('Delete', () => confirmDo('Delete rule', 'Remove this rule from the draft?',
      () => { fwDraft.rules.splice(fwDraft.rules.indexOf(r), 1); markFwDraft(); }, 'Remove'), 'btn-outline-danger')
  ];
}
const descOf = s => s.replace(/[^A-Za-z0-9 _.,:/()+#@-]/g, '').replace(/\s+/g, ' ').trim().slice(0, 64);

function ruleItems(rules, emptyText) {
  if (!rules.length) return h('div', { class: 'card-body text-secondary small' }, emptyText);
  return h('ol', { class: 'rule-list' }, rules.map((r, n) => h('li', {},
    h('span', { class: 'num' }, n + 1), r.managed ? actBadge(r.action) : badge('imported'),
    h('span', { class: 'what' }, plainRule(r),
      r.description && h('small', {}, r.description),
      !r.managed && h('details', { class: 'small text-secondary' },
        h('summary', {}, 'Technical details (read-only)'), h('code', { class: 'mono' }, r.raw))),
    h('span', { class: 'acts' }, ruleActions(r, rules, n)))));
}

views.firewall = () => {
  const fwd = fwDraft.rules.filter(r => r.chain === 'forward'), inp = fwDraft.rules.filter(r => r.chain === 'input');
  const head = h('div', { class: 'd-flex flex-wrap gap-2 align-items-center mb-3' },
    btn('+ New rule…', () => wizard(), 'btn-primary'),
    btn('Apply changes', applyFwDraft, fwDirty ? 'btn-success' : 'btn-outline-success disabled'),
    btn('Discard edits', async () => { fwDirty = false; await load(); }, 'btn-outline-secondary'),
    h('span', { class: 'small text-secondary' }, 'Edit, add or move rules locally. Nothing changes on the firewall until Apply changes.'),
    h('div', { class: 'form-check form-switch ms-auto' },
      h('input', { class: 'form-check-input', type: 'checkbox', id: 'advToggle', checked: fwAdvanced, onchange: e => { fwAdvanced = e.target.checked; render(); } }),
      h('label', { class: 'form-check-label small', for: 'advToggle' }, 'Advanced (manual rules)')));
  const notice = h('div', { class: fwDirty ? 'alert alert-warning' : 'alert alert-light border' },
    fwDirty ? 'UNSAVED DRAFT — the firewall is still running its previous rules.' :
      'Read from the live firewall. Stage changes here and use Apply changes once; old rules automatically return if not confirmed in 120 seconds.');
  if (fwAdvanced) return [head, notice, advancedFirewall()];
  const explain = h('div', { class: 'alert alert-light border explain py-2' },
    h('b', {}, 'Everything is blocked unless allowed. '),
    h('b', {}, 'Traffic rules'), ' say what devices inside may reach (the internet, other segments). ',
    h('b', {}, 'Port forwards'), ' open a door from the internet to one device inside. ',
    h('b', {}, 'Firewall access'), ' covers traffic to the firewall itself. Replies to allowed traffic always come back.');
  const b = builtins();
  return [head, notice, explain,
    card('Traffic rules — what may go where', h('span', { class: 'small text-secondary fw-normal' }, 'checked top to bottom, first match wins'),
      ruleItems(fwd, 'Nothing is allowed yet: devices cannot reach the internet or each other. Use “New rule…” → “Let devices reach the internet”.')),
    card('Port forwards — services published to the internet', null, fwDraft.forwards.length
      ? h('ol', { class: 'rule-list' }, fwDraft.forwards.map((f, n) => h('li', {}, h('span', { class: 'num' }, n + 1), badge('forward', 'text-bg-info'),
          h('span', { class: 'what' }, forwardSentence(f), f.managed && f.description && h('small', {}, f.description)),
          h('span', { class: 'acts' }, f.managed && [btn('Edit', () => editForward(f)),
            btn('Delete', () => confirmDo('Delete port forward', `Delete: ${forwardSentence(f)}?`, () => { fwDraft.forwards.splice(fwDraft.forwards.indexOf(f), 1); markFwDraft(); }, 'Delete'), 'btn-outline-danger')]))))
      : h('div', { class: 'card-body text-secondary small' }, 'Nothing is reachable from the internet. Use “New rule…” → “Publish a service to the internet”.')),
    card('Access to this firewall', [btn('Management settings', () => location.hash = '#system')], [
      ruleItems(inp, 'No extra access rules.'),
      h('ul', { class: 'rule-list border-top' }, b.map(([a, t]) => h('li', { class: 'builtin' }, h('span', { class: 'num' }, ''),
        badge(a === 'drop' ? 'block' : a === 'nat' ? 'NAT' : 'allow', a === 'drop' ? 'text-bg-secondary' : a === 'nat' ? 'text-bg-info' : 'text-bg-light border'),
        h('span', { class: 'what' }, t, h('small', {}, 'built in'))))) ])
  ];
};

// ----- wizard building blocks
const SVC = [['any', 'Everything'], ['web', 'Web (HTTP 80 + HTTPS 443)'], ['https', 'HTTPS (443)'], ['http', 'HTTP (80)'], ['ssh', 'SSH (22)'],
  ['dns', 'DNS (53)'], ['rdp', 'Remote desktop (3389)'], ['ping', 'Ping'], ['custom', 'Other port(s)…']];
function svcSpec(v) {
  switch (v.svc) {
    case 'any': return [{ proto: 'any' }];
    case 'web': return [{ proto: 'tcp', ports: '80,443' }];
    case 'https': return [{ proto: 'tcp', ports: '443' }];
    case 'http': return [{ proto: 'tcp', ports: '80' }];
    case 'ssh': return [{ proto: 'tcp', ports: '22' }];
    case 'rdp': return [{ proto: 'tcp', ports: '3389' }];
    case 'dns': return [{ proto: 'udp', ports: '53' }, { proto: 'tcp', ports: '53' }];
    case 'ping': return [{ proto: 'icmp' }];
    default: return (v.cproto === 'both' ? ['tcp', 'udp'] : [v.cproto || 'tcp']).map(p => ({ proto: p, ports: v.cports }));
  }
}
const svcName = v => v.svc === 'custom' ? `${v.cproto === 'both' ? 'TCP+UDP' : (v.cproto || 'tcp').toUpperCase()} ${v.cports}` : SVC.find(s => s[0] === v.svc)[1];
const svcFields = (exclude = [], dflt = 'any') => [
  { k: 'svc', label: 'Which traffic?', type: 'select', value: dflt, options: SVC.filter(s => !exclude.includes(s[0])) },
  { k: 'cproto', label: 'Protocol', type: 'select', value: 'tcp', options: [['tcp', 'TCP'], ['udp', 'UDP'], ['both', 'TCP + UDP']], show: v => v.svc === 'custom' },
  { k: 'cports', label: 'Port(s)', placeholder: '8080  or  8000-8100  or  80,443', show: v => v.svc === 'custom' }];
const devOpts = () => devices().map(d => [d.ip, `${d.name || 'unnamed device'} — ${d.ip}${d.reserved ? ' (static)' : ' (dynamic)'}`]);
function targetFields(p, label, allText) {
  const opts = [['all', allText]];
  if (devices().length) opts.push(['device', 'One known device']);
  opts.push(['addr', 'An IP address or subnet']);
  return [
    { k: p + 'scope', label, type: 'select', value: 'all', options: opts },
    { k: p + 'dev', label: 'Device', type: 'select', options: devOpts(), show: v => v[p + 'scope'] === 'device', help: 'Devices come from DHCP leases and reservations.' },
    { k: p + 'addr', label: 'IP address or subnet', placeholder: '192.168.10.20  or  192.168.10.0/26', show: v => v[p + 'scope'] === 'addr' }];
}
const addrOf = (v, p) => v[p + 'scope'] === 'device' ? v[p + 'dev'] : v[p + 'scope'] === 'addr' ? v[p + 'addr'] : '';
const lanOpts = () => l3().filter(i => i.role === 'lan').map(i => [i.name, `${disp(i.name)}${i.addresses.length ? ' · ' + i.addresses.join(' ') : ''}`]);
const need = (cond, msg) => { if (!cond) throw new Error(msg); };
const ruleItem = (body, position) => {
  const b = Object.assign({}, body); if (position !== undefined) b.position = position;
  for (const k of Object.keys(b)) if (b[k] === '' || b[k] === undefined) delete b[k];
  return { op: 'rule.add', body: b, text: ruleSentence(Object.assign({ proto: 'any' }, body)) };
};
const pre = {
  lan: () => lanOpts().length ? null : 'There are no LAN segments yet. Give an interface the LAN role on the Network segments page first.',
  wan: () => wan() ? null : 'No interface has the WAN role, so there is no internet side. Set one on the Network segments page first.'
};

const INTENTS = [
  { id: 'internet', ico: '🌐', title: 'Let devices reach the internet',
    desc: 'A whole segment, or one device, may go out to the internet — everything or only some services.',
    pre: () => pre.lan() || pre.wan(),
    fields: () => [{ k: 'from', label: 'From which segment?', type: 'select', options: lanOpts() },
      ...targetFields('s', 'Which devices in it?', 'Every device in the segment'), ...svcFields()],
    plan: v => {
      const src = addrOf(v, 's'); need(v.sscope === 'all' || src, 'Choose a device or enter an address.');
      return { items: svcSpec(v).map(s => ruleItem({ chain: 'forward', action: 'accept', in: v.from, out: wan().name, src, proto: s.proto, ports: s.ports,
        description: descOf(`${src ? hostText(src) : segLabel(v.from)} to internet - ${svcName(v)}`) })),
        notes: ['Outgoing traffic is translated to the WAN address automatically (NAT); no extra rule is needed.'] };
    } },
  { id: 'between', ico: '🔀', title: 'Let one segment reach another',
    desc: 'e.g. the LAN may use the printer in IoT, or the DMZ may reach a database in the LAN.',
    pre: () => lanOpts().length >= 2 ? null : 'You need at least two LAN segments for this.',
    fields: () => [{ k: 'from', label: 'From which segment?', type: 'select', options: lanOpts() },
      { k: 'to', label: 'To which segment?', type: 'select', options: lanOpts(), value: (lanOpts()[1] || [])[0] },
      ...targetFields('d', 'Which devices there?', 'Every device in that segment'), ...svcFields(),
      { k: 'reverse', label: 'Also allow the other direction', type: 'check', help: 'Replies are always allowed. Only tick this if devices on the other side must start connections too.' }],
    plan: v => {
      need(v.from !== v.to, 'Pick two different segments.');
      const dst = addrOf(v, 'd'); need(v.dscope === 'all' || dst, 'Choose a device or enter an address.');
      const items = svcSpec(v).map(s => ruleItem({ chain: 'forward', action: 'accept', in: v.from, out: v.to, dst, proto: s.proto, ports: s.ports,
        description: descOf(`${segLabel(v.from)} to ${dst ? hostText(dst) : segLabel(v.to)} - ${svcName(v)}`) }));
      if (v.reverse) svcSpec(v).forEach(s => items.push(ruleItem({ chain: 'forward', action: 'accept', in: v.to, out: v.from, src: dst, proto: s.proto, ports: s.ports,
        description: descOf(`${dst ? hostText(dst) : segLabel(v.to)} to ${segLabel(v.from)} - ${svcName(v)}`) })));
      return { items, notes: [] };
    } },
  { id: 'block', ico: '⛔', title: 'Block something',
    desc: 'Stop a device or segment from reaching the internet, another segment or a specific address — even if another rule allows it.',
    pre: () => pre.lan(),
    fields: () => [{ k: 'from', label: 'Whose traffic?', type: 'select', options: [['', 'Any segment']].concat(lanOpts()) },
      ...targetFields('s', 'Which devices?', 'Every device'),
      { k: 'to', label: 'Going where?', type: 'select', value: wan() ? 'internet' : 'anywhere',
        options: (wan() ? [['internet', 'The internet']] : []).concat(lanOpts().map(([n, l]) => ['seg:' + n, 'Segment ' + l]), [['addr', 'A specific IP address or subnet'], ['anywhere', 'Anywhere']]) },
      { k: 'taddr', label: 'Destination IP or subnet', placeholder: '8.8.8.8  or  10.20.0.0/16', show: v => v.to === 'addr' },
      ...svcFields(),
      { k: 'how', label: 'How to block', type: 'select', value: 'reject', options: [['reject', 'Reject (the device gets an immediate “refused”)'], ['drop', 'Drop silently']] }],
    plan: v => {
      const src = addrOf(v, 's'); need(v.sscope === 'all' || src, 'Choose a device or enter an address.');
      need(v.to !== 'addr' || v.taddr, 'Enter the destination address.');
      const out = v.to === 'internet' ? wan().name : v.to.startsWith('seg:') ? v.to.slice(4) : '';
      const dst = v.to === 'addr' ? v.taddr : '';
      const tgt = v.to === 'internet' ? 'internet' : out ? segLabel(out) : dst || 'anywhere';
      return { items: svcSpec(v).map(s => ruleItem({ chain: 'forward', action: v.how, in: v.from, out, src, dst, proto: s.proto, ports: s.ports,
        description: descOf(`block ${src ? hostText(src) : v.from ? segLabel(v.from) : 'all'} to ${tgt} - ${svcName(v)}`) }, 0)),
        notes: ['Block rules are placed at the top of the list so they win over allow rules.'] };
    } },
  { id: 'publish', ico: '📡', title: 'Publish a service to the internet (port forward)',
    desc: 'Make a device inside reachable from outside, e.g. a reverse proxy or web server on 443.',
    pre: () => pre.wan(),
    fields: () => [
      { k: 'dev', label: 'Which device inside?', type: 'select', options: devOpts().concat([['other', 'Another address…']]) },
      { k: 'addr', label: 'Internal IP address', placeholder: '192.168.10.20', show: v => v.dev === 'other' },
      { k: 'static', label: 'Also make this device’s address static (DHCP reservation)', type: 'check', value: true,
        show: v => { const d = devices().find(x => x.ip === v.dev); return !!d && !d.reserved; },
        help: 'Recommended: otherwise the device can get a different address and the forward stops working.' },
      ...svcFields(['any', 'ping'], 'web'),
      { k: 'ext', label: 'Public port (optional)', placeholder: 'same as the service port',
        show: v => ['https', 'http', 'ssh', 'rdp'].includes(v.svc) || (v.svc === 'custom' && /^\d+$/.test(v.cports || '')),
        help: 'Use a different outside port, e.g. 2222 on the internet → 22 on the device.' },
      { k: 'src', label: 'Only reachable from (optional)', placeholder: 'anyone — or an IP / subnet, e.g. your office' }],
    plan: v => {
      const to = v.dev === 'other' ? v.addr : v.dev; need(to, 'Choose a device or enter its address.');
      const specs = svcSpec(v); need(v.svc !== 'custom' || v.cports, 'Enter the port(s).');
      const items = [];
      const d = devices().find(x => x.ip === to);
      if (v.static && d && !d.reserved) items.push({ op: 'reservation.add', body: { mac: d.mac, ip: d.ip, hostname: d.name || undefined },
        text: `Reserve ${d.ip} for ${d.name || d.mac} (always the same address)` });
      const protoOf = s => specs.length > 1 ? 'both' : s.proto;
      for (const port of specs[0].ports.split(',')) {
        const single = /^\d+$/.test(port);
        const body = { proto: protoOf(specs[0]), port: v.ext && single ? v.ext : port, to, src: v.src || undefined,
          description: descOf(`${svcName(v)} to ${hostText(to)}`) };
        if (v.ext && single && v.ext !== port) body.toPort = port;
        items.push({ op: 'forward.add', body, text: forwardSentence(Object.assign({ in: wan().name, toPort: '', src: '' }, body)) });
      }
      return { items, notes: ['Forwarded traffic is allowed through the firewall automatically; no extra traffic rule is needed.'] };
    } },
  { id: 'fwaccess', ico: '🛡️', title: 'Allow access to this firewall',
    desc: 'e.g. answer ping on the WAN, or reach a service running on the firewall. Web UI and SSH access are under System.',
    fields: () => [{ k: 'from', label: 'From where?', type: 'select', options: [['', 'Anywhere']].concat(l3().map(i => [i.name, `${disp(i.name)}${i.role !== 'none' ? ' · ' + i.role.toUpperCase() : ''}`])) },
      ...targetFields('s', 'Which sources?', 'Everyone there'), ...svcFields(['any', 'web', 'http', 'https', 'ssh'], 'ping')],
    plan: v => {
      const src = addrOf(v, 's'); need(v.sscope === 'all' || src, 'Choose a device or enter an address.');
      return { items: svcSpec(v).map(s => ruleItem({ chain: 'input', action: 'accept', in: v.from, src, proto: s.proto, ports: s.ports,
        description: descOf(`${src || (v.from ? segLabel(v.from) : 'anywhere')} to firewall - ${svcName(v)}`) })), notes: [] };
    } }
];

// dialog body from any mix of nodes and (nested) arrays
const setBody = (...kids) => $('#dlgBody').replaceChildren(h('div', {}, kids));
function wizard(startId) {
  let intent = null, vals = null, ui = null;
  const names = ['What do you want to do?', 'Details', 'Review'];
  const steps = n => h('div', { class: 'steps' }, names.map((s, i) => [i ? '  ›  ' : '', h('span', { class: i === n ? 'on' : '' }, `${i + 1}. ${s}`)]));
  const back = $('#dlgBack'), next = $('#dlgApply');
  const chooseIntent = () => {
    dlgChrome('New rule');
    next.classList.add('d-none'); dlgApply = null;
    setBody(steps(0),
      INTENTS.map(it => h('button', { type: 'button', class: 'intent', 'data-intent': it.id, onclick: () => { intent = it; vals = null; details(); } },
        h('span', { class: 'ico' }, it.ico), h('span', {}, h('b', {}, it.title), h('span', { class: 'd' }, it.desc)))),
      h('div', { class: 'small text-secondary mt-2' }, 'Need something else? Switch the Firewall page to Advanced to write rules by hand.'));
  };
  const details = () => {
    dlgChrome('New rule — ' + intent.title, 'Next');
    back.classList.remove('d-none'); back.onclick = chooseIntent;
    const blocked = intent.pre && intent.pre();
    if (blocked) {
      next.classList.add('d-none'); dlgApply = null;
      setBody(steps(1), h('div', { class: 'alert alert-warning' }, blocked));
      return;
    }
    ui = buildFields(intent.fields(), vals);
    setBody(steps(1), ui.body);
    dlgApply = async () => { vals = ui.vals(); review(intent.plan(vals)); return KEEP; };
  };
  const review = p => {
    dlgChrome('New rule — review', p.items.length > 1 ? `Create ${p.items.length} changes` : 'Create');
    back.classList.remove('d-none'); back.onclick = details;
    setBody(steps(2),
      h('p', { class: 'mb-2' }, 'These changes will be added to a draft. Nothing is applied until you press Apply changes:'),
      h('ol', { class: 'review' }, p.items.map(it => h('li', {}, it.text, h('div', {}, h('code', {}, `${it.op} ${JSON.stringify(it.body)}`))))),
      p.notes.map(n => h('div', { class: 'alert alert-info py-2 small mb-2' }, n)));
    dlgApply = async () => {
      let count = 0;
      for (const it of p.items) {
        if (it.op === 'rule.add') {
          const item = Object.assign({id:'', origin:-1, changed:true, managed:true}, it.body);
          const pos = item.position; delete item.position;
          if (pos === 0) {
            const first = fwDraft.rules.findIndex(x => x.chain === item.chain);
            if (first >= 0) fwDraft.rules.splice(first, 0, item);
            else fwDraft.rules.push(item);
          } else fwDraft.rules.push(item);
          count++;
        } else if (it.op === 'forward.add') {
          fwDraft.forwards.push(Object.assign({id:'', origin:-1, changed:true, managed:true}, it.body));
          count++;
        } else if (it.op === 'reservation.add') {
          toast('Reserve the suggested IP separately under DHCP. Firewall changes remain a draft.', 'warning');
        }
      }
      if (count) markFwDraft();
      toast(count + ' changes added to draft. Press Apply changes to activate.', 'success');
    };
  };
  const it = INTENTS.find(x => x.id === startId);
  if (it) { intent = it; details(); } else chooseIntent();
  showDlg();
}


// ---------- software updates
function updatesPanel() {
  const status = h('div', { class: 'small mb-2', role: 'status', 'aria-live': 'polite' }, 'Not checked yet.');
  const check = btn('Check for updates', async () => {
    check.disabled = true; install.disabled = true;
    status.textContent = 'Checking official GitHub releases…';
    try {
      const x = (await op('upgrade.check')).result;
      status.textContent = x.available
        ? 'LiteFW ' + x.latest + ' is available (installed: ' + x.installed + ').'
        : 'Up to date: LiteFW ' + x.installed + '.';
      install.disabled = !x.available;
      install.textContent = x.available ? 'Install ' + x.latest : 'Install update';
    } catch (e) { status.textContent = 'Update check unavailable: ' + e.message; }
    finally { check.disabled = false; }
  }, 'btn-outline-primary');
  const install = btn('Install update', async () => {
    if (!confirm('Install the verified LiteFW release? Configuration will be backed up. No reinstall, reboot, DHCP or network changes.')) return;
    install.disabled = true; check.disabled = true;
    status.textContent = 'Downloading, verifying and installing the update…';
    try {
      const x = (await op('upgrade.install')).result;
      status.textContent = 'LiteFW ' + x.version + ' installed. Reloading…';
      window.location.reload();
    } catch (e) { status.textContent = 'Upgrade failed: ' + e.message; check.disabled = false; }
  }, 'btn-primary');
  install.disabled = true;
  const pick = h('input', { type: 'file', accept: '.tar.gz,application/gzip',
    class: 'form-control form-control-sm', 'aria-label': 'Choose a LiteFW runtime archive' });
  const upload = btn('Install uploaded file', async () => {
    const file = pick.files && pick.files[0];
    if (!file) { status.textContent = 'Choose a LiteFW runtime .tar.gz file first.'; return; }
    if (file.size > 4194304) { status.textContent = 'Upgrade file exceeds 4 MB.'; return; }
    if (!confirm('Install ' + file.name + '? Only use an official release archive. Runtime and configuration will be backed up.')) return;
    upload.disabled = true; status.textContent = 'Uploading and installing the runtime bundle…';
    try {
      const response = await fetch('/api/system/updates/upload', {
        method: 'POST', credentials: 'same-origin',
        headers: { 'Content-Type': 'application/octet-stream', 'X-LiteFWM': '1' }, body: file
      });
      const x = await response.json();
      if (!response.ok || !x.ok) throw new Error(x.error || 'Upgrade failed');
      status.textContent = 'LiteFW ' + x.result.version + ' installed. Reloading…';
      window.location.reload();
    } catch (e) { status.textContent = 'Upgrade failed: ' + e.message; }
    finally { upload.disabled = false; }
  }, 'btn-outline-secondary');
  return card('Software updates', null, h('div', { class: 'card-body' },
    h('p', { class: 'small text-secondary mb-2' }, 'Installed: LiteFW ' + S.system.version +
      '. Updates replace only the application runtime, not appliance configuration.'),
    status, h('div', { class: 'd-flex gap-2 flex-wrap mb-3' }, check, install),
    h('div', { class: 'small fw-semibold mb-1' }, 'Offline update'),
    h('p', { class: 'small text-secondary mb-2' }, 'If the firewall cannot reach GitHub, upload an official litefw2-VERSION-runtime.tar.gz bundle.'),
    h('div', { class: 'd-flex gap-2 flex-wrap mb-2' }, pick, upload),
    h('a', { href: 'https://github.com/theonemule/LITEFW2/releases', target: '_blank',
      rel: 'noopener noreferrer', class: 'small' }, 'Official LiteFW releases')));
}

// Alpine OS package management is intentionally separate from LiteFW releases.
// Check fetches official APK indexes and returns a per-package current/update list.
function alpinePackagesPanel() {
  const info = h('div', { class:'small text-secondary mb-3' },
    'Checks installed Alpine packages against configured repositories. No system packages are upgraded until you explicitly choose Apply package updates.');
  const results = h('div', { class:'mt-2' });
  const applyBtn = btn('Apply package updates', async () => {
    if (!confirm('Upgrade the listed Alpine system packages? Package scripts can restart services and affect connectivity. LiteFW will not reboot automatically. Continue?')) return;
    applyBtn.disabled = true;
    checkBtn.disabled = true;
    results.replaceChildren(h('p', { class:'small' }, 'Installing Alpine package updates. This can take several minutes…'));
    try {
      const r = (await op('packages.upgrade', {confirmed:true})).result;
      const summary = r.upgradedCount
        ? r.upgradedCount + ' packages upgraded. ' + (r.remainingCount || 0) + ' updates remain.'
        : (r.message || 'No packages required upgrading.');
      results.replaceChildren(
        h('div', { class:'alert alert-success small' }, summary,
          r.rebootSuggested ? ' A reboot is recommended for some updated system packages; no reboot was performed.' : ''),
        h('div', {class:'small text-secondary mb-2'}, 'Review the updated package inventory with Check packages. Upgrade log: ' + (r.log || 'not needed')),
        h('ul', {class:'small'}, (r.upgraded || []).map(p =>
          h('li', {class:'mono'}, p.name + ': ' + p.previousVersion + ' → ' + p.installedVersion))));
    } catch (e) {
      results.replaceChildren(h('div', {class:'alert alert-danger small'}, 'Alpine package upgrade failed: ' + e.message));
    } finally { applyBtn.disabled = true; checkBtn.disabled = false; }
  }, 'btn-primary');
  applyBtn.disabled = true;
  const checkBtn = btn('Check packages', async () => {
    checkBtn.disabled = true;
    applyBtn.disabled = true;
    results.replaceChildren(h('p', {class:'small'}, 'Refreshing official Alpine package indexes and checking installed packages…'));
    try {
      const r = (await op('packages.check', {})).result;
      const tableOf = (items, updated) => h('div', {class:'table-responsive mb-2'},
        h('table', {class:'table table-sm table-hover small align-middle mb-0'},
          h('thead', {}, h('tr', {}, [
            'Package', 'Installed version', updated ? 'Available version' : 'Status'
          ].map(x => h('th', {}, x)))),
          h('tbody', {}, items.map(p => h('tr', {},
            h('td', {class:'mono'}, p.name),
            h('td', {class:'mono'}, p.installedVersion),
            h('td', {class:'mono'}, updated ? p.availableVersion : 'Current'))))));
      const up = r.upgradable || [];
      const current = r.current || [];
      results.replaceChildren(
        h('div', {class:'small mb-2'},
          h('strong', {}, up.length + ' updates available'),
          ' · ' + current.length + ' already current · ' + r.installedCount + ' installed packages'),
        h('div', {class:'small fw-semibold mb-2'}, 'Updates available'),
        up.length ? tableOf(up, true) : h('p', {class:'small text-secondary'}, 'All installed Alpine packages are current.'),
        h('details', {class:'mt-3'}, h('summary', {class:'small'}, 'Already current (' + current.length + ')'),
          tableOf(current, false)),
        h('p', {class:'small text-secondary mt-2'},
          'Repositories: ' + (r.repositories || []).join(' · ')));
      applyBtn.disabled = up.length === 0;
    } catch (e) {
      results.replaceChildren(h('div', {class:'alert alert-danger small'}, 'Could not check Alpine packages: ' + e.message));
    } finally { checkBtn.disabled = false; }
  }, 'btn-outline-primary');
  return card('Alpine system packages', null,
    h('div', {class:'card-body'}, info,
      h('div', {class:'d-flex gap-2 flex-wrap'}, checkBtn, applyBtn),
      results));
}

// ---------- system
views.system = () => {
  const s = S.system, m = s.management;
  const out = h('pre', { class: 'mono small bg-light p-2 mb-0 d-none' });
  const host = h('input', { class: 'form-control', placeholder: 'host or IP' });
  const diag = async kind => {
    out.classList.remove('d-none'); out.textContent = 'running…';
    try { const j = await op('diag.' + kind, { host: host.value.trim() }); out.textContent = j.result.output; }
    catch (e) { out.textContent = e.message; }
  };
  return h('div', { class: 'row g-3' },
    h('div', { class: 'col-lg-6' },
      card('General', [btn('Edit', () => form('General', [{ k: 'hostname', label: 'Hostname', value: s.hostname }], v => apply('system.set', v)))],
        h('div', { class: 'card-body' }, 'Hostname: ', h('b', {}, s.hostname))),
      card('Management access', [btn('Edit', () => form('Management access', [
        { k: 'port', label: 'Web UI port', type: 'number', value: m.port },
        { k: 'mode', label: 'Allow SSH from', type: 'select', value: m.access[0] === 'any' ? 'any' : 'list', options: [['any', 'any interface (SSH only)'], ['list', 'selected SSH interfaces']] },
        { k: 'ifs', label: 'Segments', type: 'multi', value: m.access[0] === 'any' ? [] : m.access, options: l3().map(i => [i.name, disp(i.name)]), show: v => v.mode === 'list' },
        { k: 'sshEnabled', label: 'SSH server enabled', type: 'check', value: s.ssh.enabled },
        { k: 'sshPort', label: 'SSH port', type: 'number', value: s.ssh.port, show: v => v.sshEnabled }
      ], v => apply('mgmt.set', { port: v.port, sshEnabled: v.sshEnabled, sshPort: v.sshPort, access: v.mode === 'any' ? 'any' : v.ifs }),
      { note: `Your session arrives on ${m.clientInterface || 'an unknown interface'} (${m.clientIp || '?'}); LiteFWM refuses changes that would lock it out.` }), 'btn-primary')],
        h('div', { class: 'card-body' }, h('dl', { class: 'row mb-0' },
          h('dt', { class: 'col-5' }, 'Web UI'), h('dd', { class: 'col-7' }, 'port ' + m.port),
          h('dt', { class: 'col-5' }, 'Web access'), h('dd', { class: 'col-7' }, 'LAN interfaces only'),
          h('dt', { class: 'col-5' }, 'SSH access'), h('dd', { class: 'col-7' }, m.access[0] === 'any' ? 'any interface' : m.access.map(disp).join(', ')),
          h('dt', { class: 'col-5' }, 'SSH'), h('dd', { class: 'col-7' }, s.ssh.enabled ? 'enabled, port ' + s.ssh.port : 'disabled')))),
      card('Logging output', [btn('Edit', () => form('Logging output', [
        { k: 'remoteEnabled', label: 'Forward system logs to a remote syslog server', type: 'check', value: s.logging.remoteEnabled },
        { k: 'server', label: 'Syslog server', value: s.logging.server, placeholder: 'syslog.example.com or 192.168.1.20', show: v => v.remoteEnabled },
        { k: 'port', label: 'UDP port', type: 'number', value: s.logging.port || 514, show: v => v.remoteEnabled },
        { k: 'localEnabled', label: 'Keep local /var/log/messages while forwarding', type: 'check', value: s.logging.localEnabled, show: v => v.remoteEnabled }
      ], v => apply('logging.set', v, 'Logging output applied'),
      { note: 'LiteFWM uses Alpine BusyBox syslogd. Remote forwarding is standard UDP syslog. Administrative LiteFWM operations are emitted with the litefwm tag.' }), 'btn-primary')],
        h('div', { class: 'card-body' }, h('dl', { class: 'row mb-0' },
          h('dt', { class: 'col-5' }, 'Local log'), h('dd', { class: 'col-7' }, s.logging.localEnabled ? '/var/log/messages' : 'disabled while forwarding'),
          h('dt', { class: 'col-5' }, 'Remote syslog'), h('dd', { class: 'col-7' }, s.logging.remoteEnabled ? `${s.logging.server}:${s.logging.port}/udp` : 'disabled'),
          h('dt', { class: 'col-5' }, 'Service'), h('dd', { class: 'col-7' }, s.logging.serviceRunning ? 'running' : 'stopped')))),
      card('Admin password', [btn('Change', () => form('Change password', [
        { k: 'user', label: 'User', value: 'admin' }, { k: 'password', label: 'New password', type: 'password', help: 'At least 8 characters.' }
      ], v => apply('password.set', v, 'Password changed')))], h('div', { class: 'card-body small text-secondary' }, 'The browser will ask for the new password on the next request.'))),
    h('div', { class: 'col-lg-6' }, updatesPanel(), alpinePackagesPanel(), card('Diagnostics', null, h('div', { class: 'card-body' },
      h('div', { class: 'input-group mb-2' }, host, btn('Ping', () => diag('ping'), 'btn-outline-primary'), btn('DNS lookup', () => diag('lookup'), 'btn-outline-primary')), out))));
};

// ------------------------------------------------------------------ router
function render() {
  if (!S) return;
  let v = (location.hash || '#overview').slice(1);
  v = ALIAS[v] || v;
  if (!views[v]) v = 'overview';
  const nav = v.startsWith('module-') ? 'modules' : v;
  document.querySelectorAll('#sideNav .nav-link, #mobileNavLinks .nav-link').forEach(a => a.classList.toggle('active', a.getAttribute('href') === '#' + nav));
  const link = document.querySelector('#sideNav a[href="#' + nav + '"]');
  const moduleTitles = {'module-bind':'BIND DNS', 'module-dnsmasq':'DNSMasq DNS',
    'module-ddns':'Dynamic DNS', 'module-openvpn':'OpenVPN'};
  $('#pageTitle').textContent = moduleTitles[v] || (link ? link.textContent : 'LiteFW');
  $('#view').replaceChildren(...[views[v]()].flat(Infinity));
}
const ALIAS = { forwards: 'firewall', rules: 'firewall' };
// the offcanvas menu (small screens) carries the same links as the sidebar
$('#mobileNavLinks').replaceChildren(...[...document.querySelectorAll('#sideNav .nav-link')].map(a => {
  const c = a.cloneNode(true);
  c.addEventListener('click', () => { const o = bootstrap.Offcanvas.getInstance($('#mobileNav')); if (o) o.hide(); });
  return c;
}));
window.addEventListener('hashchange', load);
$('#refresh').addEventListener('click', load);
loadIdentity();
