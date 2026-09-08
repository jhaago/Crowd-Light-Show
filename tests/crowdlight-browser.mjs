import { chromium } from "playwright";
import assert from "node:assert/strict";

const base = "http://127.0.0.1:4173/index.html";

async function stubFirebase(page) {
  await page.route("https://www.gstatic.com/firebasejs/**/firebase-app.js", route =>
    route.fulfill({
      status: 200,
      contentType: "application/javascript",
      body: "export function initializeApp(config,name){return {config,name}};"
    })
  );
  await page.route("https://www.gstatic.com/firebasejs/**/firebase-database.js", route =>
    route.fulfill({
      status: 200,
      contentType: "application/javascript",
      body: `
        export function getDatabase(){ return {}; }
        export function ref(db,path){ return {db,path}; }
        export async function set(){ return; }
        export function onValue(ref,cb){ return ()=>{}; }
        export async function get(){ return { val(){ return 0; } }; }
      `
    })
  );
}

async function waitForCommand(page, predicate, timeout = 2500) {
  await page.waitForFunction(
    fnText => {
      const fn = new Function("cmd", "return (" + fnText + ")(cmd)");
      const list = window.__crowdlightTestCommands || [];
      return list.some(fn);
    },
    predicate.toString(),
    { timeout }
  );
}

async function lastCommand(page) {
  return page.evaluate(() => {
    const a = window.__crowdlightTestCommands || [];
    return a[a.length - 1] || null;
  });
}

async function testMaster(browser) {
  const page = await browser.newPage();
  await stubFirebase(page);
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));

  await page.goto(base + "?master=1&test=1", { waitUntil: "networkidle" });
  await page.waitForSelector("#masterView:not(.hidden)");

  await page.click("#allOnBtn");
  await waitForCommand(page, cmd => cmd && cmd.mode === "steady");
  assert.equal((await lastCommand(page)).mode, "steady");
  assert.equal(await page.textContent("#masterStateTitle"), "ALL LIGHTS ON");

  await page.click("#blackoutBtn");
  await waitForCommand(page, cmd => cmd && cmd.mode === "off");
  assert.equal(await page.textContent("#masterStateTitle"), "BLACKOUT");

  await page.click('[data-effect="twinkle"]');
  await page.click("#startBpmBtn");
  await waitForCommand(page, cmd => cmd && cmd.mode === "pattern" && cmd.effect === "twinkle");
  let cmd = await lastCommand(page);
  assert.equal(cmd.effect, "twinkle");
  assert.equal(cmd.division, 1);

  await page.click('#divisionSeg [data-div="2"]');
  await page.waitForTimeout(80);
  cmd = await lastCommand(page);
  assert.equal(cmd.mode, "pattern");
  assert.equal(cmd.division, 2);

  await page.evaluate(() => {
    const el = document.querySelector("#bpmRange");
    el.value = "132";
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  });
  await page.waitForTimeout(80);
  cmd = await lastCommand(page);
  assert.equal(Math.round(cmd.bpm), 132);

  await page.evaluate(() => {
    const el = document.querySelector("#flashMsRange");
    el.value = "125";
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  });
  await page.waitForTimeout(80);
  cmd = await lastCommand(page);
  assert.equal(cmd.flashMs, 125);

  // Persistent effect -> sync flash -> new ALL ON command.
  // The delayed restore must NOT resurrect the old Twinkle pattern.
  await page.click("#flashNowBtn");
  await page.waitForTimeout(120);
  assert.equal((await lastCommand(page)).mode, "flash");
  await page.click("#allOnBtn");
  await page.waitForTimeout(1450);
  assert.equal(await page.textContent("#masterStateTitle"), "ALL LIGHTS ON");
  assert.equal((await lastCommand(page)).mode, "steady");

  // New pattern -> sync flash -> BLACKOUT. Old pattern must stay cancelled.
  await page.click('[data-effect="sparkle"]');
  await page.click("#startBpmBtn");
  await page.waitForTimeout(100);
  await page.click("#flashNowBtn");
  await page.waitForTimeout(100);
  await page.click("#blackoutBtn");
  await page.waitForTimeout(1450);
  assert.equal(await page.textContent("#masterStateTitle"), "BLACKOUT");
  assert.equal((await lastCommand(page)).mode, "off");

  assert.deepEqual(errors, [], "Master page JavaScript errors: " + errors.join(" | "));
  await page.close();
}

