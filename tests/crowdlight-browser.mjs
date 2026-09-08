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
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
  await stubFirebase(page);
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));

  await page.goto(base + "?master=1&test=1", { waitUntil: "networkidle" });
  await page.waitForSelector("#masterView:not(.hidden)");
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), true, "Master page overflows horizontally on a phone viewport");

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

async function testDeferredMasterWriteFencing(browser) {
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
  await stubFirebase(page);
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));

  await page.goto(base + "?master=1&test=1", { waitUntil: "networkidle" });
  await page.evaluate(() => { window.__crowdlightTestWriteDelayMs = 300; });

  // Start a persistent pattern, then BLACKOUT before the old write completes.
  await page.click('[data-effect="twinkle"]');
  await page.click("#startBpmBtn");
  await page.waitForTimeout(40);
  await page.click("#blackoutBtn");
  await page.waitForTimeout(760);

  const state = await page.evaluate(() => window.__crowdlightTestState());
  assert.equal(state.currentMasterCommand, null, "Superseded pattern write resurrected persistent master state");
  assert.equal(await page.textContent("#masterStateTitle"), "BLACKOUT");

  // Wait beyond one normal heartbeat boundary; no pattern keepalive should be
  // recreated from the superseded write completion.
  const before = await page.evaluate(() => (window.__crowdlightTestCommands || []).length);
  await page.waitForTimeout(5200);
  const commands = await page.evaluate(() => window.__crowdlightTestCommands || []);
  const tail = commands.slice(before);
  assert.equal(tail.some(cmd => cmd.mode === "pattern"), false, "Superseded pattern heartbeat reappeared after BLACKOUT");

  assert.deepEqual(errors, [], "Deferred master test JavaScript errors: " + errors.join(" | "));
  await page.close();
}

async function makeAudiencePage(browser, torchSupported = true, options = {}) {
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
  await stubFirebase(page);

  await page.addInitScript(({supported, options}) => {
    window.__fakeTorch = {
      on: false,
      toggles: [],
      stopped: false,
      failOff: false,
      failOn: false,
      onDelayMs: Number(options.onDelayMs)||0,
      offDelayMs: Number(options.offDelayMs)||0
    };
    window.alert = msg => { window.__lastAlert = String(msg); };

    // The product receives a real MediaStream on phones. The headless test uses
    // a lightweight fake, so make the hidden video element accept that object.
    Object.defineProperty(HTMLMediaElement.prototype, "srcObject", {
      configurable: true,
      get() { return this.__crowdlightSrcObject || null; },
      set(value) { this.__crowdlightSrcObject = value; }
    });
    HTMLMediaElement.prototype.play = async function(){};

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

        const delay = requested ? window.__fakeTorch.onDelayMs : window.__fakeTorch.offDelayMs;
        if (delay) await new Promise(resolve => setTimeout(resolve, delay));

        if (requested && window.__fakeTorch.failOn) throw new Error("simulated ON failure");
        if (!requested && window.__fakeTorch.failOff) throw new Error("simulated OFF failure");

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
  }, { supported: torchSupported, options });

  return page;
}

