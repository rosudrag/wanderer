#!/usr/bin/env node
// Cookie-level smoke check for the /dev/login bypass (see dev/README.md).
//
// Plain Node, no dependencies, no install step: uses the built-in `fetch`.
// If the `playwright` package happens to already be installed in the repo,
// it is used for an extra visual screenshot pass; otherwise that part is
// skipped with a clear message and the script still reports PASS/FAIL based
// on the HTTP-level checks alone.
//
// Env vars:
//   WANDERER_DEV_AUTH_TOKEN  required — the same token the stack was started with.
//   AGENT_HOST               optional, default "localhost"
//   AGENT_PORT               optional, default "4100"
//   MAP_SLUG                 required — the map_slug printed by WandererApp.Dev.Seed.run/1
//   AGENT_NAME                optional — passed as ?name= to /dev/login

const host = process.env.AGENT_HOST || "localhost";
const port = process.env.AGENT_PORT || "4100";
const baseUrl = `http://${host}:${port}`;
const token = process.env.WANDERER_DEV_AUTH_TOKEN;
const mapSlug = process.env.MAP_SLUG;
const agentName = process.env.AGENT_NAME;

let failures = 0;

function fail(message) {
  failures += 1;
  console.error(`FAIL: ${message}`);
}

function info(message) {
  console.log(`  ${message}`);
}

if (!token) {
  fail(
    "WANDERER_DEV_AUTH_TOKEN is not set. export the same token the stack " +
      "was started with (see dev/README.md step 1)."
  );
}

if (!mapSlug) {
  fail(
    "MAP_SLUG is not set. Run the seed step " +
      "(WandererApp.Dev.Seed.run() |> IO.inspect()) and export MAP_SLUG=<map_slug> " +
      "from its output."
  );
}

if (failures > 0) {
  console.log("\nFAIL: prerequisites missing, see above.");
  process.exit(1);
}

/**
 * Follows redirects manually so we can capture every Set-Cookie header along
 * the way — `fetch`'s automatic redirect handling does not expose the
 * intermediate responses.
 */
async function followAndCollectCookies(url, maxHops = 5) {
  const jar = new Map();
  let current = url;

  for (let hop = 0; hop <= maxHops; hop += 1) {
    // The jar MUST be replayed on every hop. Without it Phoenix sees an
    // anonymous request on the redirect target and issues a fresh session
    // cookie, which overwrites the authenticated one /dev/login just set —
    // the request then succeeds with a logged-out session and the map page
    // comes back without its container.
    const cookieHeader = [...jar.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
    const response = await fetch(current, {
      redirect: "manual",
      headers: cookieHeader ? { Cookie: cookieHeader } : {},
    });

    const setCookies =
      typeof response.headers.getSetCookie === "function"
        ? response.headers.getSetCookie()
        : response.headers.get("set-cookie")
          ? [response.headers.get("set-cookie")]
          : [];

    for (const raw of setCookies) {
      const [pair] = raw.split(";");
      const eq = pair.indexOf("=");
      if (eq > 0) {
        jar.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
      }
    }

    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) {
        return { finalResponse: response, jar };
      }
      current = new URL(location, current).toString();
      continue;
    }

    return { finalResponse: response, jar };
  }

  throw new Error(`too many redirects starting at ${url}`);
}

async function main() {
  const loginUrl = new URL("/dev/login", baseUrl);
  loginUrl.searchParams.set("token", token);
  if (agentName) loginUrl.searchParams.set("name", agentName);

  console.log(`1. GET ${loginUrl.toString().replace(token, "<redacted>")}`);
  let jar;
  try {
    const result = await followAndCollectCookies(loginUrl.toString());
    jar = result.jar;
    info(`final status after redirects: ${result.finalResponse.status}`);
  } catch (err) {
    fail(`login request failed: ${err.message}`);
    return report();
  }

  const cookieHeader = [...jar.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
  if (!cookieHeader) {
    fail("no Set-Cookie header was returned by /dev/login — did not get a session.");
    return report();
  }
  info(`captured cookie(s): ${[...jar.keys()].join(", ")}`);

  const mapUrl = new URL(`/${mapSlug}`, baseUrl).toString();
  console.log(`2. GET ${mapUrl} with captured session cookie`);
  let mapResponse;
  let body;
  try {
    mapResponse = await fetch(mapUrl, { headers: { Cookie: cookieHeader } });
    body = await mapResponse.text();
  } catch (err) {
    fail(`map page request failed: ${err.message}`);
    return report();
  }

  if (mapResponse.status !== 200) {
    fail(`map page returned status ${mapResponse.status}, expected 200.`);
  } else {
    info("map page status: 200");
  }

  if (!body.includes('id="mapper"')) {
    fail('map page body does not contain the map container (id="mapper").');
  } else {
    info('map container (id="mapper") found in response body.');
  }

  await maybeScreenshot(mapUrl, cookieHeader);

  return report();
}

async function maybeScreenshot(mapUrl, cookieHeader) {
  let playwright;
  try {
    playwright = await import("playwright");
  } catch {
    info(
      "playwright is not installed — skipping optional screenshot pass " +
        "(this is expected; it is not an app dependency)."
    );
    return;
  }

  try {
    const browser = await playwright.chromium.launch();
    const context = await browser.newContext();
    await context.addCookies(
      cookieHeader.split("; ").map((pair) => {
        const eq = pair.indexOf("=");
        return {
          name: pair.slice(0, eq),
          value: pair.slice(eq + 1),
          url: mapUrl,
        };
      })
    );
    const page = await context.newPage();
    await page.goto(mapUrl, { waitUntil: "networkidle" });
    await page.waitForSelector("#mapper", { timeout: 10_000 });
    const screenshotPath = new URL("./.smoke-screenshot.png", import.meta.url);
    await page.screenshot({ path: screenshotPath });
    info(`screenshot saved to ${screenshotPath.pathname}`);
    await browser.close();
  } catch (err) {
    info(`playwright screenshot pass failed (non-fatal): ${err.message}`);
  }
}

function report() {
  console.log("");
  if (failures === 0) {
    console.log("PASS: dev-auth login + map page smoke check succeeded.");
    process.exit(0);
  } else {
    console.log(`FAIL: ${failures} check(s) failed, see above.`);
    process.exit(1);
  }
}

main();
