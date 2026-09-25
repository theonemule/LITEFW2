'use strict';

const state = { config:null, status:null, interfaces:[], leases:[], modules:[], metrics:null, captures:[] };
const titles = {
  overview:'Overview', interfaces:'Interfaces', segments:'Network segments',
  firewall:'Firewall rules', nat:'NAT & port forwards', dhcp:'DHCP',
  modules:'Optional modules', monitoring:'Monitoring', settings:'Settings'
};

function esc(v) {
  return String(v == null ? '' : v).replace(/[&<>"']/g, function(c) {
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];
  });
}
function id(prefix) { return prefix + '-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2,7); }
function zoneName(z) {
  return z==='internal'?'Internal':z==='external'?'External':'Unclassified';
}
function segmentText(s) {
  const addr=(s.addressMode||'static')==='dhcp'?'DHCP client':(s.address||'');
  return zoneName(s.zone)+' · '+(s.name||s.id)+(addr?' · '+addr:'');
}
function segOptions(selected, includeAny, preferredZone) {
  let out = includeAny ? '<option value="any">Any segment</option>' : '';
  let list=(state.config.segments||[]).slice();
  if(preferredZone) list.sort(function(a,b){return (a.zone===preferredZone?0:1)-(b.zone===preferredZone?0:1);});
  list.forEach(function(s) {
    out += '<option value="' + esc(s.id) + '"' + (s.id===selected?' selected':'') + '>' + esc(segmentText(s)) + '</option>';
  });
  return out;
}
function ifaceOptions(selected, includeBlank) {
  let out = includeBlank ? '<option value="">Select interface</option>' : '';
  (state.config.interfaces || []).forEach(function(i) {
    out += '<option value="' + esc(i.id) + '"' + (i.id===selected?' selected':'') + '>' + esc(i.name || i.id) + ' (' + esc(i.device) + ')</option>';
  });
  return out;
}
function detectedDeviceOptions(selected) {
  let out='<option value="">Select physical NIC</option>';
  (state.interfaces || []).filter(function(i){return i.physical===true || i.kind==='physical';}).forEach(function(i){
    out+='<option value="'+esc(i.name)+'"'+(i.name===selected?' selected':'')+'>'+esc(i.name)+' · '+esc(i.mac||'')+' · '+esc(i.state||'')+'</option>';
  });
  if(selected && !(state.interfaces||[]).some(function(i){return i.name===selected;})) out+='<option selected value="'+esc(selected)+'">'+esc(selected)+' (not currently detected)</option>';
  return out;
}
function ipv4Int(ip) {
  const p=String(ip||'').split('.').map(Number);
  if(p.length!==4 || p.some(function(x){return !Number.isInteger(x)||x<0||x>255;})) return null;
  return ((((p[0]<<24)>>>0)+(p[1]<<16)+(p[2]<<8)+p[3])>>>0);
}
function intIpv4(n) {
  n=n>>>0;
  return [(n>>>24)&255,(n>>>16)&255,(n>>>8)&255,n&255].join('.');
}
function cidrInfo(cidr) {
  const a=String(cidr||'').split('/');
  if(a.length!==2) return null;
  const ip=ipv4Int(a[0]), prefix=Number(a[1]);
  if(ip===null || !Number.isInteger(prefix) || prefix<0 || prefix>32) return null;
  const mask=prefix===0?0:((0xffffffff << (32-prefix))>>>0);
  const network=(ip & mask)>>>0;
  const broadcast=(network | ((~mask)>>>0))>>>0;
  const first=prefix>=31?network:(network+1)>>>0;
  const last=prefix>=31?broadcast:(broadcast-1)>>>0;
  return {network:intIpv4(network)+'/'+prefix,broadcast:intIpv4(broadcast),first:intIpv4(first),last:intIpv4(last),prefix:prefix};
}
function toast(title, body) {
  document.getElementById('toastTitle').textContent = title;
  document.getElementById('toastBody').textContent = body;
  bootstrap.Toast.getOrCreateInstance(document.getElementById('toast')).show();
}
async function api(path, options) {
  options = options || {};
  options.headers = Object.assign({'Accept':'application/json'}, options.headers || {});
  if ((options.method || 'GET') !== 'GET') {
    options.headers['X-LiteFWM-Request'] = '1';
    if (options.body && !options.headers['Content-Type']) options.headers['Content-Type'] = 'application/json';
  }
  const res = await fetch('/api' + path, options);
  const text = await res.text();
  let data = {};
  try { data = text ? JSON.parse(text) : {}; } catch (e) { data = {error:text || res.statusText}; }
  if (!res.ok || data.ok === false) throw new Error(data.error || res.statusText);
  return data;
}
async function loadAll() {
  const results = await Promise.all([
    api('/config'), api('/status'), api('/interfaces'), api('/leases'),
    api('/modules'), api('/metrics'), api('/captures')
  ]);
  state.config=results[0]; state.status=results[1]; state.interfaces=results[2];
  state.leases=results[3]; state.modules=results[4]; state.metrics=results[5]; state.captures=results[6];
  document.getElementById('statusDot').classList.add('online');
  document.getElementById('statusText').textContent = 'Connected to ' + state.status.hostname;
}
async function refresh() {
  try { await loadAll(); render(); }
  catch (e) {
    document.getElementById('statusText').textContent = 'Connection error';
    document.getElementById('view').innerHTML = '<div class="alert alert-danger"><strong>Unable to load LiteFWM.</strong><div class="mt-2">' + esc(e.message) + '</div></div>';
  }
}
async function saveConfig(message) {
  await api('/config', {method:'PUT', body:JSON.stringify(state.config)});
  toast('Configuration saved', message || 'Changes are staged. Apply when ready.');
}
function route() {
  const r=(location.hash || '#overview').slice(1);
  return titles[r] ? r : 'overview';
}
function render() {
  if (!state.config) return;
  const r=route();
  document.getElementById('pageTitle').textContent=titles[r];
  document.querySelectorAll('a[href^="#"]').forEach(function(a){ a.classList.toggle('active', a.getAttribute('href')==='#'+r); });
  const fn = {overview:renderOverview,interfaces:renderInterfaces,segments:renderSegments,firewall:renderFirewall,nat:renderNat,dhcp:renderDhcp,modules:renderModules,monitoring:renderMonitoring,settings:renderSettings}[r];
  fn();
}
function card(label, value, sub) {
  return '<div class="col-6 col-xl-3"><div class="card metric-card h-100"><div class="card-body"><div class="small text-secondary">' + esc(label) + '</div><div class="display-6">' + esc(value) + '</div><div class="small text-secondary">' + esc(sub || '') + '</div></div></div></div>';
}
function renderOverview() {
  const m=state.metrics || {conntrack:0,interfaces:[]};
  const st=state.status || {};
  const configured=state.config.interfaces||[];
  let html='<div class="row g-3 mb-4">';
  html += card('Interfaces', configured.length, 'Physical, bridge, and VLAN endpoints');
  html += card('Segments', st.segments || 0, 'L3 networks');
  html += card('Firewall rules', st.rules || 0, 'User-defined ordered rules');
  html += card('DHCP leases', st.leases || 0, 'Active leases');
  html += '</div>';
  if(configured.length<2) html+='<div class="alert alert-warning"><strong>Routed firewall setup is incomplete.</strong> A normal firewall/router needs at least two configured endpoints, typically WAN and LAN. Single-interface configurations are still allowed for initial setup and lab use.</div>';
  html += '<div class="row g-3"><div class="col-lg-7"><div class="card"><div class="card-header fw-semibold">Detected system interfaces</div><div class="table-responsive"><table class="table table-sm mb-0"><thead><tr><th>Device</th><th>Kind</th><th>State</th><th>MAC</th><th>MTU</th></tr></thead><tbody>';
  (state.interfaces || []).forEach(function(i) {
    html += '<tr><td><strong>'+esc(i.name)+'</strong></td><td>'+esc(i.kind||'physical')+'</td><td>'+esc(i.state)+'</td><td><code>'+esc(i.mac||'')+'</code></td><td>'+esc(i.mtu)+'</td></tr>';
  });
  html += '</tbody></table></div></div></div>';
  html += '<div class="col-lg-5"><div class="card h-100"><div class="card-body"><h2 class="h6">Applied state</h2><dl class="row mb-0"><dt class="col-5">Hostname</dt><dd class="col-7">'+esc(st.hostname)+'</dd><dt class="col-5">Last apply</dt><dd class="col-7">'+esc(st.lastApply)+'</dd><dt class="col-5">Management</dt><dd class="col-7">TCP '+esc(state.config.management.port)+(state.config.management.allowAny?' on any endpoint':' on selected segments')+'</dd><dt class="col-5">SSH</dt><dd class="col-7">'+(state.config.management.allowSsh?'TCP '+esc(state.config.management.sshPort||22)+' allowed':'Disabled by built-in policy')+'</dd></dl></div></div></div></div>';
  document.getElementById('view').innerHTML=html;
}
function renderInterfaces() {
  const configured=state.config.interfaces||[];
  let html='<div class="d-flex justify-content-between align-items-center mb-3"><div><p class="mb-0 text-secondary">Manage physical NICs, Linux bridges, and VLAN adapters. IP addresses are assigned separately under Network segments.</p></div><button id="addInterface" class="btn btn-primary btn-sm">Add managed interface</button></div>';
  html+='<div class="card mb-3"><div class="card-header fw-semibold">Managed interfaces</div><div class="table-responsive"><table class="table mb-0"><thead><tr><th>Name</th><th>Type</th><th>Device</th><th>Attached segments</th><th>Details</th><th></th></tr></thead><tbody>';
  configured.forEach(function(i,idx){
    const segs=(state.config.segments||[]).filter(function(s){return s.interface===i.id;});
    let details='MTU '+esc(i.mtu||1500);
    if(i.type==='bridge') details='VLAN-aware '+(i.vlanAware===false?'off':'on')+' · members: '+((i.members||[]).join(', ')||'none');
    if(i.type==='vlan') details='parent '+esc(i.parent)+' · VLAN '+esc(i.vlanId);
    html+='<tr><td><strong>'+esc(i.name||i.id)+'</strong><div class="small text-secondary">'+esc(i.id)+'</div></td><td>'+esc(i.type)+'</td><td><code>'+esc(i.device)+'</code></td><td>'+(segs.length?segs.map(function(x){return '<span class="badge badge-soft me-1">'+esc(x.name||x.id)+'</span>';}).join(''):'<span class="text-secondary">None</span>')+'</td><td class="small">'+details+'</td><td class="text-end"><div class="btn-group btn-group-sm"><button class="btn btn-outline-secondary edit-iface" data-i="'+idx+'">Edit</button><button class="btn btn-outline-danger del-iface" data-i="'+idx+'">Remove</button></div></td></tr>';
  });
  if(!configured.length) html+='<tr><td colspan="6" class="text-secondary">No interfaces are managed by LiteFWM yet. Configure a detected physical NIC or add a bridge/VLAN.</td></tr>';
  html+='</tbody></table></div></div>';
  html+='<div class="card"><div class="card-header fw-semibold">Detected host links</div><div class="table-responsive"><table class="table table-sm mb-0"><thead><tr><th>Device</th><th>Detected type</th><th>State</th><th>MAC</th><th>Owner</th><th></th></tr></thead><tbody>';
  (state.interfaces||[]).forEach(function(i){
    const managed=configured.find(function(x){return x.device===i.name;});
    const isPhysical=i.physical===true || i.kind==='physical';
    let owner=managed?'<span class="badge text-bg-success">LiteFWM managed</span>':(isPhysical?'<span class="badge badge-soft">Available NIC</span>':'<span class="badge badge-soft">System / other service</span>');
    let action='';
    if(managed) action='<button class="btn btn-sm btn-outline-secondary edit-detected" data-id="'+esc(managed.id)+'">Edit</button>';
    else if(isPhysical) action='<button class="btn btn-sm btn-outline-primary configure-detected" data-device="'+esc(i.name)+'">Configure</button>';
    html+='<tr><td><strong>'+esc(i.name)+'</strong></td><td>'+esc(i.kind||'virtual')+'</td><td>'+esc(i.state||'')+'</td><td><code>'+esc(i.mac||'')+'</code></td><td>'+owner+'</td><td class="text-end">'+action+'</td></tr>';
  });
  html+='</tbody></table></div><div class="card-footer small text-secondary">Loopback, Docker bridges, veth pairs, and other service-created links are shown for visibility but are not treated as physical NICs. LiteFWM only deletes virtual interfaces that LiteFWM itself previously created.</div></div>';
  document.getElementById('view').innerHTML=html;
  document.getElementById('addInterface').onclick=function(){editInterface(-1);};
  document.querySelectorAll('.edit-iface').forEach(function(b){b.onclick=function(){editInterface(Number(b.dataset.i));};});
  document.querySelectorAll('.edit-detected').forEach(function(b){b.onclick=function(){const idx=configured.findIndex(function(x){return x.id===b.dataset.id;});if(idx>=0)editInterface(idx);};});
  document.querySelectorAll('.configure-detected').forEach(function(b){b.onclick=function(){editInterface(-1,{type:'physical',device:b.dataset.device,id:b.dataset.device,name:b.dataset.device});};});
  document.querySelectorAll('.del-iface').forEach(function(b){b.onclick=async function(){
    const idx=Number(b.dataset.i), item=state.config.interfaces[idx];
    const refs=(state.config.segments||[]).some(function(x){return x.interface===item.id;}) ||
      (state.config.interfaces||[]).some(function(x){return x.parent===item.id || (x.members||[]).includes(item.id);});
    if(refs){toast('Interface is in use','Remove dependent segments, VLANs, or bridge membership first.');return;}
    if(confirm('Remove '+(item.name||item.id)+' from LiteFWM management?'+(item.type==='physical'?' The Linux NIC itself will not be deleted.':' The virtual link will be deleted on the next Apply.'))){
      state.config.interfaces.splice(idx,1);await saveConfig('Interface removal staged.');renderInterfaces();
    }
  };});
}
function editInterface(index,preset) {
  const old=index>=0?state.config.interfaces[index]:Object.assign({id:'',name:'',type:'physical',device:'',role:'none',mtu:1500,enabled:true,vlanAware:true,members:[]},preset||{});
  document.getElementById('modalTitle').textContent=index>=0?'Edit managed interface':'Add managed interface';
  document.getElementById('modalBody').innerHTML=
    '<div class="row g-3">'+
    '<div class="col-md-4"><label class="form-label">ID</label><input id="ifId" class="form-control" value="'+esc(old.id||'')+'"></div>'+
    '<div class="col-md-4"><label class="form-label">Name</label><input id="ifName" class="form-control" value="'+esc(old.name||'')+'"></div>'+
    '<div class="col-md-4"><label class="form-label">Type</label><select id="ifType" class="form-select"><option value="physical">Physical NIC</option><option value="bridge">Linux bridge</option><option value="vlan">VLAN adapter</option></select></div>'+
    '<div class="col-md-4"><label class="form-label">MTU</label><input id="ifMtu" type="number" min="576" max="9216" class="form-control" value="'+esc(old.mtu||1500)+'"></div>'+
    '<div class="col-md-4 d-flex align-items-end"><div class="form-check mb-2"><input id="ifEnabled" class="form-check-input" type="checkbox" '+(old.enabled===false?'':'checked')+'><label class="form-check-label">Enabled</label></div></div>'+
    '<div id="ifTypeFields" class="col-12"></div></div>';
  document.getElementById('ifType').value=old.type||'physical';
  function fields(){
    const t=document.getElementById('ifType').value;
    let h='';
    if(t==='physical') h='<label class="form-label">Physical device</label><select id="ifDevice" class="form-select">'+detectedDeviceOptions(old.device||'')+'</select><div class="form-text">Only links detected as physical NICs are offered here.</div>';
    if(t==='bridge') {
      const choices=(state.config.interfaces||[]).filter(function(x){return x.id!==old.id && x.type!=='bridge';}).map(function(x){return '<label class="form-check"><input class="form-check-input bridge-member" type="checkbox" value="'+esc(x.id)+'" '+((old.members||[]).includes(x.id)?'checked':'')+'><span class="form-check-label">'+esc(x.name||x.id)+' <code>'+esc(x.device)+'</code></span></label>';}).join('');
      h='<div class="row g-3"><div class="col-md-6"><label class="form-label">Bridge device</label><input id="ifDevice" class="form-control" placeholder="br-lan" value="'+esc(old.device||'')+'"></div><div class="col-md-6 d-flex align-items-end"><div class="form-check mb-2"><input id="ifVlanAware" class="form-check-input" type="checkbox" '+(old.vlanAware===false?'':'checked')+'><label class="form-check-label">VLAN-aware bridge</label></div></div><div class="col-12"><label class="form-label">Member interfaces</label><div class="border rounded p-2">'+(choices||'<span class="text-secondary small">Add physical or VLAN interfaces first.</span>')+'</div></div></div>';
    }
    if(t==='vlan') h='<div class="row g-3"><div class="col-md-5"><label class="form-label">Parent interface</label><select id="ifParent" class="form-select">'+ifaceOptions(old.parent||'',true)+'</select></div><div class="col-md-3"><label class="form-label">VLAN ID</label><input id="ifVlanId" type="number" min="1" max="4094" class="form-control" value="'+esc(old.vlanId==null?'':old.vlanId)+'"></div><div class="col-md-4"><label class="form-label">Device name</label><input id="ifDevice" class="form-control" placeholder="br-lan.100" value="'+esc(old.device||'')+'"><div class="form-text">Leave blank to derive parent-device.VLAN.</div></div></div>';
    document.getElementById('ifTypeFields').innerHTML=h;
  }
  document.getElementById('ifType').onchange=fields;fields();
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="saveInterface" class="btn btn-primary">Save interface</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('saveInterface').onclick=async function(){
    const type=document.getElementById('ifType').value;
    const iid=document.getElementById('ifId').value.trim();
    let device=document.getElementById('ifDevice').value.trim();
    const obj={id:iid,name:document.getElementById('ifName').value.trim()||iid,type:type,device:device,role:'none',mtu:Number(document.getElementById('ifMtu').value||1500),enabled:document.getElementById('ifEnabled').checked};
    if(type==='bridge'){obj.vlanAware=document.getElementById('ifVlanAware').checked;obj.members=Array.from(document.querySelectorAll('.bridge-member:checked')).map(function(x){return x.value;});}
    if(type==='vlan'){obj.parent=document.getElementById('ifParent').value;obj.vlanId=Number(document.getElementById('ifVlanId').value);if(!device){const parent=(state.config.interfaces||[]).find(function(x){return x.id===obj.parent;});obj.device=(parent?parent.device:obj.parent)+'.'+obj.vlanId;}}
    const prev=old.id;
    if(index>=0) state.config.interfaces[index]=obj; else state.config.interfaces.push(obj);
    if(prev && prev!==obj.id){
      (state.config.segments||[]).forEach(function(x){if(x.interface===prev)x.interface=obj.id;});
      (state.config.interfaces||[]).forEach(function(x){if(x.parent===prev)x.parent=obj.id;if(x.members)x.members=x.members.map(function(m){return m===prev?obj.id:m;});});
    }
    try{await saveConfig('Interface saved.');modal.hide();renderInterfaces();}catch(e){if(index>=0)state.config.interfaces[index]=old;else state.config.interfaces.pop();toast('Save failed',e.message);}
  };
}
function renderSegments() {
  let html='<div class="d-flex justify-content-between align-items-center mb-3"><div><p class="mb-0 text-secondary">Segments are IP configurations attached to managed interfaces. An interface may carry multiple static segments.</p></div><button class="btn btn-primary btn-sm" id="addSegment">Add segment</button></div>';
  html+='<div class="card"><div class="table-responsive"><table class="table mb-0"><thead><tr><th>Name</th><th>Zone</th><th>Interface</th><th>Addressing</th><th>Gateway / DNS</th><th>DHCP server</th><th></th></tr></thead><tbody>';
  (state.config.segments||[]).forEach(function(seg,idx){
    const i=(state.config.interfaces||[]).find(function(x){return x.id===seg.interface;});
    const staticMode=(seg.addressMode||'static')==='static';
    const ci=staticMode?cidrInfo(seg.address):null;
    const zoneClass=seg.zone==='external'?'text-bg-primary':seg.zone==='internal'?'text-bg-success':'badge-soft';
    html+='<tr><td><strong>'+esc(seg.name||seg.id)+'</strong><div class="small text-secondary">'+esc(seg.id)+'</div></td>'+
      '<td><span class="badge '+zoneClass+'">'+esc(zoneName(seg.zone))+'</span></td>'+
      '<td>'+esc(i?i.name||i.id:seg.interface)+'<div class="small text-secondary"><code>'+esc(i?i.device:'')+'</code></div></td>'+
      '<td>'+(staticMode?'<code>'+esc(seg.address)+'</code><div class="small text-secondary">'+(ci?'Network '+esc(ci.network):'Invalid CIDR')+'</div>':'<span class="badge text-bg-info">DHCP client</span>')+'</td>'+
      '<td>'+esc(seg.gateway||'—')+'<div class="small text-secondary">'+esc((seg.dns||[]).join(', ')||'DNS via DHCP / none')+'</div></td>'+
      '<td>'+(seg.dhcp&&seg.dhcp.enabled?'<span class="badge text-bg-success">On</span><div class="small text-secondary">'+esc(seg.dhcp.poolStart)+' – '+esc(seg.dhcp.poolEnd)+'</div>':'<span class="badge badge-soft">Off</span>')+'</td>'+
      '<td class="text-end"><div class="btn-group btn-group-sm"><button class="btn btn-outline-secondary edit-seg" data-i="'+idx+'">Edit</button><button class="btn btn-outline-danger del-seg" data-i="'+idx+'">Delete</button></div></td></tr>';
  });
  if(!(state.config.segments||[]).length) html+='<tr><td colspan="7" class="text-secondary">No network segments configured.</td></tr>';
  html+='</tbody></table></div></div>';
  document.getElementById('view').innerHTML=html;
  document.getElementById('addSegment').onclick=function(){editSegment(-1);};
  document.querySelectorAll('.edit-seg').forEach(function(b){b.onclick=function(){editSegment(Number(b.dataset.i));};});
  document.querySelectorAll('.del-seg').forEach(function(b){b.onclick=async function(){
    const idx=Number(b.dataset.i), old=state.config.segments[idx];
    const used=(state.config.firewall.rules||[]).some(function(r){return r.inSegment===old.id||r.outSegment===old.id;}) ||
      ['masquerade','snat'].some(function(k){return (state.config.firewall.nat[k]||[]).some(function(n){return n.sourceSegment===old.id||n.outSegment===old.id;});}) ||
      (state.config.firewall.nat.dnat||[]).some(function(n){return n.inSegment===old.id;});
    if(used){toast('Segment is in use','Remove firewall and NAT rules that reference this segment first.');return;}
    if(confirm('Delete '+(old.name||old.id)+'?')){
      state.config.segments.splice(idx,1);
      state.config.management.allowedSegments=(state.config.management.allowedSegments||[]).filter(function(x){return x!==old.id;});
      await saveConfig('Segment removed.');renderSegments();
    }
  };});
}
function editSegment(index) {
  const old=index>=0?state.config.segments[index]:{id:'',name:'',interface:'',zone:'internal',addressMode:'static',address:'',gateway:'',dns:[],domain:'',dhcpClient:{hostname:''},dhcp:{enabled:false,dns:[],ntp:[],reservations:[]}};
  const d=old.dhcp||{enabled:false,dns:[],ntp:[],reservations:[]};
  document.getElementById('modalTitle').textContent=index>=0?'Edit network segment':'Add network segment';
  document.getElementById('modalBody').innerHTML=
    '<div class="row g-3">'+
    '<div class="col-md-3"><label class="form-label">ID</label><input id="segId" class="form-control" '+(index>=0?'disabled ':'')+'value="'+esc(old.id||'')+'"></div>'+
    '<div class="col-md-3"><label class="form-label">Name</label><input id="segName" class="form-control" value="'+esc(old.name||'')+'"></div>'+
    '<div class="col-md-3"><label class="form-label">Interface</label><select id="segInterface" class="form-select">'+ifaceOptions(old.interface||'',true)+'</select></div>'+
    '<div class="col-md-3"><label class="form-label">Firewall zone</label><select id="segZone" class="form-select"><option value="internal">Internal</option><option value="external">External</option><option value="none">Unclassified</option></select></div>'+
    '<div class="col-md-4"><label class="form-label">Address assignment</label><select id="addressMode" class="form-select"><option value="static">Static IPv4</option><option value="dhcp">DHCP client</option></select></div>'+
    '<div id="staticFields" class="col-12"></div><div id="dhcpClientFields" class="col-12"></div>'+
    '<div class="col-12"><div class="form-check"><input id="managementAllowed" type="checkbox" class="form-check-input" '+((state.config.management.allowedSegments||[]).includes(old.id)?'checked':'')+'><label class="form-check-label">Allow LiteFWM management from this segment when management is restricted</label></div></div>'+
    '<div id="dhcpServerFields" class="col-12"></div></div>';
  document.getElementById('segZone').value=old.zone||'internal';
  document.getElementById('addressMode').value=old.addressMode||'static';

  function renderAddressFields(){
    const mode=document.getElementById('addressMode').value;
    if(mode==='static'){
      document.getElementById('staticFields').innerHTML='<div class="row g-3"><div class="col-md-4"><label class="form-label">Interface address / CIDR</label><input id="segAddress" class="form-control" placeholder="192.168.10.1/24" value="'+esc(old.address||'')+'"><div id="cidrPreview" class="form-text"></div></div><div class="col-md-4"><label class="form-label">Default gateway</label><input id="segGateway" class="form-control" placeholder="Usually only on an external segment" value="'+esc(old.gateway||'')+'"></div><div class="col-md-4"><label class="form-label">DNS servers</label><input id="segDns" class="form-control" placeholder="1.1.1.1, 9.9.9.9" value="'+esc((old.dns||[]).join(', '))+'"></div></div>';
      document.getElementById('dhcpClientFields').innerHTML='';
      const addr=document.getElementById('segAddress');
      function preview(){const c=cidrInfo(addr.value.trim());document.getElementById('cidrPreview').textContent=c?'Network '+c.network+' · usable '+c.first+' – '+c.last+' · broadcast '+c.broadcast:'Enter an IPv4 address with CIDR prefix.';}
      addr.oninput=preview;preview();
    } else {
      document.getElementById('staticFields').innerHTML='';
      document.getElementById('dhcpClientFields').innerHTML='<div class="row g-3"><div class="col-md-6"><label class="form-label">DHCP hostname</label><input id="dhcpClientHost" class="form-control" value="'+esc((old.dhcpClient&&old.dhcpClient.hostname)||'')+'"></div><div class="col-md-6"><div class="alert alert-light border mb-0 small">Address, subnet, gateway, and DNS are learned from the upstream DHCP server.</div></div></div>';
    }
    renderDhcpServerFields();
  }
  function renderDhcpServerFields(){
    const mode=document.getElementById('addressMode').value;
    if(mode!=='static'){document.getElementById('dhcpServerFields').innerHTML='';return;}
    document.getElementById('dhcpServerFields').innerHTML='<hr><div class="form-check mb-3"><input id="dhcpEnabled" type="checkbox" class="form-check-input" '+(d.enabled?'checked':'')+'><label class="form-check-label">Provide DHCP service on this segment</label></div><div class="row g-3"><div class="col-md-4"><label class="form-label">Pool start</label><input id="poolStart" class="form-control" value="'+esc(d.poolStart||'')+'"></div><div class="col-md-4"><label class="form-label">Pool end</label><input id="poolEnd" class="form-control" value="'+esc(d.poolEnd||'')+'"></div><div class="col-md-4"><label class="form-label">Lease time</label><input id="leaseTime" class="form-control" value="'+esc(d.leaseTime||'12h')+'"></div><div class="col-md-6"><label class="form-label">Client gateway / router</label><input id="dhcpGateway" class="form-control" placeholder="Defaults to this interface address" value="'+esc(d.gateway||'')+'"></div><div class="col-md-6"><label class="form-label">Client DNS servers</label><input id="dhcpDns" class="form-control" placeholder="Defaults to segment DNS" value="'+esc((d.dns||[]).join(', '))+'"></div><div class="col-md-6"><label class="form-label">DNS domain</label><input id="segDomain" class="form-control" placeholder="home.arpa" value="'+esc(old.domain||'')+'"></div><div class="col-md-6"><label class="form-label">NTP servers</label><input id="dhcpNtp" class="form-control" placeholder="192.168.10.1" value="'+esc((d.ntp||[]).join(', '))+'"></div></div>';
  }
  document.getElementById('addressMode').onchange=renderAddressFields;
  renderAddressFields();
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="saveSegment" class="btn btn-primary">Save segment</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('saveSegment').onclick=async function(){
    const mode=document.getElementById('addressMode').value;
    const seg={
      id:index>=0?old.id:document.getElementById('segId').value.trim(),
      name:document.getElementById('segName').value.trim()||(index>=0?old.id:document.getElementById('segId').value.trim()),
      interface:document.getElementById('segInterface').value,
      zone:document.getElementById('segZone').value,
      addressMode:mode,address:'',gateway:'',dns:[],domain:'',dhcpClient:{hostname:''},
      dhcp:{enabled:false,dns:[],ntp:[],reservations:(old.dhcp&&old.dhcp.reservations)||[]}
    };
    if(mode==='static'){
      seg.address=document.getElementById('segAddress').value.trim();
      seg.gateway=document.getElementById('segGateway').value.trim();
      seg.dns=splitCsv(document.getElementById('segDns').value);
      seg.domain=document.getElementById('segDomain').value.trim();
      seg.dhcp={enabled:document.getElementById('dhcpEnabled').checked,poolStart:document.getElementById('poolStart').value.trim(),poolEnd:document.getElementById('poolEnd').value.trim(),leaseTime:document.getElementById('leaseTime').value.trim()||'12h',gateway:document.getElementById('dhcpGateway').value.trim(),dns:splitCsv(document.getElementById('dhcpDns').value),ntp:splitCsv(document.getElementById('dhcpNtp').value),reservations:(old.dhcp&&old.dhcp.reservations)||[]};
    } else {
      seg.dhcpClient={hostname:document.getElementById('dhcpClientHost').value.trim()};
    }
    if(index>=0)state.config.segments[index]=seg;else state.config.segments.push(seg);
    state.config.management.allowedSegments=(state.config.management.allowedSegments||[]).filter(function(x){return x!==old.id&&x!==seg.id;});
    if(document.getElementById('managementAllowed').checked)state.config.management.allowedSegments.push(seg.id);
    try{await saveConfig('Network segment saved.');modal.hide();renderSegments();}catch(e){if(index>=0)state.config.segments[index]=old;else state.config.segments.pop();toast('Save failed',e.message);}
  };
}
function renderFirewall() {
  const rules=(state.config.firewall.rules||[]).slice().sort(function(a,b){return (a.position||999)-(b.position||999);});
  const d=state.config.firewall.defaults||{input:'drop',forward:'drop',output:'accept'};
  function policySelect(id,value){return '<select id="'+id+'" class="form-select form-select-sm"><option value="drop">Drop</option><option value="accept">Accept</option></select>';}
  let html='<div class="card mb-3"><div class="card-body"><h2 class="h6">Default policies</h2><div class="row g-3 align-items-end"><div class="col-md-3"><label class="form-label">INPUT</label>'+policySelect('defaultInput',d.input)+'</div><div class="col-md-3"><label class="form-label">FORWARD</label>'+policySelect('defaultForward',d.forward)+'</div><div class="col-md-3"><label class="form-label">OUTPUT</label>'+policySelect('defaultOutput',d.output)+'</div><div class="col-md-3"><button id="savePolicies" class="btn btn-outline-primary btn-sm">Save policies</button></div></div><div class="small text-secondary mt-3">INPUT controls traffic to LiteFWM. FORWARD controls traffic between network segments. OUTPUT controls traffic generated by LiteFWM. Loopback, established/related traffic, ICMP, configured SSH, and the management port are handled before user rules.</div></div></div>';
  html+='<div class="d-flex justify-content-between align-items-center mb-3"><p class="mb-0 text-secondary">Rules are expressed in network segments. Static segments also match their subnet automatically when no narrower address is specified.</p><button id="addRule" class="btn btn-primary btn-sm">Add rule</button></div>';
  html+='<div class="card"><div class="table-responsive"><table class="table mb-0"><thead><tr><th>#</th><th>Rule</th><th>From</th><th>To</th><th>Protocol</th><th>Action</th><th></th></tr></thead><tbody>';
  rules.forEach(function(r,i){
    const from=r.chain==='output'?'LiteFWM':(r.inSegment==='any'?'Any segment':segmentText((state.config.segments||[]).find(function(x){return x.id===r.inSegment;})||{id:r.inSegment,zone:'none'}));
    const to=r.chain==='input'?'LiteFWM':(r.outSegment==='any'?'Any segment':segmentText((state.config.segments||[]).find(function(x){return x.id===r.outSegment;})||{id:r.outSegment,zone:'none'}));
    html+='<tr class="'+(r.enabled===false?'rule-disabled':'')+'"><td>'+(i+1)+'</td><td><strong>'+esc(r.description||r.id)+'</strong><div class="small text-secondary">'+esc((r.chain||'forward').toUpperCase())+'</div></td><td>'+esc(from)+'</td><td>'+esc(to)+'</td><td>'+esc(r.protocol||'any')+(r.destinationPort&&r.destinationPort!=='any'?' / '+esc(r.destinationPort):'')+'</td><td><span class="badge '+(r.action==='accept'?'text-bg-success':r.action==='drop'?'text-bg-danger':'text-bg-secondary')+'">'+esc(r.action)+'</span></td><td class="text-end"><div class="btn-group btn-group-sm"><button class="btn btn-outline-secondary rule-up" data-i="'+i+'">↑</button><button class="btn btn-outline-secondary rule-down" data-i="'+i+'">↓</button><button class="btn btn-outline-secondary edit-rule" data-i="'+i+'">Edit</button><button class="btn btn-outline-danger del-rule" data-i="'+i+'">Delete</button></div></td></tr>';
  });
  if(!rules.length)html+='<tr><td colspan="7" class="text-secondary">No user firewall rules.</td></tr>';
  html+='</tbody></table></div></div>';
  document.getElementById('view').innerHTML=html;
  ['Input','Forward','Output'].forEach(function(k){document.getElementById('default'+k).value=d[k.toLowerCase()]||'drop';});
  document.getElementById('savePolicies').onclick=async function(){state.config.firewall.defaults={input:document.getElementById('defaultInput').value,forward:document.getElementById('defaultForward').value,output:document.getElementById('defaultOutput').value};await saveConfig('Default firewall policies saved.');renderFirewall();};
  document.getElementById('addRule').onclick=function(){editRule(-1,rules);};
  document.querySelectorAll('.edit-rule').forEach(function(b){b.onclick=function(){editRule(Number(b.dataset.i),rules);};});
  document.querySelectorAll('.del-rule').forEach(function(b){b.onclick=async function(){rules.splice(Number(b.dataset.i),1);rules.forEach(function(r,i){r.position=(i+1)*10;});state.config.firewall.rules=rules;await saveConfig('Firewall rule removed.');renderFirewall();};});
  document.querySelectorAll('.rule-up').forEach(function(b){b.onclick=async function(){const i=Number(b.dataset.i);if(i>0){const x=rules[i-1];rules[i-1]=rules[i];rules[i]=x;rules.forEach(function(r,n){r.position=(n+1)*10;});state.config.firewall.rules=rules;await saveConfig('Rule order changed.');renderFirewall();}};});
  document.querySelectorAll('.rule-down').forEach(function(b){b.onclick=async function(){const i=Number(b.dataset.i);if(i<rules.length-1){const x=rules[i+1];rules[i+1]=rules[i];rules[i]=x;rules.forEach(function(r,n){r.position=(n+1)*10;});state.config.firewall.rules=rules;await saveConfig('Rule order changed.');renderFirewall();}};});
}
function editRule(index,rules) {
  const r=index>=0?rules[index]:{id:id('rule'),enabled:true,chain:'forward',protocol:'any',inSegment:'any',outSegment:'any',source:'any',destination:'any',sourcePort:'any',destinationPort:'any',action:'accept',description:''};
  document.getElementById('modalTitle').textContent=index>=0?'Edit firewall rule':'Add firewall rule';
  document.getElementById('modalBody').innerHTML=
    '<div class="row g-3"><div class="col-12"><label class="form-label">Description</label><input id="ruleDesc" class="form-control" value="'+esc(r.description||'')+'"></div>'+
    '<div class="col-md-4"><label class="form-label">Traffic path</label><select id="ruleChain" class="form-select"><option value="input">Segment → LiteFWM</option><option value="forward">Segment → segment</option><option value="output">LiteFWM → segment</option></select></div>'+
    '<div class="col-md-4"><label class="form-label">Protocol</label><select id="ruleProto" class="form-select"><option value="any">Any</option><option value="tcp">TCP</option><option value="udp">UDP</option><option value="icmp">ICMP</option></select></div>'+
    '<div class="col-md-4"><label class="form-label">Action</label><select id="ruleAction" class="form-select"><option value="accept">Accept</option><option value="drop">Drop</option><option value="reject">Reject</option><option value="log">Log</option></select></div>'+
    '<div id="ruleSegmentFields" class="col-12"></div>'+
    '<div class="col-12"><details><summary class="mb-2">Advanced address and port matching</summary><div class="row g-3"><div class="col-md-6"><label class="form-label">Source CIDR / IP</label><input id="ruleSrc" class="form-control" value="'+esc(r.source||'any')+'"></div><div class="col-md-6"><label class="form-label">Destination CIDR / IP</label><input id="ruleDst" class="form-control" value="'+esc(r.destination||'any')+'"></div><div class="col-md-6"><label class="form-label">Source port</label><input id="ruleSport" class="form-control" value="'+esc(r.sourcePort||'any')+'"></div><div class="col-md-6"><label class="form-label">Destination port</label><input id="ruleDport" class="form-control" value="'+esc(r.destinationPort||'any')+'"></div></div></details></div>'+
    '<div class="col-12"><div class="form-check"><input id="ruleEnabled" type="checkbox" class="form-check-input" '+(r.enabled===false?'':'checked')+'><label class="form-check-label">Enabled</label></div></div></div>';
  document.getElementById('ruleChain').value=r.chain||'forward';
  document.getElementById('ruleProto').value=r.protocol||'any';
  document.getElementById('ruleAction').value=r.action||'accept';
  function pathFields(){
    const c=document.getElementById('ruleChain').value;
    let h='<div class="row g-3">';
    if(c!=='output')h+='<div class="col-md-6"><label class="form-label">Source / inbound segment</label><select id="ruleIn" class="form-select">'+segOptions(r.inSegment||'any',true,c==='forward'?'internal':null)+'</select></div>';
    if(c!=='input')h+='<div class="col-md-6"><label class="form-label">Destination / outbound segment</label><select id="ruleOut" class="form-select">'+segOptions(r.outSegment||'any',true,c==='forward'?'external':null)+'</select></div>';
    h+='</div>';document.getElementById('ruleSegmentFields').innerHTML=h;
  }
  document.getElementById('ruleChain').onchange=pathFields;pathFields();
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="saveRule" class="btn btn-primary">Save rule</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('saveRule').onclick=async function(){
    const chain=document.getElementById('ruleChain').value;
    const nr={id:r.id||id('rule'),description:document.getElementById('ruleDesc').value.trim(),enabled:document.getElementById('ruleEnabled').checked,chain:chain,protocol:document.getElementById('ruleProto').value,inSegment:chain==='output'?'any':document.getElementById('ruleIn').value,outSegment:chain==='input'?'any':document.getElementById('ruleOut').value,source:document.getElementById('ruleSrc').value.trim()||'any',destination:document.getElementById('ruleDst').value.trim()||'any',sourcePort:document.getElementById('ruleSport').value.trim()||'any',destinationPort:document.getElementById('ruleDport').value.trim()||'any',action:document.getElementById('ruleAction').value,position:index>=0?(r.position||((index+1)*10)):((rules.length+1)*10)};
    if(index>=0)rules[index]=nr;else rules.push(nr);state.config.firewall.rules=rules;
    try{await saveConfig('Firewall rule saved.');modal.hide();renderFirewall();}catch(e){toast('Save failed',e.message);}
  };
}
function renderNat() {
  const n=state.config.firewall.nat;
  const outbound=[];
  (n.masquerade||[]).forEach(function(x,i){outbound.push({kind:'masquerade',index:i,sourceSegment:x.sourceSegment||'',source:x.source||'any',outSegment:x.outSegment,translation:'Outbound address'});});
  (n.snat||[]).forEach(function(x,i){outbound.push({kind:'snat',index:i,sourceSegment:x.sourceSegment||'',source:x.source||'any',outSegment:x.outSegment,translation:x.toSource});});
  let html='<p class="text-secondary">Outbound NAT translates traffic from a source network segment as it leaves through an outbound segment. Port forwards translate traffic arriving on an external segment.</p>';
  html+='<div class="card mb-3"><div class="card-header d-flex align-items-center"><strong>Outbound NAT</strong><button id="addOutboundNat" class="btn btn-sm btn-outline-primary ms-auto">Add outbound NAT</button></div><div class="table-responsive"><table class="table table-sm mb-0"><thead><tr><th>Source segment</th><th>Outbound segment</th><th>Translation</th><th></th></tr></thead><tbody>';
  outbound.forEach(function(x){const src=x.sourceSegment?(state.config.segments||[]).find(function(s){return s.id===x.sourceSegment;}):null;const out=(state.config.segments||[]).find(function(s){return s.id===x.outSegment;});html+='<tr><td>'+esc(src?segmentText(src):x.source)+'</td><td>'+esc(out?segmentText(out):x.outSegment)+'</td><td>'+esc(x.translation)+'</td><td class="text-end"><button class="btn btn-sm btn-outline-danger del-outnat" data-kind="'+x.kind+'" data-i="'+x.index+'">Delete</button></td></tr>';});
  if(!outbound.length)html+='<tr><td colspan="4" class="text-secondary">No outbound NAT rules.</td></tr>';
  html+='</tbody></table></div></div>';
  html+='<div class="card"><div class="card-header d-flex align-items-center"><strong>Port forwards / destination NAT</strong><button id="addDnat" class="btn btn-sm btn-outline-primary ms-auto">Add port forward</button></div><div class="table-responsive"><table class="table table-sm mb-0"><thead><tr><th>Inbound segment</th><th>External port</th><th>Internal destination</th><th></th></tr></thead><tbody>';
  (n.dnat||[]).forEach(function(x,i){const seg=(state.config.segments||[]).find(function(s){return s.id===x.inSegment;});html+='<tr><td>'+esc(seg?segmentText(seg):x.inSegment)+'</td><td>'+esc((x.protocol||'tcp').toUpperCase())+' '+esc(x.destinationPort)+'</td><td>'+esc(x.toDestination)+'</td><td class="text-end"><button class="btn btn-sm btn-outline-danger del-dnat" data-i="'+i+'">Delete</button></td></tr>';});
  if(!(n.dnat||[]).length)html+='<tr><td colspan="4" class="text-secondary">No port forwards.</td></tr>';
  html+='</tbody></table></div></div>';
  document.getElementById('view').innerHTML=html;
  document.getElementById('addOutboundNat').onclick=editOutboundNat;
  document.getElementById('addDnat').onclick=editDnat;
  document.querySelectorAll('.del-outnat').forEach(function(b){b.onclick=async function(){state.config.firewall.nat[b.dataset.kind].splice(Number(b.dataset.i),1);await saveConfig('Outbound NAT rule removed.');renderNat();};});
  document.querySelectorAll('.del-dnat').forEach(function(b){b.onclick=async function(){state.config.firewall.nat.dnat.splice(Number(b.dataset.i),1);await saveConfig('Port forward removed.');renderNat();};});
}
function editOutboundNat() {
  document.getElementById('modalTitle').textContent='Add outbound NAT';
  document.getElementById('modalBody').innerHTML='<div class="row g-3"><div class="col-md-6"><label class="form-label">Source segment</label><select id="natSourceSegment" class="form-select">'+segOptions('',false,'internal')+'</select></div><div class="col-md-6"><label class="form-label">Outbound segment</label><select id="natOutSegment" class="form-select">'+segOptions('',false,'external')+'</select></div><div class="col-md-6"><label class="form-label">Translation</label><select id="natMode" class="form-select"><option value="masquerade">Use outbound address</option><option value="snat">Use fixed source IP</option></select></div><div id="natFixedWrap" class="col-md-6"></div></div>';
  function fields(){document.getElementById('natFixedWrap').innerHTML=document.getElementById('natMode').value==='snat'?'<label class="form-label">Translated source IP</label><input id="natFixedIp" class="form-control" placeholder="203.0.113.2">':'';}
  document.getElementById('natMode').onchange=fields;fields();
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="saveOutboundNat" class="btn btn-primary">Add rule</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('saveOutboundNat').onclick=async function(){
    const mode=document.getElementById('natMode').value, src=document.getElementById('natSourceSegment').value, out=document.getElementById('natOutSegment').value;
    if(mode==='masquerade')state.config.firewall.nat.masquerade.push({id:id('masq'),enabled:true,sourceSegment:src,source:'any',outSegment:out});
    else state.config.firewall.nat.snat.push({id:id('snat'),enabled:true,sourceSegment:src,source:'any',outSegment:out,toSource:document.getElementById('natFixedIp').value.trim()});
    try{await saveConfig('Outbound NAT rule saved.');modal.hide();renderNat();}catch(e){toast('Save failed',e.message);}
  };
}
function editDnat() {
  document.getElementById('modalTitle').textContent='Add port forward';
  document.getElementById('modalBody').innerHTML='<div class="row g-3"><div class="col-md-4"><label class="form-label">Inbound / external segment</label><select id="natIn" class="form-select">'+segOptions('',false,'external')+'</select></div><div class="col-md-2"><label class="form-label">Protocol</label><select id="natProto" class="form-select"><option value="tcp">TCP</option><option value="udp">UDP</option></select></div><div class="col-md-2"><label class="form-label">External port</label><input id="natPort" class="form-control"></div><div class="col-md-4"><label class="form-label">Internal IP[:port]</label><input id="natToDest" class="form-control"></div></div><div class="alert alert-light border small mt-3 mb-0">Destination NAT does not automatically allow forwarded traffic. Add a firewall FORWARD rule for the destination segment/address as needed.</div>';
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="saveDnat" class="btn btn-primary">Add port forward</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('saveDnat').onclick=async function(){state.config.firewall.nat.dnat.push({id:id('dnat'),enabled:true,inSegment:document.getElementById('natIn').value,protocol:document.getElementById('natProto').value,destinationPort:document.getElementById('natPort').value.trim(),toDestination:document.getElementById('natToDest').value.trim()});try{await saveConfig('Port forward saved.');modal.hide();renderNat();}catch(e){toast('Save failed',e.message);}};
}
function renderDhcp() {
  const bind=(state.modules||[]).find(function(m){return m.name==='bind';});
  let html='<div class="alert alert-light border small">DHCP ranges, gateway options, DNS options, and lease times are configured on each <strong>Network segment</strong>. This page is the operational lease and reservation view.</div>';
  html+='<div class="card mb-3"><div class="card-header fw-semibold">Active leases</div><div class="table-responsive"><table class="table mb-0"><thead><tr><th>Segment</th><th>IP</th><th>MAC</th><th>Hostname</th><th></th></tr></thead><tbody>';
  (state.leases||[]).forEach(function(l,i){
    const seg=(state.config.segments||[]).find(function(x){return x.id===l.segment;});
    html+='<tr><td>'+esc(seg?seg.name||seg.id:l.segment||'—')+'</td><td>'+esc(l.ip)+'</td><td><code>'+esc(l.mac)+'</code></td><td>'+esc(l.hostname==='*'?'':l.hostname)+'</td><td class="text-end"><button class="btn btn-sm btn-outline-primary reserve-lease" data-i="'+i+'">Reserve</button></td></tr>';
  });
  if(!(state.leases||[]).length) html+='<tr><td colspan="5" class="text-secondary">No active DHCP leases.</td></tr>';
  html+='</tbody></table></div></div>';
  html+='<div class="card"><div class="card-header d-flex align-items-center"><span class="fw-semibold">Reservations</span>'+(bind&&bind.installed?'<span class="badge text-bg-info ms-auto">BIND DNS available</span>':'')+'</div><div class="table-responsive"><table class="table table-sm mb-0"><thead><tr><th>Segment</th><th>IP</th><th>MAC</th><th>Hostname</th></tr></thead><tbody>';
  let reservations=0;
  (state.config.segments||[]).forEach(function(s){((s.dhcp&&s.dhcp.reservations)||[]).forEach(function(r){reservations++;html+='<tr><td>'+esc(s.name||s.id)+'</td><td>'+esc(r.ip)+'</td><td><code>'+esc(r.mac)+'</code></td><td>'+esc(r.hostname||'')+'</td></tr>';});});
  if(!reservations) html+='<tr><td colspan="4" class="text-secondary">No reserved leases.</td></tr>';
  html+='</tbody></table></div></div>';
  document.getElementById('view').innerHTML=html;
  document.querySelectorAll('.reserve-lease').forEach(function(b){b.onclick=function(){reserveLease(state.leases[Number(b.dataset.i)]);};});
}
function reserveLease(lease) {
  const bind=(state.modules||[]).find(function(m){return m.name==='bind';});
  const canPublish=!!(bind&&bind.installed&&bind.configured);
  document.getElementById('modalTitle').textContent='Reserve DHCP lease';
  document.getElementById('modalBody').innerHTML=
    '<div class="mb-3"><label class="form-label">Segment</label><select id="reserveSeg" class="form-select">'+segOptions(lease.segment||'',false)+'</select></div>'+
    '<div class="mb-3"><label class="form-label">IP / MAC</label><input class="form-control" disabled value="'+esc(lease.ip+' / '+lease.mac)+'"></div>'+
    '<div class="mb-3"><label class="form-label">Hostname</label><input id="reserveHost" class="form-control" value="'+esc(lease.hostname==='*'?'':lease.hostname)+'"></div>'+
    (canPublish?'<div class="form-check"><input id="reserveDns" type="checkbox" class="form-check-input"><label class="form-check-label">Publish this hostname as an A record in the configured BIND zone</label><div class="form-text">The BIND record is created when the reservation is saved. BIND must remain enabled to serve it.</div></div>':'<div class="small text-secondary">Install and configure BIND 9 to publish reserved hostnames into local DNS.</div>');
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="reserveNow" class="btn btn-primary">Reserve address</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('reserveNow').onclick=async function(){
    try{
      const host=document.getElementById('reserveHost').value.trim();
      const publish=canPublish&&document.getElementById('reserveDns').checked;
      const result=await api('/reserve',{method:'POST',body:JSON.stringify({segment:document.getElementById('reserveSeg').value,mac:lease.mac,hostname:host,publishDns:publish})});
      modal.hide();await refresh();
      let msg=lease.ip+' will stay assigned to '+lease.mac+'.';
      if(result.dns&&result.dns.fqdn) msg+=' DNS: '+result.dns.fqdn+'.';
      toast('Lease reserved',msg);
    }catch(e){toast('Reservation failed',e.message);}
  };
}
function moduleLabel(name) {
  return {
    openvpn:'OpenVPN', tailscale:'Tailscale', bind:'BIND 9 DNS',
    squid:'Squid proxy', snort:'Snort IDS/IPS', haproxy:'HAProxy',
    ddns:'Dynamic DNS'
  }[name] || name;
}
function csv(v){ return (v||[]).join(', '); }
function splitCsv(v){ return String(v||'').split(',').map(function(x){return x.trim();}).filter(Boolean); }
function selectedSegments(values) {
  values=values||[];
  return (state.config.segments||[]).map(function(s){
    return '<label class="form-check"><input class="form-check-input module-segment" type="checkbox" value="'+esc(s.id)+'" '+(values.includes(s.id)?'checked':'')+'><span class="form-check-label">'+esc(s.name||s.id)+' <code>'+esc(s.address)+'</code></span></label>';
  }).join('') || '<span class="text-secondary small">No network segments are configured yet.</span>';
}
function checkedSegmentValues(root) {
  return Array.from(root.querySelectorAll('.module-segment:checked')).map(function(x){return x.value;});
}
function renderModules() {
  const desc={
    openvpn:'Traditional routed VPN server',
    tailscale:'WireGuard-based mesh VPN',
    bind:'Authoritative and recursive DNS for local segments',
    squid:'Forward proxy and caching',
    snort:'Optional IDS/IPS engine',
    haproxy:'TCP/HTTP reverse proxy and load balancer',
    ddns:'Dynamic DNS updates using ddclient'
  };
  let html='<p class="text-secondary">Optional services remain outside the base appliance. Installed modules expose their own configuration and runtime state here.</p><div class="row g-3">';
  (state.modules||[]).forEach(function(m){
    html+='<div class="col-md-6 col-xl-4"><div class="card h-100"><div class="card-body">';
    html+='<div class="d-flex gap-2"><div><h2 class="h6 mb-1">'+esc(moduleLabel(m.name))+'</h2><p class="small text-secondary mb-2">'+esc(desc[m.name]||'Optional service')+'</p></div>';
    html+='<span class="badge ms-auto align-self-start '+(m.installed?'text-bg-success':'badge-soft')+'">'+(m.installed?'Installed':'Not installed')+'</span></div>';
    if(m.installed){
      html+='<div class="small mb-3"><span class="badge '+(m.running?'text-bg-success':'badge-soft')+'">'+(m.running?'Running':'Stopped')+'</span> ';
      html+='<span class="badge '+(m.configured?'text-bg-info':'badge-soft')+'">'+(m.configured?'Configured':'Defaults')+'</span></div>';
    }
    html+='<div class="action-row">';
    if(m.installed) html+='<button class="btn btn-sm btn-outline-primary module-config" data-name="'+esc(m.name)+'">Configure</button>';
    html+='<button class="btn btn-sm '+(m.installed?'btn-outline-danger':'btn-outline-primary')+' module-action" data-name="'+esc(m.name)+'" data-action="'+(m.installed?'remove':'install')+'">'+(m.installed?'Remove':'Install')+'</button>';
    html+='</div></div></div></div>';
  });
  html+='</div>';
  document.getElementById('view').innerHTML=html;

  document.querySelectorAll('.module-action').forEach(function(b){
    b.onclick=async function(){
      const act=b.dataset.action;
      try{
        b.disabled=true;
        await api('/module/'+act,{method:'POST',body:JSON.stringify({module:b.dataset.name})});
        await refresh();
        toast('Module updated',moduleLabel(b.dataset.name)+' '+(act==='install'?'installed and ready to configure.':'removed.'));
      }catch(e){
        b.disabled=false;
        toast('Module operation failed',e.message);
      }
    };
  });
  document.querySelectorAll('.module-config').forEach(function(b){
    b.onclick=function(){ configureModule(b.dataset.name); };
  });
}

async function configureModule(name) {
  if(name==='ddns'){ return configureDdns(); }
  let cfg,status;
  try{
    [cfg,status]=await Promise.all([api('/module/config/'+encodeURIComponent(name)),api('/module/status/'+encodeURIComponent(name))]);
  }catch(e){toast(moduleLabel(name),e.message);return;}

  const body=document.getElementById('modalBody');
  document.getElementById('modalTitle').textContent=moduleLabel(name);
  let fields='<div class="d-flex align-items-center mb-3"><div><div class="fw-semibold">'+esc(moduleLabel(name))+'</div><div class="small text-secondary">Module-specific configuration is stored separately from the core firewall configuration.</div></div><span class="badge ms-auto '+(status.running?'text-bg-success':'badge-soft')+'">'+(status.running?'Running':'Stopped')+'</span></div>';

  if(name==='openvpn'){
    fields+='<div class="row g-3">'+
      '<div class="col-md-3"><label class="form-label">Protocol</label><select id="modProtocol" class="form-select"><option value="udp">UDP</option><option value="tcp">TCP</option></select></div>'+
      '<div class="col-md-3"><label class="form-label">Port</label><input id="modPort" type="number" class="form-control" value="'+esc(cfg.port||1194)+'"></div>'+
      '<div class="col-md-3"><label class="form-label">Tunnel device</label><input id="modDevice" class="form-control" value="'+esc(cfg.device||'tun0')+'"></div>'+
      '<div class="col-md-3"><label class="form-label">VPN network</label><input id="modNetwork" class="form-control" value="'+esc(cfg.network||'10.8.0.0/24')+'"></div>'+
      '<div class="col-md-6"><label class="form-label">Bind address</label><input id="modBind" class="form-control" value="'+esc(cfg.bindAddress||'0.0.0.0')+'"></div>'+
      '<div class="col-md-6"><label class="form-label">DNS servers</label><input id="modDns" class="form-control" value="'+esc(csv(cfg.dns))+'" placeholder="10.0.0.1, 1.1.1.1"></div>'+
      '<div class="col-12"><label class="form-label">Routes pushed to clients</label><input id="modRoutes" class="form-control" value="'+esc(csv(cfg.pushRoutes))+'" placeholder="10.0.10.0/24, 10.0.20.0/24"></div>'+
      '<div class="col-md-4"><label class="form-label">CA file</label><input id="modCa" class="form-control" value="'+esc(cfg.caFile||'')+'"></div>'+
      '<div class="col-md-4"><label class="form-label">Server certificate</label><input id="modCert" class="form-control" value="'+esc(cfg.certFile||'')+'"></div>'+
      '<div class="col-md-4"><label class="form-label">Private key</label><input id="modKey" class="form-control" value="'+esc(cfg.keyFile||'')+'"></div>'+
      '<div class="col-12"><div class="form-check"><input id="modClientToClient" class="form-check-input" type="checkbox" '+(cfg.clientToClient?'checked':'')+'><label class="form-check-label">Allow VPN clients to reach each other</label></div></div>'+
      '</div>';
  } else if(name==='tailscale'){
    fields+='<div class="row g-3">'+
      '<div class="col-md-6"><label class="form-label">Hostname</label><input id="modHostname" class="form-control" value="'+esc(cfg.hostname||'')+'" placeholder="litefwm"></div>'+
      '<div class="col-md-6"><label class="form-label">Auth key</label><input id="modAuthKey" type="password" class="form-control" placeholder="'+(cfg.authKeySet?'Leave blank to keep current key':'Optional reusable/ephemeral key')+'"></div>'+
      '<div class="col-12"><label class="form-label">Advertise routes</label><input id="modRoutes" class="form-control" value="'+esc(csv(cfg.advertiseRoutes))+'" placeholder="10.0.10.0/24, 10.0.20.0/24"></div>'+
      '<div class="col-md-4"><div class="form-check"><input id="modAcceptRoutes" class="form-check-input" type="checkbox" '+(cfg.acceptRoutes?'checked':'')+'><label class="form-check-label">Accept routes</label></div></div>'+
      '<div class="col-md-4"><div class="form-check"><input id="modExit" class="form-check-input" type="checkbox" '+(cfg.advertiseExitNode?'checked':'')+'><label class="form-check-label">Advertise exit node</label></div></div>'+
      '<div class="col-md-4"><div class="form-check"><input id="modTailscaleSsh" class="form-check-input" type="checkbox" '+(cfg.ssh?'checked':'')+'><label class="form-check-label">Enable Tailscale SSH</label></div></div>'+
      '</div>';
  } else if(name==='bind'){
    fields+='<div class="row g-3">'+
      '<div class="col-md-6"><label class="form-label">Local DNS zone</label><input id="modZone" class="form-control" value="'+esc(cfg.zone||'lan')+'" placeholder="home.arpa"></div>'+
      '<div class="col-md-6"><label class="form-label">Forwarders</label><input id="modForwarders" class="form-control" value="'+esc(csv(cfg.forwarders))+'" placeholder="1.1.1.1, 1.0.0.1"></div>'+
      '<div class="col-md-6"><label class="form-label">Listen on segments</label><div id="modListenSegments" class="border rounded p-2">'+selectedSegments(cfg.listenSegments)+'</div></div>'+
      '<div class="col-md-6"><label class="form-label">Allow recursion from segments</label><div id="modRecursionSegments" class="border rounded p-2">'+selectedSegments(cfg.allowRecursionSegments)+'</div></div>'+
      '<div class="col-12"><label class="form-label">A records</label><textarea id="modRecords" class="form-control mono" rows="6" placeholder="router=10.0.10.1&#10;nas=10.0.10.20">'+esc((cfg.records||[]).map(function(r){return r.name+'='+r.address;}).join('\n'))+'</textarea><div class="form-text">One record per line as name=IPv4. DHCP reservations can also publish here from the DHCP page.</div></div>'+
      '</div>';
  } else if(name==='squid'){
    fields+='<div class="row g-3">'+
      '<div class="col-md-6"><label class="form-label">Listen segment</label><select id="modListenSegment" class="form-select"><option value="">All addresses</option>'+segOptions(cfg.listenSegment||'',false)+'</select></div>'+
      '<div class="col-md-3"><label class="form-label">Port</label><input id="modPort" type="number" class="form-control" value="'+esc(cfg.port||3128)+'"></div>'+
      '<div class="col-md-3"><label class="form-label">Memory cache (MB)</label><input id="modCache" type="number" class="form-control" value="'+esc(cfg.cacheMb||256)+'"></div>'+
      '<div class="col-md-6"><label class="form-label">Allowed client segments</label><div id="modAllowedSegments" class="border rounded p-2">'+selectedSegments(cfg.allowedSegments)+'</div></div>'+
      '<div class="col-md-6"><label class="form-label">Visible hostname</label><input id="modVisibleHostname" class="form-control" value="'+esc(cfg.visibleHostname||'litefwm')+'"><label class="form-label mt-3">Blocked domains</label><textarea id="modBlocked" class="form-control mono" rows="4">'+esc((cfg.blockedDomains||[]).join('\n'))+'</textarea></div>'+
      '</div>';
  } else if(name==='snort'){
    const opts='<option value="">Select interface</option>'+(state.config.interfaces||[]).map(function(i){return '<option value="'+esc(i.device)+'" '+(cfg.interface===i.device?'selected':'')+'>'+esc(i.name||i.id)+' ('+esc(i.device)+')</option>';}).join('');
    fields+='<div class="row g-3">'+
      '<div class="col-md-6"><label class="form-label">Monitor interface</label><select id="modInterface" class="form-select">'+opts+'</select></div>'+
      '<div class="col-md-3"><label class="form-label">Mode</label><select id="modMode" class="form-select"><option value="ids">IDS</option><option value="ips">IPS</option></select></div>'+
      '<div class="col-md-3"><label class="form-label">HOME_NET</label><input id="modHomeNet" class="form-control" value="'+esc(cfg.homeNet||'any')+'"></div>'+
      '<div class="col-12"><label class="form-label">Snort configuration file</label><input id="modConfigFile" class="form-control" value="'+esc(cfg.configFile||'/etc/snort/snort.conf')+'"></div>'+
      '<div class="col-12"><label class="form-label">Additional command arguments</label><input id="modExtraArgs" class="form-control" value="'+esc(cfg.extraArgs||'')+'"></div>'+
      '</div>';
  } else if(name==='haproxy'){
    fields+='<div class="row g-3">'+
      '<div class="col-md-3"><label class="form-label">Mode</label><select id="modMode" class="form-select"><option value="http">HTTP</option><option value="tcp">TCP</option></select></div>'+
      '<div class="col-md-5"><label class="form-label">Listen address</label><input id="modListenAddress" class="form-control" value="'+esc(cfg.listenAddress||'0.0.0.0')+'"></div>'+
      '<div class="col-md-4"><label class="form-label">Listen port</label><input id="modPort" type="number" class="form-control" value="'+esc(cfg.listenPort||80)+'"></div>'+
      '<div class="col-md-4"><label class="form-label">Balance</label><select id="modBalance" class="form-select"><option value="roundrobin">Round robin</option><option value="leastconn">Least connections</option><option value="source">Source hash</option></select></div>'+
      '<div class="col-12"><label class="form-label">Backend servers</label><textarea id="modBackends" class="form-control mono" rows="6" placeholder="web1=10.0.10.21:8080&#10;web2=10.0.10.22:8080,nocheck">'+esc((cfg.backendServers||[]).map(function(x){return x.name+'='+x.address+(x.check===false?',nocheck':'');}).join('\n'))+'</textarea><div class="form-text">One server per line as name=address:port. Append ,nocheck to disable health checking.</div></div>'+
      '</div>';
  }

  fields+='<hr><div class="form-check"><input id="modEnabled" class="form-check-input" type="checkbox" '+(cfg.enabled?'checked':'')+'><label class="form-check-label">Enable '+esc(moduleLabel(name))+'</label></div>';
  body.innerHTML=fields;

  if(name==='openvpn') document.getElementById('modProtocol').value=cfg.protocol||'udp';
  if(name==='snort') document.getElementById('modMode').value=cfg.mode||'ids';
  if(name==='haproxy'){document.getElementById('modMode').value=cfg.mode||'http';document.getElementById('modBalance').value=cfg.balance||'roundrobin';}

  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Close</button><button id="modSave" class="btn btn-outline-primary">Save</button><button id="modApply" class="btn btn-primary">Save & apply</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));
  modal.show();

  function lines(id){
    return document.getElementById(id).value.split(/\r?\n/).map(function(x){return x.trim();}).filter(Boolean);
  }
  function collect(){
    let x={enabled:document.getElementById('modEnabled').checked};
    if(name==='openvpn') Object.assign(x,{mode:'server',protocol:document.getElementById('modProtocol').value,port:Number(document.getElementById('modPort').value),bindAddress:document.getElementById('modBind').value.trim(),device:document.getElementById('modDevice').value.trim(),network:document.getElementById('modNetwork').value.trim(),dns:splitCsv(document.getElementById('modDns').value),pushRoutes:splitCsv(document.getElementById('modRoutes').value),clientToClient:document.getElementById('modClientToClient').checked,caFile:document.getElementById('modCa').value.trim(),certFile:document.getElementById('modCert').value.trim(),keyFile:document.getElementById('modKey').value.trim()});
    if(name==='tailscale') Object.assign(x,{authKey:document.getElementById('modAuthKey').value,hostname:document.getElementById('modHostname').value.trim(),advertiseRoutes:splitCsv(document.getElementById('modRoutes').value),acceptRoutes:document.getElementById('modAcceptRoutes').checked,advertiseExitNode:document.getElementById('modExit').checked,ssh:document.getElementById('modTailscaleSsh').checked});
    if(name==='bind'){
      const records=lines('modRecords').map(function(line){const pos=line.indexOf('=');return {name:(pos>=0?line.slice(0,pos):line).trim(),address:(pos>=0?line.slice(pos+1):'').trim()};});
      Object.assign(x,{zone:document.getElementById('modZone').value.trim(),listenSegments:checkedSegmentValues(document.getElementById('modListenSegments')),forwarders:splitCsv(document.getElementById('modForwarders').value),allowRecursionSegments:checkedSegmentValues(document.getElementById('modRecursionSegments')),records:records});
    }
    if(name==='squid') Object.assign(x,{listenSegment:document.getElementById('modListenSegment').value,port:Number(document.getElementById('modPort').value),allowedSegments:checkedSegmentValues(document.getElementById('modAllowedSegments')),cacheMb:Number(document.getElementById('modCache').value),blockedDomains:lines('modBlocked'),visibleHostname:document.getElementById('modVisibleHostname').value.trim()});
    if(name==='snort') Object.assign(x,{interface:document.getElementById('modInterface').value,homeNet:document.getElementById('modHomeNet').value.trim(),mode:document.getElementById('modMode').value,configFile:document.getElementById('modConfigFile').value.trim(),extraArgs:document.getElementById('modExtraArgs').value.trim()});
    if(name==='haproxy'){
      const backendServers=lines('modBackends').map(function(line){const nc=line.endsWith(',nocheck');if(nc)line=line.slice(0,-8);const pos=line.indexOf('=');return {name:(pos>=0?line.slice(0,pos):line).trim(),address:(pos>=0?line.slice(pos+1):'').trim(),check:!nc};});
      Object.assign(x,{mode:document.getElementById('modMode').value,listenAddress:document.getElementById('modListenAddress').value.trim(),listenPort:Number(document.getElementById('modPort').value),balance:document.getElementById('modBalance').value,backendServers:backendServers});
    }
    return x;
  }
  async function save(apply){
    try{
      await api('/module/config/'+encodeURIComponent(name),{method:'PUT',body:JSON.stringify(collect())});
      if(apply){
        const result=await api('/module/apply/'+encodeURIComponent(name),{method:'POST'});
        toast(moduleLabel(name),result.message||'Configuration applied.');
        modal.hide();
      }else toast(moduleLabel(name),'Configuration saved.');
      await refresh();
    }catch(e){toast(moduleLabel(name)+' error',e.message);}
  }
  document.getElementById('modSave').onclick=function(){save(false);};
  document.getElementById('modApply').onclick=function(){save(true);};
}