async function testAudienceSuccess(browser) {
  const page = await makeAudiencePage(browser, true);
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));

  await page.goto(base + "?test=1", { waitUntil: "networkidle" });
  await page.click("#joinBtn");
  await page.waitForSelector("#readyCard:not(.hidden)", { timeout: 3000 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), true, "Audience page overflows horizontally on a phone viewport");

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

  // A properly scheduled one-shot still works once the global safety interval
  // from the previous physical ON transition has elapsed.
  await page.waitForTimeout(520);
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

  // C4 regression: repeated one-shot commands are subject to the same global
  // physical ON limiter as rhythmic patterns.
  await page.waitForTimeout(520);
  const rapidStart = await page.evaluate(() => window.__fakeTorch.toggles.length);
  for (let i = 0; i < 8; i++) {
    await page.evaluate(i => {
      const now = Date.now();
      window.__crowdlightInjectCommand({
        id: "rapid-flash-" + i,
        mode: "flash",
        startAt: now + 20,
        validUntil: now + 800,
        flashMs: 45
      });
    }, i);
    await page.waitForTimeout(190);
  }
  await page.waitForTimeout(180);
  const rapidOnTimes = await page.evaluate(start => (
    window.__fakeTorch.toggles.slice(start).filter(x => x.on).map(x => x.at)
  ), rapidStart);
  for (let i = 1; i < rapidOnTimes.length; i++) {
    assert.ok(
      rapidOnTimes[i] - rapidOnTimes[i - 1] >= 430,
      "Repeated one-shots exceeded the global 2 flashes/sec safety ceiling"
    );
  }

  // Execution-time freshness: a flash received on time but delayed by an
  // event-loop stall must be dropped when its callback finally runs late.
  await page.waitForTimeout(520);
  const delayedStart = await page.evaluate(() => window.__fakeTorch.toggles.length);
  await page.evaluate(() => {
    const now = Date.now();
    window.__crowdlightInjectCommand({
      id: "execute-late-flash",
      mode: "flash",
      startAt: now + 40,
      validUntil: now + 1500,
      flashMs: 60
    });
    const stop = performance.now() + 720;
    while (performance.now() < stop) {}
  });
  await page.waitForTimeout(120);
  const delayedAfter = await page.evaluate(() => window.__fakeTorch.toggles.length);
  assert.equal(delayedAfter, delayedStart, "An overdue scheduled flash executed after event-loop suspension");

  // If a persistent command stops being refreshed, the phone must fail safe OFF.
  // Allow the previous flash's global 2 Hz safety interval to clear first.
  await page.waitForTimeout(520);
  await page.evaluate(() => window.__crowdlightInjectCommand({
    id: "expiring-steady",
    mode: "steady",
    startAt: Date.now() + 20,
    validUntil: Date.now() + 220
  }));
  await page.waitForTimeout(80);
  assert.equal(await page.evaluate(() => window.__fakeTorch.on), true);
  await page.waitForTimeout(360);
  assert.equal(await page.evaluate(() => window.__fakeTorch.on), false, "Expired steady command did not fail safe OFF");

  // Sustained patterns are hard-limited to at most 2 flashes per second,
  // even if a much faster BPM is requested.
  const patternStartIndex = await page.evaluate(() => window.__fakeTorch.toggles.length);
  await page.evaluate(() => {
    const now = Date.now();
    window.__crowdlightInjectCommand({
      id: "rate-limit-pattern",
      mode: "pattern",
      bpm: 240,
      division: 1,
      effect: "unison",
      flashMs: 45,
      phaseStart: now + 40,
      startAt: now + 40,
      validUntil: now + 1700
    });
  });
  await page.waitForTimeout(1220);
  const patternOnTimes = await page.evaluate(start => (
    window.__fakeTorch.toggles.slice(start).filter(x => x.on).map(x => x.at)
  ), patternStartIndex);
  assert.ok(patternOnTimes.length >= 1, "Pattern safety test did not produce any flashes");
  for (let i = 1; i < patternOnTimes.length; i++) {
    assert.ok(patternOnTimes[i] - patternOnTimes[i - 1] >= 430, "Pattern exceeded the 2 flashes/sec safety ceiling");
  }
  await page.evaluate(() => window.__crowdlightInjectCommand({
    id: "off-after-rate-test",
    mode: "off",
    validUntil: Date.now() + 60000
  }));
  await page.waitForTimeout(80);
  assert.equal(await page.evaluate(() => window.__fakeTorch.on), false);

  // C1 regression: BLACKOUT during an already-running pattern flash must
  // permanently invalidate that pattern closure. It must not schedule again.
  await page.waitForTimeout(520);
  const c1Start = await page.evaluate(() => window.__fakeTorch.toggles.length);
  await page.evaluate(() => {
    const now = Date.now();
    window.__crowdlightInjectCommand({
      id: "c1-pattern",
      mode: "pattern",
      bpm: 120,
      division: 1,
      effect: "unison",
      flashMs: 180,
      phaseStart: now + 30,
      startAt: now + 30,
      validUntil: now + 2000
    });
  });
  await page.waitForTimeout(90);
  assert.equal(await page.evaluate(() => window.__fakeTorch.on), true, "C1 setup did not enter flash ON state");
  await page.evaluate(() => window.__crowdlightInjectCommand({
    id: "c1-blackout",
    mode: "off",
    validUntil: Date.now() + 60000
  }));
  await page.waitForTimeout(1100);
  assert.equal(await page.evaluate(() => window.__fakeTorch.on), false, "Pattern relit after BLACKOUT");
  const c1OnEvents = await page.evaluate(start => (
    window.__fakeTorch.toggles.slice(start).filter(x => x.on)
  ), c1Start);
  assert.equal(c1OnEvents.length, 1, "Old pattern scheduled another flash after BLACKOUT");

  // Malformed/unknown input is a fail-safe event and must never remove the
  // watchdog while leaving a torch ON.
  await page.waitForTimeout(520);
  await page.evaluate(() => window.__crowdlightInjectCommand({
    id: "valid-before-malformed",
    mode: "steady",
    startAt: Date.now() + 20,
    validUntil: Date.now() + 1000
  }));
  await page.waitForTimeout(80);
  assert.equal(await page.evaluate(() => window.__fakeTorch.on), true);
  await page.evaluate(() => window.__crowdlightInjectCommand({
    id: "malformed",
    mode: "mystery",
    validUntil: Date.now() + 1000
  }));
  await page.waitForTimeout(100);
  assert.equal(await page.evaluate(() => window.__fakeTorch.on), false, "Malformed command left torch ON");

  await page.click("#leaveBtn");
  await page.waitForSelector("#joinCard:not(.hidden)");
  assert.equal(await page.evaluate(() => window.__fakeTorch.stopped), true);

  assert.deepEqual(errors, [], "Audience page JavaScript errors: " + errors.join(" | "));
  await page.close();
}

