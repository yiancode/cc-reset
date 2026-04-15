#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cc-reset-oauth-helper-"));
process.env.HOME = tempRoot;
process.env.CLAUDE_CONFIG_DIR = path.join(tempRoot, ".claude");

const modulePath = new URL("../lib/oauth-helper.mjs", import.meta.url);
const {
  getClaudeCredentialsPath,
  writeCredentialsJson,
  writeEnvFile,
} = await import(modulePath);

const tokenData = {
  access_token: "access-token",
  refresh_token: "refresh-token",
  expires_in: 60,
  scope: "user:profile user:inference",
  subscription_type: "max",
  rate_limit_tier: "default_claude_max_20x",
  account: { email_address: "user@example.com", uuid: "acct-123" },
  organization: { uuid: "org-123" },
};

const profile = {
  account: { display_name: "Test User" },
  organization: { uuid: "org-123" },
};

const credentialsPath = getClaudeCredentialsPath();
fs.mkdirSync(path.dirname(credentialsPath), { recursive: true });
fs.writeFileSync(
  credentialsPath,
  JSON.stringify(
    {
      someOtherKey: { keep: true },
      claudeAiOauth: { accessToken: "old-token", preserveMe: "yes" },
    },
    null,
    2,
  ),
);

const writtenCredPath = writeCredentialsJson({ tokenData });
assert.equal(writtenCredPath, credentialsPath);

const credentialsJson = JSON.parse(fs.readFileSync(credentialsPath, "utf8"));
assert.equal(credentialsJson.someOtherKey.keep, true);
assert.equal(credentialsJson.claudeAiOauth.accessToken, "access-token");
assert.equal(credentialsJson.claudeAiOauth.refreshToken, "refresh-token");
assert.equal(credentialsJson.claudeAiOauth.preserveMe, "yes");
assert.deepEqual(credentialsJson.claudeAiOauth.scopes, ["user:profile", "user:inference"]);

writeEnvFile({ apiKey: null, tokenData, profile, mode: "claude-subscription" });
const envFile = path.join(tempRoot, ".config", "cc-reset", "env.sh");
const subscriptionEnv = fs.readFileSync(envFile, "utf8");
assert.match(subscriptionEnv, /CLAUDE_CODE_USER_EMAIL='user@example\.com'/);
assert.doesNotMatch(subscriptionEnv, /CLAUDE_CODE_OAUTH_TOKEN/);
assert.doesNotMatch(subscriptionEnv, /CLAUDE_CODE_OAUTH_REFRESH_TOKEN/);
assert.doesNotMatch(subscriptionEnv, /CLAUDE_CODE_OAUTH_SCOPES/);

writeEnvFile({ apiKey: "api-key-123", tokenData, profile, mode: "api-key" });
const apiKeyEnv = fs.readFileSync(envFile, "utf8");
assert.match(apiKeyEnv, /ANTHROPIC_API_KEY='api-key-123'/);

console.log("oauth-helper tests passed");
