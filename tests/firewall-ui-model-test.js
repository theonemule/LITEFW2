'use strict';
// Dependency-free UI model smoke: node tests/firewall-ui-model-test.js
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
class NodeMock {
  constructor(tag, value = '') {
    this.tag = tag;
    this.attrs = {};
    this.children = [];
    this.value = value;
    this._text = value;
    this.classList = { add() {}, remove() {}, toggle() {}, contains() { return false; } };
  }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = [...children]; }
  setAttribute(k,v) { this.attrs[k] = v; }
  getAttribute(k) { return this.attrs[k] || null; }
  addEventListener() {}
  cloneNode() { return new NodeMock(this.tag,this._text); }
  get textContent() { return this._text + this.children.map(c => c.textContent || '').join(''); }
  set textContent(v) { this._text = String(v); this.children = []; }
}
const els = new Map();
const get = id => {
  if (!els.has(id)) els.set(id,new NodeMock('fixture'));
  return els.get(id);
};
const sandbox = {
  Node: NodeMock,
  document: {
    createElement:tag=>new NodeMock(tag),
    createTextNode:value=>new NodeMock('#text',value),
    querySelector:get,
    querySelectorAll:()=>[]
  },
  window:{addEventListener(){}},
  location:{hash:'#firewall'},
  bootstrap:{Modal:{getOrCreateInstance:()=>({_isTransitioning:false,show(){},hide(){}})}},
  fetch:()=>Promise.reject(Error('UI-only test')),
  console
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync('www/app.js','utf8'),sandbox,{filename:'www/app.js'});
const run = expr => vm.runInContext(expr,sandbox);
const state = {
  system:{management:{port:80,access:['any']},ssh:{enabled:false}},
  interfaces:[
    {name:'eth0',label:'WAN',kind:'physical',role:'wan',master:'',addresses:['198.51.100.2/24']},
    {name:'eth1',label:'Office',kind:'physical',role:'lan',master:'',addresses:['192.168.10.1/24']}
  ],
  firewall:{
    policies:{INPUT:'DROP',FORWARD:'DROP',OUTPUT:'ACCEPT'},masquerade:['eth0'],
    rules:[
      {id:'11111111',chain:'forward',action:'accept',in:'eth1',out:'eth0',src:'',dst:'',proto:'tcp',ports:'443',managed:true,raw:'test'},
      {id:'22222222',chain:'input',action:'drop',in:'eth0',out:'',src:'',dst:'',proto:'icmp',ports:'',managed:true,raw:'test'},
      {id:'33333333',chain:'output',action:'drop',in:'',out:'eth0',src:'',dst:'',proto:'udp',ports:'53',managed:true,raw:'test'}
    ],forwards:[]
  },
  dhcp:{leases:[],reservations:[]}
};
sandbox.fixtureState=state;
run('S=fixtureState; initFwDraft(S.firewall)');
const fields=run('ruleEditorFields(null)');
const scopes=fields.find(f=>f.k==='fromScope').options;
assert(scopes.some(x=>x[0]==='wan'));
assert(scopes.some(x=>x[0]==='host'));
assert(scopes.some(x=>x[0]==='iface:eth1'));
assert(fields.some(f=>f.k==='srcPorts'));
assert(fields.some(f=>f.k==='ports'));
assert(fields.some(f=>f.k==='position'));
const inputValues={
  fromScope:'wan',toScope:'host',proto:'tcp',ports:'8443',srcPorts:'1024-65535',
  src:'198.51.100.1-198.51.100.50',dst:'',action:'reject',description:'Restricted host'
};
sandbox.inputValues=inputValues;
const input=JSON.parse(JSON.stringify(run('ruleFromValues(inputValues)')));
assert.strictEqual(input.chain,'input');
assert.strictEqual(input.source.address,inputValues.src);
assert.strictEqual(input.source.ports,'1024-65535');
assert.strictEqual(input.destination.scope,'host');
sandbox.badValues={fromScope:'host',toScope:'host',proto:'any',action:'accept'};
assert.throws(()=>run('ruleFromValues(badValues)'),/loopback/);
sandbox.inputRule=input;
const sentence=run('ruleSentence(inputRule)');
assert(sentence.includes('WAN')&&sentence.includes('this firewall')&&sentence.includes('source port 1024-65535'));
const text=run('views.firewall()').map(n=>n.textContent).join(' ');
assert(text.includes('Traffic rules — one ordered policy'));
assert(text.includes('Office')&&text.includes('WAN'));
assert(text.includes('this firewall'));
assert(!text.includes('Forwarding rules (filter FORWARD)'));
assert(!text.includes('Input rules (filter INPUT)'));
assert(!text.includes('Technical details'));
assert(!text.includes('Advanced (manual rules)'));
assert(!text.includes('iptables -')&&!text.includes('nft -'));
run("wizard('custom')");
assert(get('#dlgBody').textContent.includes('Source'));
assert(get('#dlgBody').textContent.includes('Destination'));
assert(get('#dlgBody').textContent.includes('Priority'));
assert(run('INTENTS').some(i=>i.id==='internet'));
assert(run('INTENTS').some(i=>i.id==='publish'));
console.log('PASS unified firewall UI model: scope choices, IP/range and port editing, one policy list, plain-language wizard');