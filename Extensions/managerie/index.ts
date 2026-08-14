/**
 * managerie - Managerie connector extension for Pi
 *
 * Forwards agent messages and live status to the Managerie menubar app via
 * its file event spool (~/.pi/agent/managerie/events/) — no ports, no
 * sockets. Also watches the Managerie inbox so the app can inject replies
 * into this session. Optional TTS via <voice> tags (off by default).
 *
 * Commands:
 *   /tts        - Toggle TTS on/off
 *   /tts-mute   - Mute audio (keeps voice tags in responses)
 *   /tts-style  - Toggle voice style (succinct/verbose)
 *   /tts-voice  - Change TTS voice
 *   /tts-say    - Speak arbitrary text
 *   /tts-stop   - Stop current speech
 *   /tts-status - Show status
 *
 * Global shortcut (via Managerie.app): Cmd+. to stop speech
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
const AVAILABLE_VOICES = ["auto", "alba", "vera", "paul", "charles", "michael", "anna", "fantine", "eponine", "cosette", "eve", "george", "mary", "marius", "javert", "azelma", "caro_davy", "peter_yearsley", "stuart_bell"];

// System prompt injection for voice tags - succinct style
const VOICE_PROMPT_SUCCINCT = `
## Voice Output

You have text-to-speech capabilities. When responding, include natural spoken summaries using <voice> tags.

Guidelines for <voice> content:
- Keep it brief and conversational (1-3 sentences)
- Summarize what you're doing or found, don't read code/details verbatim
- If you must read code make sure its verbalised e.g. <voice>fn len<'a> (s1 &'a) -> str</voice> is terrible instead say <voice> function len quote a in angle brackets paren s1 ampersand quote a end paren returns str </voice> . 
- Use natural speech patterns, contractions, casual tone
- Place <voice> tags at natural pause points in your response
- Use ONLY <voice>...</voice> tags for speech
- Never use other tags anywhere (no <emphasis>, <strong>, SSML, XML, or HTML tags)
- Never nest tags inside <voice>; keep voice text plain
- For code: describe what it does, don't read the code itself
- For errors: summarize the issue conversationally
- For confirmations: keep it simple like "Done!" or "Got it, working on that."

Examples:
- Starting work: <voice>Okay, let me look into that for you.</voice>
- Found something: <voice>Found the issue. Looks like there's a typo in the config file.</voice>
- Completed task: <voice>All done! Created the new component with the props you asked for.</voice>
- Explaining code: <voice>This function takes a list of users and filters out the inactive ones.</voice>

The text outside <voice> tags shows normally in the terminal. Only <voice> content is spoken.
`;

// System prompt injection for voice tags - verbose/conversational style
const VOICE_PROMPT_VERBOSE = `
## Voice Output

You have text-to-speech capabilities. When responding, use <voice> tags liberally to speak conversationally with the user.

Guidelines for <voice> content:
- Speak most of your conversational responses - questions, comments, reactions, explanations
- Use natural speech patterns, contractions, casual tone
- Multiple <voice> tags per response is encouraged
- Speak your thinking process, questions, and follow-ups
- Use ONLY <voice>...</voice> tags for speech
- Never use other tags anywhere (no <emphasis>, <strong>, SSML, XML, or HTML tags)
- Never nest tags inside <voice>; keep voice text plain
- For code: describe what it does (don't read the code itself)
- For file contents and technical details: summarize rather than read verbatim
- For errors: explain what went wrong conversationally
- For questions to the user: always speak them

Examples:
- Starting work: <voice>Okay, let me look into that for you.</voice>
- Thinking aloud: <voice>Hmm, this looks like it might be a permissions issue. Let me check the file ownership.</voice>
- Asking questions: <voice>Do you want me to fix this automatically, or would you rather review it first?</voice>
- Casual remarks: <voice>Nice! That test is passing now.</voice>
- Explaining findings: <voice>So I found the bug. Basically the loop was off by one, so it was skipping the last item in the array. Pretty common mistake actually.</voice>
- Follow-ups: <voice>That should do it! Let me know if you want me to add any tests for this.</voice>

The text outside <voice> tags shows normally in the terminal. Only <voice> content is spoken.
Speak freely and conversationally - the user prefers hearing your responses.
`;

type BrokerRequest = {
  type: "health" | "speak" | "stop" | "status";
  text?: string;
  voice?: string;
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
  queued?: number;
  pending?: number;
  playing?: boolean;
};

export default function (pi: ExtensionAPI) {
  let ttsEnabled = false;      // Voice mode is opt-in — Managerie is notification-first (/tts to enable)
  let ttsMuted = false;        // Just mute audio, keep voice tags
  let serverReady = false;
  let serverWarningShown = false;  // Only show server warning once per session
  let voiceStyle: "succinct" | "verbose" = "verbose";  // Voice prompt style
  let currentVoice = "auto";  // Current TTS voice ("auto" = let Loqui assign per-session)
  let currentSessionId: string | undefined;

  // Notification-first: track the turn's final assistant text so it can be
  // forwarded to Managerie as a notification when voice mode is off.
  let lastAssistantText = "";

  // Streaming parser state
  let lastFullText = "";
  let parserBuffer = "";
  let insideVoice = false;
  let speakBuffer = "";

  // Status tracking
  let lastStatusSent = "";
  const projectName = path.basename(process.cwd());
  let lastCtx: any = null;

  // Send agent status event to the broker (fire-and-forget)
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
    sendBrokerCommand(command).catch(() => {});
  }

  function sendStatusRemove() {
    sendBrokerCommand({
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
  const myPid = process.pid;
  const myInboxDir = path.join(INBOX_BASE_DIR, String(myPid));

  // Ensure inbox directory exists
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
              { customType: "voice_input", content: msg.text, display: true },
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

  // Start watching the inbox directory
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

  // Stop the inbox watcher
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
  async function sendBrokerCommand(command: BrokerRequest, _timeoutMs = 2500): Promise<BrokerResponse> {
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
  async function checkServer(): Promise<boolean> {
    serverReady = appAlive();
    return serverReady;
  }

  // Strip any accidental nested markup from voice content (e.g. <emphasis>)
  function sanitizeVoiceContent(text: string): string {
    return text.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
  }

  function activeSessionKey(): string {
    const sid = currentSessionId?.trim();
    return sid && sid.length > 0 ? sid : projectName;
  }

  async function enqueueSpeech(text: string) {
    if (!text.trim()) return;

    // Skip silently when server is known down to avoid log spam.
    if (!serverReady) return;

    try {
      const response = await sendBrokerCommand({
        type: "speak",
        text,
        voice: currentVoice === "auto" ? undefined : currentVoice,
        sourceApp: "pi",
        sessionId: activeSessionKey(),
        pid: process.pid,
      });

      if (!response.ok) {
        console.log("[TTS] Broker rejected speech:", response.error ?? "unknown error");
      }
    } catch {
      // Connection likely failed; mark not ready and fail silently.
      serverReady = false;
    }
  }

  function longestTagPrefixSuffix(text: string, tag: string): number {
    const max = Math.min(text.length, tag.length - 1);
    for (let len = max; len > 0; len--) {
      if (text.endsWith(tag.slice(0, len))) return len;
    }
    return 0;
  }

  function flushSpeakBuffer(force = false) {
    if (!speakBuffer.trim()) return;

    if (force) {
      const chunk = sanitizeVoiceContent(speakBuffer);
      speakBuffer = "";
      if (chunk) void enqueueSpeech(chunk);
      return;
    }

    // Prefer sentence-ish chunks for better prosody while still low-latency.
    let splitAt = -1;
    for (let i = 0; i < speakBuffer.length; i++) {
      const ch = speakBuffer[i];
      const next = speakBuffer[i + 1] ?? "";
      if ((ch === "." || ch === "!" || ch === "?" || ch === "…") && (!next || /[\s"'\)\]]/.test(next))) {
        splitAt = i + 1;
      }
    }

    if (splitAt > 0) {
      const chunk = sanitizeVoiceContent(speakBuffer.slice(0, splitAt));
      speakBuffer = speakBuffer.slice(splitAt).replace(/^\s+/, "");
      if (chunk) void enqueueSpeech(chunk);
      return;
    }

    // Fallback: flush long chunks at a word boundary.
    if (speakBuffer.length >= 140) {
      const preferred = 110;
      let split = speakBuffer.lastIndexOf(" ", preferred);
      if (split < 60) split = preferred;
      const chunk = sanitizeVoiceContent(speakBuffer.slice(0, split));
      speakBuffer = speakBuffer.slice(split).replace(/^\s+/, "");
      if (chunk) void enqueueSpeech(chunk);
    }
  }

  function streamVoiceText(text: string, forceFlush = false) {
    if (text) speakBuffer += text;
    flushSpeakBuffer(forceFlush);
  }

  function processDelta(delta: string) {
    if (!delta) return;

    parserBuffer += delta;

    while (parserBuffer.length > 0) {
      if (!insideVoice) {
        const openIdx = parserBuffer.indexOf("<voice>");
        if (openIdx >= 0) {
          parserBuffer = parserBuffer.slice(openIdx + "<voice>".length);
          insideVoice = true;
          continue;
        }

        const keep = longestTagPrefixSuffix(parserBuffer, "<voice>");
        parserBuffer = keep > 0 ? parserBuffer.slice(-keep) : "";
        return;
      }

      const closeIdx = parserBuffer.indexOf("</voice>");
      if (closeIdx >= 0) {
        const voiceText = parserBuffer.slice(0, closeIdx);
        streamVoiceText(voiceText, true);
        parserBuffer = parserBuffer.slice(closeIdx + "</voice>".length);
        insideVoice = false;
        continue;
      }

      const keep = longestTagPrefixSuffix(parserBuffer, "</voice>");
      const emitLen = parserBuffer.length - keep;
      if (emitLen > 0) {
        const textToSpeak = parserBuffer.slice(0, emitLen);
        streamVoiceText(textToSpeak, false);
      }
      parserBuffer = keep > 0 ? parserBuffer.slice(-keep) : "";
      return;
    }
  }

  // Process streaming text for voice tags (start speaking as soon as <voice> opens)
  async function processStreamingText(fullText: string) {
    if (!ttsEnabled || ttsMuted) return;

    // Retry server check if not ready
    if (!serverReady) {
      await checkServer();
      if (!serverReady) return;
    }

    let delta = "";
    if (fullText.startsWith(lastFullText)) {
      delta = fullText.slice(lastFullText.length);
    } else {
      // Stream was re-written (rare). Reset parser to avoid corrupt state.
      parserBuffer = "";
      insideVoice = false;
      speakBuffer = "";
      delta = fullText;
    }

    lastFullText = fullText;
    processDelta(delta);
  }

  function resetStreamingState(flushRemainder = false) {
    if (flushRemainder) {
      if (insideVoice && parserBuffer) {
        streamVoiceText(parserBuffer, true);
      } else {
        flushSpeakBuffer(true);
      }
    }

    lastFullText = "";
    parserBuffer = "";
    insideVoice = false;
    speakBuffer = "";
  }

  // Inject voice prompt into system prompt (only if TTS enabled)
  pi.on("before_agent_start", async (event) => {
    if (!ttsEnabled) return; // Don't inject voice prompt if disabled
    const prompt = voiceStyle === "verbose" ? VOICE_PROMPT_VERBOSE : VOICE_PROMPT_SUCCINCT;
    return {
      systemPrompt: event.systemPrompt + "\n" + prompt,
    };
  });

  // Check server on session start
  pi.on("session_start", async (_event, ctx) => {
    currentSessionId = ctx.sessionManager.getSessionId();
    serverWarningShown = false;  // Reset for new session

    // Show PID in status bar (used by Managerie jump handler to identify panes)
    ctx.ui.setStatus("pid", `πid${process.pid}`);

    // Start inbox watcher for receiving messages from external apps
    startInboxWatcher();

    const ready = await checkServer();
    if (ready) {
      ctx.ui.setStatus("managerie", ttsEnabled ? "🏠🔊" : "🏠");
    } else {
      if (!serverWarningShown) {
        ctx.ui.notify(
          "⚠️ Managerie is not running — agent notifications and replies are offline.",
          "warning"
        );
        serverWarningShown = true;
      }
      ctx.ui.setStatus("managerie", "⚠️");
    }
  });

  pi.on("session_switch", async (_event, ctx) => {
    currentSessionId = ctx.sessionManager.getSessionId();
  });

  pi.on("message_start", async (event, ctx) => {
    if (event.message.role === "user") {
      // User sent a new message — clear queued/playing speech for the active Pi session only.
      if (!serverReady) {
        await checkServer();
      }
      if (serverReady) {
        sendBrokerCommand({
          type: "stop",
          sourceApp: "pi",
          sessionId: activeSessionKey(),
        }).catch(() => {});
      }
    }

    if (event.message.role === "assistant") {
      resetStreamingState();
      lastAssistantText = "";
      // Re-check server in case it was started/stopped
      const wasReady = serverReady;
      await checkServer();
      if (wasReady !== serverReady) {
        updateStatus(ctx);
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

    const fullText = textParts.join(" ");
    lastAssistantText = fullText;

    if (!ttsEnabled || ttsMuted) return;
    void processStreamingText(fullText);
  });

  pi.on("message_end", async (event) => {
    if (event.message.role === "assistant") {
      resetStreamingState(true);
    }
  });

  // Status events: agent lifecycle
  pi.on("agent_start", async (_event, ctx) => {
    lastCtx = ctx;
    sendStatus("starting");
  });

  pi.on("agent_end", async (_event, ctx) => {
    lastCtx = ctx;
    sendStatus("done");

    // Notification-first: with voice mode off, forward the turn's final
    // message so Managerie can surface it as a notification.
    if (!ttsEnabled) {
      const text = lastAssistantText.replace(/\s+/g, " ").trim().slice(0, 400);
      lastAssistantText = "";
      if (text) {
        if (!serverReady) await checkServer();
        if (serverReady) {
          sendBrokerCommand({
            type: "speak",
            text,
            sourceApp: "pi",
            sessionId: activeSessionKey(),
            pid: process.pid,
          }).catch(() => {});
        }
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

  // Helper to update status display
  function updateStatus(ctx: { ui: { setStatus: (id: string, text: string) => void } }) {
    if (!ttsEnabled) {
      ctx.ui.setStatus("tts", "🔇 off");
    } else if (ttsMuted) {
      ctx.ui.setStatus("tts", "🔇");
    } else if (serverReady) {
      ctx.ui.setStatus("tts", voiceStyle === "verbose" ? "🔊+" : "🔊");
    } else {
      ctx.ui.setStatus("tts", "⚠️");
    }
  }

  // Commands
  pi.registerCommand("tts", {
    description: "Toggle TTS completely on/off (includes voice prompt injection)",
    handler: async (_args, ctx) => {
      ttsEnabled = !ttsEnabled;
      ttsMuted = false; // Reset mute when toggling master
      ctx.ui.notify(
        ttsEnabled
          ? "🔊 TTS enabled - I'll include voice summaries"
          : "🔇 TTS disabled - normal text responses",
        "info"
      );
      updateStatus(ctx);
    },
  });

  pi.registerCommand("tts-mute", {
    description: "Mute/unmute TTS audio (keeps voice tags in responses)",
    handler: async (_args, ctx) => {
      if (!ttsEnabled) {
        ctx.ui.notify("TTS is disabled. Use /tts to enable first.", "warning");
        return;
      }
      ttsMuted = !ttsMuted;
      ctx.ui.notify(ttsMuted ? "🔇 TTS muted" : "🔊 TTS unmuted", "info");
      updateStatus(ctx);
    },
  });

  pi.registerCommand("tts-style", {
    description: "Toggle voice style: succinct (brief summaries) or verbose (more conversational)",
    handler: async (_args, ctx) => {
      voiceStyle = voiceStyle === "verbose" ? "succinct" : "verbose";
      ctx.ui.notify(
        voiceStyle === "verbose"
          ? "🔊+ Voice style: verbose (more conversational)"
          : "🔊 Voice style: succinct (brief summaries)",
        "info"
      );
      updateStatus(ctx);
    },
  });

  pi.registerCommand("tts-voice", {
    description: `Change TTS voice (${AVAILABLE_VOICES.join(", ")})`,
    handler: async (args, ctx) => {
      if (!args) {
        const voiceDisplay = currentVoice === "auto" ? "auto (Loqui assigns per-session)" : currentVoice;
        ctx.ui.notify(`Current voice: ${voiceDisplay}\nAvailable: ${AVAILABLE_VOICES.join(", ")}`, "info");
        return;
      }
      const voice = args.trim().toLowerCase();
      if (!AVAILABLE_VOICES.includes(voice)) {
        ctx.ui.notify(`Unknown voice: ${voice}\nAvailable: ${AVAILABLE_VOICES.join(", ")}`, "warning");
        return;
      }
      currentVoice = voice;
      const msg = voice === "auto" 
        ? "🎤 Voice: auto (Loqui will assign different voices per session)"
        : `🎤 Voice changed to: ${voice}`;
      ctx.ui.notify(msg, "info");
    },
  });

  pi.registerCommand("tts-say", {
    description: "Speak arbitrary text",
    handler: async (args, ctx) => {
      if (!args) {
        ctx.ui.notify("Usage: /tts-say <text>", "warning");
        return;
      }
      if (!serverReady) {
        const ready = await checkServer();
        if (!ready) {
          ctx.ui.notify("Loqui broker not running", "error");
          return;
        }
      }
      await enqueueSpeech(args);
    },
  });

  pi.registerCommand("tts-stop", {
    description: "Stop current speech",
    handler: async (_args, ctx) => {
      try {
        await sendBrokerCommand({ type: "stop", sourceApp: "pi", sessionId: activeSessionKey() });
        ctx.ui.notify("Speech stopped", "info");
      } catch {
        ctx.ui.notify("Could not reach Loqui broker", "warning");
      }
    },
  });

  pi.registerCommand("tts-status", {
    description: "Show TTS status",
    handler: async (_args, ctx) => {
      const ready = await checkServer();
      const voiceDisplay = currentVoice === "auto" ? "auto (per-session)" : currentVoice;
      const status = [
        `Server: ${ready ? "running ✓" : "not running ✗"}`,
        `TTS: ${ttsEnabled ? "enabled" : "disabled"}`,
        `Audio: ${ttsMuted ? "muted" : "on"}`,
        `Voice: ${voiceDisplay}`,
        `Style: ${voiceStyle}`,
        `Session: ${currentSessionId ?? "unknown"}`,
      ].join(" | ");
      ctx.ui.notify(status, "info");
      updateStatus(ctx);
    },
  });
}
