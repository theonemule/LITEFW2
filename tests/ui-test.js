// Browser test of the LiteFWM UI against the lab (tests/lab.sh ui). Drives the real forms and
// verifies every change on the machine through /api/state.
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'playwright-core');
const API = process.env.API, LAN = process.env.LAN, TRUNK = process.env.TRUNK;
const auth = 'Basic ' + Buffer.from('admin:labpass123').toString('base64');
const state = async () => (await fetch(API + '/api/state', { headers: { Authorization: auth } })).json();
let fails = 0; const ok = (c, m) => { console.log((c ? '  ok   ' : '  FAIL ') + m); if (!c) fails++; };
(async () => {
  const b = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
  const ctx = await b.newContext({ httpCredentials: { username: 'admin', password: 'labpass123' }, viewport: { width: 1400, height: 900 } });
  const p = await ctx.newPage(); const errs = [];
  p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error' && !/status of 400/.test(m.text())) errs.push(m.text()); });
  const go = async v => { await p.goto(API + '/#' + v); await p.waitForSelector(`#navLinks a.active[href="#${v}"]`); await p.waitForTimeout(200); };
  const applyDlg = async () => { await p.click('#dlgApply'); await p.waitForFunction(() => !document.querySelector('#dlg').classList.contains('show') || document.querySelector('#dlgErr').textContent, null, { timeout: 60000 });
    const e = await p.textContent('#dlgErr'); if (e) { await p.click('#dlg .btn-secondary'); await p.waitForTimeout(400); } else await p.waitForTimeout(600); return e; };
  const row = txt => p.locator('tr', { hasText: txt });

  // 1. promote a lease to static
  await go('dhcp');
  let st = await state(); const lease = st.dhcp.leases.find(l => l.ip.startsWith('192.168.10.'));
  await row(lease.mac).getByRole('button', { name: 'Make static' }).click();
  await p.fill('#f_ip', '192.168.10.60'); await p.fill('#f_hostname', 'webhost');
  let e = await applyDlg(); ok(!e, 'promote lease via UI ' + (e || ''));
  st = await state(); ok(st.dhcp.reservations.some(r => r.mac === lease.mac && r.ip === '192.168.10.60' && r.hostname === 'webhost'), 'reservation live on the machine');
  ok(await row(lease.mac).first().locator('text=static → 192.168.10.60').count() > 0, 'lease row shows static badge');
  // conflicting reservation shows an error in the dialog
  await p.click('text=Add reservation'); await p.fill('#f_mac', '02:00:00:00:00:77'); await p.fill('#f_ip', '192.168.10.60');
  e = await applyDlg(); ok(/already reserved/.test(e || ''), 'conflict error shown in dialog: ' + e);

  // 2. firewall rule through the form
  await go('firewall');
  await p.locator('.card', { hasText: 'Forwarding rules' }).getByRole('button', { name: 'Add rule' }).click();
  await p.selectOption('#f_action', 'reject'); await p.selectOption('#f_in', LAN); await p.fill('#f_src', '192.168.10.0/24');
  await p.selectOption('#f_proto', 'tcp'); await p.fill('#f_ports', '25'); await p.fill('#f_description', 'no smtp'); await p.selectOption('#f_position', '0');
  e = await applyDlg(); ok(!e, 'add rule via UI ' + (e || ''));
  st = await state(); const fr = st.firewall.rules.filter(r => r.chain === 'forward');
  ok(fr[0] && fr[0].description === 'no smtp' && fr[0].action === 'reject' && fr[0].ports === '25', 'rule is first in kernel');
  await row('no smtp').getByRole('button', { name: '↓' }).click(); await p.waitForTimeout(1500);
  st = await state(); ok(st.firewall.rules.filter(r => r.chain === 'forward')[1].description === 'no smtp', 'move down via UI');
  await row('no smtp').getByRole('button', { name: 'Edit' }).click(); await p.fill('#f_ports', '25,465'); e = await applyDlg();
  st = await state(); ok(!e && st.firewall.rules.some(r => r.description === 'no smtp' && r.ports === '25,465'), 'edit rule via UI');
  await row('no smtp').getByRole('button', { name: 'Delete' }).click(); e = await applyDlg();
  st = await state(); ok(!e && !st.firewall.rules.some(r => r.description === 'no smtp'), 'delete rule via UI');

  // 3. port forward
  await go('forwards'); await p.click('text=Add port forward');
  await p.fill('#f_port', '8443'); await p.fill('#f_to', '192.168.10.60'); await p.fill('#f_toPort', '443'); await p.fill('#f_description', 'proxy');
  e = await applyDlg(); st = await state(); ok(!e && st.firewall.forwards.some(f => f.port === '8443' && f.to === '192.168.10.60'), 'port forward via UI ' + (e || ''));
  await row('proxy').getByRole('button', { name: 'Delete' }).click(); e = await applyDlg();

  // 4. L2: bridge + VLAN + segment + DHCP via UI
  await go('interfaces'); await p.click('text=New bridge');
  await p.fill('#f_name', 'br5'); await p.check('#f_vlanFiltering'); await p.check('#f_members' + TRUNK);
  e = await applyDlg(); ok(!e, 'create VLAN-aware bridge via UI ' + (e || ''));
  await p.click('text=New VLAN'); await p.selectOption('#f_parent', 'br5'); await p.fill('#f_vid', '40');
  e = await applyDlg(); st = await state(); ok(!e && st.interfaces.some(i => i.name === 'br5.40' && i.vid === 40), 'VLAN 40 on br5 via UI ' + (e || ''));
  ok(await p.locator('.card', { hasText: 'VLAN membership — br5' }).count() === 1, 'VLAN membership card shown');
  await go('segments'); await row('br5.40').getByRole('button', { name: 'Edit' }).click();
  await p.fill('#f_label', 'Guest'); await p.selectOption('#f_role', 'lan'); await p.selectOption('#f_mode', 'static'); await p.fill('#f_addresses', '192.168.40.1/24');
  e = await applyDlg(); ok(!e, 'segment via UI ' + (e || ''));
  await go('dhcp'); await row('br5.40').getByRole('button', { name: 'Configure' }).click();
  ok(await p.inputValue('#f_start') === '192.168.40.100', 'DHCP range pre-suggested');
  e = await applyDlg(); st = await state(); ok(!e && st.interfaces.find(i => i.name === 'br5.40').dhcpServer.enabled, 'DHCP server via UI ' + (e || ''));
  await p.screenshot({ path: '/tmp/lfwlab-ui-dhcp-after.png', fullPage: true });
  await go('interfaces'); await p.screenshot({ path: '/tmp/lfwlab-ui-interfaces-after.png', fullPage: true });
  // cleanup through UI
  await go('segments'); await row('br5.40').getByRole('button', { name: 'Edit' }).click(); await p.selectOption('#f_role', 'none'); await p.selectOption('#f_mode', 'none'); e = await applyDlg();
  await go('interfaces'); await row('br5.40').getByRole('button', { name: 'Delete' }).click(); e = await applyDlg(); ok(!e, 'delete VLAN via UI ' + (e || ''));
  await p.locator('tr', { has: p.locator('td', { hasText: /^br5$/ }) }).getByRole('button', { name: 'Delete' }).click(); e = await applyDlg(); ok(!e, 'delete bridge via UI ' + (e || ''));
  await go('dhcp'); await row('webhost').last().getByRole('button', { name: 'Delete' }).click(); e = await applyDlg();
  st = await state(); ok(!st.dhcp.reservations.length && !st.interfaces.some(i => i.name.startsWith('br5')), 'clean state after UI clean-up');
  for (const v of ['overview', 'system', 'firewall', 'dns']) { await go(v); await p.screenshot({ path: '/tmp/lfwlab-ui-' + v + '.png', fullPage: true }); }
  ok(errs.length === 0, 'no browser errors ' + JSON.stringify(errs));
  await b.close(); console.log(fails ? fails + ' UI failures' : 'UI flow passed'); process.exit(fails ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