async function testPendingOnBlackout(browser) {
  const page = await makeAudiencePage(browser, true, { onDelayMs: 280 });
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));

  await page.goto(base + "?test=1", { waitUntil: "networkidle" });
  await page.click("#joinBtn");
  await page.waitForSelector("#readyCard:not(.hidden)", { timeout: 5000 });

  // Allow the confirmation flash safety interval to clear.
  await page.waitForTimeout(520);

  await page.evaluate(() => window.__crowdlightInjectCommand({
    id: "pending-on",
    mode: "steady",
    startAt: Date.now() + 10,
    validUntil: Date.now() + 2000
  }));
  await page.waitForTimeout(50);

  // BLACKOUT while the delayed ON applyConstraints() is still unresolved.
  await page.evaluate(() => window.__crowdlightInjectCommand({
    id: "blackout-during-pending-on",
    mode: "off",
    validUntil: Date.now() + 60000
  }));

  await page.waitForTimeout(500);
  assert.equal(await page.evaluate(() => window.__fakeTorch.on), false, "Pending ON completed after BLACKOUT and remained ON");
  assert.equal((await page.evaluate(() => window.__crowdlightTestState())).desiredTorchOn, false);

  assert.deepEqual(errors, [], "Pending-ON test JavaScript errors: " + errors.join(" | "));
  await page.close();
}

async function testOffFailureStopsStream(browser) {
  const page = await makeAudiencePage(browser, true);
  const errors = [];
  page.on("pageerror", e => errors.push(e.message));

  await page.goto(base + "?test=1", { waitUntil: "networkidle" });
  await page.click("#joinBtn");
  await page.waitForSelector("#readyCard:not(.hidden)", { timeout: 3000 });
  await page.waitForTimeout(520);

  await page.evaluate(() => window.__crowdlightInjectCommand({
    id: "off-failure-steady",
    mode: "steady",
    startAt: Date.now() + 10,
    validUntil: Date.now() + 2000
  }));
  await page.waitForTimeout(80);
  assert.equal(await page.evaluate(() => window.__fakeTorch.on), true);

  await page.evaluate(() => { window.__fakeTorch.failOff = true; });
  await page.evaluate(() => window.__crowdlightInjectCommand({
    id: "off-failure-blackout",
    mode: "off",
    validUntil: Date.now() + 60000
  }));
  await page.waitForTimeout(180);

  assert.equal(await page.evaluate(() => window.__fakeTorch.stopped), true, "OFF failure did not force-stop camera track");
  assert.equal(await page.evaluate(() => window.__fakeTorch.on), false, "Force-stopped camera remained logically ON");

  assert.deepEqual(errors, [], "OFF-failure test JavaScript errors: " + errors.join(" | "));
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
  await testDeferredMasterWriteFencing(browser);
  await testAudienceSuccess(browser);
  await testPendingOnBlackout(browser);
  await testOffFailureStopsStream(browser);
  await testAudienceFailure(browser);
  console.log("CrowdLight browser regression tests passed.");
} finally {
  await browser.close();
}
