/**
 * managerie - Managerie connector extension for Pi
 *
 * Forwards agent messages and live status to the Managerie menubar app via
 * its file event spool (~/.pi/agent/managerie/events/) — no ports, no
 * sockets. Also watches the Managerie inbox so the app can inject replies
 * into this session.
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import process from "node:process";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

// Inbox configuration for receiving messages from external apps
const INBOX_BASE_DIR = path.join(os.homedir(), ".pi", "agent", "managerie-inbox");

// Port-free transport: events are dropped as files into Managerie's spool
// directory; the app watches it and ingests. The heartbeat file (touched by
// the app every 10s) is how we know Managerie is running.
const SPOOL_DIR = path.join(os.homedir(), ".pi", "agent", "managerie", "events");
const HEARTBEAT_FILE = path.join(os.homedir(), ".pi", "agent", "managerie", "app.alive");

/**
 * `speak` is the legacy wire name for "deliver this message" — kept so
 * already-installed Managerie builds keep working.
 */
type BrokerRequest = {
  type: "health" | "speak" | "status";
  text?: string;
  sourceApp?: string;
  sessionId?: string;
  pid?: number;
  // Status event fields
  status?: string;
  detail?: string;
  project?: string;
  cwd?: string;
  contextPercent?: number;
};

type BrokerResponse = {
  ok?: boolean;
  error?: string;
};

