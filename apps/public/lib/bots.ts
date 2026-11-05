// Known-bot User-Agent filter for the public vehicle-detail capture.
// Approved MVP scope (docs/product-plan.md, statistics definitions): a
// server-side filter over known bot User-Agents, accepted as imperfect; it is
// not identity verification and it never blocks the page, only the metric.
// Matching is a case-insensitive substring scan: simple, auditable and easy to
// extend when a new agent shows up in the view events.

const KNOWN_BOT_PATTERNS: readonly string[] = [
  // Search crawlers
  "googlebot",
  "bingbot",
  "slurp",
  "duckduckbot",
  "baiduspider",
  "yandexbot",
  "yisouspider",
  "sogou",
  "applebot",
  "petalbot",
  // Social and messaging link previews
  "facebookexternalhit",
  "fbexternalhit",
  "twitterbot",
  "linkedinbot",
  "whatsapp",
  "telegrambot",
  "discordbot",
  "slackbot",
  "pinterest",
  // AI and archive crawlers
  "gptbot",
  "chatgpt-user",
  "claudebot",
  "claude-web",
  "anthropic-ai",
  "perplexitybot",
  "cohere-ai",
  "amazonbot",
  "bytespider",
  "ccbot",
  "ia_archiver",
  "archive.org_bot",
  // SEO, monitoring and automation tools
  "ahrefsbot",
  "semrushbot",
  "mj12bot",
  "dotbot",
  "serpstatbot",
  "uptimerobot",
  "pingdom",
  "crawler",
  "spider",
  // Non-browser agents that routinely fetch pages
  "curl/",
  "wget/",
  "python-requests/",
  "python-httpx/",
  "libwww-perl",
];

/**
 * Returns true when the User-Agent belongs to a known bot or automated agent.
 * A missing or empty User-Agent is not a known bot and is therefore counted;
 * only known patterns are filtered, per the approved imperfect MVP scope.
 */
export function isKnownBotUa(userAgent: string | null | undefined): boolean {
  if (!userAgent) {
    return false;
  }
  const normalized = userAgent.toLowerCase();
  return KNOWN_BOT_PATTERNS.some((pattern) => normalized.includes(pattern));
}
