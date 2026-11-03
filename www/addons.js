'use strict';
// Optional LiteFW add-on pages. Loaded after app.js so each page shares the
// existing resource loader, modal forms and authenticated operation layer.
const ADDON_FIELDS = {
  suricata: [
    {k:'interface',label:'Capture interface',type:'select',choices:'interfaces'},
    {k:'mode',label:'Inspection mode',type:'select',value:'ids',options:[['ids','IDS — detect only'],['ips','IPS — NFQUEUE inline (advanced)']]}
  ],
  geoip: [
    {k:'countries',label:'Blocked countries (ISO-3166 two-letter codes)',type:'list',value:['ru','cn'],help:'CIDR feeds are retrieved only on explicit Refresh. Blocking applies to IPv4 sources.'},
    {k:'enabled',label:'Enable blocking after a successful list refresh',type:'check',value:false}
  ],
  crowdsec: [
    {k:'enabled',label:'Enable CrowdSec detection and LiteFW-managed IP blocking',type:'check',value:false}
  ],
  wireguard: [
    {k:'interface',label:'WireGuard interface',value:'wg0'},
    {k:'address',label:'Tunnel address (CIDR)',value:'10.240.0.1/24'},
    {k:'listenPort',label:'UDP listen port',type:'number',value:51820},
    {k:'privateKey',label:'Private key',type:'password',help:'Generate with wg genkey; blank on edit retains the stored key. Never returned to the browser.'},
    {k:'peersJson',label:'Peers (JSON array)',type:'textarea',rows:7,value:'[]',help:'Example: [{"publicKey":"<base64>","allowedIPs":"10.240.0.2/32","endpoint":"vpn.example.org:51820"}]'}
  ],
  cloudflared: [
    {k:'token',label:'Cloudflare tunnel token',type:'password',help:'Remotely managed tunnel token; saved root-only. Configuration is outbound-only.'}
  ],
  multiwan: [
    {k:'uplinksJson',label:'WAN uplinks (JSON array)',type:'textarea',rows:7,
     value:'[{"interface":"eth0","gateway":"192.0.2.1","priority":10},{"interface":"eth2","gateway":"198.51.100.1","priority":20}]',
     help:'Minimum two uplinks; lower priority value is preferred. Saving alone never changes the active default route.'},
    {k:'enabled',label:'Enable monitoring on next Start',type:'check',value:false}
  ],
  mdns: [
    {k:'interfaces',label:'LAN segments for reflection',type:'multi',choices:'lan',help:'Two or more LAN interfaces only; never use WAN.'}
  ],
  captive: [
    {k:'interface',label:'Guest LAN interface',type:'select',choices:'lan'},
    {k:'gatewayName',label:'Portal display name',value:'LiteFW Guest'}
  ],
  frr: [
    {k:'asn',label:'Local BGP AS number',type:'number',value:64512},
    {k:'routerId',label:'BGP router ID (IPv4)',value:'10.0.0.1'},
    {k:'neighborsJson',label:'BGP neighbors (JSON array)',type:'textarea',rows:5,value:'[{"address":"192.0.2.2","remoteAs":64513}]',
     help:'Explicit peers only. Verify remote AS and routes before enabling.'},
    {k:'networks',label:'Advertised IPv4 prefixes',type:'list',value:[],help:'Only configured prefixes are advertised. No implicit redistribution.'}
  ]
};
function addonForm(id) {
  const m=moduleBy(id); if(!m || !m.installed) return;
  const settings=moduleState(id).settings||{};
  const fields=ADDON_FIELDS[id].map(f=>{
    const copy={...f};
    if(f.choices==='lan'||f.choices==='interfaces'){
      let ifs=(S.interfaces||[]).filter(x=>x.name && x.kind!=='loopback');
      if(f.choices==='lan') ifs=ifs.filter(x=>x.role==='lan');
      copy.options=ifs.map(x=>[x.name,x.name+(x.role?' ('+x.role+')':'')]);
      delete copy.choices;
    }
    if(copy.k.endsWith('Json')) {
      const target=copy.k.slice(0,-4);
      if(settings[target]!=null) copy.value=JSON.stringify(settings[target],null,2);
    } else if(settings[copy.k]!==undefined && !['privateKey','token'].includes(copy.k)){
      copy.value=settings[copy.k];
    }
    return copy;
  });
  form('Configure '+m.name,fields,v=>{
    const body={...v};
    for(const key of Object.keys(body)){
      if(key.endsWith('Json')){
        const field=key.slice(0,-4);
        try { body[field]=JSON.parse(body[key]); }
        catch(e){ throw new Error('Invalid JSON in '+key+': '+e.message); }
        delete body[key];
      }
    }
    if(id==='geoip') body.countries=(body.countries||[]).map(x=>x.toLowerCase());
    if(id==='frr') {body.asn=Number(body.asn);body.networks=body.networks||[];}
    if(id==='wireguard') body.listenPort=Number(body.listenPort);
    if(id==='multiwan') body.uplinks=(body.uplinks||[]).map(x=>({...x,priority:Number(x.priority)}));
    return apply(id+'.configure',body,m.name+' settings saved');
  },{
    note: id==='multiwan'?'Save the candidate WAN gateways without activating them. Start explicitly to enable failover; verify out-of-band access first.':
      id==='suricata'?'IDS captures traffic without enforcement. IPS uses an inline NFQUEUE; verify rules and fail-open behavior before enabling on production traffic.':
      id==='geoip'?'Refresh downloads IPdeny country CIDR feeds and loads the ipset before enabling rules. Country databases are approximate.':
      id==='crowdsec'?'CrowdSec requires a compatible firewall bouncer for automatic blocking. Detection alone does not create firewall rules.':
      id==='captive'?'Captive portal applies only to an isolated guest network. Validate openNDS compatibility with LiteFW firewall reloads before production use.':
      id==='frr'?'BGP changes must be reviewed carefully. Incorrect advertisements can create significant routing outages.':
      'Saving does not start or expose a service; enable it explicitly when ready.',
    applyText:'Validate and save'
  });
}
function addonPanel(id){
  const m=moduleBy(id);
  if(!m)return [card('Module missing',null,h('div',{class:'card-body'},'Module catalog is unavailable.'))];
  if(!m.installed)return [
    h('div',{class:'mb-3'},btn('Back to modules',()=>location.hash='#modules')),
    card(m.name,[btn('Install',()=>moduleInstall(m),'btn-primary')],h('div',{class:'card-body'},m.description))
  ];
  const state=moduleState(id),settings=state.settings||{},working=!!state.running;
  const details=Object.entries(settings).filter(([k])=>!['credentialConfigured','token','privateKey','psk'].includes(k))
    .map(([k,v])=>h('div',{class:'small mb-1'},
      h('strong',{},k+': '),
      h('span',{class:'mono'},typeof v==='object'?JSON.stringify(v):String(v))));
  return [
    h('div',{class:'mb-3'},btn('Back to modules',()=>location.hash='#modules')),
    card(m.name,[
      badge(working?'running':'stopped',working?'text-bg-success':'text-bg-secondary'),
      btn('Configure',()=>addonForm(id),'btn-primary'),
      ...(id==='geoip'?[btn('Refresh country lists',()=>apply('geoip.refresh',{},'GeoIP lists refreshed'),'btn-outline-primary')]:[]),
      ...(id==='crowdsec'?[btn('Sync decisions',()=>apply('crowdsec.decisionssync',{},'CrowdSec IP bans refreshed'),'btn-outline-primary')]:[]),
      ...(id==='suricata'?[btn('Update signatures',()=>apply('suricata.rulesupdate',{},'Suricata rule update completed'),'btn-outline-primary')]:[]),
      ...moduleServiceButtons(id+'.service',working,!!state.configured)
    ],h('div',{class:'card-body'},
      h('p',{class:'text-secondary small'},m.description),
      ...(details.length?details:[h('p',{class:'small'},'No configuration saved yet.')]),
      ...(id==='crowdsec'?[h('p',{class:'small text-warning mt-2'},'LiteFW syncs CrowdSec IPv4 bans into its firewall-owned IP set. Community intelligence requires CrowdSec LAPI connectivity.')]:[]),
      ...(id==='multiwan'?[h('p',{class:'small text-warning mt-2'},'Starting changes routing only after gateway health checks; verify console access before activation.')]:[])
    ))
  ];
}
for(const id of Object.keys(ADDON_FIELDS)){
  VIEW_APIS['module-'+id]=['segments','system','modules/'+id];
  views['module-'+id]=()=>addonPanel(id);
}
// Extend the existing System page, preserving its original controls.
const litefwOriginalSystemView=views.system;
views.system=()=>{
  const root=litefwOriginalSystemView();
  const x=(S.system&&S.system.telemetry)||{},label=x.otlpEnabled?'Enabled':'Disabled';
  root.append(h('div',{class:'col-12'},
    card('Telemetry export — Prometheus / OpenTelemetry',
      [btn('Configure',()=>form('Telemetry export',[
        {k:'prometheus',label:'Enable authenticated Prometheus metrics endpoint',type:'check',value:!!x.prometheus,
         help:'Available at /api/telemetry/metrics over the existing LAN-only authenticated management listener.'},
        {k:'otlpEnabled',label:'Push OpenTelemetry OTLP/HTTP metrics',type:'check',value:!!x.otlpEnabled},
        {k:'endpoint',label:'OTLP HTTPS endpoint (/v1/metrics)',value:x.endpoint||'',placeholder:'https://collector.example.net/v1/metrics',show:v=>v.otlpEnabled},
        {k:'token',label:'Bearer token',type:'password',value:'',show:v=>v.otlpEnabled,
         help:x.tokenConfigured?'Blank preserves existing token.':'Optional for collectors that allow unauthenticated HTTPS ingestion.'},
        {k:'intervalMinutes',label:'Push interval',type:'select',value:String(x.intervalMinutes||5),
         options:[['5','5 minutes'],['15','15 minutes'],['30','30 minutes'],['60','60 minutes']],show:v=>v.otlpEnabled}
      ],v=>apply('telemetry.set',{...v,intervalMinutes:Number(v.intervalMinutes||5)},'Telemetry settings saved'),
      {note:'LiteFW exports metrics, not centralized logs. Never expose management metrics on WAN.'}),'btn-primary')],
      h('div',{class:'card-body small'},
        h('div',{},'Prometheus: ',x.prometheus?'Enabled (Basic Auth, LAN only)':'Disabled'),
        h('div',{},'OTLP: ',label),
        h('div',{},'Collector: ',x.endpoint||'Not configured'),
        x.prometheus?h('div',{class:'mono mt-2'},'/api/telemetry/metrics'):null
      ))
  ));
  return root;
};
// Start the initial view only once the add-on routes are registered.
load();