async function makeAudiencePage(browser, torchSupported = true) {
  const page = await browser.newPage();
  await stubFirebase(page);

  await page.addInitScript(supported => {
    window.__fakeTorch = { on: false, toggles: [], stopped: false };
    window.alert = msg => { window.__lastAlert = String(msg); };

    const track = {
      readyState: "live",
      getCapabilities() { return supported ? { torch: true } : {}; },
      getSettings() { return { torch: window.__fakeTorch.on, deviceId: "rear-camera" }; },
      async applyConstraints(constraints) {
        const adv = constraints?.advanced?.[0];
        const requested = adv && Object.prototype.hasOwnProperty.call(adv, "torch")
          ? adv.torch
          : constraints?.torch;
        if (!supported || typeof requested !== "boolean") throw new Error("torch unsupported");
        window.__fakeTorch.on = requested;
        window.__fakeTorch.toggles.push({ on: requested, at: Date.now() });
      },
      stop() {
        this.readyState = "ended";
        window.__fakeTorch.stopped = true;
        window.__fakeTorch.on = false;
      }
    };

    const stream = {
      getVideoTracks() { return [track]; },
      getTracks() { return [track]; }
    };

    Object.defineProperty(navigator, "mediaDevices", {
      configurable: true,
      value: {
        async getUserMedia() { return stream; },
        async enumerateDevices() {
          return [{ kind: "videoinput", deviceId: "rear-camera", label: "Back Camera" }];
        }
      }
    });

    Object.defineProperty(navigator, "wakeLock", {
      configurable: true,
      value: {
        async request() {
          return { addEventListener(){}, async release(){} };
        }
      }
    });
  }, torchSupported);

  return page;
}

async function testAudienceSuccess(browser) {
  const page = await makeAudiencePage(browser, true);
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));

  await page.goto(base + "?test=1", { waitUntil: "networkidle" });
  await page.click("#joinBtn");
  await page.waitForSelector("#readyCard:not(.hidden)", { timeout: 3000 });

  let fake = await page.evaluate(() => window.__fakeTorch);
  assert.equal(fake.on, false);
  assert.ok(fake.toggles.some(x => x.on === true), "Confirmation flash never turned on");
  assert.ok(fake.toggles.some(x => x.on === false), "Confirmation flash never turned off");
  assert.equal(await page.textContent("#audienceConn"), "TEST");

  // Steady ON and BLACKOUT command handling.
  await page.evaluate(() => window.__crowdlightInjectCommand({
    id: "steady-1",
    mode: "steady",
    startAt: Date.now() + 30,
    validUntil: Date.now() + 1500
  }));
  await page.waitForTimeout(90);
  assert.equal(await page.evaluate(() => window.__fakeTorch.on), true);

  await page.evaluate(() => window.__crowdlightInjectCommand({
    id: "off-1",
    mode: "off",
    validUntil: Date.now() + 60000
  }));
  await page.waitForTimeout(40);
  assert.equal(await page.evaluate(() => window.__fakeTorch.on), false);

  // A stale one-shot must not flash a reconnecting phone late.
  const before = await page.evaluate(() => window.__fakeTorch.toggles.length);
  await page.evaluate(() => window.__crowdlightInjectCommand({
    id: "late-flash",
    mode: "flash",
    startAt: Date.now() - 1200,
    validUntil: Date.now() + 1000,
    flashMs: 90
  }));
  await page.waitForTimeout(180);
  const after = await page.evaluate(() => window.__fakeTorch.toggles.length);
  assert.equal(after, before, "Stale flash was incorrectly executed");

  // A properly scheduled one-shot still works.
  await page.evaluate(() => window.__crowdlightInjectCommand({
    id: "good-flash",
    mode: "flash",
    startAt: Date.now() + 40,
    validUntil: Date.now() + 1000,
    flashMs: 60
  }));
  await page.waitForTimeout(180);
  fake = await page.evaluate(() => window.__fakeTorch);
  assert.equal(fake.on, false);
  assert.ok(fake.toggles.length >= before + 2, "Scheduled flash did not toggle on/off");

  await page.click("#leaveBtn");
  await page.waitForSelector("#joinCard:not(.hidden)");
  assert.equal(await page.evaluate(() => window.__fakeTorch.stopped), true);

  assert.deepEqual(errors, [], "Audience page JavaScript errors: " + errors.join(" | "));
  await page.close();
}

async function testAudienceFailure(browser) {
  const page = await makeAudiencePage(browser, false);
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));

  await page.goto(base + "?test=1", { waitUntil: "networkidle" });
  await page.click("#joinBtn");
  await page.waitForFunction(() => !!window.__lastAlert, null, { timeout: 3000 });

  assert.equal(await page.locator("#joinCard").evaluate(el => !el.classList.contains("hidden")), true);
  assert.equal(await page.locator("#readyCard").evaluate(el => el.classList.contains("hidden")), true);
  assert.match(await page.textContent("#joinBtn"), /TRY AGAIN/);
  assert.deepEqual(errors, [], "Failure-flow JavaScript errors: " + errors.join(" | "));
  await page.close();
}

const browser = await chromium.launch({ headless: true });
try {
  await testMaster(browser);
  await testAudienceSuccess(browser);
  await testAudienceFailure(browser);
  console.log("CrowdLight browser regression tests passed.");
} finally {
  await browser.close();
}
