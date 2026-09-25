'use strict';
// LiteFWM web UI. There is no client-side configuration: every view renders
// the live system state from /api/state, and every Apply sends one operation
// that changes the machine immediately, after which the state is re-read.

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
const card = (title, actions, body) => h('div', { class: 'card mb-3' },
  h('div', { class: 'card-header' }, title, h('div', { class: 'actions' }, actions || [])), body);
const table = (heads, rows, empty) => h('div', { class: 'table-responsive' },
  h('table', { class: 'table table-sm table-hover mb-0' },
    h('thead', {}, h('tr', {}, heads.map(x => h('th', {}, x)))),
    h('tbody', {}, rows.length ? rows : h('tr', {}, h('td', { colspan: heads.length, class: 'text-secondary' }, empty || 'None')))));
const dash = v => (v === '' || v == null) ? '—' : v;

// ------------------------------------------------------------------ API
let S = null;
async function load() {
  try {
    const r = await fetch('/api/state', { cache: 'no-store', credentials: 'same-origin' });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || r.statusText);
    S = j;
    $('#hostName').textContent = S.system.hostname;
    $('#stamp').textContent = 'live state read ' + new Date().toLocaleTimeString();
    render();
  } catch (e) {
    $('#view').replaceChildren(h('div', { class: 'alert alert-danger' }, 'Could not read the system state: ' + e.message));
  }
}
async function op(name, body) {
  const r = await fetch('/api/op/' + name, {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', 'X-LiteFWM': '1' },
    body: JSON.stringify(body || {})
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
let dlgApply = null;
$('#dlgApply').addEventListener('click', async () => {
  if (!dlgApply) return;
  const b = $('#dlgApply'); b.disabled = true; $('#dlgErr').textContent = '';
  try { await dlgApply(); dlg().hide(); }
  catch (e) { $('#dlgErr').textContent = e.message; }
  finally { b.disabled = false; }
});

// form(title, fields, onApply(values), {note, applyText})
// field: {k, label, type: text|number|select|check|multi|list|textarea|password|info, value,
//         options: [[value,label]], help, placeholder, show: vals => bool}
function form(title, fields, onApply, o = {}) {
  const ctl = {};
  const body = h('div', {});
  if (o.note) body.append(h('div', { class: 'alert alert-' + (o.noteKind || 'info') + ' py-2 small' }, o.note));
  const wraps = [];
  for (const f of fields) {
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
  const vals = () => {
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
  const refresh = () => { const v = vals(); for (const [f, w] of wraps) w.classList.toggle('d-none', !!f.show && !f.show(v)); };
  body.addEventListener('change', refresh); body.addEventListener('input', refresh);
  refresh();
  $('#dlgTitle').textContent = title;
  $('#dlgBody').replaceChildren(body);
  $('#dlgErr').textContent = '';
  $('#dlgApply').textContent = o.applyText || 'Apply';
  $('#dlgApply').className = 'btn ' + (o.danger ? 'btn-danger' : 'btn-primary');
  dlgApply = () => {
    const v = vals();
    for (const [f] of wraps) if (f.show && !f.show(v)) delete v[f.k];
    return onApply(v);
  };
  dlg().show();
}
const confirmDo = (title, msg, fn, text) => form(title, [], fn, { note: msg, noteKind: 'warning', applyText: text || 'Apply', danger: true });

// ------------------------------------------------------------------ helpers
const ip2int = ip => ip.split('.').reduce((a, o) => a * 256 + (+o), 0);
const inCidr = (ip, cidr) => { const [n, p] = cidr.split('/'); const s = 2 ** (32 - +p); return Math.floor(ip2int(ip) / s) === Math.floor(ip2int(n) / s); };
const int2ip = n => [24, 16, 8, 0].map(b => Math.floor(n / 2 ** b) % 256).join('.');
const I = n => S.interfaces.find(i => i.name === n);
const disp = n => { if (!n) return 'any'; const i = I(n); return i && i.label ? `${n} (${i.label})` : n; };
const l3 = () => S.interfaces.filter(i => ['physical', 'bridge', 'vlan'].includes(i.kind) && !i.master);
const ifOpts = anyLabel => [['', anyLabel || 'any']].concat(l3().map(i => [i.name, disp(i.name) + (i.role !== 'none' ? ' · ' + i.role.toUpperCase() : '')]));
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
      stat('Port forwards', S.firewall.forwards.length, '#forwards')),
    h('div', { class: 'row g-3' },
      h('div', { class: 'col-lg-5' }, card('System', null, h('div', { class: 'card-body' }, h('dl', { class: 'row mb-0 small' },
        [['Hostname', s.hostname], ['LiteFWM', s.version], ['Alpine', s.alpine], ['Kernel', s.kernel], ['Uptime', upt],
         ['Load', s.load], ['Memory used', memPct + '%'], ['Resolvers', s.resolvers.join(', ') || '—'],
         ['IP forwarding', s.ipForward ? 'on' : 'OFF'], ['DNS/DHCP (dnsmasq)', s.services.dnsmasq ? 'running' : 'STOPPED'],
         ['Web UI', 'port ' + s.management.port + ' · ' + (s.management.access[0] === 'any' ? 'all interfaces' : s.management.access.join(', '))],
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
    const acts = [btn('MTU', () => form('MTU of ' + i.name, [{ k: 'mtu', label: 'MTU', type: 'number', value: i.mtu }], v => apply('iface.set', { name: i.name, mtu: v.mtu })))];
    if (i.kind === 'bridge') acts.push(btn('+ Port', () => addPort(i)),
      btn(i.vlanFiltering ? 'VLAN filter off' : 'VLAN filter on', () => apply('bridge.set', { name: i.name, vlanFiltering: !i.vlanFiltering })),
      btn('Delete', () => confirmDo('Delete bridge', `Delete ${i.name}? If it has an IP configuration it is handed back to its first Ethernet port.`, () => apply('bridge.delete', { name: i.name }, 'Bridge deleted'), 'Delete'), 'btn-outline-danger'));
    if (i.kind === 'vlan') acts.push(btn('Delete', () => confirmDo('Delete VLAN', `Delete ${i.name}?`, () => apply('vlan.delete', { name: i.name }, 'VLAN deleted'), 'Delete'), 'btn-outline-danger'));
    return h('tr', {},
      h('td', { class: 'mono text-nowrap' }, h('span', { class: 'dot ' + (i.carrier ? 'up' : 'down'), title: i.oper }), i.name),
      h('td', {}, i.kind), h('td', { class: 'mono small' }, i.mac), h('td', {}, i.mtu), h('td', {}, relation),
      h('td', { class: 'mono small' }, i.addresses.join(' ') || '—'), h('td', { class: 'text-end text-nowrap' }, acts));
  });
  const vcards = S.interfaces.filter(i => i.kind === 'bridge' && i.vlanFiltering).map(b =>
    card(`VLAN membership — ${b.name}`, null, table(['Port', 'Untagged (PVID)', 'Tagged', ''],
      b.bridgeVlans.map(p => h('tr', {}, h('td', { class: 'mono' }, p.port, p.self ? ' (bridge / VLAN interfaces)' : ''),
        h('td', {}, dash((p.vlans.find(v => v.pvid) || {}).vid)), h('td', {}, p.vlans.filter(v => !v.pvid).map(v => v.vid).join(', ') || '—'),
        h('td', { class: 'text-end' }, btn('Edit', () => portVlans(b, p))))))));
  return [card('Interfaces (layer 2)', [btn('New bridge', newBridge, 'btn-primary'), btn('New VLAN', newVlan, 'btn-primary')],
    table(['Name', 'Type', 'MAC', 'MTU', 'Bridge / VLAN', 'IPv4', ''], rows)), vcards];
};

// ---------- segments (layer 3)
function editSegment(i) {
  const w = wan();
  form('Segment on ' + i.name, [
    { k: 'label', label: 'Segment name', value: i.label, placeholder: 'e.g. LAN, DMZ, IoT' },
    { k: 'role', label: 'Role', type: 'select', value: i.role, options: [['lan', 'LAN — internal segment'], ['wan', 'WAN — internet uplink (default route, outbound NAT)'], ['none', 'Unassigned']],
      help: w && w.name !== i.name ? `${w.name} is the WAN; there can only be one.` : null },
    { k: 'mode', label: 'Addressing', type: 'select', value: i.mode, options: [['static', 'Static'], ['dhcp', 'DHCP client'], ['none', 'No address']] },
    { k: 'addresses', label: 'Addresses (CIDR)', type: 'list', value: i.mode === 'static' ? i.addresses : [], placeholder: '192.168.10.1/24', show: v => v.mode === 'static' },
    { k: 'gateway', label: 'Default gateway', value: i.mode === 'static' ? i.gateway : '', show: v => v.mode === 'static' && v.role === 'wan' },
    { k: 'dns', label: 'Upstream DNS servers for the firewall', type: 'list', value: i.role === 'wan' && i.mode === 'static' ? S.system.resolvers : [], show: v => v.mode === 'static' && v.role === 'wan',
      help: 'Written to /etc/resolv.conf. With DHCP the provider\'s servers are used.' }
  ], v => apply('segment.set', Object.assign({ interface: i.name }, v), 'Segment applied'),
  { note: clientWarn(i.name), noteKind: 'warning' });
}
views.segments = () => [
  card('Network segments (layer 3)', null, table(['Interface', 'Name', 'Role', 'Addressing', 'Addresses', 'Gateway', 'DHCP server', ''],
    l3().map(i => h('tr', {},
      h('td', { class: 'mono' }, h('span', { class: 'dot ' + (i.carrier ? 'up' : 'down') }), i.name, h('div', { class: 'small text-secondary' }, i.kind)),
      h('td', {}, dash(i.label)), h('td', {}, roleBadge(i.role)), h('td', {}, i.mode),
      h('td', { class: 'mono small' }, i.addresses.join(' ') || '—'), h('td', { class: 'mono small' }, dash(i.gateway)),
      h('td', {}, i.dhcpServer.enabled ? `${i.dhcpServer.start} – ${i.dhcpServer.end}` : '—'),
      h('td', { class: 'text-end' }, btn('Edit', () => editSegment(i))))))),
  h('p', { class: 'small text-secondary' }, 'Bridge ports are configured through their bridge. Every LAN segment is isolated from the others and from the internet until a firewall rule allows the traffic.')
];

// ---------- DHCP
function editDhcpd(i) {
  const d = i.dhcpServer, c = i.addresses[0];
  let s = d.start, e = d.end;
  if (!d.enabled && c) { const [n, p] = c.split('/'); if (+p <= 24) { const b = ip2int(n) - ip2int(n) % 256; s = int2ip(b + 100); e = int2ip(b + 199); } }
  const own = c ? c.split('/')[0] : '';
  form('DHCP server on ' + disp(i.name), [
    { k: 'enabled', label: 'Enable DHCP server', type: 'check', value: d.enabled || !d.start },
    { k: 'start', label: 'Range start', value: s, show: v => v.enabled },
    { k: 'end', label: 'Range end', value: e, show: v => v.enabled },
    { k: 'leaseTime', label: 'Lease time', value: d.leaseTime || '12h', help: 'e.g. 3600, 30m, 12h, 7d', show: v => v.enabled },
    { k: 'router', label: 'Gateway handed to clients', value: d.router === own ? '' : d.router, placeholder: own + ' (this firewall)', show: v => v.enabled },
    { k: 'dns', label: 'DNS servers handed to clients', type: 'list', value: (d.dns || []).join() === own ? [] : d.dns, placeholder: own + ' (this firewall)', show: v => v.enabled },
    { k: 'domain', label: 'Domain name', value: d.domain, placeholder: S.dns.domain || 'lan', show: v => v.enabled },
    { k: 'ntp', label: 'NTP servers', type: 'list', value: d.ntp, show: v => v.enabled }
  ], v => apply('dhcpd.set', Object.assign({ interface: i.name }, v), 'DHCP server applied'));
}
function reserve(mac, ip, hostname, isEdit) {
  form(isEdit ? 'Edit reservation' : 'Make this address static', [
    { k: 'mac', label: 'MAC address', type: isEdit === 'new' ? 'text' : 'info', value: mac },
    { k: 'ip', label: 'Reserved IP address', value: ip, help: 'Always handed to this MAC. Must be inside a segment with a DHCP server; may be inside or outside the dynamic range.' },
    { k: 'hostname', label: 'Hostname', value: hostname, help: 'Optional. Resolves as hostname.' + (S.dns.domain || 'lan') + ' on the firewall DNS.' }
  ], v => apply('reservation.add', { mac: v.mac || mac, ip: v.ip, hostname: v.hostname }, 'Reservation applied'),
  { note: isEdit ? null : 'The device keeps its current address. If you choose a different IP it moves when it next renews its lease (or reconnects).' });
}
views.dhcp = () => {
  const now = Date.now() / 1000;
  const lans = l3().filter(i => i.role === 'lan');
  const leaseByMac = Object.fromEntries(S.dhcp.leases.map(l => [l.mac, l]));
  return [
    card('DHCP servers', null, table(['Segment', 'Subnet', 'Range', 'Lease', 'Gateway / DNS', ''],
      lans.map(i => { const d = i.dhcpServer; return h('tr', {},
        h('td', {}, disp(i.name)), h('td', { class: 'mono small' }, i.addresses.join(' ') || '—'),
        h('td', { class: 'mono small' }, d.enabled ? `${d.start} – ${d.end}` : badge('off')), h('td', {}, d.enabled ? d.leaseTime : ''),
        h('td', { class: 'mono small' }, d.enabled ? `${d.router} / ${(d.dns || []).join(', ')}` : ''),
        h('td', { class: 'text-end' }, i.mode === 'static' && i.addresses.length ? btn('Configure', () => editDhcpd(i)) : h('span', { class: 'small text-secondary' }, 'needs a static address'))); }),
      'No LAN segments. Give an interface the LAN role first.')),
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

// ---------- DNS
views.dns = () => {
  const d = S.dns;
  const edit = () => form('DNS settings', [
    { k: 'domain', label: 'Local domain', value: d.domain || 'lan', help: 'DHCP clients and reservations resolve as name.domain.' },
    { k: 'upstream', label: 'Upstream DNS servers', type: 'list', value: d.upstream, placeholder: 'empty = the WAN\'s resolvers (' + S.system.resolvers.join(', ') + ')' },
    { k: 'hosts', label: 'Local host records (one per line: name ip)', type: 'textarea', value: d.hosts.map(x => `${x.name} ${x.ip}`).join('\n'), placeholder: 'nas 192.168.10.5' }
  ], v => apply('dns.set', { domain: v.domain, upstream: v.upstream, hosts: v.hosts.split('\n').map(l => l.trim().split(/\s+/)).filter(x => x[0]).map(([name, ip]) => ({ name, ip })) }, 'DNS applied'));
  return card('DNS resolver (dnsmasq)', [btn('Edit', edit, 'btn-primary')], h('div', { class: 'card-body' },
    h('dl', { class: 'row mb-0' },
      h('dt', { class: 'col-sm-3' }, 'Local domain'), h('dd', { class: 'col-sm-9 mono' }, dash(d.domain)),
      h('dt', { class: 'col-sm-3' }, 'Upstream servers'), h('dd', { class: 'col-sm-9 mono' }, d.upstream.join(', ') || `WAN resolvers (${S.system.resolvers.join(', ') || 'none'})`),
      h('dt', { class: 'col-sm-3' }, 'Serves'), h('dd', { class: 'col-sm-9' }, l3().filter(i => i.role === 'lan').map(i => disp(i.name)).join(', ') || 'no LAN segments'),
      h('dt', { class: 'col-sm-3' }, 'Host records'), h('dd', { class: 'col-sm-9 mono' }, d.hosts.length ? d.hosts.map(x => h('div', {}, `${x.name} → ${x.ip}`)) : '—'))));
};

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
    return isNew ? apply('rule.add', v, 'Rule added') : apply('rule.update', Object.assign({ id: r.id }, v), 'Rule updated');
  }, { note: 'Rules are evaluated top to bottom; the first match wins. Anything not allowed is dropped. Replies to allowed traffic are allowed automatically.' });
}
function ruleTable(chain) {
  const rs = S.firewall.rules.filter(r => r.chain === chain);
  const acts = { accept: 'text-bg-success', drop: 'text-bg-danger', reject: 'text-bg-warning' };
  const ep = (i, a) => [h('div', {}, disp(i)), a && h('div', { class: 'mono small' }, a)];
  return table(['#', 'Action', 'From', chain === 'forward' ? 'To' : 'Destination', 'Service', 'Description', ''],
    rs.map((r, n) => h('tr', {},
      h('td', { class: 'text-secondary' }, n + 1), h('td', {}, badge(r.action === 'accept' ? 'allow' : r.action, acts[r.action])),
      h('td', {}, ep(r.in, r.src)), h('td', {}, chain === 'forward' ? ep(r.out, r.dst) : (r.dst || 'this firewall')),
      h('td', { class: 'mono small' }, r.proto === 'any' ? 'any' : r.proto + (r.ports ? ' ' + r.ports : '')),
      h('td', {}, r.managed ? dash(r.description) : h('span', { class: 'mono small text-secondary', title: 'not created by LiteFWM; read-only' }, r.raw)),
      h('td', { class: 'text-end text-nowrap' }, r.managed && [
        btn('↑', () => apply('rule.move', { id: r.id, position: Math.max(0, n - 1) }, 'Moved'), n === 0 ? 'btn-outline-secondary disabled' : null), ' ',
        btn('↓', () => apply('rule.move', { id: r.id, position: n + 1 }, 'Moved'), n === rs.length - 1 ? 'btn-outline-secondary disabled' : null), ' ',
        btn('Edit', () => editRule(r)), ' ',
        btn('Delete', () => confirmDo('Delete rule', `Delete rule ${n + 1}${r.description ? ' "' + r.description + '"' : ''}?`, () => apply('rule.delete', { id: r.id }, 'Rule deleted'), 'Delete'), 'btn-outline-danger')]))),
    chain === 'forward' ? 'No rules: all traffic between segments and to the internet is blocked.' : 'No rules.');
}
views.firewall = () => {
  const w = wan(), s = S.system;
  const lans = l3().filter(i => i.role === 'lan').map(i => disp(i.name)).join(', ') || 'none';
  const implicit = [
    ['allow', 'Replies to allowed connections (established / related)'],
    ['allow', `Web UI tcp/${s.management.port}` + (s.ssh.enabled ? ` and SSH tcp/${s.ssh.port}` : '') + ' to this firewall from ' + (s.management.access[0] === 'any' ? 'any interface' : s.management.access.join(', '))],
    ['allow', `DNS, DHCP and ping to this firewall from LAN segments (${lans})`],
    ['allow', 'Port forwards (see Port forwards)'],
    ['nat', w ? `Outbound NAT (masquerade) on the WAN ${disp(w.name)}` : 'Outbound NAT: no WAN segment defined'],
    ['drop', `Everything else (policy INPUT ${S.firewall.policies.INPUT || '?'}, FORWARD ${S.firewall.policies.FORWARD || '?'})`]
  ];
  return [
    card('Forwarding rules — between segments and to the internet', [btn('Add rule', () => editRule(null, 'forward'), 'btn-primary')], ruleTable('forward')),
    card('Input rules — traffic to this firewall', [btn('Add rule', () => editRule(null, 'input'), 'btn-primary')], ruleTable('input')),
    card('Built-in behaviour', [btn('Management access', () => location.hash = '#system')], table(['', 'Rule'],
      implicit.map(([a, t]) => h('tr', { class: 'implicit' }, h('td', {}, badge(a, a === 'drop' ? 'text-bg-danger' : a === 'nat' ? 'text-bg-info' : 'text-bg-success')), h('td', {}, t)))))
  ];
};

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
  ], v => isNew ? apply('forward.add', v, 'Port forward added') : apply('forward.update', Object.assign({ id: f.id }, v), 'Port forward updated'),
  { note: 'Forwarded traffic is allowed through the firewall automatically; no extra rule is needed.' });
}
views.forwards = () => card('Port forwards (destination NAT)', [btn('Add port forward', () => editForward(null), 'btn-primary')],
  table(['Interface', 'Protocol', 'External port', 'Internal host', 'Sources', 'Description', ''],
    S.firewall.forwards.map(f => h('tr', {},
      h('td', {}, disp(f.in)), h('td', {}, f.proto === 'both' ? 'tcp+udp' : f.proto), h('td', { class: 'mono' }, f.port),
      h('td', { class: 'mono' }, f.to + (f.toPort ? ':' + f.toPort : '')), h('td', { class: 'mono small' }, f.src || 'anyone'),
      h('td', {}, f.managed ? dash(f.description) : h('span', { class: 'mono small text-secondary' }, f.raw)),
      h('td', { class: 'text-end text-nowrap' }, f.managed && [btn('Edit', () => editForward(f)), ' ',
        btn('Delete', () => confirmDo('Delete port forward', `Delete the forward of port ${f.port}?`, () => apply('forward.delete', { id: f.id }, 'Port forward deleted'), 'Delete'), 'btn-outline-danger')]))),
    'No port forwards.'));

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
        { k: 'mode', label: 'Allow the web UI' + (s.ssh.enabled ? ' and SSH' : '') + ' from', type: 'select', value: m.access[0] === 'any' ? 'any' : 'list', options: [['any', 'any interface'], ['list', 'selected segments only']] },
        { k: 'ifs', label: 'Segments', type: 'multi', value: m.access[0] === 'any' ? [] : m.access, options: l3().map(i => [i.name, disp(i.name)]), show: v => v.mode === 'list' },
        { k: 'sshEnabled', label: 'SSH server enabled', type: 'check', value: s.ssh.enabled },
        { k: 'sshPort', label: 'SSH port', type: 'number', value: s.ssh.port, show: v => v.sshEnabled }
      ], v => apply('mgmt.set', { port: v.port, sshEnabled: v.sshEnabled, sshPort: v.sshPort, access: v.mode === 'any' ? 'any' : v.ifs }),
      { note: `Your session arrives on ${m.clientInterface || 'an unknown interface'} (${m.clientIp || '?'}); LiteFWM refuses changes that would lock it out.` }), 'btn-primary')],
        h('div', { class: 'card-body' }, h('dl', { class: 'row mb-0' },
          h('dt', { class: 'col-5' }, 'Web UI'), h('dd', { class: 'col-7' }, 'port ' + m.port),
          h('dt', { class: 'col-5' }, 'Allowed from'), h('dd', { class: 'col-7' }, m.access[0] === 'any' ? 'any interface' : m.access.map(disp).join(', ')),
          h('dt', { class: 'col-5' }, 'SSH'), h('dd', { class: 'col-7' }, s.ssh.enabled ? 'enabled, port ' + s.ssh.port : 'disabled')))),
      card('Admin password', [btn('Change', () => form('Change password', [
        { k: 'user', label: 'User', value: 'admin' }, { k: 'password', label: 'New password', type: 'password', help: 'At least 8 characters.' }
      ], v => apply('password.set', v, 'Password changed')))], h('div', { class: 'card-body small text-secondary' }, 'The browser will ask for the new password on the next request.'))),
    h('div', { class: 'col-lg-6' }, card('Diagnostics', null, h('div', { class: 'card-body' },
      h('div', { class: 'input-group mb-2' }, host, btn('Ping', () => diag('ping'), 'btn-outline-primary'), btn('DNS lookup', () => diag('lookup'), 'btn-outline-primary')), out))));
};

// ------------------------------------------------------------------ router
function render() {
  if (!S) return;
  const v = (location.hash || '#overview').slice(1);
  const fn = views[v] || views.overview;
  document.querySelectorAll('#navLinks .nav-link').forEach(a => a.classList.toggle('active', a.getAttribute('href') === '#' + v));
  $('#view').replaceChildren(...[fn()].flat(Infinity));
}
window.addEventListener('hashchange', load);
$('#refresh').addEventListener('click', load);
load();
