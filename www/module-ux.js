'use strict';
// Task-oriented module dashboards, loaded after the legacy module catalog.
// Every action uses the same authenticated resource API as the rest of LiteFW.
const uxSettings = id => moduleState(id).settings || {};
const uxBody = (...children) => h('div',{class:'card-body'},...children);
const uxHelp = text => h('p',{class:'text-secondary small mb-2'},text);
const uxPill = (yes,on,off) => badge(yes,on||'text-bg-success',off);
const uxInstalled = id => { const m=moduleBy(id); return !!(m && m.installed); };
const uxNoInstall = id => {
  const m=moduleBy(id);
  return [h('div',{class:'mb-3'},btn('Back to modules',()=>location.hash='#modules')),
    card(m ? m.name : 'Unavailable',
      [m && btn('Install',()=>moduleInstall(m),'btn-primary')],
      uxBody(uxHelp(m ? m.description : 'Module not found'),
        h('div',{class:'alert alert-light border small mb-0'},
          'Installation requires a compatible native package or a verified supported vendor build. No service starts until you configure and activate it.')))];
};
const uxTop = (id, actions) => {
  const m=moduleBy(id),s=moduleState(id);
  return [h('div',{class:'mb-3'},btn('Back to modules',()=>location.hash='#modules')),
    card(m.name,[badge(s.running?'Running':'Stopped',s.running?'text-bg-success':'text-bg-secondary'),
      ...actions, ...moduleServiceButtons(id+'.service',!!s.running,!!s.configured)],
      uxBody(uxHelp(m.description)))];
};
function uxDownload(name,data,type) {
  const url=URL.createObjectURL(new Blob([data],{type:type||'text/plain;charset=utf-8'}));
  const a=document.createElement('a');a.href=url;a.download=name;a.click();
  setTimeout(()=>URL.revokeObjectURL(url),2000);
}
function uxError(e){toast(e.message||String(e),'danger');}

