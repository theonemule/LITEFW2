// Browser test of the LiteFWM UI against the lab (tests/lab.sh ui). Drives the real forms and
// the rule wizard, and verifies every change on the machine (/api/state) and with real traffic.
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'playwright-core');
const { execSync } = require('child_process');
const API = process.env.API, LAN = process.env.LAN, TRUNK = process.env.TRUNK;
const FWIP = API.replace(/^https?:\/\//, '');
const auth = 'Basic ' + Buffer.from('admin:labpass123').toString('base64');
const state = async () => (await fetch(API + '/api/state', { headers: { Authorization: auth } })).json();
const sh = cmd => { try { return execSync(cmd, { stdio: ['ignore', 'pipe', 'ignore'], timeout: 20000 }).toString(); } catch { return null; } };
const lanNet = () => sh(`sudo docker exec lfwlab-lan1 wget -q -T 4 -O - http://10.250.0.2/`) !== null;
const fromIsp = port => sh(`sudo docker exec lfwlab-isp wget -q -T 4 -O - http://${FWIP}:${port}/`);
let fails = 0; const ok = (c, m) => { console.log((c ? '  ok   ' : '  FAIL ') + m); if (!c) fails++; };

(async () => {
  const b = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
  const ctx = await b.newContext({ httpCredentials: { username: 'admin', password: 'labpass123' }, viewport: { width: 1400, height: 900 } });
  const p = await ctx.newPage(); const errs = [];
  p.on('pageerror', e => errs.push(e.message));
  p.on('console', m => { if (m.type() === 'error' && !/status of 400/.test(m.text())) errs.push(m.text()); });
  const go = async v => { await p.goto(API + '/#' + v); await p.waitForSelector(`#sideNav a.active[href="#${v}"]`); await p.waitForTimeout(250); };
  const settle = async () => { await p.waitForFunction(() => !document.querySelector('#dlg').classList.contains('show') || document.querySelector('#dlgErr').textContent, null, { timeout: 60000 }); };
  const applyDlg = async () => { await p.click('#dlgApply'); await settle();
    const e = await p.textContent('#dlgErr'); if (e) { await p.click('#dlg .btn-secondary'); await p.waitForTimeout(400); } else await p.waitForTimeout(700); return e; };
  const next = async () => { await p.click('#dlgApply'); await p.waitForTimeout(300); return p.textContent('#dlgErr'); };
  const row = txt => p.locator('tr', { hasText: txt });
  const li = txt => p.locator('.rule-list li', { hasText: txt });
  const startWizard = async id => { await go('firewall'); await p.click('text=+ New rule…'); await p.click(`button.intent[data-intent="${id}"]`); await p.waitForTimeout(200); };
  let e, st;

  console.log('== layout');
  for (const [v, t] of [['overview', 'Overview'], ['interfaces', 'Interfaces'], ['segments', 'Network segments'], ['firewall', 'Firewall & port forwards'], ['dhcp', 'DHCP'], ['dns', 'DNS'], ['system', 'System']]) {
    await go(v); ok(await p.isVisible('aside.sidebar') && (await p.textContent('#pageTitle')) === t, `sidebar + title on #${v}`);
  }
  await p.goto(API + '/#forwards'); await p.waitForSelector('#sideNav a.active[href="#firewall"]'); ok((await p.textContent('#pageTitle')) === 'Firewall & port forwards', 'old #forwards link lands on the firewall page');
  ok((await p.textContent('#statusText')) === 'Connected', 'status footer shows Connected');

  console.log('== wizard: internet access (real traffic)');
  st = await state();
  const lanwan = st.firewall.rules.find(r => r.chain === 'forward' && r.in === LAN);
  await go('firewall');
  if (lanwan) { await li(lanwan.description || 'LAN').getByRole('button', { name: 'Delete' }).click(); e = await applyDlg(); ok(!e, 'delete the existing LAN rule from the plain-language list'); }
  ok(!lanNet(), 'lan1 cannot reach the internet with no rule');
  await startWizard('internet');
  await p.selectOption('#f_from', LAN); await p.selectOption('#f_svc', 'web');
  ok(!(await next()), 'details accepted');
  ok(/Allow LAN → the internet · TCP 80,443/.test(await p.textContent('#dlgBody')), 'review shows a plain-English sentence');
  e = await applyDlg(); ok(!e, 'wizard created the rule ' + (e || ''));
  ok(lanNet(), 'lan1 now reaches the internet (web)');
  ok(await li('Allow LAN → the internet').count() === 1, 'rule listed as a sentence');

  console.log('== wizard: block one device (real traffic)');
  st = await state(); const l1 = st.dhcp.leases.find(l => l.ip.startsWith('192.168.10.'));
  await startWizard('block');
  await p.selectOption('#f_from', LAN); await p.selectOption('#f_sscope', 'device'); await p.selectOption('#f_sdev', l1.ip);
  await p.selectOption('#f_to', 'internet'); await p.selectOption('#f_svc', 'any');
  await next(); e = await applyDlg(); ok(!e, 'block rule created ' + (e || ''));
  st = await state(); const fr = st.firewall.rules.filter(r => r.chain === 'forward');
  ok(fr[0].action === 'reject' && fr[0].src === l1.ip, 'block rule placed first');
  ok(!lanNet(), 'lan1 is blocked although the segment is allowed');
  await go('firewall'); await li('Block').getByRole('button', { name: 'Delete' }).click(); e = await applyDlg();
  ok(!e && lanNet(), 'removing the block restores access');

  console.log('== wizard: publish a service (port forward + reservation, real traffic)');
  await startWizard('publish');
  await p.selectOption('#f_dev', l1.ip); ok(await p.isChecked('#f_static'), 'offers to make the dynamic device static');
  await p.selectOption('#f_svc', 'http'); await p.fill('#f_ext', '8088');
  await next();
  const rv = await p.textContent('#dlgBody');
  ok(/Reserve/.test(rv) && /TCP 8088 on this firewall is forwarded to .* port 80/.test(rv), 'review lists reservation + forward');
  e = await applyDlg(); ok(!e, 'publish applied ' + (e || ''));
  st = await state();
  ok(st.dhcp.reservations.some(r => r.ip === l1.ip && r.mac === l1.mac), 'reservation created on the machine');
  ok(/hello from lan1/.test(fromIsp(8088) || ''), 'internet → firewall:8088 reaches lan1:80');
  await go('firewall'); ok(await li('forwarded to').count() === 1, 'port forward listed as a sentence');
  await li('forwarded to').getByRole('button', { name: 'Delete' }).click(); e = await applyDlg();
  ok(!e && fromIsp(8088) === null, 'deleting the forward closes the port');
  await go('dhcp'); await row(l1.mac).last().getByRole('button', { name: 'Delete' }).click(); e = await applyDlg();

  console.log('== wizard: preconditions and firewall access');
  await startWizard('between');
  ok(/at least two LAN segments/.test(await p.textContent('#dlgBody')), 'between-segments explains it needs two LANs');
  await p.click('#dlgBack'); ok(await p.locator('button.intent').count() === 5, 'Back returns to the intent choice');
  await p.click('#dlg .btn-secondary'); await p.waitForTimeout(400);
  for (const r of (await state()).firewall.rules.filter(r => r.chain === 'input'))
    await fetch(API + '/api/op/rule.delete', { method: 'POST', headers: { Authorization: auth, 'X-LiteFWM': '1' }, body: JSON.stringify({ id: r.id }) });
  ok(sh(`sudo docker exec lfwlab-isp ping -c1 -W2 ${FWIP}`) === null, 'ping from the internet blocked by default');
  await startWizard('fwaccess');
  st = await state(); const wanIf = st.interfaces.find(i => i.role === 'wan').name;
  await p.selectOption('#f_from', wanIf); await next(); e = await applyDlg();
  ok(!e && sh(`sudo docker exec lfwlab-isp ping -c1 -W2 ${FWIP}`) !== null, 'ping from the internet allowed by an access rule');
  await go('firewall'); await li('this firewall · ping').getByRole('button', { name: 'Delete' }).click(); await applyDlg();

  console.log('== advanced (manual) mode');
  await go('firewall'); await p.check('#advToggle');
  await p.locator('.card', { hasText: 'Forwarding rules (filter FORWARD)' }).getByRole('button', { name: 'Add rule' }).click();
  await p.selectOption('#f_action', 'reject'); await p.selectOption('#f_in', LAN); await p.fill('#f_src', '192.168.10.0/24');
  await p.selectOption('#f_proto', 'tcp'); await p.fill('#f_ports', '25'); await p.fill('#f_description', 'no smtp'); await p.selectOption('#f_position', '0');
  e = await applyDlg(); ok(!e, 'manual rule added ' + (e || ''));
  await row('no smtp').getByRole('button', { name: '↓' }).click(); await p.waitForTimeout(1500);
  st = await state(); ok(st.firewall.rules.filter(r => r.chain === 'forward')[1].description === 'no smtp', 'manual move down');
  await row('no smtp').getByRole('button', { name: 'Edit' }).click(); await p.fill('#f_ports', '25,465'); e = await applyDlg();
  st = await state(); ok(!e && st.firewall.rules.some(r => r.description === 'no smtp' && r.ports === '25,465'), 'manual edit');
  await row('no smtp').getByRole('button', { name: 'Delete' }).click(); e = await applyDlg();
  await p.uncheck('#advToggle');

  console.log('== DHCP: lease → static');
  await go('dhcp');
  st = await state(); const lease = st.dhcp.leases.find(l => l.ip.startsWith('192.168.10.'));
  await row(lease.mac).getByRole('button', { name: 'Make static' }).click();
  await p.fill('#f_ip', '192.168.10.60'); await p.fill('#f_hostname', 'webhost');
  e = await applyDlg(); st = await state();
  ok(!e && st.dhcp.reservations.some(r => r.mac === lease.mac && r.ip === '192.168.10.60'), 'promote lease via UI');
  await p.click('text=Add reservation'); await p.fill('#f_mac', '02:00:00:00:00:77'); await p.fill('#f_ip', '192.168.10.60');
  e = await applyDlg(); ok(/already reserved/.test(e || ''), 'conflict shown in dialog');
  await row('webhost').last().getByRole('button', { name: 'Delete' }).click(); await applyDlg();

  console.log('== L2/L3 forms');
  await go('interfaces'); await p.click('text=New bridge');
  await p.fill('#f_name', 'br5'); await p.check('#f_vlanFiltering'); await p.check('#f_members' + TRUNK);
  e = await applyDlg(); ok(!e, 'VLAN-aware bridge ' + (e || ''));
  await p.click('text=New VLAN'); await p.selectOption('#f_parent', 'br5'); await p.fill('#f_vid', '40');
  e = await applyDlg(); st = await state(); ok(!e && st.interfaces.some(i => i.name === 'br5.40'), 'VLAN 40');
  ok(await p.locator('.card', { hasText: 'VLAN membership — br5' }).count() === 1, 'VLAN membership card');
  await go('segments'); await row('br5.40').getByRole('button', { name: 'Edit' }).click();
  await p.fill('#f_label', 'Guest'); await p.selectOption('#f_role', 'lan'); await p.selectOption('#f_mode', 'static'); await p.fill('#f_addresses', '192.168.40.1/24');
  e = await applyDlg(); ok(!e, 'segment');
  await go('dhcp'); await row('br5.40').getByRole('button', { name: 'Configure' }).click();
  ok(await p.inputValue('#f_start') === '192.168.40.100', 'DHCP range suggested');
  e = await applyDlg(); ok(!e, 'DHCP server');
  await startWizard('between');
  await p.selectOption('#f_from', LAN); await p.selectOption('#f_to', 'br5.40'); await p.selectOption('#f_svc', 'ping'); await p.check('#f_reverse');
  await next(); ok((await p.locator('.review li').count()) === 2, 'between-segments + reverse makes two rules');
  e = await applyDlg(); st = await state(); ok(!e && st.firewall.rules.filter(r => r.proto === 'icmp' && r.chain === 'forward').length === 2, 'both rules created');
  for (const r of st.firewall.rules.filter(r => r.proto === 'icmp' && r.chain === 'forward')) await fetch(API + '/api/op/rule.delete', { method: 'POST', headers: { Authorization: auth, 'X-LiteFWM': '1' }, body: JSON.stringify({ id: r.id }) });
  await go('segments'); await row('br5.40').getByRole('button', { name: 'Edit' }).click(); await p.selectOption('#f_role', 'none'); await p.selectOption('#f_mode', 'none'); await applyDlg();
  await go('interfaces'); await row('br5.40').getByRole('button', { name: 'Delete' }).click(); e = await applyDlg(); ok(!e, 'delete VLAN');
  await p.locator('tr', { has: p.locator('td', { hasText: /^br5$/ }) }).getByRole('button', { name: 'Delete' }).click(); e = await applyDlg(); ok(!e, 'delete bridge');

  console.log('== mobile');
  const m = await ctx.newPage(); await m.setViewportSize({ width: 390, height: 844 });
  m.on('pageerror', e => errs.push(e.message));
  await m.goto(API + '/#overview'); await m.waitForSelector('#sideNav a.active', { state: 'attached' });
  ok(!(await m.isVisible('aside.sidebar')), 'sidebar hidden on a phone');
  await m.click('#menuBtn'); await m.waitForSelector('#mobileNav.show');
  await m.click('#mobileNavLinks a[href="#firewall"]'); await m.waitForTimeout(700);
  ok(!(await m.isVisible('#mobileNav.show')) && (await m.textContent('#pageTitle')) === 'Firewall & port forwards', 'menu navigates and closes');
  await m.screenshot({ path: '/tmp/lfwlab-ui-mobile-firewall.png', fullPage: true });
  await go('firewall'); await p.screenshot({ path: '/tmp/lfwlab-ui-firewall.png', fullPage: true });
  await p.click('text=+ New rule…'); await p.waitForTimeout(400); await p.screenshot({ path: '/tmp/lfwlab-ui-wizard.png' });

  st = await state();
  ok(!st.interfaces.some(i => i.name.startsWith('br5')) && !st.dhcp.reservations.length && !st.firewall.forwards.length, 'lab left clean');
  ok(errs.length === 0, 'no browser errors ' + JSON.stringify(errs));
  await b.close(); console.log(fails ? fails + ' UI failures' : 'UI flow passed'); process.exit(fails ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
