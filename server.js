#!/usr/bin/env node
/**
 * precisionit-mail — MCP stdio server that sends email via the SMTP2GO HTTP API.
 *
 * Credentials are NEVER read from config. They arrive as environment variables,
 * injected at runtime by the Key Vault launcher (mcp-keyvault-launch.js):
 *
 *   SMTP2GO_API_KEY   (required)  — key scoped to /email/send
 *   MAIL_SENDER       (optional)  — default From; falls back to dan@myprecisionit.com
 *   SMTP2GO_API_BASE  (optional)  — override region, e.g. https://us-api.smtp2go.com/v3
 *   MAIL_DRY_RUN      (optional)  — "1"/"true" → don't send, just report what would send
 *
 * Exposes one tool: send_email
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { readFile } from "node:fs/promises";
import { basename, extname } from "node:path";

const API_BASE = process.env.SMTP2GO_API_BASE || "https://api.smtp2go.com/v3";
const API_KEY = process.env.SMTP2GO_API_KEY;
const DEFAULT_SENDER = process.env.MAIL_SENDER || "dan@myprecisionit.com";
const DRY_RUN = /^(1|true|yes)$/i.test(process.env.MAIL_DRY_RUN || "");
const MAX_TOTAL_BYTES = 50 * 1024 * 1024; // SMTP2GO hard cap: 50 MB content+attachments+headers

const MIME = {
  ".pdf": "application/pdf",
  ".html": "text/html", ".htm": "text/html",
  ".csv": "text/csv", ".txt": "text/plain", ".json": "application/json",
  ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
  ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ".xls": "application/vnd.ms-excel",
  ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  ".doc": "application/msword",
  ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  ".zip": "application/zip",
};

const asArray = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);

async function buildAttachments(paths) {
  const out = [];
  let total = 0;
  for (const p of asArray(paths)) {
    if (p !== null && typeof p === "object") {
      // Pre-encoded content object { filename, content_base64, mimetype? } —
      // caller read the file client-side and passed the bytes directly.
      // Also accepts the internal gateway shape { filename, fileblob, mimetype }.
      const b64 = p.content_base64 ?? p.fileblob;
      if (!b64) throw new Error(`Attachment object missing content_base64: ${JSON.stringify(p)}`);
      const ext = extname(p.filename ?? "").toLowerCase();
      const decoded = Buffer.from(b64, "base64");
      total += decoded.length;
      out.push({
        filename: p.filename,
        fileblob: b64,
        mimetype: p.mimetype || MIME[ext] || "application/octet-stream",
      });
    } else {
      let buf;
      try {
        buf = await readFile(String(p));
      } catch (e) {
        throw new Error(`Attachment not found or unreadable: ${p} (${e.code || e.message})`);
      }
      total += buf.length;
      out.push({
        filename: basename(String(p)),
        fileblob: buf.toString("base64"),
        mimetype: MIME[extname(String(p)).toLowerCase()] || "application/octet-stream",
      });
    }
  }
  return { attachments: out, total };
}

const server = new Server(
  { name: "precisionit-mail", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "send_email",
      description:
        "Send an email via SMTP2GO from dan@myprecisionit.com (or an override). " +
        "Supports HTML and/or plain-text bodies, cc/bcc, reply-to, and file attachments. " +
        "ATTACHMENTS: pass a { filename, content_base64, mimetype? } object (base64-encode " +
        "the file first via Bash: base64 -i /path/to/file) — file path strings only work " +
        "when the server process can read them directly (local stdio, not the remote gateway). " +
        "Intended primarily for sending generated reports.",
      inputSchema: {
        type: "object",
        properties: {
          to: {
            description: "Recipient address, or array of addresses.",
            anyOf: [{ type: "string" }, { type: "array", items: { type: "string" } }],
          },
          subject: { type: "string" },
          body_html: { type: "string", description: "HTML body. Provide this and/or body_text." },
          body_text: { type: "string", description: "Plain-text body / fallback." },
          cc: { anyOf: [{ type: "string" }, { type: "array", items: { type: "string" } }] },
          bcc: { anyOf: [{ type: "string" }, { type: "array", items: { type: "string" } }] },
          reply_to: { type: "string" },
          sender: {
            type: "string",
            description: `From address. Defaults to ${DEFAULT_SENDER}. Domain must be verified in SMTP2GO.`,
          },
          attachments: {
            description:
              "File attachment(s). Each item is EITHER a local file path string (only works " +
              "when the server process can read the path — i.e. the local stdio connector, not " +
              "the remote gateway) OR a pre-encoded content object for remote/gateway use: " +
              "{ filename: string, content_base64: string, mimetype?: string }. " +
              "To attach a file via the remote gateway, base64-encode it first " +
              "(e.g. Bash: base64 -i /path/to/file) and pass the object form.",
            anyOf: [
              { type: "string" },
              {
                type: "object",
                properties: {
                  filename: { type: "string" },
                  content_base64: { type: "string", description: "Base64-encoded file content." },
                  mimetype: { type: "string" },
                },
                required: ["filename", "content_base64"],
              },
              {
                type: "array",
                items: {
                  anyOf: [
                    { type: "string" },
                    {
                      type: "object",
                      properties: {
                        filename: { type: "string" },
                        content_base64: { type: "string" },
                        mimetype: { type: "string" },
                      },
                      required: ["filename", "content_base64"],
                    },
                  ],
                },
              },
            ],
          },
        },
        required: ["to", "subject"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  if (req.params.name !== "send_email") {
    return { content: [{ type: "text", text: `Unknown tool: ${req.params.name}` }], isError: true };
  }

  const a = req.params.arguments || {};
  const to = asArray(a.to);
  const cc = asArray(a.cc);
  const bcc = asArray(a.bcc);

  try {
    if (!API_KEY) throw new Error("SMTP2GO_API_KEY is not set — the Key Vault launcher did not inject it.");
    if (to.length === 0) throw new Error("At least one 'to' recipient is required.");
    if (!a.body_html && !a.body_text) throw new Error("Provide body_html and/or body_text.");

    const { attachments, total } = await buildAttachments(a.attachments);
    if (total > MAX_TOTAL_BYTES) {
      throw new Error(
        `Attachments total ${(total / 1048576).toFixed(1)} MB, over SMTP2GO's 50 MB limit. ` +
        `Send a link instead, or split the report.`
      );
    }

    const payload = {
      sender: a.sender || DEFAULT_SENDER,
      to,
      subject: a.subject,
      ...(cc.length ? { cc } : {}),
      ...(bcc.length ? { bcc } : {}),
      ...(a.body_html ? { html_body: a.body_html } : {}),
      ...(a.body_text ? { text_body: a.body_text } : {}),
      ...(attachments.length ? { attachments } : {}),
      ...(a.reply_to ? { custom_headers: [{ header: "Reply-To", value: a.reply_to }] } : {}),
    };

    if (DRY_RUN) {
      const summary = {
        dry_run: true,
        from: payload.sender,
        to, cc, bcc,
        subject: payload.subject,
        has_html: !!a.body_html,
        has_text: !!a.body_text,
        attachments: attachments.map((x) => `${x.filename} (${x.mimetype})`),
        total_attachment_bytes: total,
      };
      return { content: [{ type: "text", text: "DRY RUN — nothing sent.\n" + JSON.stringify(summary, null, 2) }] };
    }

    const res = await fetch(`${API_BASE}/email/send`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-Smtp2go-Api-Key": API_KEY,
      },
      body: JSON.stringify(payload),
    });

    const data = await res.json().catch(() => ({}));

    if (!res.ok || (data?.data?.failed ?? 0) > 0 || data?.data?.error) {
      const detail =
        data?.data?.error ||
        (data?.data?.failures ? JSON.stringify(data.data.failures) : `HTTP ${res.status}`);
      return {
        content: [{ type: "text", text: `Send failed: ${detail}\nrequest_id: ${data?.request_id || "n/a"}` }],
        isError: true,
      };
    }

    const d = data.data || {};
    return {
      content: [
        {
          type: "text",
          text:
            `Sent. email_id=${d.email_id || "n/a"} succeeded=${d.succeeded ?? "?"} ` +
            `to=[${to.join(", ")}]${cc.length ? ` cc=[${cc.join(", ")}]` : ""}` +
            `${attachments.length ? ` attachments=${attachments.length}` : ""}`,
        },
      ],
    };
  } catch (e) {
    return { content: [{ type: "text", text: `Error: ${e.message}` }], isError: true };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