function geoipPanel() {
  if(!uxInstalled('geoip'))return uxNoInstall('geoip');
  const settings=uxSettings('geoip'),state=moduleState('geoip');
  const selection=new Set(settings.countries||[]);
  const search=h('input',{class:'form-control',type:'search',placeholder:'Search countries or two-letter codes',id:'geoip-search'});
  const group=h('select',{class:'form-select',id:'geoip-group'},
    [['all','All countries'],['A-F','A–F'],['G-L','G–L'],['M-R','M–R'],['S-Z','S–Z']]
      .map(([value,name])=>h('option',{value},name)));
  const onlySelected=h('input',{type:'checkbox',class:'form-check-input',id:'geoip-selected-only'});
  const count=h('span',{class:'small fw-semibold'},'');
  const list=h('div',{class:'row g-2',id:'geoip-country-choices'});
  let visible=[];
  function update() {
    const q=search.value.toLowerCase().trim(),grp=group.value;
    visible=COUNTRY_OPTIONS.filter(([code,name])=>{
      const c=name.charAt(0).toUpperCase();
      if(grp!=='all' && !(c>=grp[0] && c<=grp[2]))return false;
      if(onlySelected.checked&&!selection.has(code))return false;
      return !q||name.toLowerCase().includes(q)||code.includes(q);
    });
    count.textContent=selection.size+' countries selected';
    list.replaceChildren(...visible.map(([code,name])=>{
      const box=h('input',{type:'checkbox',class:'form-check-input mt-0',id:'geoip-'+code,
        checked:selection.has(code),onchange:e=>{
          if(e.target.checked)selection.add(code);else selection.delete(code);
          count.textContent=selection.size+' countries selected';
        }});
      return h('div',{class:'col-12 col-sm-6 col-lg-4 col-xl-3'},
        h('label',{class:'border rounded px-2 py-2 d-flex gap-2 align-items-center w-100 h-100',for:'geoip-'+code},
          box,h('span',{},name),h('span',{class:'small text-secondary ms-auto'},code.toUpperCase())));
    }));
    if(!visible.length)list.append(h('p',{class:'text-secondary'},'No matching countries.'));
  }
  search.addEventListener('input',update);
  group.addEventListener('change',update);
  onlySelected.addEventListener('change',update);
  const chooseVisible=btn('Select shown',()=>{visible.forEach(([code])=>selection.add(code));update()},'btn-outline-primary');
  const clear=btn('Clear all',()=>{selection.clear();update()},'btn-outline-secondary');
  const save=btn('Save selected countries',async()=>{
    if(!selection.size)return toast('Select at least one country.','warning');
    if(selection.size>100)return toast('Select up to 100 countries per policy.','warning');
    try {await apply('geoip.configure',{countries:[...selection].sort(),enabled:false},
      'Countries saved. Refresh the feeds, then Start blocking when ready.')}
    catch(e){uxError(e)}
  },'btn-primary');
  update();
  return [...uxTop('geoip',[
      btn('Refresh IP lists',()=>apply('geoip.refresh',{},'Country IP lists refreshed'),'btn-outline-primary')
    ]),
    card('Blocked countries', [count],uxBody(
      uxHelp('Search and select countries. Saving the selection does not turn on blocking. Refresh the country IP lists, then explicitly Start. IPv4 only.'),
      h('div',{class:'row g-2 mb-3'},
        h('div',{class:'col-md-8'},search),h('div',{class:'col-md-4'},group)),
      h('div',{class:'d-flex gap-3 align-items-center flex-wrap mb-3'},
        h('label',{class:'form-check-label d-flex align-items-center gap-2',for:'geoip-selected-only'},onlySelected,'Show selected only'),
        chooseVisible,clear),
      h('div',{class:'border rounded p-3 mb-3',style:'max-height:430px;overflow-y:auto'},list),
      h('div',{class:'d-flex align-items-center justify-content-between flex-wrap gap-3'},
        h('span',{class:'small text-secondary'},'Loaded CIDR networks: '+(settings.loadedNetworks||0)),
        save)))
  ];
}
function suricataSettingsForm() {
  const x=uxSettings('suricata'),ifaces=(S.interfaces||[]).filter(i=>i.kind!=='loopback');
  form('Suricata capture and inspection',[
    {k:'interface',label:'Inspection interface',type:'select',value:x.interface||'',
      options:ifaces.map(i=>[i.name,i.name+' — '+(i.label||i.role||'interface')])},
    {k:'mode',label:'Operating mode',type:'select',value:x.mode||'ids',
      options:[['ids','IDS: alert only'],['ips','IPS: inline rule enforcement']]},
  ],v=>apply('suricata.configure',v,'Suricata configuration saved; restart to apply'),{
    note:'IDS is the safer starting point. IPS inspects forwarded traffic through NFQUEUE and can drop packets matching enabled DROP rules. Saving does not automatically start or restart the engine.',
    applyText:'Save inspection settings'
  });
}
function suricataSourceForm(x) {
  x=x||{};
  form(x.id?'Edit rule source':'Add HTTPS rule source',[
    {k:'id',label:'Short source ID',value:x.id||'',placeholder:'et-open',
      help:'Lowercase letters, numbers, dashes and underscores; cannot include spaces.'},
    {k:'name',label:'Display name',value:x.name||'',placeholder:'Emerging Threats Open'},
    {k:'url',label:'HTTPS .rules URL',value:x.url||'',placeholder:'https://example.org/rules/threats.rules'},
    {k:'enabled',label:'Enable source',type:'check',value:x.enabled!==false}
  ],v=>apply('suricata.sourceset',v,'Source saved. Refresh it to retrieve signatures.'),{
    note:'Only HTTPS plain-text Suricata rules are supported. Downloads are size-limited and must pass Suricata validation before activation.'
  });
}
function suricataUploadForm(){
  let picker;
  form('Import custom Suricata rules',[
    {k:'id',label:'Ruleset ID',placeholder:'local-signatures'},
    {k:'name',label:'Display name',placeholder:'Local custom rules'}
  ],async v=>{
    const file=picker&&picker.files&&picker.files[0];
    if(!file)throw new Error('Choose a .rules text file.');
    if(file.size>1024*1024)throw new Error('Maximum file size is 1 MiB.');
    return apply('suricata.rulesupload',{...v,content:await file.text()},
      'Ruleset imported and validated; restart Suricata to apply');
  },{note:'Custom signatures are validated by Suricata before replacing the active ruleset.',
    decorate:body=>{
      picker=h('input',{type:'file',accept:'.rules,text/plain',class:'form-control',id:'suricata-upload'});
      body.append(h('div',{class:'mb-3'},
        h('label',{class:'form-label small fw-semibold',for:'suricata-upload'},'Suricata .rules file'),picker));
    }});
}
async function suricataExport(id){
  try {
    const j=await op('suricata.rulesexport',{id:id||''}),v=j.result||j;
    uxDownload(v.filename||'suricata.rules',v.content||'');
  }catch(e){uxError(e)}
}
function suricataPanel(){
  if(!uxInstalled('suricata'))return uxNoInstall('suricata');
  const st=moduleState('suricata'),settings=st.settings||{},
    sources=st.sources||[],rules=st.rules||[];
  const sourceRows=sources.map(x=>h('tr',{},
    h('td',{},h('strong',{},x.name||x.id),h('div',{class:'small text-secondary mono'},x.id)),
    h('td',{},badge(x.enabled?'Enabled':'Disabled',x.enabled?'text-bg-success':'text-bg-secondary')),
    h('td',{class:'small mono'},x.kind==='upload'?'Uploaded file':(x.url||'—')),
    h('td',{class:'text-end'},
      btn(x.enabled?'Disable':'Enable',()=>apply('suricata.sourceenable',{id:x.id,enabled:!x.enabled},'Source state saved'),'btn-outline-secondary'),' ',
      ...(x.kind==='url'?[btn('Refresh',()=>apply('suricata.sourcerefresh',{id:x.id},'Source updated'),'btn-outline-primary'),' ']:[]),
      btn('Download',()=>suricataExport(x.id),'btn-outline-secondary'),' ',
      ...(x.kind==='url'?[btn('Edit',()=>suricataSourceForm(x),'btn-outline-secondary'),' ']:[]),
      btn('Remove',()=>confirmDo('Remove ruleset','Delete the '+x.name+' source and its signatures?',
        ()=>apply('suricata.sourceremove',{id:x.id},'Ruleset removed'),'Remove'),'btn-outline-danger'))));
  const search=h('input',{class:'form-control',type:'search',placeholder:'Search SIDs, signature messages or rulesets'});
  const result=h('div',{},'');
  const rowFor=r=>h('tr',{},
    h('td',{class:'mono'},r.sid),
    h('td',{},r.message||'Signature '+r.sid),
    h('td',{class:'small'},r.source||'—'),
    h('td',{},badge(r.action||'alert',r.action==='drop'?'text-bg-danger':'text-bg-secondary')),
    h('td',{class:'text-end'},
      btn(r.enabled===false?'Enable':'Disable',()=>apply('suricata.ruleenable',{sid:String(r.sid),enabled:r.enabled===false},
        'Signature state updated. Restart to apply.'),r.enabled===false?'btn-outline-success':'btn-outline-secondary')));
  function filter(){
    const q=search.value.trim().toLowerCase();
    const matches=rules.filter(r=>!q||String(r.sid).includes(q)||(r.message||'').toLowerCase().includes(q)||(r.source||'').toLowerCase().includes(q));
    result.replaceChildren(table(['SID','Rule message','Source','Action','Control'],matches.slice(0,150).map(rowFor),
      'No loaded signatures. Add a source or upload a ruleset.'));
  }
  search.addEventListener('input',filter);filter();
  return [...uxTop('suricata',[
      btn('Inspection settings',suricataSettingsForm,'btn-primary'),
      btn('Update signatures',()=>apply('suricata.rulesupdate',{},'Signature updates requested'),'btn-outline-primary')
    ]),
    card('Inspection overview',null,uxBody(
      h('div',{class:'row g-3'},
        [['Interface',settings.interface||'Not configured'],['Mode',(settings.mode||'IDS').toUpperCase()],
          ['Rule sources',sources.length],['Visible signatures',rules.length]].map(([k,v])=>
          h('div',{class:'col-6 col-lg-3'},h('div',{class:'small text-secondary'},k),h('strong',{},v)))),
      h('p',{class:'small text-secondary mt-3 mb-0'},'Changes to rules and sources are staged and validated. Restart Suricata explicitly to load a new ruleset.'))),
    card('Rule sources',[
      btn('Add HTTPS source',()=>suricataSourceForm(),'btn-primary'),
      btn('Upload .rules',suricataUploadForm,'btn-outline-primary'),
      btn('Download active',()=>suricataExport(''),'btn-outline-secondary')
    ],table(['Ruleset','Status','Source','Actions'],sourceRows,'No rule sources configured.')),
    card('Signature controls',[badge(rules.length+' visible','text-bg-light border text-dark')],
      uxBody(uxHelp('Enable or disable an individual signature by SID. Search the imported rule sets; changes require an explicit engine restart.'),search),
      result)
  ];
}
function wireguardSettingsForm(){
  const x=uxSettings('wireguard'),ips=moduleState('wireguard').peers||x.peers||[];
  form('WireGuard server',[
    {k:'interface',label:'WireGuard device',value:x.interface||'wg0'},
    {k:'address',label:'Tunnel address and prefix',value:x.address||'10.240.0.1/24',placeholder:'10.240.0.1/24'},
    {k:'listenPort',label:'UDP listen port',type:'number',value:x.listenPort||51820},
    {k:'serverEndpoint',label:'Public hostname or IP for client profiles',value:x.serverEndpoint||'',
      placeholder:'vpn.example.net',help:'The server must be reachable at this address from clients.'},
    {k:'dns',label:'Optional client DNS server',value:x.dns||'',placeholder:'10.240.0.1'}
  ],v=>apply('wireguard.configure',{...v,listenPort:Number(v.listenPort),peers:ips,privateKey:''},
    'WireGuard server saved. Start it when ready.'),{
    note:'LiteFW generates and protects the server key automatically on the first save. Configure the public endpoint for downloadable client profiles; saving does not start the VPN.'
  });
}
function wireguardPeerForm(x){
  x=x||{};
  form(x.id?'Edit WireGuard peer':'Add WireGuard peer',[
    {k:'id',label:'Peer name',value:x.id||'',placeholder:'laptop'},
    {k:'publicKey',label:'Client public key (optional)',value:x.publicKey||'',
      help:'Leave blank for LiteFW to generate a client keypair and downloadable profile. Paste an existing client public key to use a key you already manage.'},
    {k:'allowedIPs',label:'Client tunnel IP/CIDR',value:x.allowedIPs||'',placeholder:'10.240.0.2/32'},
    {k:'endpoint',label:'Optional remote endpoint (site-to-site)',value:x.endpoint||'',placeholder:'branch.example.net:51820'},
    {k:'persistentKeepalive',label:'Keepalive seconds',type:'number',value:x.persistentKeepalive||25},
    {k:'enabled',label:'Enable this peer',type:'check',value:x.enabled!==false}
  ],v=>apply('wireguard.peerset',{...v,persistentKeepalive:Number(v.persistentKeepalive)},
    'Peer saved; restart WireGuard if already running.'),{
    note:'Peers are managed individually. Auto-generated private keys are stored root-only and may be downloaded only by authenticated administrators.'
  });
}
async function wireguardProfile(id) {
  try {const j=await op('wireguard.clientprofile',{id}),x=j.result||j;
    uxDownload(x.filename||id+'.conf',x.profile||'','application/x-wireguard-profile')}
  catch(e){uxError(e)}
}
function wireguardPanel(){
  if(!uxInstalled('wireguard'))return uxNoInstall('wireguard');
  const x=uxSettings('wireguard'),st=moduleState('wireguard'),peers=st.peers||x.peers||[];
  return [...uxTop('wireguard',[btn('Server settings',wireguardSettingsForm,'btn-primary')]),
    card('WireGuard server',null,uxBody(
      h('div',{class:'row g-3'},
        [['Interface',x.interface||'Not configured'],['Tunnel subnet',x.address||'—'],
         ['Listen port',x.listenPort||'—'],['Peers',peers.length]].map(([k,v])=>
          h('div',{class:'col-6 col-lg-3'},h('div',{class:'text-secondary small'},k),h('strong',{},v)))),
      h('div',{class:'mt-3 small'},h('strong',{},'Server public key: '),
        h('span',{class:'mono'},st.publicKey||x.publicKey||'Created on first save')),
      h('div',{class:'small text-secondary mt-2'},'Public endpoint for downloadable client profiles: ',x.serverEndpoint||'Not configured'))),
    card('VPN peers',[btn('Add peer',()=>wireguardPeerForm(),'btn-primary')],
      table(['Peer','Tunnel IP','Public key','Status','Actions'],
        peers.map(p=>h('tr',{},
          h('td',{},h('strong',{},p.id||'Peer')),
          h('td',{class:'mono'},p.allowedIPs),
          h('td',{class:'small mono'},(p.publicKey||'').slice(0,16)+'…'),
          h('td',{},badge(p.enabled===false?'Disabled':'Enabled',p.enabled===false?'text-bg-secondary':'text-bg-success')),
          h('td',{class:'text-end'},
            btn('Edit',()=>wireguardPeerForm(p),'btn-outline-primary'),' ',
            btn(p.enabled===false?'Enable':'Disable',()=>apply('wireguard.peerenable',{id:p.id,enabled:p.enabled===false},
              'Peer state updated'),'btn-outline-secondary'),' ',
            ...(p.hasClientProfile?[btn('Download client',()=>wireguardProfile(p.id),'btn-outline-secondary'),' ']:[]),
            btn('Remove',()=>confirmDo('Remove peer','Delete '+p.id+' and its saved client credentials?',
              ()=>apply('wireguard.peerremove',{id:p.id},'Peer removed'),'Remove'),'btn-outline-danger')))),
        'No peers configured. Add a peer to generate or import a public key.'))
  ];
}
function simpleAddonPage(id,fields,title,note){
  if(!uxInstalled(id))return uxNoInstall(id);
  const x=uxSettings(id),s=moduleState(id);
  const change=()=>form(title,fields.map(f=>({...f,
    value:(x[f.k]!==undefined && f.type!=='password'?x[f.k]:f.value),
    options:f.choices==='lan'?(S.interfaces||[]).filter(i=>i.role==='lan').map(i=>[i.name,i.name+(i.label?' · '+i.label:'')]):f.options
  })),v=>apply(id+'.configure',v,'Configuration saved; start when ready'),{note});
  return [...uxTop(id,[btn('Configure',change,'btn-primary')]),
    card('Configuration',null,uxBody(uxHelp(note), ...Object.entries(x)
      .filter(([k])=>!['token','privateKey','psk'].includes(k))
      .map(([k,v])=>h('div',{class:'small mb-2'},h('strong',{},k+': '),
        typeof v==='object'?JSON.stringify(v):String(v))),!Object.keys(x).length&&'Not configured'))];
}
function multiwanPanel(){
  if(!uxInstalled('multiwan'))return uxNoInstall('multiwan');
  const x=uxSettings('multiwan');
  let uplinks=(x.uplinks||[]).map(u=>({...u}));
  const display=h('div',{});
  const actions=h('div',{class:'d-flex gap-2 flex-wrap mb-3'},
    btn('Add WAN uplink',()=>edit(-1),'btn-primary'),
    btn('Save WAN configuration',async()=>{
      if(uplinks.length<2)return toast('Configure at least two WAN links before saving.','warning');
      try{await apply('multiwan.configure',{uplinks,enabled:false},'WAN failover configuration saved; use Start to activate.')}catch(e){uxError(e)}
    },'btn-outline-success'));
  function paint(){
    display.replaceChildren(table(['Preference','WAN','Gateway','Actions'],uplinks.map((u,i)=>h('tr',{},
      h('td',{},String(u.priority)),h('td',{class:'mono'},u.interface),h('td',{class:'mono'},u.gateway),
      h('td',{class:'text-end'},btn('Edit',()=>edit(i),'btn-outline-primary'),' ',
        btn('Remove',()=>{uplinks.splice(i,1);paint()},'btn-outline-danger')))),
      'No uplinks added. Add a primary and at least one backup.'));
  }
  function edit(index){
    const old=index>=0?uplinks[index]:{};
    form(index>=0?'Edit uplink':'Add WAN uplink',[
      {k:'interface',label:'WAN interface',type:'select',value:old.interface||'',options:(S.interfaces||[])
         .filter(i=>i.role==='wan'||i.role==='none').map(i=>[i.name,i.name+(i.label?' · '+i.label:'')])},
      {k:'gateway',label:'Gateway IPv4',value:old.gateway||'',placeholder:'192.0.2.1'},
      {k:'priority',label:'Priority (lower = preferred)',type:'number',value:old.priority||10}
    ],v=>{
      const item={interface:v.interface,gateway:v.gateway,priority:Number(v.priority)};
      if(uplinks.some((u,i)=>i!==index&&u.interface===item.interface))throw new Error('Each WAN interface can only be listed once.');
      if(index>=0)uplinks[index]=item;else uplinks.push(item);
      uplinks.sort((a,b)=>a.priority-b.priority);paint();
    },{note:'Stage all WAN interfaces locally, then save them together. Saving does not switch routes.'});
  }
  paint();
  return [...uxTop('multiwan',[]),card('WAN failover priority',null,
    uxBody(uxHelp('Lower priority numbers are preferred. Stage at least two links, then save. Start requires a console/rollback plan.'),actions,display))];
}
function frrPanel(){
  if(!uxInstalled('frr'))return uxNoInstall('frr');
  const x=uxSettings('frr'),neighbors=x.neighbors||[],nets=x.networks||[];
  const save=(updates)=>apply('frr.configure',{...x,...updates},'BGP configuration saved; restart required');
  const addNeighbor=()=>{if(!x.asn)return toast('Configure the local BGP AS and router ID first.','warning');return form('Add BGP neighbor',[
    {k:'address',label:'Peer IPv4 address',placeholder:'192.0.2.2'},
    {k:'remoteAs',label:'Peer AS number',type:'number',value:64513}
  ],v=>save({neighbors:[...neighbors,{address:v.address,remoteAs:Number(v.remoteAs)}]}));};
  const addNetwork=()=>{if(!x.asn)return toast('Configure the local BGP AS and router ID first.','warning');return form('Advertise IPv4 prefix',[
    {k:'prefix',label:'Advertised network CIDR',placeholder:'10.30.0.0/24'}
  ],v=>save({networks:[...nets,v.prefix]}));};
  return [...uxTop('frr',[
    btn('BGP settings',()=>form('BGP router settings',[
      {k:'asn',label:'Local AS number',type:'number',value:x.asn||64512},
      {k:'routerId',label:'Router ID (IPv4)',value:x.routerId||'10.0.0.1'}
    ],v=>save({asn:Number(v.asn),routerId:v.routerId})),'btn-primary')
  ]),
    card('BGP neighbors',[btn('Add neighbor',addNeighbor,'btn-primary')],
      table(['Peer','Remote AS','Actions'],neighbors.map(n=>h('tr',{},
        h('td',{class:'mono'},n.address),h('td',{},n.remoteAs),
        h('td',{class:'text-end'},btn('Remove',()=>save({neighbors:neighbors.filter(t=>t.address!==n.address)}),'btn-outline-danger')))),
      'No peers configured')),
    card('Advertised prefixes',[btn('Add prefix',addNetwork,'btn-primary')],
      table(['CIDR','Action'],nets.map(n=>h('tr',{},h('td',{class:'mono'},n),
        h('td',{class:'text-end'},btn('Remove',()=>save({networks:nets.filter(t=>t!==n)}),'btn-outline-danger')))),
      'Nothing advertised by default.'))];
}
views['module-geoip']=geoipPanel;
views['module-suricata']=suricataPanel;
views['module-wireguard']=wireguardPanel;
views['module-multiwan']=multiwanPanel;
views['module-frr']=frrPanel;
views['module-mdns']=()=>simpleAddonPage('mdns',[
  {k:'interfaces',label:'LAN segments to bridge via mDNS',type:'multi',choices:'lan'}
],'mDNS reflector','Select at least two LAN interfaces. WAN interfaces are never included.');
views['module-captive']=()=>simpleAddonPage('captive',[
  {k:'interface',label:'Guest LAN interface',type:'select',choices:'lan'},
  {k:'gatewayName',label:'Guest portal title',value:'LiteFW Guest'}
],'Guest captive portal','Use a dedicated guest interface. Captive portal activation is explicit; the management interface remains LAN-only.');
views['module-cloudflared']=()=>simpleAddonPage('cloudflared',[
  {k:'token',label:'Cloudflare tunnel token',type:'password',value:'',help:'Paste the tunnel connector token from Cloudflare Zero Trust. Leave blank later to preserve the existing token.'}
],'Cloudflare Tunnel','Cloudflare Tunnel is outbound-only. Create the tunnel and public hostname mappings in Cloudflare Zero Trust, then paste the connector token.');
views['module-crowdsec']=()=>simpleAddonPage('crowdsec',[
  {k:'enabled',label:'Enable local CrowdSec ban remediation',type:'check',value:false}
],'CrowdSec detection and remediation','CrowdSec needs an available supported engine and local API to synchronize security decisions. LiteFW owns the resulting firewall rules.');
load();
