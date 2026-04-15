#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const CONFIG_DIR = path.join(os.homedir(), ".config", "cc-reset");
const STATE_DIR = path.join(CONFIG_DIR, "state");
const SESSION_FILE = path.join(STATE_DIR, "oauth-session.json");
const ENV_FILE = path.join(CONFIG_DIR, "env.sh");
const CLAUDE_HOME = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");

const OAUTH = {
  authorizeUrl: "https://claude.com/cai/oauth/authorize",
  tokenUrl: "https://platform.claude.com/v1/oauth/token",
  profileUrl: "https://api.anthropic.com/api/oauth/profile",
  apiKeyUrl: "https://api.anthropic.com/api/oauth/claude_cli/create_api_key",
  clientId: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
  redirectUri: "https://platform.claude.com/oauth/code/callback",
  scopes: [
    "org:create_api_key",
    "user:profile",
    "user:inference",
    "user:sessions:claude_code",
    "user:mcp_servers",
    "user:file_upload",
  ],
};

const INFERENCE_SCOPE = "user:inference";

function ensureDirs() {
  fs.mkdirSync(STATE_DIR, { recursive: true });
}

function ensureClaudeHome() {
  fs.mkdirSync(CLAUDE_HOME, { recursive: true });
}

function getClaudeCredentialsPath() {
  return path.join(CLAUDE_HOME, ".credentials.json");
}

function getClaudeGlobalConfigPath() {
  const nestedConfig = path.join(CLAUDE_HOME, ".config.json");
  if (fs.existsSync(nestedConfig)) {
    return nestedConfig;
  }
  return `${CLAUDE_HOME}.json`;
}

function readJsonIfExists(file) {
  if (!fs.existsSync(file)) {
    return null;
  }
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function base64url(input) {
  return Buffer.from(input)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function randomUrlSafe(bytes = 32) {
  return base64url(crypto.randomBytes(bytes));
}

function sha256Base64Url(value) {
  return base64url(crypto.createHash("sha256").update(value).digest());
}

function writeJson(file, data) {
  fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`, "utf8");
}

function writeSecretFile(file, content) {
  fs.writeFileSync(file, content, { mode: 0o600 });
  fs.chmodSync(file, 0o600);
}

function detectClaudeVersion() {
  const result = spawnSync("claude", ["--version"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0) {
    return null;
  }
  const output = `${result.stdout || ""}\n${result.stderr || ""}`;
  const match = output.match(/(\d+\.\d+\.\d+)/);
  return match ? match[1] : null;
}

function readSession() {
  if (!fs.existsSync(SESSION_FILE)) {
    throw new Error(`OAuth session not found: ${SESSION_FILE}`);
  }
  return JSON.parse(fs.readFileSync(SESSION_FILE, "utf8"));
}

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token.startsWith("--")) {
      const [key, inline] = token.split("=", 2);
      if (inline !== undefined) {
        args[key] = inline;
      } else if (argv[i + 1] && !argv[i + 1].startsWith("--")) {
        args[key] = argv[i + 1];
        i += 1;
      } else {
        args[key] = true;
      }
    } else {
      args._.push(token);
    }
  }
  return args;
}

function buildAuthUrl({ state, codeChallenge, email }) {
  const url = new URL(OAUTH.authorizeUrl);
  url.searchParams.set("code", "true");
  url.searchParams.set("client_id", OAUTH.clientId);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("redirect_uri", OAUTH.redirectUri);
  url.searchParams.set("scope", OAUTH.scopes.join(" "));
  url.searchParams.set("code_challenge", codeChallenge);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("state", state);
  if (email) {
    url.searchParams.set("login_hint", email);
  }
  return url.toString();
}

function startFlow(email) {
  ensureDirs();
  const codeVerifier = randomUrlSafe(32);
  const state = randomUrlSafe(32);
  const codeChallenge = sha256Base64Url(codeVerifier);
  const authUrl = buildAuthUrl({ state, codeChallenge, email });

  const session = {
    createdAt: new Date().toISOString(),
    clientId: OAUTH.clientId,
    redirectUri: OAUTH.redirectUri,
    tokenUrl: OAUTH.tokenUrl,
    profileUrl: OAUTH.profileUrl,
    apiKeyUrl: OAUTH.apiKeyUrl,
    state,
    codeVerifier,
    codeChallenge,
    email: email ?? null,
    authUrl,
  };
  writeJson(SESSION_FILE, session);
  return session;
}

function parseCallbackInput({ callbackUrl, codeState }) {
  if (callbackUrl) {
    const url = new URL(callbackUrl);
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    if (!code || !state) {
      throw new Error("Callback URL is missing code or state.");
    }
    return { code, state, source: "callback-url" };
  }

  if (codeState) {
    const parts = String(codeState).trim().split("#");
    if (parts.length !== 2 || !parts[0] || !parts[1]) {
      throw new Error("code-state must match '<code>#<state>'.");
    }
    return { code: parts[0], state: parts[1], source: "code-state" };
  }

  throw new Error("No callback input provided.");
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, options);
  const text = await response.text();
  let data = {};
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      data = { raw: text };
    }
  }
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} ${response.statusText}: ${JSON.stringify(data)}`);
  }
  return data;
}

