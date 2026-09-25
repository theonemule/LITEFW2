'use strict';

const state={config:null,status:null,interfaces:[],leases:[],modules:[],metrics:null,captures:[]};
const titles={overview:'Overview',interfaces:'Interfaces',segments:'Network segments',firewall:'Firewall rules',nat:'NAT & port forwards',dhcp:'DHCP',modules:'Modules',monitoring:'Monitoring',settings:'Settings'};

function esc(v){return String(v==null?'':v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
function uid(p){return p+'-'+Date.now().toString(36)+'-'+Math.random().toString(36).slice(2,6);}
function csv(v){return (v||[]).join(', ');}
function splitCsv(v){return String(v||'').split(',').map(x=>x.trim()).filter(Boolean);}
function toast(title,body){document.getElementById('toastTitle').textContent=title;document.getElementById('toastBody').textContent=body;bootstrap.Toast.getOrCreateInstance(document.getElementById('toast')).show();}
async function api(path,options){
  options=options||{}; options.headers=Object.assign({'Accept':'application/json'},options.headers||{});
  if((options.method||'GET')!=='GET'){
    options.headers['X-LiteFWM-Request']='1';
    if(options.body&&!options.headers['Content-Type'])options.headers['Content-Type']='application/json';
  }
  const r=await fetch('/api'+path,options),t=await r.text();let d={};
  try{d=t?JSON.parse(t):{};}catch(e){d={error:t||r.statusText};}
  if(!r.ok||d.ok===false)throw new Error(d.error||r.statusText);
  return d;
}
async function loadAll(){
  const x=await Promise.all([api('/config'),api('/status'),api('/interfaces'),api('/leases'),api('/modules'),api('/metrics'),api('/captures')]);
  state.config=x[0];state.status=x[1];state.interfaces=x[2];state.leases=x[3];state.modules=x[4];state.metrics=x[5];state.captures=x[6];
  document.getElementById('statusDot').classList.add('online');
  document.getElementById('statusText').textContent='Connected to '+(state.status.hostname||'appliance');
}
async function refresh(){
  try{await loadAll();render();}
  catch(e){document.getElementById('statusText').textContent='Connection error';document.getElementById('view').innerHTML='<div class="alert alert-danger"><strong>Unable to read live state.</strong><div class="mt-2">'+esc(e.message)+'</div></div>';}
}
async function commitLive(message){
  const result=await api('/config',{method:'PUT',body:JSON.stringify(state.config)});
  if(result&&result.version)state.config=result;
  await loadAll();
  render();
  toast('Live system updated',message||'The running system and native configuration were updated.');
}
function route(){const r=(location.hash||'#overview').slice(1);return titles[r]?r:'overview';}
function render(){if(!state.config)return;const r=route();document.getElementById('pageTitle').textContent=titles[r];document.querySelectorAll('a[href^="#"]').forEach(a=>a.classList.toggle('active',a.getAttribute('href')==='#'+r));({overview:renderOverview,interfaces:renderInterfaces,segments:renderSegments,firewall:renderFirewall,nat:renderNat,dhcp:renderDhcp,modules:renderModules,monitoring:renderMonitoring,settings:renderSettings}[r])();}
function card(label,value,sub){return '<div class="col-6 col-xl-3"><div class="card metric-card h-100"><div class="card-body"><div class="small text-secondary">'+esc(label)+'</div><div class="display-6">'+esc(value)+'</div><div class="small text-secondary">'+esc(sub||'')+'</div></div></div></div>';}
function iface(id){return (state.config.interfaces||[]).find(x=>x.id===id||x.device===id);}
function seg(id){return (state.config.segments||[]).find(x=>x.id===id);}
function zoneName(z){return z==='external'?'External / default route':z==='internal'?'Internal':'Unclassified';}
function shownAddress(s){return s.addressMode==='dhcp'?(s.currentAddress||'DHCP, no lease'):(s.address||s.currentAddress||'—');}
function eligibleInterfaces(){return (state.config.interfaces||[]).filter(i=>i.managed!==false&&['physical','bridge','vlan'].includes(i.type));}
function interfaceOptions(selected,types){
  let h='<option value="">Select interface</option>';
  eligibleInterfaces().filter(i=>!types||types.includes(i.type)).forEach(i=>h+='<option value="'+esc(i.id)+'"'+(i.id===selected?' selected':'')+'>'+esc(i.device)+' · '+esc(i.type)+(i.ipv4&&i.ipv4.length?' · '+esc(i.ipv4.map(a=>a.cidr).join(', ')):'')+'</option>');
  return h;
}
function segmentOptions(selected,any){
  let h=any?'<option value="any">Any</option>':'<option value="">Select network segment</option>';
  (state.config.segments||[]).forEach(s=>h+='<option value="'+esc(s.id)+'"'+(s.id===selected?' selected':'')+'>'+esc(s.id)+' · '+esc(s.interface)+' · '+esc(shownAddress(s))+'</option>');
  return h;
}
function cidrInfo(cidr){
  const a=String(cidr||'').split('/'),p=a[0].split('.').map(Number),prefix=Number(a[1]);
  if(a.length!==2||p.length!==4||p.some(x=>!Number.isInteger(x)||x<0||x>255)||!Number.isInteger(prefix)||prefix<0||prefix>32)return null;
  const n=((((p[0]<<24)>>>0)+(p[1]<<16)+(p[2]<<8)+p[3])>>>0),mask=prefix===0?0:((0xffffffff<<(32-prefix))>>>0),net=(n&mask)>>>0,bc=(net|((~mask)>>>0))>>>0;
  const ip=x=>[(x>>>24)&255,(x>>>16)&255,(x>>>8)&255,x&255].join('.');
  return {network:ip(net)+'/'+prefix,first:ip(prefix>=31?net:(net+1)>>>0),last:ip(prefix>=31?bc:(bc-1)>>>0),broadcast:ip(bc)};
}

function renderOverview(){
  const c=state.config,m=state.metrics||{},s=state.status||{};
  let h='<div class="row g-3 mb-4">'+card('Interfaces',(c.interfaces||[]).filter(x=>x.name!=='lo').length,'Read from Linux')+card('IP segments',(c.segments||[]).length,'Current IPv4 assignments')+card('Firewall rules',(c.firewall&&c.firewall.rules||[]).length,'Current iptables rules')+card('DHCP leases',(state.leases||[]).length,'Current dnsmasq leases')+'</div>';
  h+='<div class="alert alert-info"><strong>Live-state mode.</strong> LiteFWM reads Linux and service configuration directly. Changes take effect immediately and are persisted in native Alpine/service files. There is no LiteFWM network configuration database and no Apply step.</div>';
  h+='<div class="card"><div class="card-header fw-semibold">Live network</div><div class="table-responsive"><table class="table table-sm mb-0"><thead><tr><th>Device</th><th>Type</th><th>State</th><th>IPv4</th><th>Master / parent</th></tr></thead><tbody>';
  (c.interfaces||[]).forEach(i=>{h+='<tr><td><strong>'+esc(i.device)+'</strong></td><td>'+esc(i.type)+'</td><td>'+esc(i.state||'')+'</td><td><code>'+esc((i.ipv4||[]).map(a=>a.cidr).join(', ')||'—')+'</code></td><td>'+esc(i.master||i.parent||'—')+'</td></tr>';});
  h+='</tbody></table></div></div>';
  document.getElementById('view').innerHTML=h;
}

function renderInterfaces(){
  const list=(state.config.interfaces||[]).filter(i=>i.name!=='lo');
  let h='<div class="d-flex justify-content-between align-items-center mb-3"><div><p class="mb-0 text-secondary">This is the running Linux link state. Create bridges or VLANs here; physical NICs already exist and do not need to be pre-registered.</p></div><button id="addVirtual" class="btn btn-primary btn-sm">Add bridge or VLAN</button></div>';
  h+='<div class="card"><div class="table-responsive"><table class="table mb-0"><thead><tr><th>Device</th><th>Type</th><th>State</th><th>Addresses</th><th>Topology</th><th>Persistence</th><th></th></tr></thead><tbody>';
  list.forEach(i=>{
    const ips=(i.ipv4||[]).map(a=>a.cidr).join(', ')||'—';
    let top='—';
    if(i.type==='bridge')top='members: '+((i.members||[]).join(', ')||'none');
    else if(i.type==='vlan')top='parent: '+(i.parent||'?')+' · VLAN '+(i.vlanId==null?'?':i.vlanId);
    else if(i.master)top='member of '+i.master;
    const canEdit=['bridge','vlan'].includes(i.type),canDelete=canEdit;
    h+='<tr><td><strong>'+esc(i.device)+'</strong><div class="small text-secondary">'+esc(i.mac||'')+'</div></td><td>'+esc(i.type)+'</td><td>'+esc(i.state||'')+'</td><td><code>'+esc(ips)+'</code>'+(i.defaultRoute?'<div class="small text-secondary">default via '+esc(i.defaultGateway||'')+'</div>':'')+'</td><td>'+esc(top)+'</td><td>'+(i.persistent?'<span class="badge text-bg-success">native</span>':'<span class="badge badge-soft">runtime only</span>')+'</td><td class="text-end"><div class="btn-group btn-group-sm"><button class="btn btn-outline-primary ip-settings" data-id="'+esc(i.id)+'">IP settings</button>'+(canEdit?'<button class="btn btn-outline-secondary edit-interface" data-id="'+esc(i.id)+'">Edit</button>':'')+(canDelete?'<button class="btn btn-outline-danger delete-interface" data-id="'+esc(i.id)+'">Delete</button>':'')+'</div></td></tr>';
  });
  h+='</tbody></table></div></div>';
  document.getElementById('view').innerHTML=h;
  document.getElementById('addVirtual').onclick=()=>editInterface(null);
  document.querySelectorAll('.edit-interface').forEach(b=>b.onclick=()=>editInterface(iface(b.dataset.id)));
  document.querySelectorAll('.ip-settings').forEach(b=>b.onclick=()=>editIpForInterface(b.dataset.id));
  document.querySelectorAll('.delete-interface').forEach(b=>b.onclick=async()=>{
    const i=iface(b.dataset.id),used=(state.config.segments||[]).filter(s=>s.interface===i.id);
    if(used.length){toast('Cannot delete interface','Move or remove its IP configuration first.');return;}
    if(i.type==='bridge'&&(i.members||[]).length){if(!confirm('Delete '+i.device+' and detach its members?'))return;}
    else if(!confirm('Delete '+i.device+' now?'))return;
    state.config.interfaces=state.config.interfaces.filter(x=>x.id!==i.id);
    await commitLive(i.device+' removed from the running system.');
  });
}

function editInterface(existing){
  const old=existing||{id:'',name:'',device:'',type:'bridge',mtu:1500,enabled:true,vlanAware:true,members:[],parent:'',vlanId:null,managed:true,persistent:true};
  document.getElementById('modalTitle').textContent=existing?'Edit '+old.device:'Create bridge or VLAN';
  document.getElementById('modalBody').innerHTML='<div class="row g-3"><div class="col-md-4"><label class="form-label">Type</label><select id="liType" class="form-select"><option value="bridge">Linux bridge</option><option value="vlan">VLAN adapter</option></select></div><div class="col-md-4"><label class="form-label">Device name</label><input id="liDevice" class="form-control" value="'+esc(old.device||'')+'" placeholder="br0"></div><div class="col-md-4"><label class="form-label">MTU</label><input id="liMtu" type="number" class="form-control" value="'+esc(old.mtu||1500)+'"></div><div id="liFields" class="col-12"></div></div>';
  const type=document.getElementById('liType');type.value=old.type==='vlan'?'vlan':'bridge';if(existing)type.disabled=true;
  function fields(){
    if(type.value==='bridge'){
      const choices=(state.config.interfaces||[]).filter(i=>i.id!==old.id&&['physical','vlan'].includes(i.type)).map(i=>{
        const checked=(old.members||[]).includes(i.id),hasIp=(i.ipv4||[]).length||i.defaultRoute;
        return '<label class="form-check mb-2"><input class="form-check-input bridge-member" type="checkbox" value="'+esc(i.id)+'" '+(checked?'checked':'')+'><span class="form-check-label"><strong>'+esc(i.device)+'</strong> · '+esc(i.type)+(hasIp?' <span class="text-warning">· current IP/routes will migrate to the bridge</span>':'')+'</span></label>';
      }).join('');
      document.getElementById('liFields').innerHTML='<div class="row g-3"><div class="col-md-6"><label class="form-label">Member interfaces</label><div class="border rounded p-2">'+(choices||'<span class="text-secondary">No eligible member interfaces. A bridge may also be created empty.</span>')+'</div></div><div class="col-md-6"><div class="form-check mt-4"><input id="liVlanAware" class="form-check-input" type="checkbox" '+(old.vlanAware===false?'':'checked')+'><label class="form-check-label">VLAN-aware bridge</label></div><div class="form-text mt-2">When a member currently owns an IP address or default route, LiteFWM moves that L3 configuration to the bridge before enslaving the NIC.</div></div></div>';
    }else{
      document.getElementById('liFields').innerHTML='<div class="row g-3"><div class="col-md-7"><label class="form-label">Parent interface</label><select id="liParent" class="form-select">'+interfaceOptions(old.parent||'', ['physical','bridge'])+'</select></div><div class="col-md-5"><label class="form-label">VLAN ID</label><input id="liVid" type="number" min="1" max="4094" class="form-control" value="'+esc(old.vlanId==null?'':old.vlanId)+'"></div></div><div class="form-text mt-2">The parent can be a physical NIC or a Linux bridge. Leave the VLAN itself unnumbered or add its IP under IP settings after creation.</div>';
    }
  }
  type.onchange=fields;fields();
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="liSave" class="btn btn-primary">Apply live change</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('liSave').onclick=async()=>{
    const t=type.value,dev=document.getElementById('liDevice').value.trim();
    if(!dev){toast('Interface','Device name is required.');return;}
    let obj={id:existing?old.id:dev,name:dev,device:dev,type:t,kind:t,managed:true,persistent:true,enabled:true,mtu:Number(document.getElementById('liMtu').value||1500),ipv4:[]};
    if(t==='bridge'){obj.vlanAware=document.getElementById('liVlanAware').checked;obj.members=Array.from(document.querySelectorAll('.bridge-member:checked')).map(x=>x.value);}
    else{obj.parent=document.getElementById('liParent').value;obj.vlanId=Number(document.getElementById('liVid').value);obj.members=[];if(!obj.parent||!obj.vlanId){toast('VLAN','Parent and VLAN ID are required.');return;}}
    if(existing){state.config.interfaces=state.config.interfaces.map(x=>x.id===old.id?obj:x);}
    else state.config.interfaces.push(obj);
    try{await commitLive(t==='bridge'?dev+' created/updated. Member IP configuration was migrated to the bridge where necessary.':dev+' VLAN created/updated.');modal.hide();}catch(e){toast('Interface change failed',e.message);}
  };
}
function editIpForInterface(id){
  const existing=(state.config.segments||[]).filter(s=>s.interface===id);
  if(existing.length===1)editSegment(existing[0]);else if(existing.length>1){
    location.hash='#segments';render();toast('Multiple IP configurations',id+' has multiple network segments. Edit the one you want from Network segments.');
  }else editSegment(null,id);
}

function renderSegments(){
  const list=state.config.segments||[];
  let h='<div class="d-flex justify-content-between align-items-center mb-3"><div><p class="mb-0 text-secondary">These rows are derived from current interface addresses, DHCP state, routes, resolver state, and dnsmasq. They are not stored in a LiteFWM database.</p></div><button id="addSeg" class="btn btn-primary btn-sm">Add IP configuration</button></div>';
  h+='<div class="card"><div class="table-responsive"><table class="table mb-0"><thead><tr><th>Interface</th><th>Current address</th><th>Assignment</th><th>Network role</th><th>Gateway / DNS</th><th>DHCP server</th><th></th></tr></thead><tbody>';
  list.forEach(s=>{
    const actions=s.managed===false?'<span class="small text-secondary">Observed only</span>':'<div class="btn-group btn-group-sm"><button class="btn btn-outline-secondary edit-segment" data-id="'+esc(s.id)+'">Edit</button><button class="btn btn-outline-danger delete-segment" data-id="'+esc(s.id)+'">Remove IP</button></div>';
    h+='<tr><td><strong>'+esc(s.interface)+'</strong><div class="small text-secondary">'+esc(s.id)+'</div></td><td><code>'+esc(shownAddress(s))+'</code></td><td>'+(s.addressMode==='dhcp'?'<span class="badge text-bg-info">DHCP client</span>':'<span class="badge badge-soft">Static</span>')+'</td><td>'+esc(zoneName(s.zone))+'</td><td>'+esc(s.gateway||'—')+'<div class="small text-secondary">'+esc(csv(s.dns)||'—')+'</div></td><td>'+(s.dhcp&&s.dhcp.enabled?'<span class="badge text-bg-success">On</span><div class="small text-secondary">'+esc(s.dhcp.poolStart||'')+' – '+esc(s.dhcp.poolEnd||'')+'</div>':'Off')+'</td><td class="text-end">'+actions+'</td></tr>';
  });
  if(!list.length)h+='<tr><td colspan="7" class="text-secondary">No global IPv4 configuration is currently present.</td></tr>';
  h+='</tbody></table></div></div>';
  document.getElementById('view').innerHTML=h;
  document.getElementById('addSeg').onclick=()=>editSegment(null);
  document.querySelectorAll('.edit-segment').forEach(b=>b.onclick=()=>editSegment(seg(b.dataset.id)));
  document.querySelectorAll('.delete-segment').forEach(b=>b.onclick=async()=>{
    const s=seg(b.dataset.id);
    if(s.zone==='external'&&!confirm('This segment carries the default route. Removing it can disconnect this browser. Continue?'))return;
    if(s.zone!=='external'&&!confirm('Remove '+shownAddress(s)+' from '+s.interface+' now?'))return;
    state.config.segments=state.config.segments.filter(x=>x.id!==s.id);
    try{await commitLive('IP configuration removed from '+s.interface+'.');}catch(e){toast('IP removal',e.message);}
  });
}
function editSegment(existing,forcedInterface){
  const old=existing||{id:uid('segment'),name:'',interface:forcedInterface||'',addressMode:'static',address:'',currentAddress:'',gateway:'',dns:[],domain:'',dhcpClient:{hostname:''},dhcp:{enabled:false,dns:[],ntp:[],reservations:[]}};
  const d=old.dhcp||{enabled:false,dns:[],ntp:[],reservations:[]};
  document.getElementById('modalTitle').textContent=existing?'Edit IP configuration':'Add IP configuration';
  document.getElementById('modalBody').innerHTML='<div class="row g-3"><div class="col-md-6"><label class="form-label">Interface</label><select id="sgIface" class="form-select">'+interfaceOptions(old.interface)+'</select></div><div class="col-md-6"><label class="form-label">Address assignment</label><select id="sgMode" class="form-select"><option value="static">Static IPv4</option><option value="dhcp">DHCP client</option></select></div><div id="sgAddressFields" class="col-12"></div><div id="sgDhcpFields" class="col-12"></div></div>';
  document.getElementById('sgMode').value=old.addressMode||'static';
  if(forcedInterface)document.getElementById('sgIface').value=forcedInterface;
  function draw(){
    const mode=document.getElementById('sgMode').value;
    if(mode==='dhcp'){
      document.getElementById('sgAddressFields').innerHTML='<div class="alert alert-light border mb-0"><strong>Current lease:</strong> <code>'+esc(old.currentAddress||'none')+'</code><br><span class="small text-secondary">Gateway and DNS are learned from the DHCP server. The current lease address is requested again on reboot when available.</span></div>';
      document.getElementById('sgDhcpFields').innerHTML='';
    }else{
      document.getElementById('sgAddressFields').innerHTML='<div class="row g-3"><div class="col-md-4"><label class="form-label">Address / CIDR</label><input id="sgAddr" class="form-control" value="'+esc(old.address||old.currentAddress||'')+'" placeholder="192.168.10.1/24"><div id="sgCidr" class="form-text"></div></div><div class="col-md-4"><label class="form-label">Default gateway</label><input id="sgGw" class="form-control" value="'+esc(old.gateway||'')+'" placeholder="Only if this should be the default route"></div><div class="col-md-4"><label class="form-label">DNS servers</label><input id="sgDns" class="form-control" value="'+esc(csv(old.dns))+'" placeholder="1.1.1.1, 9.9.9.9"></div></div>';
      const a=document.getElementById('sgAddr'),preview=()=>{const c=cidrInfo(a.value.trim());document.getElementById('sgCidr').textContent=c?'Network '+c.network+' · usable '+c.first+' – '+c.last+' · broadcast '+c.broadcast:'Enter IPv4/CIDR.';};a.oninput=preview;preview();
      document.getElementById('sgDhcpFields').innerHTML='<hr><div class="form-check mb-3"><input id="sgDhcpEnable" class="form-check-input" type="checkbox" '+(d.enabled?'checked':'')+'><label class="form-check-label">Run DHCP server on this network</label></div><div class="row g-3"><div class="col-md-4"><label class="form-label">Pool start</label><input id="sgPoolStart" class="form-control" value="'+esc(d.poolStart||'')+'"></div><div class="col-md-4"><label class="form-label">Pool end</label><input id="sgPoolEnd" class="form-control" value="'+esc(d.poolEnd||'')+'"></div><div class="col-md-4"><label class="form-label">Lease time</label><input id="sgLease" class="form-control" value="'+esc(d.leaseTime||'12h')+'"></div><div class="col-md-4"><label class="form-label">Client gateway</label><input id="sgRouter" class="form-control" value="'+esc(d.gateway||'')+'"></div><div class="col-md-4"><label class="form-label">Client DNS</label><input id="sgDhcpDns" class="form-control" value="'+esc(csv(d.dns))+'"></div><div class="col-md-4"><label class="form-label">NTP</label><input id="sgNtp" class="form-control" value="'+esc(csv(d.ntp))+'"></div><div class="col-md-6"><label class="form-label">Domain</label><input id="sgDomain" class="form-control" value="'+esc(old.domain||'')+'"></div></div>';
    }
  }
  document.getElementById('sgMode').onchange=draw;draw();
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="sgSave" class="btn btn-primary">Apply live IP change</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('sgSave').onclick=async()=>{
    const mode=document.getElementById('sgMode').value,iid=document.getElementById('sgIface').value;
    if(!iid){toast('IP configuration','Select an interface.');return;}
    let x=Object.assign({},old,{interface:iid,addressMode:mode,managed:true,zone:old.zone||'internal'});
    if(mode==='dhcp'){x.address='';x.gateway='';x.dns=[];x.dhcp={enabled:false,dns:[],ntp:[],reservations:[]};}
    else{
      x.address=document.getElementById('sgAddr').value.trim();x.currentAddress=x.address;x.gateway=document.getElementById('sgGw').value.trim();x.dns=splitCsv(document.getElementById('sgDns').value);x.domain=document.getElementById('sgDomain').value.trim();
      x.dhcp={enabled:document.getElementById('sgDhcpEnable').checked,poolStart:document.getElementById('sgPoolStart').value.trim(),poolEnd:document.getElementById('sgPoolEnd').value.trim(),leaseTime:document.getElementById('sgLease').value.trim()||'12h',gateway:document.getElementById('sgRouter').value.trim(),dns:splitCsv(document.getElementById('sgDhcpDns').value),ntp:splitCsv(document.getElementById('sgNtp').value),reservations:d.reservations||[]};
    }
    if(existing)state.config.segments=state.config.segments.map(s=>s.id===old.id?x:s);else state.config.segments.push(x);
    try{await commitLive('IP configuration on '+iid+' updated immediately.');modal.hide();}catch(e){toast('IP change failed',e.message);}
  };
}

function renderFirewall(){
  const f=state.config.firewall||{defaults:{input:'accept',forward:'accept',output:'accept'},rules:[]};
  let h='<div class="alert alert-light border">This is the current <code>iptables</code> filter table. Saving a policy or rule rewrites the live table immediately and persists it to Alpine’s native iptables rules file.</div>';
  h+='<div class="card mb-3"><div class="card-body"><div class="row g-3 align-items-end">';
  ['input','forward','output'].forEach(k=>h+='<div class="col-md-3"><label class="form-label">'+k.toUpperCase()+'</label><select id="pol-'+k+'" class="form-select"><option value="accept">ACCEPT</option><option value="drop">DROP</option></select></div>');
  h+='<div class="col-md-3"><button id="savePolicies" class="btn btn-primary">Apply policies</button></div></div></div></div>';
  h+='<div class="d-flex justify-content-between mb-2"><strong>Live rules</strong><button id="addRule" class="btn btn-sm btn-primary">Add rule</button></div><div class="card"><div class="table-responsive"><table class="table table-sm mb-0"><thead><tr><th>Chain</th><th>In</th><th>Out</th><th>Source</th><th>Destination</th><th>Protocol / port</th><th>Action</th><th></th></tr></thead><tbody>';
  (f.rules||[]).forEach((r,n)=>{h+='<tr><td>'+esc((r.chain||'').toUpperCase())+'</td><td>'+esc(r.inSegment||'any')+'</td><td>'+esc(r.outSegment||'any')+'</td><td>'+esc(r.source||'any')+'</td><td>'+esc(r.destination||'any')+'</td><td>'+esc(r.protocol||'any')+(r.destinationPort&&r.destinationPort!=='any'?' / '+esc(r.destinationPort):'')+'</td><td>'+esc(r.action||'')+'</td><td class="text-end"><div class="btn-group btn-group-sm"><button class="btn btn-outline-secondary edit-rule" data-i="'+n+'">Edit</button><button class="btn btn-outline-danger del-rule" data-i="'+n+'">Delete</button></div></td></tr>';});
  h+='</tbody></table></div></div>';
  document.getElementById('view').innerHTML=h;
  ['input','forward','output'].forEach(k=>document.getElementById('pol-'+k).value=f.defaults[k]||'accept');
  document.getElementById('savePolicies').onclick=async()=>{f.defaults={input:document.getElementById('pol-input').value,forward:document.getElementById('pol-forward').value,output:document.getElementById('pol-output').value};try{await commitLive('iptables default policies updated.');}catch(e){toast('Firewall',e.message);}};
  document.getElementById('addRule').onclick=()=>editRule(null);
  document.querySelectorAll('.edit-rule').forEach(b=>b.onclick=()=>editRule(f.rules[Number(b.dataset.i)]));
  document.querySelectorAll('.del-rule').forEach(b=>b.onclick=async()=>{f.rules.splice(Number(b.dataset.i),1);try{await commitLive('Firewall rule removed.');}catch(e){toast('Firewall',e.message);}});
}
function editRule(existing){
  const r=existing||{id:uid('rule'),chain:'forward',protocol:'any',source:'any',destination:'any',sourcePort:'any',destinationPort:'any',action:'accept',inSegment:'any',outSegment:'any',enabled:true};
  document.getElementById('modalTitle').textContent=existing?'Edit live firewall rule':'Add live firewall rule';
  document.getElementById('modalBody').innerHTML='<div class="row g-3"><div class="col-md-4"><label class="form-label">Chain</label><select id="frChain" class="form-select"><option value="input">INPUT</option><option value="forward">FORWARD</option><option value="output">OUTPUT</option></select></div><div class="col-md-4"><label class="form-label">Inbound segment</label><select id="frIn" class="form-select">'+segmentOptions(r.inSegment||'any',true)+'</select></div><div class="col-md-4"><label class="form-label">Outbound segment</label><select id="frOut" class="form-select">'+segmentOptions(r.outSegment||'any',true)+'</select></div><div class="col-md-4"><label class="form-label">Protocol</label><select id="frProto" class="form-select"><option value="any">Any</option><option value="tcp">TCP</option><option value="udp">UDP</option><option value="icmp">ICMP</option></select></div><div class="col-md-4"><label class="form-label">Source</label><input id="frSrc" class="form-control" value="'+esc(r.source||'any')+'"></div><div class="col-md-4"><label class="form-label">Destination</label><input id="frDst" class="form-control" value="'+esc(r.destination||'any')+'"></div><div class="col-md-4"><label class="form-label">Source port</label><input id="frSport" class="form-control" value="'+esc(r.sourcePort||'any')+'"></div><div class="col-md-4"><label class="form-label">Destination port</label><input id="frDport" class="form-control" value="'+esc(r.destinationPort||'any')+'"></div><div class="col-md-4"><label class="form-label">Action</label><select id="frAction" class="form-select"><option value="accept">ACCEPT</option><option value="drop">DROP</option><option value="reject">REJECT</option><option value="log">LOG</option></select></div></div>';
  ['Chain','Proto','Action'].forEach(k=>document.getElementById('fr'+k).value=r[k.toLowerCase()]||r.action);
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="frSave" class="btn btn-primary">Apply live rule</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('frSave').onclick=async()=>{
    const nr={id:r.id||uid('rule'),enabled:true,chain:document.getElementById('frChain').value,protocol:document.getElementById('frProto').value,inSegment:document.getElementById('frIn').value,outSegment:document.getElementById('frOut').value,source:document.getElementById('frSrc').value.trim()||'any',destination:document.getElementById('frDst').value.trim()||'any',sourcePort:document.getElementById('frSport').value.trim()||'any',destinationPort:document.getElementById('frDport').value.trim()||'any',action:document.getElementById('frAction').value,description:''};
    const rules=state.config.firewall.rules||[],idx=existing?rules.indexOf(existing):-1;if(idx>=0)rules[idx]=nr;else rules.push(nr);delete nr.raw;
    try{await commitLive('Firewall rule applied immediately.');modal.hide();}catch(e){toast('Firewall rule',e.message);}
  };
}

function renderNat(){
  const n=(state.config.firewall||{}).nat||{masquerade:[],snat:[],dnat:[]};
  let h='<div class="alert alert-light border">These rows are read from the live <code>nat</code> table. Changes are applied immediately.</div>';
  h+='<div class="card mb-3"><div class="card-header d-flex"><strong>Outbound NAT</strong><button id="addMasq" class="btn btn-sm btn-primary ms-auto">Add outbound NAT</button></div><div class="table-responsive"><table class="table table-sm mb-0"><thead><tr><th>Type</th><th>Source</th><th>Outbound</th><th>Translation</th><th></th></tr></thead><tbody>';
  const out=[];(n.masquerade||[]).forEach((x,i)=>out.push({kind:'masquerade',i,x}));(n.snat||[]).forEach((x,i)=>out.push({kind:'snat',i,x}));
  out.forEach(o=>h+='<tr><td>'+esc(o.kind)+'</td><td>'+esc(o.x.sourceSegment||o.x.source||'any')+'</td><td>'+esc(o.x.outSegment||'')+'</td><td>'+esc(o.kind==='snat'?o.x.toSource:'outbound address')+'</td><td class="text-end"><button class="btn btn-sm btn-outline-danger del-nat" data-kind="'+o.kind+'" data-i="'+o.i+'">Delete</button></td></tr>');
  h+='</tbody></table></div></div>';
  h+='<div class="card"><div class="card-header d-flex"><strong>Port forwards</strong><button id="addDnat" class="btn btn-sm btn-primary ms-auto">Add port forward</button></div><div class="table-responsive"><table class="table table-sm mb-0"><thead><tr><th>Inbound</th><th>Protocol</th><th>Port</th><th>Destination</th><th></th></tr></thead><tbody>';
  (n.dnat||[]).forEach((x,i)=>h+='<tr><td>'+esc(x.inSegment||'')+'</td><td>'+esc(x.protocol||'tcp')+'</td><td>'+esc(x.destinationPort||'')+'</td><td>'+esc(x.toDestination||'')+'</td><td class="text-end"><button class="btn btn-sm btn-outline-danger del-dnat" data-i="'+i+'">Delete</button></td></tr>');
  h+='</tbody></table></div></div>';
  document.getElementById('view').innerHTML=h;
  document.getElementById('addMasq').onclick=editOutboundNat;document.getElementById('addDnat').onclick=editDnat;
  document.querySelectorAll('.del-nat').forEach(b=>b.onclick=async()=>{n[b.dataset.kind].splice(Number(b.dataset.i),1);try{await commitLive('NAT rule removed.');}catch(e){toast('NAT',e.message);}});
  document.querySelectorAll('.del-dnat').forEach(b=>b.onclick=async()=>{n.dnat.splice(Number(b.dataset.i),1);try{await commitLive('Port forward removed.');}catch(e){toast('NAT',e.message);}});
}
function editOutboundNat(){
  document.getElementById('modalTitle').textContent='Add outbound NAT';
  document.getElementById('modalBody').innerHTML='<div class="row g-3"><div class="col-md-4"><label class="form-label">Source segment</label><select id="natSrc" class="form-select">'+segmentOptions('',false)+'</select></div><div class="col-md-4"><label class="form-label">Outbound segment</label><select id="natOut" class="form-select">'+segmentOptions('',false)+'</select></div><div class="col-md-4"><label class="form-label">Translation</label><select id="natMode" class="form-select"><option value="masquerade">Outbound address</option><option value="snat">Fixed source IP</option></select></div><div id="natFixed" class="col-md-4"></div></div>';
  const draw=()=>document.getElementById('natFixed').innerHTML=document.getElementById('natMode').value==='snat'?'<label class="form-label">Fixed source IP</label><input id="natIp" class="form-control">':'';document.getElementById('natMode').onchange=draw;draw();
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="natSave" class="btn btn-primary">Apply live NAT</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('natSave').onclick=async()=>{const mode=document.getElementById('natMode').value,x={id:uid(mode),enabled:true,sourceSegment:document.getElementById('natSrc').value,source:'any',outSegment:document.getElementById('natOut').value};if(mode==='snat'){x.toSource=document.getElementById('natIp').value.trim();state.config.firewall.nat.snat.push(x);}else state.config.firewall.nat.masquerade.push(x);try{await commitLive('Outbound NAT applied.');modal.hide();}catch(e){toast('NAT',e.message);}};
}
function editDnat(){
  document.getElementById('modalTitle').textContent='Add port forward';
  document.getElementById('modalBody').innerHTML='<div class="row g-3"><div class="col-md-4"><label class="form-label">Inbound segment</label><select id="dnIn" class="form-select">'+segmentOptions('',false)+'</select></div><div class="col-md-2"><label class="form-label">Protocol</label><select id="dnProto" class="form-select"><option value="tcp">TCP</option><option value="udp">UDP</option></select></div><div class="col-md-2"><label class="form-label">Port</label><input id="dnPort" class="form-control"></div><div class="col-md-4"><label class="form-label">Destination IP[:port]</label><input id="dnTo" class="form-control"></div></div>';
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="dnSave" class="btn btn-primary">Apply port forward</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('dnSave').onclick=async()=>{state.config.firewall.nat.dnat.push({id:uid('dnat'),enabled:true,inSegment:document.getElementById('dnIn').value,protocol:document.getElementById('dnProto').value,destinationPort:document.getElementById('dnPort').value.trim(),toDestination:document.getElementById('dnTo').value.trim()});try{await commitLive('Port forward applied.');modal.hide();}catch(e){toast('NAT',e.message);}};
}

function renderDhcp(){
  let h='<div class="alert alert-light border">DHCP policy is configured with each static network segment. This page is the live lease view.</div><div class="card"><div class="table-responsive"><table class="table table-sm mb-0"><thead><tr><th>IP</th><th>MAC</th><th>Hostname</th><th>Interface</th><th></th></tr></thead><tbody>';
  (state.leases||[]).forEach((l,i)=>h+='<tr><td><code>'+esc(l.ip)+'</code></td><td><code>'+esc(l.mac)+'</code></td><td>'+esc(l.hostname||'')+'</td><td>'+esc(l.segment||'')+'</td><td class="text-end"><button class="btn btn-sm btn-outline-primary reserve-lease" data-i="'+i+'">Reserve</button></td></tr>');
  if(!(state.leases||[]).length)h+='<tr><td colspan="5" class="text-secondary">No active dnsmasq leases.</td></tr>';h+='</tbody></table></div></div>';
  document.getElementById('view').innerHTML=h;
  document.querySelectorAll('.reserve-lease').forEach(b=>b.onclick=async()=>{const l=state.leases[Number(b.dataset.i)],host=prompt('Hostname for this reservation',l.hostname||'')||'';try{await api('/reserve',{method:'POST',body:JSON.stringify({segment:l.segment||'',mac:l.mac,hostname:host,publishDns:false})});await refresh();toast('DHCP reservation','Reservation written to native dnsmasq configuration.');}catch(e){toast('DHCP',e.message);}});
}

function moduleLabel(n){return {openvpn:'OpenVPN',tailscale:'Tailscale',bind:'BIND 9',squid:'Squid',snort:'Snort',haproxy:'HAProxy',ddns:'Dynamic DNS'}[n]||n;}
function renderModules(){
  let h='<div class="alert alert-light border">Module status is read from installed packages, OpenRC, and each service’s native configuration file. LiteFWM does not maintain module JSON state.</div><div class="row g-3">';
  (state.modules||[]).forEach(m=>{h+='<div class="col-md-6 col-xl-4"><div class="card h-100"><div class="card-body"><div class="d-flex"><h2 class="h6">'+esc(moduleLabel(m.name))+'</h2><span class="badge ms-auto '+(m.running?'text-bg-success':'badge-soft')+'">'+(m.running?'Running':m.installed?'Installed':'Not installed')+'</span></div><div class="small text-secondary mb-3">'+esc(m.configPath||'')+'</div>'+(m.installed?'<div class="d-flex gap-2"><button class="btn btn-sm btn-outline-primary configure-module" data-name="'+esc(m.name)+'">Configure native file</button><button class="btn btn-sm btn-outline-danger remove-module" data-name="'+esc(m.name)+'">Remove</button></div>':'<button class="btn btn-sm btn-primary install-module" data-name="'+esc(m.name)+'">Install</button>')+'</div></div></div>';});h+='</div>';
  document.getElementById('view').innerHTML=h;
  document.querySelectorAll('.install-module').forEach(b=>b.onclick=async()=>{try{const r=await api('/module/install',{method:'POST',body:JSON.stringify({module:b.dataset.name})});await refresh();toast('Module',r.message||'Installed.');}catch(e){toast('Module',e.message);}});
  document.querySelectorAll('.remove-module').forEach(b=>b.onclick=async()=>{if(!confirm('Remove '+moduleLabel(b.dataset.name)+' package/service?'))return;try{const r=await api('/module/remove',{method:'POST',body:JSON.stringify({module:b.dataset.name})});await refresh();toast('Module',r.message||'Removed.');}catch(e){toast('Module',e.message);}});
  document.querySelectorAll('.configure-module').forEach(b=>b.onclick=()=>configureModule(b.dataset.name));
}
async function configureModule(name){
  try{
    const [cfg,st]=await Promise.all([api('/module/config/'+encodeURIComponent(name)),api('/module/status/'+encodeURIComponent(name))]);
    document.getElementById('modalTitle').textContent=moduleLabel(name)+' native configuration';
    document.getElementById('modalBody').innerHTML='<div class="mb-3"><strong>Path:</strong> <code>'+esc(cfg.path||st.path||'')+'</code><span class="badge ms-2 '+(st.running?'text-bg-success':'badge-soft')+'">'+(st.running?'Running':'Stopped')+'</span></div><textarea id="modRaw" class="form-control font-monospace" rows="20">'+esc(cfg.raw||'')+'</textarea><div class="form-check mt-3"><input id="modEnable" class="form-check-input" type="checkbox" '+(cfg.enabled?'checked':'')+'><label class="form-check-label">Enable service at boot and run it now</label></div>';
    document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="modSave" class="btn btn-primary">Write native file & restart</button>';
    const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
    document.getElementById('modSave').onclick=async()=>{try{await api('/module/config/'+encodeURIComponent(name),{method:'PUT',body:JSON.stringify({raw:document.getElementById('modRaw').value,enabled:document.getElementById('modEnable').checked})});await refresh();modal.hide();toast(moduleLabel(name),'Native configuration written and service state updated.');}catch(e){toast(moduleLabel(name),e.message);}};
  }catch(e){toast(moduleLabel(name),e.message);}
}

function renderMonitoring(){
  const m=state.metrics||{},ifs=m.interfaces||[];
  let h='<div class="row g-3 mb-3">'+card('Conntrack',m.conntrack||0,'Tracked flows')+card('Load',m.load1||0,'1 minute')+card('Memory available',Math.round(((m.memory||{}).available||0)/1048576)+' MB','Live host')+card('Captures',(state.captures||[]).length,'Saved pcaps')+'</div>';
  h+='<div class="card mb-3"><div class="card-header fw-semibold">Interface counters</div><div class="table-responsive"><table class="table table-sm mb-0"><thead><tr><th>Device</th><th>RX bytes</th><th>TX bytes</th></tr></thead><tbody>';
  ifs.forEach(i=>h+='<tr><td>'+esc(i.name||i.interface||'')+'</td><td>'+esc(i.rxBytes||i.rx_bytes||0)+'</td><td>'+esc(i.txBytes||i.tx_bytes||0)+'</td></tr>');h+='</tbody></table></div></div>';
  h+='<button id="newCapture" class="btn btn-sm btn-outline-primary">Packet capture</button>';
  document.getElementById('view').innerHTML=h;document.getElementById('newCapture').onclick=startCapture;
}
function startCapture(){
  document.getElementById('modalTitle').textContent='Packet capture';
  document.getElementById('modalBody').innerHTML='<div class="row g-3"><div class="col-md-8"><label class="form-label">Network segment / interface</label><select id="capSeg" class="form-select">'+segmentOptions('',false)+'</select></div><div class="col-md-4"><label class="form-label">Seconds</label><input id="capSeconds" type="number" min="1" max="300" class="form-control" value="30"></div></div>';
  document.getElementById('modalFooter').innerHTML='<button class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button><button id="capStart" class="btn btn-primary">Capture</button>';
  const modal=bootstrap.Modal.getOrCreateInstance(document.getElementById('formModal'));modal.show();
  document.getElementById('capStart').onclick=async()=>{try{await api('/capture',{method:'POST',body:JSON.stringify({segment:document.getElementById('capSeg').value,seconds:Number(document.getElementById('capSeconds').value||30)})});modal.hide();await refresh();toast('Capture','Packet capture completed.');}catch(e){toast('Capture',e.message);}};
}

function renderSettings(){
  const m=state.config.management||{};
  let h='<div class="row g-3"><div class="col-lg-6"><div class="card"><div class="card-body"><h2 class="h6">Management</h2><label class="form-label">Hostname</label><input id="setHost" class="form-control mb-3" value="'+esc(state.config.hostname||'')+'"><label class="form-label">LiteFWM port</label><input id="setPort" type="number" class="form-control mb-3" value="'+esc(m.port||5187)+'"><hr><div class="form-check mb-3"><input id="setSsh" class="form-check-input" type="checkbox" '+(m.allowSsh?'checked':'')+'><label class="form-check-label">Run SSH service</label></div><label class="form-label">SSH port</label><input id="setSshPort" type="number" class="form-control mb-3" value="'+esc(m.sshPort||22)+'"><button id="saveSettings" class="btn btn-primary">Apply live settings</button></div></div></div><div class="col-lg-6"><div class="card"><div class="card-body"><h2 class="h6">Persistence model</h2><p>LiteFWM has no network JSON database. It reads and writes the host’s native configuration.</p><dl class="row mb-0"><dt class="col-5">Network</dt><dd class="col-7"><code>/etc/network/interfaces</code></dd><dt class="col-5">Firewall</dt><dd class="col-7"><code>/etc/iptables/rules-save</code></dd><dt class="col-5">DHCP</dt><dd class="col-7"><code>/etc/dnsmasq.d/litefwm.conf</code></dd><dt class="col-5">Web</dt><dd class="col-7"><code>/etc/lighttpd/litefwm.conf</code></dd><dt class="col-5">Modules</dt><dd class="col-7">Each service’s native file</dd></dl></div></div></div></div>';
  document.getElementById('view').innerHTML=h;
  document.getElementById('saveSettings').onclick=async()=>{state.config.hostname=document.getElementById('setHost').value.trim();state.config.management.port=Number(document.getElementById('setPort').value);state.config.management.allowSsh=document.getElementById('setSsh').checked;state.config.management.sshPort=Number(document.getElementById('setSshPort').value);try{await commitLive('Management settings changed immediately.');}catch(e){toast('Settings',e.message);}};
}

window.addEventListener('hashchange',render);
document.getElementById('validateBtn').onclick=async()=>{try{const r=await api('/validate',{method:'POST'});toast('Live-state check',r.message||'Live configuration is valid.');}catch(e){toast('Validation failed',e.message);}};
const rb=document.getElementById('refreshBtn');if(rb)rb.onclick=refresh;
refresh();