async function configureDdns() {
  let cfg, status;
  try {
    [cfg,status]=await Promise.all([api('/ddns'),api('/ddns/status')]);
  } catch(e) {
    toast('Dynamic DNS',e.message);
    return;
  }

  const providers=[
    ['cloudflare','Cloudflare'],
    ['noip','No-IP'],
    ['duckdns','DuckDNS'],
    ['namecheap','Namecheap'],
    ['digitalocean','DigitalOcean'],
    ['hetzner','Hetzner DNS'],
    ['dyndns2','Generic DynDNS2']
  ];
  const providerOptions=providers.map(function(x){return '<option value="'+x[0]+'"'+(cfg.provider===x[0]?' selected':'')+'>'+x[1]+'</option>';}).join('');
  const ifaceOptions='<option value="">Select interface</option>'+(state.interfaces||[]).map(function(i){return '<option value="'+esc(i.name)+'"'+(cfg.interface===i.name?' selected':'')+'>'+esc(i.name)+'</option>';}).join('');

  document.getElementById('modalTitle').textContent='Dynamic DNS';
  document.getElementById('modalBody').innerHTML=
    '<div class="d-flex align-items-center mb-3"><div><div class="fw-semibold">ddclient</div><div class="small text-secondary">Update public DNS records when the WAN address changes.</div></div><span class="badge ms-auto '+(status.running?'text-bg-success':'badge-soft')+'">'+(status.running?'Running':'Stopped')+'</span></div>'+
    '<div class="row g-3">'+
      '<div class="col-md-4"><label class="form-label">Provider</label><select id="ddnsProvider" class="form-select">'+providerOptions+'</select></div>'+
      '<div class="col-md-4"><label class="form-label">Check interval</label><div class="input-group"><input id="ddnsInterval" type="number" min="60" max="86400" class="form-control" value="'+esc(cfg.interval||300)+'"><span class="input-group-text">sec</span></div></div>'+
      '<div class="col-md-4"><label class="form-label">Address source</label><select id="ddnsSource" class="form-select"><option value="web">Public IP lookup</option><option value="interface">Local interface</option></select></div>'+
      '<div id="ddnsInterfaceWrap" class="col-md-6"><label class="form-label">Interface</label><select id="ddnsInterface" class="form-select">'+ifaceOptions+'</select></div>'+
      '<div class="col-md-6"><label class="form-label">Hostnames</label><input id="ddnsHosts" class="form-control" placeholder="home.example.com, vpn.example.com" value="'+esc((cfg.hostnames||[]).join(', '))+'"><div id="ddnsHostHelp" class="form-text"></div></div>'+
      '<div id="ddnsZoneWrap" class="col-md-6"><label class="form-label">DNS zone</label><input id="ddnsZone" class="form-control" placeholder="example.com" value="'+esc(cfg.zone||'')+'"></div>'+
      '<div id="ddnsServerWrap" class="col-md-6"><label class="form-label">DynDNS server</label><input id="ddnsServer" class="form-control" placeholder="members.example.com" value="'+esc(cfg.server||'')+'"></div>'+
      '<div id="ddnsLoginWrap" class="col-md-6"><label id="ddnsLoginLabel" class="form-label">Username</label><input id="ddnsLogin" class="form-control" value="'+esc(cfg.login||'')+'"></div>'+
      '<div class="col-md-6"><label id="ddnsPasswordLabel" class="form-label">Password / API token</label><input id="ddnsPassword" type="password" class="form-control" placeholder="'+(cfg.passwordSet?'Leave blank to keep current credential':'Required')+'"><div class="form-text">Credentials are stored root-only on the appliance and are never returned by the API.</div></div>'+
      '<div class="col-12"><div class="form-check"><input id="ddnsEnabled" type="checkbox" class="form-check-input" '+(cfg.enabled?'checked':'')+'><label class="form-check-label">Enable Dynamic DNS service</label></div></div>'+
      '<div class="col-12"><div id="ddnsProviderHelp" class="alert alert-secondary mb-0"></div></div>'+
      '<div class="col-12"><div id="ddnsQueryOutput" class="code-box d-none"></div></div>'+
    '</div>';

  document.getElementById('ddnsSource').value=cfg.source||'web';

  function refreshDdnsFields(){
    const provider=document.getElementById('ddnsProvider').value;
    const source=document.getElementById('ddnsSource').value;
    document.getElementById('ddnsInterfaceWrap').classList.toggle('d-none',source!=='interface');

    const needsZone=['cloudflare','digitalocean','hetzner'].includes(provider);
    const needsServer=provider==='dyndns2';
    const needsLogin=['noip','namecheap','dyndns2'].includes(provider);
    document.getElementById('ddnsZoneWrap').classList.toggle('d-none',!needsZone);
    document.getElementById('ddnsServerWrap').classList.toggle('d-none',!needsServer);
    document.getElementById('ddnsLoginWrap').classList.toggle('d-none',!needsLogin);

    const help={
      cloudflare:'Use a Cloudflare API token. Set DNS zone to the parent zone, such as example.com. No username is required.',
      noip:'Use the No-IP username and password for the hostname.',
      duckdns:'Use the DuckDNS token. Host entries are the DuckDNS host names without the .duckdns.org suffix.',
      namecheap:'Set Username to the registered domain, such as example.com, and use its Dynamic DNS password.',
      digitalocean:'Use a DigitalOcean API token and set the DNS zone.',
      hetzner:'Use a Hetzner DNS API token and set the DNS zone.',
      dyndns2:'Generic DynDNS2 endpoint. Supply the update server, username, password, and fully-qualified hostname.'
    };
    document.getElementById('ddnsProviderHelp').textContent=help[provider]||'';
    document.getElementById('ddnsHostHelp').textContent=provider==='duckdns'?'Example: myhouse, myvpn':'Comma-separated DNS names.';
  }
  document.getElementById('ddnsProvider').onchange=refreshDdnsFields;
  document.getElementById('ddnsSource').onchange=refreshDdnsFields;
  refreshDdnsFields();

  document.getElementById('modalFooter').innerHTML=
    '<button class="btn btn-secondary" data-bs-dismiss="modal">Close</button>'+
    '<button id="ddnsQuery" class="btn btn-outline-secondary">Check IP source</button>'+
    '<button id="ddnsSave" class="btn btn-outline-primary">Save</button>'+
    '<button id="ddnsApply" class="btn btn-primary">Save & apply</button>';

  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));
  modal.show();

  function collectDdns(){
    return {
      enabled:document.getElementById('ddnsEnabled').checked,
      provider:document.getElementById('ddnsProvider').value,
      interval:Number(document.getElementById('ddnsInterval').value||300),
      source:document.getElementById('ddnsSource').value,
      interface:document.getElementById('ddnsInterface').value,
      zone:document.getElementById('ddnsZone').value.trim(),
      server:document.getElementById('ddnsServer').value.trim(),
      login:document.getElementById('ddnsLogin').value.trim(),
      password:document.getElementById('ddnsPassword').value,
      hostnames:document.getElementById('ddnsHosts').value.split(',').map(function(x){return x.trim();}).filter(Boolean)
    };
  }
  async function saveDdns(apply){
    try{
      await api('/ddns',{method:'PUT',body:JSON.stringify(collectDdns())});
      if(apply) {
        const result=await api('/ddns/apply',{method:'POST'});
        toast('Dynamic DNS',result.message||'Configuration applied.');
      } else {
        toast('Dynamic DNS','Configuration saved.');
      }
      await refresh();
      if(apply) modal.hide();
    }catch(e){
      toast('Dynamic DNS error',e.message);
    }
  }
  document.getElementById('ddnsSave').onclick=function(){saveDdns(false);};
  document.getElementById('ddnsApply').onclick=function(){saveDdns(true);};
  document.getElementById('ddnsQuery').onclick=async function(){
    try{
      await api('/ddns',{method:'PUT',body:JSON.stringify(collectDdns())});
      const result=await api('/ddns/query',{method:'POST'});
      const box=document.getElementById('ddnsQueryOutput');
      box.classList.remove('d-none');
      box.textContent=result.output||'No output.';
    }catch(e){
      toast('Dynamic DNS check failed',e.message);
    }
  };
}

