import assert from "node:assert/strict";
import { test } from "node:test";

import { isKnownBotUa } from "./bots.ts";

const CHROME =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const FIREFOX =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:133.0) Gecko/20100101 Firefox/133.0";
const SAFARI =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 " +
  "(KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1";

test("ordinary browser User-Agents are counted", () => {
  assert.equal(isKnownBotUa(CHROME), false);
  assert.equal(isKnownBotUa(FIREFOX), false);
  assert.equal(isKnownBotUa(SAFARI), false);
});

test("known search crawler User-Agents are filtered", () => {
  assert.equal(
    isKnownBotUa(
      "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
    ),
    true,
  );
  assert.equal(
    isKnownBotUa(
      "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)",
    ),
    true,
  );
  assert.equal(isKnownBotUa("DuckDuckBot/1.1; (+http://duckduckgo.com/duckduckbot.html)"), true);
  assert.equal(
    isKnownBotUa(
      "Mozilla/5.0 (compatible; YandexBot/3.0; +http://yandex.com/bots)",
    ),
    true,
  );
  assert.equal(
    isKnownBotUa(
      "Mozilla/5.0 (compatible; Baiduspider/2.0; +http://www.baidu.com/search/spider.html)",
    ),
    true,
  );
});

test("known social preview and AI crawler User-Agents are filtered", () => {
  assert.equal(
    isKnownBotUa("facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"),
    true,
  );
  assert.equal(isKnownBotUa("Twitterbot/1.0"), true);
  assert.equal(isKnownBotUa("WhatsApp/2.24.0.0 A"), true);
  assert.equal(
    isKnownBotUa("Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.0; +https://openai.com/gptbot)"),
    true,
  );
  assert.equal(isKnownBotUa("ClaudeBot/1.0"), true);
});

test("known non-browser agents are filtered", () => {
  assert.equal(isKnownBotUa("curl/8.5.0"), true);
  assert.equal(isKnownBotUa("Wget/1.21.4"), true);
  assert.equal(isKnownBotUa("python-requests/2.32.3"), true);
  assert.equal(
    isKnownBotUa("Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)"),
    true,
  );
  assert.equal(isKnownBotUa("UptimeRobot/2.0; http://www.uptimerobot.com/"), true);
});

test("a missing or empty User-Agent is not a known bot", () => {
  assert.equal(isKnownBotUa(null), false);
  assert.equal(isKnownBotUa(undefined), false);
  assert.equal(isKnownBotUa(""), false);
});

test("matching is case-insensitive and works on partial tokens", () => {
  assert.equal(isKnownBotUa("GOOGLEBOT/2.1"), true);
  assert.equal(isKnownBotUa("SomeCrawler/1.0"), true);
});
