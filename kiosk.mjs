import { chromium } from 'playwright';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const config = JSON.parse(readFileSync(resolve(__dirname, 'config.json')));
const strings = JSON.parse(readFileSync(resolve(__dirname, 'strings.json')));

const { KIOSK_USERNAME, KIOSK_PASSWORD } = process.env;

if (!KIOSK_USERNAME || !KIOSK_PASSWORD) {
  console.error(strings.missingEnvVars);
  process.exit(1);
}

const targetUrl = config.url;

async function isLoginPage(page) {
  try {
    const url = page.url();
    if (config.loginUrlPattern && url.includes(config.loginUrlPattern)) {
      return true;
    }
    const indicator = await page.$(config.selectors.loginIndicator);
    return indicator !== null;
  } catch {
    return false;
  }
}

async function performLogin(page) {
  console.log(strings.loginDetected);
  await page.waitForSelector(config.selectors.username, {
    timeout: config.navigationTimeout,
  });
  await page.fill(config.selectors.username, KIOSK_USERNAME);
  await page.fill(config.selectors.password, KIOSK_PASSWORD);
  await page.click(config.selectors.submit);
  await page.waitForLoadState('networkidle');
  console.log(strings.loginComplete);
}

async function navigateWithRetry(page, url) {
  for (let attempt = 1; attempt <= config.maxRetries; attempt++) {
    try {
      await page.goto(url, {
        waitUntil: 'networkidle',
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
  const context = await chromium.launchPersistentContext(userDataDir, {
    args: config.chromiumArgs,
    headless: false,
    viewport: null,
  });

  const page = context.pages()[0] || await context.newPage();

  console.log(strings.navigating);
  await navigateWithRetry(page, targetUrl);

  if (await isLoginPage(page)) {
    await performLogin(page);
  }

  console.log(strings.kioskRunning);

  setInterval(async () => {
    try {
      if (await isLoginPage(page)) {
        await performLogin(page);
      }
    } catch (err) {
      console.error(strings.sessionCheckError, err.message);
      try {
        console.log(strings.recoveryAttempt);
        await navigateWithRetry(page, targetUrl);
        if (await isLoginPage(page)) {
          await performLogin(page);
        }
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
