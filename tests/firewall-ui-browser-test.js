'use strict';
// Headless Chromium smoke for LiteFW's unified firewall browser workflow.
// Requires playwright-core and an HTTP mock server (mock-firewall-ui-server.py).
const assert=require('assert');
const {chromium}=require(process.env.PLAYWRIGHT_CORE || 'playwright-core');

(async()=>{
  const browser=await chromium.launch({
    executablePath:process.env.CHROME || '/usr/bin/chromium-browser',
    headless:true,args:['--no-sandbox','--disable-dev-shm-usage']
  });
  try{
    const p=await browser.newPage({viewport:{width:1330,height:940}});
    const errors=[];
    p.on('pageerror',e=>errors.push(e.message));
    await p.goto('http://127.0.0.1:8097/#firewall');
    await p.waitForFunction(()=>document.querySelector('#statusText').textContent==='Connected');
    const unified=p.locator('.card',{hasText:'Traffic rules — one ordered policy'});
    assert.strictEqual(await unified.count(),1);
    assert.strictEqual(await unified.locator('.rule-list li').count(),3);
    assert.strictEqual(await p.locator('#advToggle').count(),0);
    assert.strictEqual(await p.locator('.card',{hasText:'Input rules (filter INPUT)'}).count(),0);
    assert.strictEqual(await p.locator('.card',{hasText:'Forwarding rules (filter FORWARD)'}).count(),0);

    // New wizard is source/destination based; no nftables syntax involved.
    await p.getByRole('button',{name:'+ New rule…'}).click();
    await p.selectOption('#f_action','drop');
    await p.selectOption('#f_fromScope','host');
    await p.selectOption('#f_toScope','wan');
    await p.selectOption('#f_proto','udp');
    await p.fill('#f_ports','5353');
    await p.fill('#f_description','local host multicast');
    await p.selectOption('#f_position','top');
    await p.click('#dlgApply'); // review, not kernel apply
    assert((await p.locator('#dlgBody').textContent()).includes('this firewall'));
    assert((await p.locator('#dlgBody').textContent()).includes('WAN'));
    assert(!(await p.locator('#dlgBody').textContent()).includes('nft add'));
    await p.click('#dlgApply'); // add to local draft
    await p.waitForFunction(()=>document.querySelector('#view').textContent.includes('local host multicast'));
    assert.strictEqual(await unified.locator('.rule-list li').count(),4);
    const first=unified.locator('.rule-list li').first();
    assert((await first.textContent()).includes('local host multicast'));
    assert((await p.locator('#view').textContent()).includes('UNSAVED DRAFT'));

    // Update in same plain-language editor.
    await first.getByRole('button',{name:'Edit'}).click();
    assert.strictEqual(await p.inputValue('#f_fromScope'),'host');
    await p.fill('#f_ports','5353,853');
    await p.click('#dlgApply');
    await p.waitForFunction(()=>document.querySelector('#view').textContent.includes('UDP 5353,853'));

    // WAN to this firewall lives in the same ordered policy.
    await p.getByRole('button',{name:'+ New rule…'}).click();
    await p.selectOption('#f_fromScope','wan');
    await p.selectOption('#f_toScope','host');
    await p.selectOption('#f_proto','tcp');
    await p.fill('#f_src','198.51.100.10-198.51.100.50');
    await p.fill('#f_srcPorts','1024-65535');
    await p.fill('#f_ports','22');
    await p.fill('#f_description','restricted host admin');
    await p.click('#dlgApply');
    assert((await p.locator('#dlgBody').textContent()).includes('source port 1024-65535'));
    await p.click('#dlgApply');
    await p.waitForFunction(()=>document.querySelector('#view').textContent.includes('restricted host admin'));
    assert.strictEqual(await unified.locator('.rule-list li').count(),5);

    // Existing guided recipes still exist.
    await p.getByRole('button',{name:'Guided examples…'}).click();
    assert.strictEqual(await p.locator('button.intent').count(),6);
    assert((await p.locator('#dlgBody').textContent()).includes('Publish a service'));
    await p.getByRole('button',{name:'Cancel'}).click();
    assert.deepStrictEqual(errors,[]);
    console.log('PASS Chromium wizard: source/destination selection, host paths, ports/ranges, staged list, editing and guided examples');
  }finally{
    await browser.close();
  }
})().catch(err=>{console.error(err);process.exit(1);});