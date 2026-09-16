import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
let checked = 0;
// Resolve relative resources and fragment links across both pages, including file:// use.
for (const name of ['index.html', 'business-case.html']) {
  const html = readFileSync(resolve(root, name), 'utf8');
  const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
  assert.equal(new Set(ids).size, ids.length, `${name}: duplicate IDs`);
  assert.match(html, /<html lang="cs">/);
  assert.match(html, /name="viewport"/);
  for (const match of html.matchAll(/(?:href|src)="([^"]+)"/g)) {
    const url = match[1];
    if (/^https?:/.test(url)) continue;
    const [file, fragment] = url.split('#');
    const path = resolve(root, file || name);
    assert.ok(existsSync(path), `${name}: missing resource ${url}`);
    if (fragment) {
      const target = readFileSync(path, 'utf8');
      assert.ok(target.includes(`id="${fragment}"`), `${name}: broken fragment ${url}`);
    }
    checked++;
  }
  for (const match of html.matchAll(/aria-(?:controls|labelledby)="([^"]+)"/g)) {
    assert.ok(ids.includes(match[1]), `${name}: missing ARIA target ${match[1]}`);
  }
}
const home = readFileSync(resolve(root, 'index.html'), 'utf8');
assert.equal((home.match(/role="tab"/g) || []).length, 3);
assert.equal((home.match(/role="tabpanel"/g) || []).length, 3);
assert.ok(home.includes('placené služby zatím neprodáváme'));
assert.ok(home.includes('V aplikaci zatím uvidíte název CallType'));
assert.ok(home.includes('nemá nezávislý audit'));
assert.ok(home.includes('256 KiB'));
assert.ok(!home.includes('business-case.html'), 'Investor page must not be linked from home');
assert.ok(!home.includes('id="investori"'), 'Investor section must be off the home page');
assert.ok(!home.includes('Jay Plus'), 'Personal paid plan must be removed');
assert.ok(home.includes('Skupinový chat zůstává zdarma i pro malé týmy'));
assert.ok(home.includes('Domluvit firemní pilot'));
assert.ok(home.includes('Jay Business'));
assert.ok(!/data-billing|team-price|team-billing|Jay Team/.test(home));
assert.ok(home.includes('id="nis2"'));
for (const provider of ['Google Disk', 'OneDrive', 'zDrive']) assert.ok(home.includes(provider));
assert.ok(home.includes('Tato propojení nejsou v současné betě dostupná'));
const pricing = home.match(/<div class="pricing-grid">([\s\S]*?)<details class="pricing-details">/)[1];
assert.ok(!/záloh/i.test(pricing), 'Backups must not be a pricing-plan feature');
assert.ok(home.includes('Tarify Jay nezahrnují zálohovací kapacitu'));
const investor = readFileSync(resolve(root, 'business-case.html'), 'utf8');
assert.ok(investor.includes('id="investori"'));
assert.ok(!investor.includes('Plus'));
assert.ok(investor.includes('900 Free + 100 míst Business'));
console.log(`PASS: ${checked} local links/resources, unique IDs, ARIA references, Czech metadata, and beta disclosures.`);
