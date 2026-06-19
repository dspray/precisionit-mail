#!/usr/bin/env node
/**
 * mcp-keyvault-launch.js
 * PrecisionIT — per-user Key Vault credential injector for API-key MCP connectors.
 *
 * Authenticates as the signed-in technician (their `az login` session), reads the
 * named secret from the RW vault, and on a 403 (no RW access) falls back to the
 * RO vault. Entra entitlement decides which vault answers, so RW vs RO is enforced
 * by Azure — nothing on the technician's machine makes that decision. The secret
 * is injected into the child process and never written to the config file.
 *
 * USAGE (in the Claude Desktop config command/args):
 *   node mcp-keyvault-launch.js \
 *     --secret <secret-name>:<ENV_VAR> [--secret ...] \
 *     -- <real command> <real args...>
 *
 * REQUIRED ENV (non-secret — fine to leave in the config "env" block):
 *   KV_VAULT_RW_URL   e.g. https://PrecisionIT-MCP-RW.vault.azure.net/
 * OPTIONAL ENV:
 *   KV_VAULT_RO_URL   e.g. https://PrecisionIT-MCP-RO.vault.azure.net/  (enables RO fallback)
 *   KV_TENANT_ID      pin the Entra tenant for AzureCliCredential (multi-tenant only)
 *
 * PREREQUISITE per machine: Azure CLI installed and the tech has run `az login`.
 * stdout is reserved for the MCP JSON-RPC stream; all diagnostics go to stderr.
 */

const { spawn } = require("node:child_process");
const { AzureCliCredential } = require("@azure/identity");
const { SecretClient } = require("@azure/keyvault-secrets");

function log(...a) { process.stderr.write(`[kv-launch] ${a.join(" ")}\n`); }
function die(msg, code = 1) { log("FATAL:", msg); process.exit(code); }

// Parse:  --secret name:ENVVAR (repeatable)  --  command args...
function parseArgs(argv) {
  const secrets = [];
  let i = 0;
  for (; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--secret") {
      const spec = argv[++i];
      if (!spec || !spec.includes(":")) die(`--secret expects "name:ENVVAR", got "${spec}"`);
      const idx = spec.indexOf(":");
      secrets.push({ secretName: spec.slice(0, idx), envVar: spec.slice(idx + 1) });
    } else if (a === "--") { i++; break; }
    else die(`unexpected argument "${a}" (use: --secret name:ENVVAR ... -- command args)`);
  }
  const command = argv.slice(i);
  if (secrets.length === 0) die("no --secret mappings provided");
  if (command.length === 0) die("no downstream command provided after --");
  return { secrets, command };
}

function getConfig() {
  const rwUrl = process.env.KV_VAULT_RW_URL;
  if (!rwUrl) die("missing required env KV_VAULT_RW_URL");
  return {
    rwUrl,
    roUrl: process.env.KV_VAULT_RO_URL || null,
    tenantId: process.env.KV_TENANT_ID || undefined,
  };
}

// Per-user identity: the signed-in tech's Azure CLI session.
function getCredential(cfg) {
  return new AzureCliCredential(cfg.tenantId ? { tenantId: cfg.tenantId } : {});
}

// RW first; fall back to RO ONLY on 403 (no RW access for this user). A 404 or any
// other error is surfaced — we never silently downgrade a privileged user to RO
// because a secret is misnamed/missing in the vault they can actually read.
async function resolveSecret(rwClient, roClient, secretName) {
  try {
    const res = await rwClient.getSecret(secretName);
    if (!res || res.value == null || res.value === "") throw new Error("empty value in RW vault");
    return { value: res.value, tier: "RW" };
  } catch (e) {
    if (e.statusCode === 403 && roClient) {
      log(`no RW access for "${secretName}" (403) — falling back to RO vault`);
      const res = await roClient.getSecret(secretName);
      if (!res || res.value == null || res.value === "") throw new Error("empty value in RO vault");
      return { value: res.value, tier: "RO" };
    }
    throw e;
  }
}

async function main() {
  const { secrets, command } = parseArgs(process.argv.slice(2));
  const cfg = getConfig();

  let rwClient, roClient = null;
  try {
    const cred = getCredential(cfg);
    rwClient = new SecretClient(cfg.rwUrl, cred);
    if (cfg.roUrl) roClient = new SecretClient(cfg.roUrl, cred);
  } catch (e) {
    die(`could not initialize Key Vault client: ${e.message}`);
  }

  const injected = {};
  for (const { secretName, envVar } of secrets) {
    try {
      const { value, tier } = await resolveSecret(rwClient, roClient, secretName);
      injected[envVar] = value;
      log(`resolved "${secretName}" -> $${envVar} [${tier}]`);
    } catch (e) {
      const code = e.statusCode ? ` (${e.statusCode})` : "";
      let hint = "";
      if (e.statusCode === 403) {
        hint = ' — no access in either vault; check Entra group membership / the data-plane "Key Vault Secrets User" role';
      } else if (e.statusCode === 401 || /az login|CredentialUnavailable|not.*found|please run/i.test(e.message)) {
        hint = " — not signed in; run `az login` and restart Claude";
      }
      die(`failed to fetch "${secretName}"${code}: ${e.message}${hint}`);
    }
  }

  // Spawn the real MCP server with secrets injected. stdio:"inherit" passes the
  // JSON-RPC stream straight through to the host untouched — do not change this.
  const [cmd, ...cmdArgs] = command;
  const child = spawn(cmd, cmdArgs, { stdio: "inherit", env: { ...process.env, ...injected } });
  child.on("error", (e) => die(`failed to spawn "${cmd}": ${e.message}`));
  child.on("exit", (code, signal) => {
    if (signal) process.kill(process.pid, signal);
    else process.exit(code ?? 0);
  });
  for (const sig of ["SIGINT", "SIGTERM"]) {
    process.on(sig, () => { try { child.kill(sig); } catch { /* already gone */ } });
  }
}

main().catch((e) => die(e.stack || e.message));