async function exchangeCode(session, parsed) {
  if (parsed.state !== session.state) {
    throw new Error("OAuth state mismatch. Start a new login flow and try again.");
  }

  const payload = {
    grant_type: "authorization_code",
    code: parsed.code,
    redirect_uri: session.redirectUri,
    client_id: session.clientId,
    code_verifier: session.codeVerifier,
    state: parsed.state,
  };

  return fetchJson(session.tokenUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
}

async function fetchProfile(accessToken) {
  try {
    return await fetchJson(OAUTH.profileUrl, {
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
    });
  } catch {
    return null;
  }
}

async function createApiKey(accessToken) {
  const data = await fetchJson(OAUTH.apiKeyUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
    },
  });
  if (!data.raw_key) {
    throw new Error("API key creation succeeded but raw_key was missing.");
  }
  return data.raw_key;
}

function parseScopes(scopeValue) {
  return String(scopeValue ?? "")
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function shouldUseClaudeSubscriptionEnv(tokenData) {
  return parseScopes(tokenData.scope).includes(INFERENCE_SCOPE);
}

function shellEscape(value) {
  return `'${String(value).replace(/'/g, `'\"'\"'`)}'`;
}

function writeCredentialsJson({ tokenData }) {
  ensureClaudeHome();
  const credFile = getClaudeCredentialsPath();
  const current = readJsonIfExists(credFile) ?? {};
  const scopes = parseScopes(tokenData.scope);
  const expiresAt = tokenData.expires_in
    ? Date.now() + tokenData.expires_in * 1000
    : Date.now() + 30 * 24 * 60 * 60 * 1000;

  const next = {
    ...current,
    claudeAiOauth: {
      ...(current.claudeAiOauth ?? {}),
      accessToken: tokenData.access_token,
      refreshToken: tokenData.refresh_token ?? null,
      expiresAt,
      scopes,
      subscriptionType: tokenData.subscription_type ?? "unknown",
      rateLimitTier: tokenData.rate_limit_tier ?? "default",
    },
  };

  writeSecretFile(credFile, `${JSON.stringify(next, null, 2)}\n`);
  return credFile;
}

function writeEnvFile({ apiKey, tokenData, profile, mode }) {
  ensureDirs();
  const lines = ["# Generated by cc-reset login"];

  if (mode === "api-key" && apiKey) {
    lines.push(`export ANTHROPIC_API_KEY=${shellEscape(apiKey)}`);
  } else if (mode !== "claude-subscription") {
    throw new Error("No auth material available to write.");
  }

  const accountEmail = tokenData.account?.email_address ?? "";
  const accountUuid = tokenData.account?.uuid ?? "";
  const orgUuid = tokenData.organization?.uuid ?? profile?.organization?.uuid ?? "";
  const displayName = profile?.account?.display_name ?? "";

  if (accountEmail) lines.push(`export CLAUDE_CODE_USER_EMAIL=${shellEscape(accountEmail)}`);
  if (accountUuid) lines.push(`export CLAUDE_CODE_ACCOUNT_UUID=${shellEscape(accountUuid)}`);
  if (orgUuid) lines.push(`export CLAUDE_CODE_ORGANIZATION_UUID=${shellEscape(orgUuid)}`);
  if (displayName) lines.push(`export CLAUDE_CODE_DISPLAY_NAME=${shellEscape(displayName)}`);

  writeSecretFile(ENV_FILE, `${lines.join("\n")}\n`);
}

function markClaudeOnboarding({ mode, tokenData, profile }) {
  const configPath = getClaudeGlobalConfigPath();
  fs.mkdirSync(path.dirname(configPath), { recursive: true });

  const current = readJsonIfExists(configPath) ?? {};
  const next = { ...current };
  next.hasCompletedOnboarding = true;

  const detectedVersion = detectClaudeVersion();
  if (detectedVersion) {
    next.lastOnboardingVersion = detectedVersion;
  }

  if (mode === "claude-subscription") {
    next.hasAvailableSubscription = true;
  }

  const organization = profile?.organization ?? {};
  const account = profile?.account ?? {};
  const organizationUuid = tokenData.organization?.uuid ?? organization.uuid ?? current.oauthAccount?.organizationUuid;
  const accountUuid = tokenData.account?.uuid ?? account.uuid ?? current.oauthAccount?.accountUuid;
  const emailAddress = tokenData.account?.email_address ?? account.email ?? current.oauthAccount?.emailAddress;

  next.oauthAccount = {
    ...(current.oauthAccount ?? {}),
    ...(accountUuid ? { accountUuid } : {}),
    ...(emailAddress ? { emailAddress } : {}),
    ...(organizationUuid ? { organizationUuid } : {}),
    ...(account.display_name ? { displayName: account.display_name } : {}),
    ...(organization.has_extra_usage_enabled !== undefined ? { hasExtraUsageEnabled: organization.has_extra_usage_enabled } : {}),
    ...(organization.billing_type ? { billingType: organization.billing_type } : {}),
    ...(organization.subscription_created_at ? { subscriptionCreatedAt: organization.subscription_created_at } : {}),
    ...(account.created_at ? { accountCreatedAt: account.created_at } : {}),
  };

  writeJson(configPath, next);
  return configPath;
}

async function commandStart(args) {
  const session = startFlow(args["--email"]);
  const payload = {
    authUrl: session.authUrl,
    sessionFile: SESSION_FILE,
    redirectUri: session.redirectUri,
    state: session.state,
    codeChallenge: session.codeChallenge,
  };
  if (args["--json"]) {
    process.stdout.write(`${JSON.stringify(payload)}\n`);
    return;
  }
  process.stdout.write(`Auth URL: ${payload.authUrl}\n`);
}

async function commandParse(args) {
  const parsed = parseCallbackInput({
    callbackUrl: args["--callback-url"],
    codeState: args["--code-state"],
  });
  process.stdout.write(`${JSON.stringify(parsed)}\n`);
}

async function commandComplete(args) {
  const session = readSession();
  const parsed = parseCallbackInput({
    callbackUrl: args["--callback-url"],
    codeState: args["--code-state"],
  });
  const tokenData = await exchangeCode(session, parsed);
  const profile = await fetchProfile(tokenData.access_token);
  const mode = shouldUseClaudeSubscriptionEnv(tokenData) ? "claude-subscription" : "api-key";
  let apiKey = null;
  let credentialsFile = null;

  if (mode === "claude-subscription") {
    credentialsFile = writeCredentialsJson({ tokenData });
  } else {
    apiKey = await createApiKey(tokenData.access_token);
  }

  writeEnvFile({ apiKey, tokenData, profile, mode });
  const claudeConfigFile = markClaudeOnboarding({ mode, tokenData, profile });

  const result = {
    ok: true,
    mode,
    envFile: ENV_FILE,
    claudeConfigFile,
    credentialsFile,
    sessionFile: SESSION_FILE,
    accountEmail: tokenData.account?.email_address ?? null,
    accountUuid: tokenData.account?.uuid ?? null,
    organizationUuid: tokenData.organization?.uuid ?? profile?.organization?.uuid ?? null,
  };
  writeJson(SESSION_FILE, {
    ...session,
    completedAt: new Date().toISOString(),
    mode,
    envFile: ENV_FILE,
    claudeConfigFile,
    credentialsFile,
    accountEmail: result.accountEmail,
    accountUuid: result.accountUuid,
    organizationUuid: result.organizationUuid,
  });
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

function help() {
  process.stdout.write(`cc-reset OAuth helper

Usage:
  node lib/oauth-helper.mjs start [--email <email>] [--json]
  node lib/oauth-helper.mjs parse-callback (--callback-url <url> | --code-state <code#state>)
  node lib/oauth-helper.mjs complete (--callback-url <url> | --code-state <code#state>)
`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const command = args._[0] ?? "help";

  switch (command) {
    case "start":
      await commandStart(args);
      break;
    case "parse-callback":
      await commandParse(args);
      break;
    case "complete":
      await commandComplete(args);
      break;
    case "help":
    case "--help":
    case "-h":
      help();
      break;
    default:
      throw new Error(`Unknown command: ${command}`);
  }
}

const isEntrypoint = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isEntrypoint) {
  main().catch((error) => {
    process.stderr.write(`[oauth-helper] ${error.message}\n`);
    process.exit(1);
  });
}

export {
  getClaudeCredentialsPath,
  parseScopes,
  shouldUseClaudeSubscriptionEnv,
  writeCredentialsJson,
  writeEnvFile,
};