export default function (pi: ExtensionAPI) {
  let appReady = false;
  let appWarningShown = false;  // Only warn once per session
  let currentSessionId: string | undefined;

  // Track the turn's final assistant text so it can be forwarded to Managerie
  // as a notification when the turn ends.
  let lastAssistantText = "";

  // Status tracking
  let lastStatusSent = "";
  const projectName = path.basename(process.cwd());
  let lastCtx: any = null;

  // Send agent status event to Managerie (fire-and-forget)
  function sendStatus(status: string, detail?: string) {
    lastStatusSent = status;
    const command: BrokerRequest = {
      type: "status",
      pid: process.pid,
      project: projectName,
      cwd: process.cwd(),
      status,
      detail: detail ? detail.slice(0, 100) : undefined,
    };
    // Include context usage if available
    if (lastCtx) {
      try {
        const usage = lastCtx.getContextUsage();
        if (usage && usage.percent != null) {
          command.contextPercent = Math.round(usage.percent);
        }
      } catch {}
    }
    sendCommand(command).catch(() => {});
  }

  function sendStatusRemove() {
    sendCommand({
      type: "status",
      pid: process.pid,
      status: "remove",
    }).catch(() => {});
    lastStatusSent = "";
  }

  function compactDetail(text?: string, max = 64): string | undefined {
    if (!text) return undefined;
    const oneLine = text.replace(/\s+/g, " ").trim();
    if (!oneLine) return undefined;
    return oneLine.length > max ? oneLine.slice(0, max - 1) + "…" : oneLine;
  }

  // Inbox watcher state
  let inboxWatcher: fs.FSWatcher | null = null;
  let inboxDebounceTimer: ReturnType<typeof setTimeout> | null = null;
  const myInboxDir = path.join(INBOX_BASE_DIR, String(process.pid));

  function ensureInboxDir() {
    try {
      fs.mkdirSync(myInboxDir, { recursive: true });
    } catch {
      // Ignore errors
    }
  }

  // Process all pending message files in inbox
  function processInboxMessages() {
    try {
      const files = fs.readdirSync(myInboxDir).filter(f => f.endsWith(".json")).sort();
      for (const file of files) {
        const filePath = path.join(myInboxDir, file);
        try {
          const content = fs.readFileSync(filePath, "utf-8");
          const msg = JSON.parse(content);

          if (msg.text) {
            // Inject the message into pi
            pi.sendMessage(
              { customType: "managerie_input", content: msg.text, display: true },
              { triggerTurn: true }
            );
          }

          // Delete the file after processing
          fs.unlinkSync(filePath);
        } catch {
          // Ignore individual file errors, try to delete anyway
          try { fs.unlinkSync(filePath); } catch { /* ignore */ }
        }
      }
    } catch {
      // Ignore read errors
    }
  }

  function startInboxWatcher() {
    if (inboxWatcher) return;

    ensureInboxDir();
    processInboxMessages(); // Process any pending messages

    try {
      inboxWatcher = fs.watch(myInboxDir, () => {
        // Debounce rapid events
        if (inboxDebounceTimer) clearTimeout(inboxDebounceTimer);
        inboxDebounceTimer = setTimeout(() => {
          inboxDebounceTimer = null;
          processInboxMessages();
        }, 50);
      });

      inboxWatcher.on("error", () => {
        stopInboxWatcher();
      });
    } catch {
      // Ignore watcher errors
    }
  }

  function stopInboxWatcher() {
    if (inboxDebounceTimer) {
      clearTimeout(inboxDebounceTimer);
      inboxDebounceTimer = null;
    }
    if (inboxWatcher) {
      inboxWatcher.close();
      inboxWatcher = null;
    }
  }

  // Is the Managerie app alive? It touches the heartbeat file every 10s.
  function appAlive(maxAgeMs = 30_000): boolean {
    try {
      const stat = fs.statSync(HEARTBEAT_FILE);
      return Date.now() - stat.mtimeMs < maxAgeMs;
    } catch {
      return false;
    }
  }

  // Drop an event file into the spool — atomic tmp-write + rename so the app
  // never reads a half-written file. Fire-and-forget: no ports, no responses.
  let spoolSeq = 0;
  async function sendCommand(command: BrokerRequest): Promise<BrokerResponse> {
    if (command.type === "health") {
      return { ok: appAlive() };
    }
    fs.mkdirSync(SPOOL_DIR, { recursive: true });
    // Zero-padded ms timestamp keeps lexicographic order == arrival order.
    const name = `${String(Date.now()).padStart(13, "0")}-${process.pid}-${(spoolSeq++).toString(36)}${Math.random()
      .toString(36)
      .slice(2, 6)}.json`;
    const tmpPath = path.join(SPOOL_DIR, `.${name}.tmp`);
    fs.writeFileSync(tmpPath, `${JSON.stringify(command)}\n`);
    fs.renameSync(tmpPath, path.join(SPOOL_DIR, name));
    return { ok: true };
  }

  // Check if the Managerie app is running (heartbeat freshness — no network).
  async function checkApp(): Promise<boolean> {
    appReady = appAlive();
    return appReady;
  }

  function activeSessionKey(): string {
    const sid = currentSessionId?.trim();
    return sid && sid.length > 0 ? sid : projectName;
  }

  pi.on("session_start", async (_event, ctx) => {
    currentSessionId = ctx.sessionManager.getSessionId();
    appWarningShown = false;  // Reset for new session

    // Show PID in status bar (used by Managerie jump handler to identify panes)
    ctx.ui.setStatus("pid", `πid${process.pid}`);

    // Start inbox watcher for receiving messages from external apps
    startInboxWatcher();

    const ready = await checkApp();
    if (ready) {
      ctx.ui.setStatus("managerie", "🏠");
    } else {
      if (!appWarningShown) {
        ctx.ui.notify(
          "⚠️ Managerie is not running — agent notifications and replies are offline.",
          "warning"
        );
        appWarningShown = true;
      }
      ctx.ui.setStatus("managerie", "⚠️");
    }
  });

  pi.on("session_switch", async (_event, ctx) => {
    currentSessionId = ctx.sessionManager.getSessionId();
  });

  pi.on("message_start", async (event, ctx) => {
    if (event.message.role === "assistant") {
      lastAssistantText = "";
      // Re-check in case the app was started/stopped
      const wasReady = appReady;
      await checkApp();
      if (wasReady !== appReady) {
        ctx.ui.setStatus("managerie", appReady ? "🏠" : "⚠️");
      }
    }
  });

  pi.on("message_update", async (event, ctx) => {
    lastCtx = ctx;
    // Send status: agent is thinking/streaming
    if (lastStatusSent !== "thinking") {
      sendStatus("thinking");
    }

    const msg = event.message;
    if (msg.role !== "assistant") return;

    const textParts = msg.content
      .filter((c): c is { type: "text"; text: string } => c.type === "text")
      .map((c) => c.text);

    lastAssistantText = textParts.join(" ");
  });

  // Status events: agent lifecycle
  pi.on("agent_start", async (_event, ctx) => {
    lastCtx = ctx;
    sendStatus("starting");
  });

  pi.on("agent_end", async (_event, ctx) => {
    lastCtx = ctx;
    sendStatus("done");

    // Forward the turn's final message so Managerie can surface it as a
    // notification.
    const text = lastAssistantText.replace(/\s+/g, " ").trim().slice(0, 400);
    lastAssistantText = "";
    if (text) {
      if (!appReady) await checkApp();
      if (appReady) {
        sendCommand({
          type: "speak",
          text,
          sourceApp: "pi",
          sessionId: activeSessionKey(),
          pid: process.pid,
        }).catch(() => {});
      }
    }
  });

  // Status events: tool execution
  pi.on("tool_execution_start", async (event, ctx) => {
    lastCtx = ctx;
    const { toolName, args = {} } = event;

    switch (toolName) {
      case "read":
        sendStatus("reading", compactDetail(path.basename(args.path ?? "")) ?? "read");
        break;
      case "edit":
      case "write":
        sendStatus("editing", compactDetail(path.basename(args.path ?? "")) ?? toolName);
        break;
      case "bash":
        sendStatus("running", compactDetail(args.command) ?? "bash");
        break;
      case "grep":
      case "find":
      case "ls":
        sendStatus("searching", toolName);
        break;
      case "web_search":
      case "fetch_content":
      case "read_web_page":
        sendStatus("running", toolName);
        break;
      default:
        sendStatus("running", toolName);
    }
  });

  pi.on("tool_execution_end", async (event, ctx) => {
    lastCtx = ctx;
    if (event.isError) {
      sendStatus("error", event.toolName);
    }
  });

  // Cleanup on session shutdown
  pi.on("session_shutdown", async () => {
    sendStatusRemove();
    stopInboxWatcher();
    // Try to remove inbox directory
    try {
      fs.rmSync(myInboxDir, { recursive: true, force: true });
    } catch {
      // Ignore cleanup errors
    }
  });

  pi.registerCommand("managerie-status", {
    description: "Show Managerie connection status",
    handler: async (_args, ctx) => {
      const ready = await checkApp();
      const status = [
        `Managerie: ${ready ? "running ✓" : "not running ✗"}`,
        `Session: ${currentSessionId ?? "unknown"}`,
        `Project: ${projectName}`,
      ].join(" | ");
      ctx.ui.notify(status, "info");
      ctx.ui.setStatus("managerie", ready ? "🏠" : "⚠️");
    },
  });
}
