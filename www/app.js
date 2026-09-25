'use strict';

const state = { config:null, status:null, interfaces:[], leases:[], modules:[], metrics:null, captures:[] };
const titles = {
  overview:'Overview', segments:'Network segments', firewall:'Firewall rules',
  nat:'NAT & port forwards', dhcp:'DHCP', modules:'Optional modules',
  monitoring:'Monitoring', settings:'Settings'
};

function esc(v) {
  return String(v == null ? '' : v).replace(/[&<>"']/g, function(c) {
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];
  });
}
function id(prefix) { return prefix + '-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2,7); }
function segOptions(selected, includeAny) {
  let out = includeAny ? '<option value="any">Any</option>' : '';
  (state.config.segments || []).forEach(function(s) {
    out += '<option value="' + esc(s.id) + '"' + (s.id===selected?' selected':'') + '>' + esc(s.name || s.id) + '</option>';
  });
  return out;
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
  const fn = {overview:renderOverview,segments:renderSegments,firewall:renderFirewall,nat:renderNat,dhcp:renderDhcp,modules:renderModules,monitoring:renderMonitoring,settings:renderSettings}[r];
  fn();
}
function card(label, value, sub) {
  return '<div class="col-6 col-xl-3"><div class="card metric-card h-100"><div class="card-body"><div class="small text-secondary">' + esc(label) + '</div><div class="display-6">' + esc(value) + '</div><div class="small text-secondary">' + esc(sub || '') + '</div></div></div></div>';
}
function renderOverview() {
  const m=state.metrics || {conntrack:0,interfaces:[]};
  const s=state.status || {};
  let html='<div class="row g-3 mb-4">';
  html += card('Segments', s.segments || 0, 'Interfaces, bridges, and VLANs');
  html += card('Firewall rules', s.rules || 0, 'Ordered rules');
  html += card('DHCP leases', s.leases || 0, 'Active leases');
  html += card('Connections', m.conntrack || 0, 'Conntrack entries');
  html += '</div>';
  html += '<div class="row g-3"><div class="col-lg-7"><div class="card"><div class="card-header fw-semibold">Network interfaces</div><div class="table-responsive"><table class="table table-sm mb-0"><thead><tr><th>Interface</th><th>State</th><th>Address</th><th>MTU</th></tr></thead><tbody>';
  (state.interfaces || []).forEach(function(i) {
    const addrs=(i.addresses || []).map(function(a){return a.address+'/'+a.prefixlen;}).join(', ');
    html += '<tr><td><strong>'+esc(i.name)+'</strong></td><td>'+esc(i.state)+'</td><td>'+esc(addrs || '—')+'</td><td>'+esc(i.mtu)+'</td></tr>';
  });
  html += '</tbody></table></div></div></div>';
  html += '<div class="col-lg-5"><div class="card h-100"><div class="card-body"><h2 class="h6">Applied state</h2><dl class="row mb-0"><dt class="col-5">Hostname</dt><dd class="col-7">'+esc(s.hostname)+'</dd><dt class="col-5">Last apply</dt><dd class="col-7">'+esc(s.lastApply)+'</dd><dt class="col-5">Management</dt><dd class="col-7">'+(state.config.management.allowAny?'Any interface':esc((state.config.management.allowedSegments||[]).join(', ') || 'None'))+'</dd></dl></div></div></div></div>';
  document.getElementById('view').innerHTML=html;
}
function renderSegments() {
  let html='<div class="d-flex justify-content-between align-items-center mb-3"><p class="text-secondary mb-0">A segment can be a physical interface, Linux bridge, or VLAN.</p><button class="btn btn-primary btn-sm" id="addSegment">Add segment</button></div>';
  html+='<div class="card"><div class="table-responsive"><table class="table mb-0"><thead><tr><th>Name</th><th>Type</th><th>Device</th><th>Address</th><th>DHCP</th><th></th></tr></thead><tbody>';
  (state.config.segments||[]).forEach(function(s,idx) {
    let dev=s.interface || s.bridge || s.device || ((s.parent&&s.vlanId!=null)?s.parent+'.'+s.vlanId:'');
    html+='<tr><td><strong>'+esc(s.name||s.id)+'</strong><div class="small text-secondary">'+esc(s.id)+'</div></td><td>'+esc(s.type)+'</td><td>'+esc(dev)+'</td><td>'+esc(s.address)+'</td><td>'+(s.dhcp&&s.dhcp.enabled?'<span class="badge text-bg-success">On</span>':'<span class="badge badge-soft">Off</span>')+'</td><td class="text-end"><div class="btn-group btn-group-sm"><button class="btn btn-outline-secondary edit-seg" data-i="'+idx+'">Edit</button><button class="btn btn-outline-danger del-seg" data-i="'+idx+'">Delete</button></div></td></tr>';
  });
  html+='</tbody></table></div></div>';
  document.getElementById('view').innerHTML=html;
  document.getElementById('addSegment').onclick=function(){ editSegment(-1); };
  document.querySelectorAll('.edit-seg').forEach(function(b){b.onclick=function(){editSegment(Number(b.dataset.i));};});
  document.querySelectorAll('.del-seg').forEach(function(b){b.onclick=async function(){if(confirm('Delete this segment from the staged configuration?')){state.config.segments.splice(Number(b.dataset.i),1); await saveConfig('Segment removed from staged configuration.'); renderSegments();}};});
}
function editSegment(index) {
  const old=index>=0?state.config.segments[index]:{id:'',name:'',type:'interface',address:'',mtu:1500,dhcp:{enabled:false,reservations:[]}};
  const d=old.dhcp||{enabled:false,reservations:[]};
  document.getElementById('modalTitle').textContent=index>=0?'Edit segment':'Add segment';
  document.getElementById('modalBody').innerHTML=
    '<div class="row g-3">'+
    '<div class="col-md-4"><label class="form-label">ID</label><input id="segId" class="form-control" value="'+esc(old.id)+'"></div>'+
    '<div class="col-md-4"><label class="form-label">Name</label><input id="segName" class="form-control" value="'+esc(old.name||'')+'"></div>'+
    '<div class="col-md-4"><label class="form-label">Type</label><select id="segType" class="form-select"><option value="interface">Interface</option><option value="bridge">Bridge</option><option value="vlan">VLAN</option></select></div>'+
    '<div id="segTypeFields" class="col-12"></div>'+
    '<div class="col-md-8"><label class="form-label">Segment address/CIDR</label><input id="segAddress" class="form-control" placeholder="192.168.10.1/24" value="'+esc(old.address||'')+'"></div>'+
    '<div class="col-md-4"><label class="form-label">MTU</label><input id="segMtu" type="number" class="form-control" value="'+esc(old.mtu||1500)+'"></div>'+
    '<div class="col-12"><label class="form-label">Default gateway <span class="text-secondary">(optional, one segment only)</span></label><input id="segGateway" class="form-control" placeholder="203.0.113.1" value="'+esc(old.gateway||'')+'"></div>'+
    '<div class="col-12"><hr><div class="form-check"><input id="dhcpEnabled" type="checkbox" class="form-check-input" '+(d.enabled?'checked':'')+'><label class="form-check-label">Enable DHCP on this segment</label></div></div>'+
    '<div class="col-md-4"><label class="form-label">Pool start</label><input id="poolStart" class="form-control" value="'+esc(d.poolStart||'')+'"></div>'+
    '<div class="col-md-4"><label class="form-label">Pool end</label><input id="poolEnd" class="form-control" value="'+esc(d.poolEnd||'')+'"></div>'+
    '<div class="col-md-4"><label class="form-label">Lease time</label><input id="leaseTime" class="form-control" value="'+esc(d.leaseTime||'12h')+'"></div>'+
    '<div class="col-md-6"><label class="form-label">Router</label><input id="dhcpGateway" class="form-control" value="'+esc(d.gateway||'')+'"></div>'+
    '<div class="col-md-6"><label class="form-label">DNS servers</label><input id="dhcpDns" class="form-control" placeholder="1.1.1.1, 9.9.9.9" value="'+esc((d.dns||[]).join(', '))+'"></div>'+
    '<div class="col-12"><div class="form-check"><input id="managementAllowed" type="checkbox" class="form-check-input" '+((state.config.management.allowedSegments||[]).includes(old.id)?'checked':'')+'><label class="form-check-label">Allow LiteFWM management from this segment</label></div></div>'+
    '</div>';
  document.getElementById('segType').value=old.type;
  function typeFields(){
    const t=document.getElementById('segType').value;
    let h='';
    if(t==='interface') h='<label class="form-label">Interface</label><input id="segInterface" class="form-control" placeholder="eth1" value="'+esc(old.interface||'')+'">';
    if(t==='bridge') h='<div class="row g-3"><div class="col-md-4"><label class="form-label">Bridge</label><input id="segBridge" class="form-control" placeholder="br0" value="'+esc(old.bridge||'')+'"></div><div class="col-md-8"><label class="form-label">Members</label><input id="segMembers" class="form-control" placeholder="eth1, eth2" value="'+esc((old.members||[]).join(', '))+'"></div></div>';
    if(t==='vlan') h='<div class="row g-3"><div class="col-md-5"><label class="form-label">Parent</label><input id="segParent" class="form-control" placeholder="eth1" value="'+esc(old.parent||'')+'"></div><div class="col-md-3"><label class="form-label">VLAN ID</label><input id="segVlanId" type="number" class="form-control" value="'+esc(old.vlanId==null?'':old.vlanId)+'"></div><div class="col-md-4"><label class="form-label">Device override</label><input id="segDevice" class="form-control" placeholder="optional" value="'+esc(old.device||'')+'"></div></div>';
    document.getElementById('segTypeFields').innerHTML=h;
  }
  document.getElementById('segType').onchange=typeFields; typeFields();
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="saveSegment" class="btn btn-primary">Save segment</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal')); modal.show();
  document.getElementById('saveSegment').onclick=async function(){
    const t=document.getElementById('segType').value;
    const seg={
      id:document.getElementById('segId').value.trim(), name:document.getElementById('segName').value.trim(),
      type:t, address:document.getElementById('segAddress').value.trim(), gateway:document.getElementById('segGateway').value.trim(), mtu:Number(document.getElementById('segMtu').value||1500),
      dhcp:{
        enabled:document.getElementById('dhcpEnabled').checked,
        poolStart:document.getElementById('poolStart').value.trim(), poolEnd:document.getElementById('poolEnd').value.trim(),
        leaseTime:document.getElementById('leaseTime').value.trim()||'12h',
        gateway:document.getElementById('dhcpGateway').value.trim(),
        dns:document.getElementById('dhcpDns').value.split(',').map(function(x){return x.trim();}).filter(Boolean),
        reservations:(old.dhcp&&old.dhcp.reservations)||[]
      }
    };
    if(t==='interface') seg.interface=document.getElementById('segInterface').value.trim();
    if(t==='bridge'){seg.bridge=document.getElementById('segBridge').value.trim();seg.members=document.getElementById('segMembers').value.split(',').map(function(x){return x.trim();}).filter(Boolean);}
    if(t==='vlan'){seg.parent=document.getElementById('segParent').value.trim();seg.vlanId=Number(document.getElementById('segVlanId').value);const dv=document.getElementById('segDevice').value.trim();if(dv)seg.device=dv;}
    if(!seg.dhcp.enabled) seg.dhcp={enabled:false,reservations:(old.dhcp&&old.dhcp.reservations)||[]};
    const previousId=old.id;
    if(index>=0) state.config.segments[index]=seg; else state.config.segments.push(seg);
    const allowed=state.config.management.allowedSegments||[];
    state.config.management.allowedSegments=allowed.filter(function(x){return x!==previousId && x!==seg.id;});
    if(document.getElementById('managementAllowed').checked) state.config.management.allowedSegments.push(seg.id);
    try { await saveConfig('Segment saved.'); modal.hide(); renderSegments(); } catch(e){ toast('Save failed',e.message); }
  };
}
function renderFirewall() {
  const rules=(state.config.firewall.rules||[]).slice().sort(function(a,b){return (a.position||999)-(b.position||999);});
  let html='<div class="d-flex justify-content-between align-items-center mb-3"><div><p class="mb-0 text-secondary">Rules are evaluated top to bottom. Established and related traffic is accepted before this list.</p></div><button id="addRule" class="btn btn-primary btn-sm">Add rule</button></div>';
  html+='<div class="card"><div class="table-responsive"><table class="table mb-0"><thead><tr><th>#</th><th>Rule</th><th>Source</th><th>Destination</th><th>Action</th><th></th></tr></thead><tbody>';
  rules.forEach(function(r,i){
    html+='<tr class="'+(r.enabled===false?'rule-disabled':'')+'"><td>'+(i+1)+'</td><td><strong>'+esc(r.description||r.id)+'</strong><div class="small text-secondary">'+esc((r.chain||'forward').toUpperCase())+' · '+esc(r.protocol||'any')+'</div></td><td>'+esc(r.inSegment||'any')+'<div class="small text-secondary">'+esc(r.source||'any')+(r.sourcePort&&r.sourcePort!=='any'?':'+esc(r.sourcePort):'')+'</div></td><td>'+esc(r.outSegment||'any')+'<div class="small text-secondary">'+esc(r.destination||'any')+(r.destinationPort&&r.destinationPort!=='any'?':'+esc(r.destinationPort):'')+'</div></td><td><span class="badge '+(r.action==='accept'?'text-bg-success':r.action==='drop'?'text-bg-danger':'text-bg-secondary')+'">'+esc(r.action)+'</span></td><td class="text-end"><div class="btn-group btn-group-sm"><button class="btn btn-outline-secondary rule-up" data-i="'+i+'">↑</button><button class="btn btn-outline-secondary rule-down" data-i="'+i+'">↓</button><button class="btn btn-outline-secondary edit-rule" data-i="'+i+'">Edit</button><button class="btn btn-outline-danger del-rule" data-i="'+i+'">Delete</button></div></td></tr>';
  });
  html+='</tbody></table></div></div>';
  document.getElementById('view').innerHTML=html;
  document.getElementById('addRule').onclick=function(){editRule(-1,rules);};
  document.querySelectorAll('.edit-rule').forEach(function(b){b.onclick=function(){editRule(Number(b.dataset.i),rules);};});
  document.querySelectorAll('.del-rule').forEach(function(b){b.onclick=async function(){rules.splice(Number(b.dataset.i),1);rules.forEach(function(r,i){r.position=(i+1)*10;});state.config.firewall.rules=rules;await saveConfig('Firewall rule removed.');renderFirewall();};});
  document.querySelectorAll('.rule-up').forEach(function(b){b.onclick=async function(){const i=Number(b.dataset.i);if(i>0){const x=rules[i-1];rules[i-1]=rules[i];rules[i]=x;rules.forEach(function(r,n){r.position=(n+1)*10;});state.config.firewall.rules=rules;await saveConfig('Rule order changed.');renderFirewall();}};});
  document.querySelectorAll('.rule-down').forEach(function(b){b.onclick=async function(){const i=Number(b.dataset.i);if(i<rules.length-1){const x=rules[i+1];rules[i+1]=rules[i];rules[i]=x;rules.forEach(function(r,n){r.position=(n+1)*10;});state.config.firewall.rules=rules;await saveConfig('Rule order changed.');renderFirewall();}};});
}
function editRule(index, rules) {
  const r=index>=0?rules[index]:{id:id('rule'),enabled:true,chain:'forward',protocol:'tcp',inSegment:'any',outSegment:'any',source:'any',destination:'any',sourcePort:'any',destinationPort:'any',action:'accept',description:''};
  document.getElementById('modalTitle').textContent=index>=0?'Edit firewall rule':'Add firewall rule';
  document.getElementById('modalBody').innerHTML=
    '<div class="row g-3">'+
    '<div class="col-12"><label class="form-label">Description</label><input id="ruleDesc" class="form-control" value="'+esc(r.description||'')+'"></div>'+
    '<div class="col-md-4"><label class="form-label">Chain</label><select id="ruleChain" class="form-select"><option value="forward">Forward</option><option value="input">Input</option><option value="output">Output</option></select></div>'+
    '<div class="col-md-4"><label class="form-label">Protocol</label><select id="ruleProto" class="form-select"><option>any</option><option>tcp</option><option>udp</option><option>icmp</option></select></div>'+
    '<div class="col-md-4"><label class="form-label">Action</label><select id="ruleAction" class="form-select"><option value="accept">Accept</option><option value="drop">Drop</option><option value="reject">Reject</option><option value="log">Log</option></select></div>'+
    '<div class="col-md-6"><label class="form-label">Inbound segment</label><select id="ruleIn" class="form-select">'+segOptions(r.inSegment||'any',true)+'</select></div>'+
    '<div class="col-md-6"><label class="form-label">Outbound segment</label><select id="ruleOut" class="form-select">'+segOptions(r.outSegment||'any',true)+'</select></div>'+
    '<div class="col-md-6"><label class="form-label">Source CIDR</label><input id="ruleSrc" class="form-control" value="'+esc(r.source||'any')+'"></div>'+
    '<div class="col-md-6"><label class="form-label">Destination CIDR</label><input id="ruleDst" class="form-control" value="'+esc(r.destination||'any')+'"></div>'+
    '<div class="col-md-6"><label class="form-label">Source port</label><input id="ruleSport" class="form-control" value="'+esc(r.sourcePort||'any')+'"></div>'+
    '<div class="col-md-6"><label class="form-label">Destination port</label><input id="ruleDport" class="form-control" value="'+esc(r.destinationPort||'any')+'"></div>'+
    '<div class="col-12 form-check ms-2"><input id="ruleEnabled" type="checkbox" class="form-check-input" '+(r.enabled===false?'':'checked')+'><label class="form-check-label">Enabled</label></div></div>';
  document.getElementById('ruleChain').value=r.chain||'forward';document.getElementById('ruleProto').value=r.protocol||'any';document.getElementById('ruleAction').value=r.action||'accept';
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="saveRule" class="btn btn-primary">Save rule</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('saveRule').onclick=async function(){
    const nr={id:r.id||id('rule'),description:document.getElementById('ruleDesc').value.trim(),enabled:document.getElementById('ruleEnabled').checked,chain:document.getElementById('ruleChain').value,protocol:document.getElementById('ruleProto').value,inSegment:document.getElementById('ruleIn').value,outSegment:document.getElementById('ruleOut').value,source:document.getElementById('ruleSrc').value.trim()||'any',destination:document.getElementById('ruleDst').value.trim()||'any',sourcePort:document.getElementById('ruleSport').value.trim()||'any',destinationPort:document.getElementById('ruleDport').value.trim()||'any',action:document.getElementById('ruleAction').value,position:index>=0?(r.position||((index+1)*10)):((rules.length+1)*10)};
    if(index>=0)rules[index]=nr;else rules.push(nr);state.config.firewall.rules=rules;
    try{await saveConfig('Firewall rule saved.');modal.hide();renderFirewall();}catch(e){toast('Save failed',e.message);}
  };
}
function renderNat() {
  const n=state.config.firewall.nat;
  function section(title,kind,rows,cols) {
    let h='<div class="card mb-3"><div class="card-header d-flex align-items-center"><strong>'+esc(title)+'</strong><button class="btn btn-sm btn-outline-primary ms-auto add-nat" data-kind="'+kind+'">Add</button></div><div class="table-responsive"><table class="table table-sm mb-0"><thead><tr>';
    cols.forEach(function(c){h+='<th>'+esc(c)+'</th>';});h+='<th></th></tr></thead><tbody>';
    rows.forEach(function(x,i){
      h+='<tr>';
      if(kind==='masquerade')h+='<td>'+esc(x.source||'any')+'</td><td>'+esc(x.outSegment)+'</td>';
      if(kind==='snat')h+='<td>'+esc(x.source||'any')+'</td><td>'+esc(x.outSegment)+'</td><td>'+esc(x.toSource)+'</td>';
      if(kind==='dnat')h+='<td>'+esc(x.inSegment)+'</td><td>'+esc(x.protocol||'tcp')+'/'+esc(x.destinationPort)+'</td><td>'+esc(x.toDestination)+'</td>';
      h+='<td class="text-end"><button class="btn btn-sm btn-outline-danger del-nat" data-kind="'+kind+'" data-i="'+i+'">Delete</button></td></tr>';
    });
    h+='</tbody></table></div></div>';return h;
  }
  let html='<p class="text-secondary">Masquerade handles typical outbound Internet NAT. SNAT fixes the translated source address. DNAT implements port forwarding.</p>';
  html+=section('Masquerade','masquerade',n.masquerade||[],['Source','Outbound segment']);
  html+=section('Source NAT','snat',n.snat||[],['Source','Outbound segment','Translated source']);
  html+=section('Destination NAT / port forwards','dnat',n.dnat||[],['Inbound segment','Port','Destination']);
  document.getElementById('view').innerHTML=html;
  document.querySelectorAll('.add-nat').forEach(function(b){b.onclick=function(){editNat(b.dataset.kind);};});
  document.querySelectorAll('.del-nat').forEach(function(b){b.onclick=async function(){state.config.firewall.nat[b.dataset.kind].splice(Number(b.dataset.i),1);await saveConfig('NAT rule removed.');renderNat();};});
}
function editNat(kind) {
  document.getElementById('modalTitle').textContent='Add '+kind.toUpperCase()+' rule';
  let body='<div class="row g-3">';
  if(kind==='masquerade')body+='<div class="col-md-6"><label class="form-label">Source CIDR</label><input id="natSource" class="form-control" value="any"></div><div class="col-md-6"><label class="form-label">Outbound segment</label><select id="natOut" class="form-select">'+segOptions('',false)+'</select></div>';
  if(kind==='snat')body+='<div class="col-md-4"><label class="form-label">Source CIDR</label><input id="natSource" class="form-control" value="any"></div><div class="col-md-4"><label class="form-label">Outbound segment</label><select id="natOut" class="form-select">'+segOptions('',false)+'</select></div><div class="col-md-4"><label class="form-label">To source IP</label><input id="natToSource" class="form-control"></div>';
  if(kind==='dnat')body+='<div class="col-md-3"><label class="form-label">Inbound segment</label><select id="natIn" class="form-select">'+segOptions('',false)+'</select></div><div class="col-md-2"><label class="form-label">Protocol</label><select id="natProto" class="form-select"><option>tcp</option><option>udp</option></select></div><div class="col-md-3"><label class="form-label">External port</label><input id="natPort" class="form-control"></div><div class="col-md-4"><label class="form-label">Internal IP[:port]</label><input id="natToDest" class="form-control"></div>';
  body+='</div>';document.getElementById('modalBody').innerHTML=body;
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="saveNat" class="btn btn-primary">Add rule</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('saveNat').onclick=async function(){
    let x={id:id(kind),enabled:true};
    if(kind==='masquerade'){x.source=document.getElementById('natSource').value.trim()||'any';x.outSegment=document.getElementById('natOut').value;}
    if(kind==='snat'){x.source=document.getElementById('natSource').value.trim()||'any';x.outSegment=document.getElementById('natOut').value;x.toSource=document.getElementById('natToSource').value.trim();}
    if(kind==='dnat'){x.inSegment=document.getElementById('natIn').value;x.protocol=document.getElementById('natProto').value;x.destinationPort=document.getElementById('natPort').value.trim();x.toDestination=document.getElementById('natToDest').value.trim();}
    state.config.firewall.nat[kind].push(x);try{await saveConfig('NAT rule saved.');modal.hide();renderNat();}catch(e){toast('Save failed',e.message);}
  };
}
function renderDhcp() {
  let html='<div class="card mb-3"><div class="card-header fw-semibold">Active leases</div><div class="table-responsive"><table class="table mb-0"><thead><tr><th>IP</th><th>MAC</th><th>Hostname</th><th></th></tr></thead><tbody>';
  (state.leases||[]).forEach(function(l,i){html+='<tr><td>'+esc(l.ip)+'</td><td><code>'+esc(l.mac)+'</code></td><td>'+esc(l.hostname==='*'?'':l.hostname)+'</td><td class="text-end"><button class="btn btn-sm btn-outline-primary reserve-lease" data-i="'+i+'">Reserve</button></td></tr>';});
  html+='</tbody></table></div></div>';
  html+='<div class="card"><div class="card-header fw-semibold">Reservations</div><div class="table-responsive"><table class="table table-sm mb-0"><thead><tr><th>Segment</th><th>IP</th><th>MAC</th><th>Hostname</th></tr></thead><tbody>';
  (state.config.segments||[]).forEach(function(s){((s.dhcp&&s.dhcp.reservations)||[]).forEach(function(r){html+='<tr><td>'+esc(s.name||s.id)+'</td><td>'+esc(r.ip)+'</td><td><code>'+esc(r.mac)+'</code></td><td>'+esc(r.hostname||'')+'</td></tr>';});});
  html+='</tbody></table></div></div>';
  document.getElementById('view').innerHTML=html;
  document.querySelectorAll('.reserve-lease').forEach(function(b){b.onclick=function(){reserveLease(state.leases[Number(b.dataset.i)]);};});
}
function reserveLease(lease) {
  document.getElementById('modalTitle').textContent='Reserve DHCP lease';
  document.getElementById('modalBody').innerHTML='<div class="mb-3"><label class="form-label">Segment</label><select id="reserveSeg" class="form-select">'+segOptions('',false)+'</select></div><div class="mb-3"><label class="form-label">IP / MAC</label><input class="form-control" disabled value="'+esc(lease.ip+' / '+lease.mac)+'"></div><div><label class="form-label">Hostname</label><input id="reserveHost" class="form-control" value="'+esc(lease.hostname==='*'?'':lease.hostname)+'"></div>';
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="reserveNow" class="btn btn-primary">Reserve address</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('reserveNow').onclick=async function(){try{await api('/reserve',{method:'POST',body:JSON.stringify({segment:document.getElementById('reserveSeg').value,mac:lease.mac,hostname:document.getElementById('reserveHost').value.trim()})});modal.hide();await refresh();toast('Lease reserved',lease.ip+' will stay assigned to '+lease.mac+'.');}catch(e){toast('Reservation failed',e.message);}};
}
function renderModules() {
  const desc={
    openvpn:'Traditional routed or bridged VPN',
    tailscale:'WireGuard-based mesh VPN',
    bind:'Full BIND DNS service',
    squid:'Forward proxy and caching',
    snort:'Optional IDS/IPS engine',
    haproxy:'Reverse proxy and TCP/HTTP load balancer',
    ddns:'Dynamic DNS updates using ddclient'
  };
  let html='<p class="text-secondary">These packages are not part of the base appliance. Install only what you need.</p><div class="row g-3">';
  (state.modules||[]).forEach(function(m){
    html+='<div class="col-md-6 col-xl-4"><div class="card h-100"><div class="card-body">';
    html+='<div class="d-flex"><div><h2 class="h6 mb-1">'+esc(m.name)+'</h2><p class="small text-secondary">'+esc(desc[m.name]||'Optional service')+'</p></div>';
    html+='<span class="badge ms-auto align-self-start '+(m.installed?'text-bg-success':'badge-soft')+'">'+(m.installed?'Installed':'Not installed')+'</span></div>';
    html+='<div class="action-row">';
    if(m.name==='ddns' && m.installed) html+='<button class="btn btn-sm btn-outline-primary ddns-config">Configure</button>';
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
        toast('Module updated',b.dataset.name+' '+(act==='install'?'installed.':'removed.'));
      }catch(e){
        b.disabled=false;
        toast('Module operation failed',e.message);
      }
    };
  });
  const ddns=document.querySelector('.ddns-config');
  if(ddns) ddns.onclick=configureDdns;
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
  let html='<div class="row g-3"><div class="col-lg-5"><div class="card"><div class="card-body"><h2 class="h6">Management access</h2><div class="form-check mb-3"><input id="allowAnyMgmt" type="checkbox" class="form-check-input" '+(state.config.management.allowAny?'checked':'')+'><label class="form-check-label">Allow management port from any interface</label></div><label class="form-label">Port</label><input id="mgmtPort" type="number" class="form-control mb-3" value="'+esc(state.config.management.port)+'"><button id="saveSettings" class="btn btn-primary btn-sm">Save settings</button></div></div></div>';
  html+='<div class="col-lg-7"><div class="card"><div class="card-header fw-semibold">Raw configuration</div><div class="card-body"><textarea id="rawConfig" class="form-control font-monospace" rows="20">'+esc(JSON.stringify(state.config,null,2))+'</textarea><div class="mt-3 d-flex gap-2"><button id="saveRaw" class="btn btn-outline-primary btn-sm">Save raw JSON</button><button id="reloadRaw" class="btn btn-outline-secondary btn-sm">Reload</button></div></div></div></div></div>';
  document.getElementById('view').innerHTML=html;
  document.getElementById('saveSettings').onclick=async function(){state.config.management.allowAny=document.getElementById('allowAnyMgmt').checked;state.config.management.port=Number(document.getElementById('mgmtPort').value);try{await saveConfig('Management settings saved.');renderSettings();}catch(e){toast('Save failed',e.message);}};
  document.getElementById('saveRaw').onclick=async function(){try{state.config=JSON.parse(document.getElementById('rawConfig').value);await saveConfig('Raw configuration saved.');renderSettings();}catch(e){toast('Invalid configuration',e.message);}};
  document.getElementById('reloadRaw').onclick=function(){renderSettings();};
}

window.addEventListener('hashchange',render);
document.getElementById('validateBtn').onclick=async function(){try{const r=await api('/validate',{method:'POST'});toast('Validation passed',r.message||'Configuration is valid.');}catch(e){toast('Validation failed',e.message);}};
document.getElementById('applyBtn').onclick=async function(){if(!confirm('Apply the staged network, DHCP, NAT, and firewall configuration now?'))return;try{const r=await api('/apply',{method:'POST'});toast('Configuration applied',r.message||'Applied successfully.');await refresh();}catch(e){toast('Apply failed',e.message);}};
refresh();
