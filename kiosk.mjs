import { chromium } from 'playwright';
import { readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync, readdirSync } from 'node:fs';

const __dirname = dirname(fileURLToPath(import.meta.url));

const config = JSON.parse(readFileSync(resolve(__dirname, 'config.json')));
const strings = JSON.parse(readFileSync(resolve(__dirname, 'strings.json')));

const EXIT_SEQUENCE = 'exitnow';

const { KIOSK_USERNAME, KIOSK_PASSWORD } = process.env;

if (!KIOSK_USERNAME || !KIOSK_PASSWORD) {
  console.error(strings.missingEnvVars);
  process.exit(1);
}

const targetUrl = config.url;

async function isLoggedIn(page) {
  try {
    if (config.selectors.loggedInCookie) {
      const cookies = await page.context().cookies();
      return cookies.some((c) => c.name === config.selectors.loggedInCookie);
    }
    const indicator = await page.$(config.selectors.loggedInIndicator);
    if (!indicator) return false;
    if (config.selectors.loggedInText) {
      const text = await indicator.textContent();
      return text?.trim() === config.selectors.loggedInText;
    }
    return true;
  } catch {
    return false;
  }
}

async function performLogin(page) {
  console.log(strings.loginDetected);
  await navigateWithRetry(page, config.loginUrl);
  await page.waitForSelector(config.selectors.username, {
    timeout: config.navigationTimeout,
  });
  await page.fill(config.selectors.username, KIOSK_USERNAME);
  await page.fill(config.selectors.password, KIOSK_PASSWORD);
  await page.click(config.selectors.submit);
  await page.waitForURL((url) => !url.href.includes('login'), {
    timeout: config.loginTimeout || 60000,
  });
  console.log(strings.loginComplete);
}

async function dismissOverlays(page) {
  if (!config.selectors.cookieAccept) return;
  try {
    const btn = await page.waitForSelector(config.selectors.cookieAccept, {
      timeout: 5000,
    });
    await btn.click();
    console.log(strings.cookieDismissed);
  } catch {
    // overlay not present, continue
  }
}

async function navigateWithRetry(page, url) {
  for (let attempt = 1; attempt <= config.maxRetries; attempt++) {
    try {
      await page.goto(url, {
        waitUntil: 'domcontentloaded',
        timeout: config.navigationTimeout,
      });
      return;
    } catch (err) {
      console.error(
        `${strings.navigationRetry} (${attempt}/${config.maxRetries}):`,
        err.message,
      );
      if (attempt < config.maxRetries) {
        await new Promise((r) => setTimeout(r, config.retryDelay));
      }
    }
  }
  throw new Error(strings.navigationFailed);
}

async function startKiosk() {
  console.log(strings.starting);

  console.log(strings.launchingBrowser);
  const userDataDir = resolve(__dirname, config.userDataDir || 'browser-data');
  const extensionsDir = resolve(__dirname, 'extensions');
  const extensionArgs = [];
  if (existsSync(extensionsDir)) {
    const extPaths = readdirSync(extensionsDir, { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => resolve(extensionsDir, d.name));
    if (extPaths.length > 0) {
      extensionArgs.push(
        `--disable-extensions-except=${extPaths.join(',')}`,
        `--load-extension=${extPaths.join(',')}`,
      );
    }
  }

  const context = await chromium.launchPersistentContext(userDataDir, {
    args: [...config.chromiumArgs, ...extensionArgs],
    headless: false,
    viewport: null,
  });

  const page = context.pages()[0] || await context.newPage();

  console.log(strings.navigating);
  await navigateWithRetry(page, targetUrl);
  await dismissOverlays(page);

  if (!(await isLoggedIn(page))) {
    await performLogin(page);
    await navigateWithRetry(page, targetUrl);
    await page.waitForSelector(config.selectors.loggedInIndicator, {
      timeout: config.navigationTimeout,
    });
  }

  console.log(strings.kioskRunning);

  await page.exposeFunction('__kioskExit', async () => {
    console.log(strings.exitSequenceTriggered);
    await context.close();
    try {
      execSync('sudo systemctl stop kiosk');
    } catch {
      // systemd not available or not running as service
    }
    process.exit(0);
  });

  await page.evaluate((seq) => {
    let buffer = '';
    document.addEventListener('keydown', (e) => {
      buffer += e.key.toLowerCase();
      if (buffer.length > seq.length) {
        buffer = buffer.slice(-seq.length);
      }
      if (buffer === seq) {
        window.__kioskExit();
      }
    });
  }, EXIT_SEQUENCE);

  setInterval(async () => {
    try {
      if (!(await isLoggedIn(page))) {
        await performLogin(page);
        await navigateWithRetry(page, targetUrl);
      }
    } catch (err) {
      console.error(strings.sessionCheckError, err.message);
      try {
        console.log(strings.recoveryAttempt);
        await navigateWithRetry(page, targetUrl);
      } catch (retryErr) {
        console.error(strings.recoveryFailed, retryErr.message);
      }
    }
  }, config.checkInterval);

  page.on('crash', () => {
    console.error(strings.pageCrashed);
    process.exit(1);
  });
}

startKiosk().catch((err) => {
  console.error(strings.fatalError, err.message);
  process.exit(1);
});