function renderMonitoring() {
  const m=state.metrics||{interfaces:[],memory:{}};
  let html='<div class="row g-3 mb-3">'+card('Conntrack',m.conntrack||0,'Active tracked flows')+card('Load',m.load1||0,'1 minute load average')+card('Memory available',Math.round((m.memory&&m.memory.available||0)/1048576)+' MB','Target appliance')+card('Captures',(state.captures||[]).length,'Saved packet captures')+'</div>';
  html+='<div class="card mb-3"><div class="card-header d-flex align-items-center"><strong>Interface traffic</strong><button id="captureBtn" class="btn btn-sm btn-outline-primary ms-auto">Start packet capture</button></div><div class="table-responsive"><table class="table table-sm mb-0"><thead><tr><th>Interface</th><th>RX</th><th>TX</th><th>Packets RX/TX</th></tr></thead><tbody>';
  (m.interfaces||[]).forEach(function(i){html+='<tr><td>'+esc(i.name)+'</td><td>'+esc(formatBytes(i.rxBytes))+'</td><td>'+esc(formatBytes(i.txBytes))+'</td><td>'+esc(i.rxPackets)+' / '+esc(i.txPackets)+'</td></tr>';});
  html+='</tbody></table></div></div>';
  html+='<div class="card mb-3"><div class="card-header fw-semibold">Diagnostics</div><div class="card-body"><div class="row g-2"><div class="col-md-5"><input id="diagHost" class="form-control form-control-sm" placeholder="host.example.com or IP"></div><div class="col-auto"><button id="diagLookup" class="btn btn-sm btn-outline-primary">DNS lookup</button></div><div class="col-auto"><button id="diagPing" class="btn btn-sm btn-outline-secondary">Ping</button></div><div class="col-auto"><button id="diagRoute" class="btn btn-sm btn-outline-secondary">Route</button></div></div><div id="diagBox" class="code-box mt-3">Diagnostic output will appear here.</div></div></div>';
  html+='<div class="card"><div class="card-header d-flex"><strong>Firewall log</strong><button id="loadLogs" class="btn btn-sm btn-outline-secondary ms-auto">Refresh log</button></div><div id="logBox" class="code-box border-0 rounded-0">Select Refresh log to load recent firewall entries.</div></div>';
  document.getElementById('view').innerHTML=html;
  document.getElementById('captureBtn').onclick=startCapture;
  async function runDiag(kind){const host=document.getElementById('diagHost').value.trim();if(!host)return;try{const d=await api('/diag/'+kind,{method:'POST',body:JSON.stringify({host:host})});document.getElementById('diagBox').textContent=d.output||'No output.';}catch(e){toast('Diagnostic failed',e.message);}}
  document.getElementById('diagLookup').onclick=function(){runDiag('lookup');};
  document.getElementById('diagPing').onclick=function(){runDiag('ping');};
  document.getElementById('diagRoute').onclick=function(){runDiag('route');};
  document.getElementById('loadLogs').onclick=async function(){try{const d=await api('/logs/firewall');document.getElementById('logBox').textContent=(d.lines||[]).join('\n')||'No LiteFWM firewall log entries.';}catch(e){toast('Log error',e.message);}};
}
function formatBytes(n){n=Number(n||0);if(n<1024)return n+' B';if(n<1048576)return (n/1024).toFixed(1)+' KB';if(n<1073741824)return (n/1048576).toFixed(1)+' MB';return (n/1073741824).toFixed(1)+' GB';}
function startCapture(){
  document.getElementById('modalTitle').textContent='Start packet capture';
  document.getElementById('modalBody').innerHTML='<div class="row g-3"><div class="col-md-8"><label class="form-label">Segment</label><select id="capSeg" class="form-select">'+segOptions('',false)+'</select></div><div class="col-md-4"><label class="form-label">Seconds</label><input id="capSeconds" type="number" min="1" max="300" value="30" class="form-control"></div></div><div class="alert alert-secondary mt-3 mb-0">Captures are capped at five minutes and stored on the appliance.</div>';
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="capStart" class="btn btn-primary">Start capture</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('capStart').onclick=async function(){try{await api('/capture',{method:'POST',body:JSON.stringify({segment:document.getElementById('capSeg').value,seconds:Number(document.getElementById('capSeconds').value||30)})});modal.hide();await refresh();toast('Capture complete','Packet capture saved on the appliance.');}catch(e){toast('Capture failed',e.message);}};
}
function renderSettings() {
  let html='<div class="row g-3"><div class="col-lg-5"><div class="card"><div class="card-body"><h2 class="h6">Management access</h2>'+
    '<div class="form-check mb-3"><input id="allowAnyMgmt" type="checkbox" class="form-check-input" '+(state.config.management.allowAny?'checked':'')+'><label class="form-check-label">Allow management port from any interface</label></div>'+
    '<label class="form-label">Management port</label><input id="mgmtPort" type="number" class="form-control mb-3" value="'+esc(state.config.management.port)+'">'+
    '<hr><div class="form-check mb-3"><input id="allowSsh" type="checkbox" class="form-check-input" '+(state.config.management.allowSsh?'checked':'')+'><label class="form-check-label">Allow SSH to the appliance</label></div>'+
    '<label class="form-label">SSH port</label><input id="sshPort" type="number" class="form-control mb-3" value="'+esc(state.config.management.sshPort||22)+'">'+
    '<div class="small text-secondary mb-3">These are built-in INPUT exceptions so the appliance remains manageable even with the default INPUT policy set to DROP.</div>'+
    '<button id="saveSettings" class="btn btn-primary btn-sm">Save settings</button></div></div></div>';
  html+='<div class="col-lg-7"><div class="card"><div class="card-header fw-semibold">Raw configuration</div><div class="card-body"><textarea id="rawConfig" class="form-control font-monospace" rows="20">'+esc(JSON.stringify(state.config,null,2))+'</textarea><div class="mt-3 d-flex gap-2"><button id="saveRaw" class="btn btn-outline-primary btn-sm">Save raw JSON</button><button id="reloadRaw" class="btn btn-outline-secondary btn-sm">Reload</button></div></div></div></div></div>';
  document.getElementById('view').innerHTML=html;
  document.getElementById('saveSettings').onclick=async function(){
    state.config.management.allowAny=document.getElementById('allowAnyMgmt').checked;
    state.config.management.port=Number(document.getElementById('mgmtPort').value);
    state.config.management.allowSsh=document.getElementById('allowSsh').checked;
    state.config.management.sshPort=Number(document.getElementById('sshPort').value);
    try{await saveConfig('Management and SSH settings saved.');renderSettings();}catch(e){toast('Save failed',e.message);}
  };
  document.getElementById('saveRaw').onclick=async function(){try{state.config=JSON.parse(document.getElementById('rawConfig').value);await saveConfig('Raw configuration saved.');renderSettings();}catch(e){toast('Invalid configuration',e.message);}};
  document.getElementById('reloadRaw').onclick=function(){renderSettings();};
}

window.addEventListener('hashchange',render);
document.getElementById('validateBtn').onclick=async function(){try{const r=await api('/validate',{method:'POST'});toast('Validation passed',r.message||'Configuration is valid.');}catch(e){toast('Validation failed',e.message);}};
document.getElementById('applyBtn').onclick=async function(){if(!confirm('Apply the staged network, DHCP, NAT, and firewall configuration now?'))return;try{const r=await api('/apply',{method:'POST'});toast('Configuration applied',r.message||'Applied successfully.');await refresh();}catch(e){toast('Apply failed',e.message);}};
refresh();
