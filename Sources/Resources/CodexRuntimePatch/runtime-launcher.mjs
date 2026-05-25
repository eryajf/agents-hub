#!/usr/bin/env node
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync } from "node:fs";
import http from "node:http";
import net from "node:net";
import path from "node:path";

const connectTimeoutMs = 12000;
const httpTimeoutMs = 3000;
const initialLoadSettleMs = 1000;

const targets = [
  {
    feature: "fast",
    label: "Fast mode",
    file: "use-is-fast-mode-enabled-CwUgvZ2O.js",
    search: "d?.authMethod!==`chatgpt`||g",
    replacement: "false                    ||g",
  },
  {
    feature: "plugins",
    label: "Plugins sidebar",
    file: "app-main-DG-Mf4Wj.js",
    search:
      "{authMethod:c}=Ba(),l=Li(`533078438`),u=Cc(c),d=e&&l&&u,f=bs({hostId:Tt}),p=e&&f&&!u,",
    replacement:
      "{authMethod:c}=Ba(),l=Li(`533078438`),u=Cc(c),d=!1  ,f=bs({hostId:Tt}),p=e&&f       ,",
  },
  {
    feature: "plugins",
    label: "Plugins page",
    file: "skills-page-C8PW4EqX.js",
    search: "let m=f,g,v;",
    replacement: "let m=0,g,v;",
  },
  {
    feature: "plugins",
    label: "Plugins page legacy repair",
    file: "skills-page-C8PW4EqX.js",
    search: "s&&!1)",
    replacement: "s&&!m)",
  },
  {
    feature: "plugins",
    label: "Plugin detail",
    file: "plugin-detail-page-jAJa26RM.js",
    search: "{authMethod:i}=oe();if(Be(i)){",
    replacement: "{authMethod:i}=oe();if(!1   ){",
  },
  {
    feature: "plugins",
    label: "Plugin availability",
    file: "check-plugin-availability-6p9UsIaB.js",
    search:
      "let F=w.length>0&&N===w.length?M?`disabled-by-admin`:`connector-unavailable`:null,I;",
    replacement:
      "let F=w.length>0&&N===w.length?M?`disabled-by-admin`:null                   :null,I;",
  },
  {
    feature: "plugins",
    label: "Plugin install flow",
    file: "use-plugin-install-flow-IT_xMrDV.js",
    search: "let g=m,_=(u?.apps.length??0)>0&&u?.summary.authPolicy===`ON_INSTALL`,v;",
    replacement: "let g=m,_=(u?.apps.length??0)>0&&!1                                  ,v;",
  },
  {
    feature: "appshot",
    label: "Appshot availability",
    file: "use-is-appshot-available-D0PV8qeY.js",
    search: "return n===`macOS`&&r",
    replacement: "return n===`macOS`   ",
  },
  {
    feature: "appshot",
    label: "Appshot service enablement",
    file: "app-main-DG-Mf4Wj.js",
    search: "appshotsEnabled:r,artifactsPane:!0",
    replacement: "appshotsEnabled:!0,artifactsPane:1",
  },
];

function parseArgs() {
  const result = { app: "", port: 0, features: new Set() };
  for (let index = 2; index < process.argv.length; index += 1) {
    const arg = process.argv[index];
    if (arg === "--app") {
      result.app = process.argv[++index] ?? "";
    } else if (arg === "--port") {
      result.port = Number(process.argv[++index] ?? "0");
    } else if (arg === "--features") {
      for (const feature of (process.argv[++index] ?? "").split(",")) {
        if (feature) result.features.add(feature);
      }
    }
  }
  if (!result.app || !result.port || result.features.size === 0) {
    throw new Error("Usage: runtime-launcher.mjs --app <Codex.app> --port <port> --features fast,plugins,appshot");
  }
  return result;
}

function isRuntimeJavaScriptResource(resourceUrl) {
  return /^app:\/\/[^?#]+\/(?:webview\/)?assets\/[^/?#]+\.js(?:[?#].*)?$/.test(resourceUrl);
}

function targetMatchesURL(target, resourceUrl) {
  return resourceUrl.includes(`/assets/${target.file}`) || resourceUrl.includes(`/webview/assets/${target.file}`);
}

function applyPatches(resourceUrl, body, features) {
  let content = body;
  const labels = [];
  for (const target of targets) {
    if (!features.has(target.feature) || !targetMatchesURL(target, resourceUrl)) {
      continue;
    }
    if (content.includes(target.replacement)) {
      labels.push(target.label);
      continue;
    }
    if (content.includes(target.search)) {
      content = content.replace(target.search, target.replacement);
      labels.push(target.label);
    }
  }
  return { content, labels };
}

function httpGetJson(url) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let request = null;
    const timeout = setTimeout(() => {
      request?.destroy(new Error(`Timed out fetching ${url}.`));
    }, httpTimeoutMs);
    const finish = (callback) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      callback();
    };
    request = http
      .get(url, (response) => {
        const chunks = [];
        response.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
        response.on("end", () => {
          if ((response.statusCode ?? 500) >= 400) {
            finish(() => reject(new Error(`HTTP ${response.statusCode}`)));
            return;
          }
          try {
            finish(() => resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))));
          } catch (error) {
            finish(() => reject(error));
          }
        });
      })
      .on("error", (error) => finish(() => reject(error)));
  });
}

function encodeTextFrame(payload) {
  const body = Buffer.from(payload, "utf8");
  const mask = randomBytes(4);
  const header = [0x81];
  if (body.length < 126) {
    header.push(0x80 | body.length);
  } else if (body.length <= 0xffff) {
    header.push(0x80 | 126, (body.length >> 8) & 0xff, body.length & 0xff);
  } else {
    const length = Buffer.alloc(8);
    length.writeBigUInt64BE(BigInt(body.length), 0);
    header.push(0x80 | 127, ...length);
  }
  const masked = Buffer.alloc(body.length);
  for (let index = 0; index < body.length; index += 1) {
    masked[index] = body[index] ^ mask[index % 4];
  }
  return Buffer.concat([Buffer.from(header), mask, masked]);
}

function decodeTextFrames(buffer, fragments = []) {
  const messages = [];
  let offset = 0;
  let pendingFragments = fragments;
  while (offset + 2 <= buffer.length) {
    const firstByte = buffer[offset];
    const finalFrame = (firstByte & 0x80) !== 0;
    const opcode = firstByte & 0x0f;
    const secondByte = buffer[offset + 1];
    const masked = (secondByte & 0x80) !== 0;
    let length = secondByte & 0x7f;
    let headerLength = 2;
    if (length === 126) {
      if (offset + 4 > buffer.length) break;
      length = buffer.readUInt16BE(offset + 2);
      headerLength = 4;
    } else if (length === 127) {
      if (offset + 10 > buffer.length) break;
      const bigLength = buffer.readBigUInt64BE(offset + 2);
      if (bigLength > BigInt(Number.MAX_SAFE_INTEGER)) {
        throw new Error("CDP frame payload is too large.");
      }
      length = Number(bigLength);
      headerLength = 10;
    }
    if (masked) throw new Error("Unexpected masked server WebSocket frame.");
    if (offset + headerLength + length > buffer.length) break;

    const payload = buffer.subarray(offset + headerLength, offset + headerLength + length);
    if (opcode === 1) {
      if (finalFrame) {
        messages.push(payload.toString("utf8"));
      } else {
        pendingFragments = [payload];
      }
    } else if (opcode === 0 && pendingFragments.length > 0) {
      pendingFragments.push(payload);
      if (finalFrame) {
        messages.push(Buffer.concat(pendingFragments).toString("utf8"));
        pendingFragments = [];
      }
    }
    offset += headerLength + length;
  }
  return { messages, remaining: buffer.subarray(offset), fragments: pendingFragments };
}

class CdpConnection {
  constructor(socket, initialBuffer = Buffer.alloc(0)) {
    this.socket = socket;
    this.nextCommandId = 1;
    this.pending = new Map();
    this.handlers = new Map();
    this.buffer = initialBuffer;
    this.fragments = [];
    this.closed = false;
    socket.on("data", (chunk) => this.read(chunk));
    socket.on("error", (error) => this.rejectAll(error));
    socket.on("close", () => this.rejectAll(new Error("CDP WebSocket connection closed.")));
    if (initialBuffer.length > 0) this.read(Buffer.alloc(0));
  }

  static connect(webSocketUrl) {
    return new Promise((resolve, reject) => {
      const parsed = new URL(webSocketUrl);
      const key = randomBytes(16).toString("base64");
      const socket = net.createConnection({ host: parsed.hostname, port: Number(parsed.port) || 80 });
      const timeout = setTimeout(() => {
        socket.destroy(new Error("Timed out connecting to CDP WebSocket."));
      }, connectTimeoutMs);
      let handshake = Buffer.alloc(0);
      let settled = false;
      const finish = (callback) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        socket.removeAllListeners("data");
        callback();
      };
      socket.on("connect", () => {
        socket.write(
          [
            `GET ${parsed.pathname}${parsed.search} HTTP/1.1`,
            `Host: ${parsed.host}`,
            "Upgrade: websocket",
            "Connection: Upgrade",
            `Sec-WebSocket-Key: ${key}`,
            "Sec-WebSocket-Version: 13",
            "\r\n",
          ].join("\r\n"),
        );
      });
      socket.on("data", (chunk) => {
        handshake = Buffer.concat([handshake, chunk]);
        const headerEnd = handshake.indexOf("\r\n\r\n");
        if (headerEnd === -1) return;
        const header = handshake.subarray(0, headerEnd).toString("utf8");
        const remaining = handshake.subarray(headerEnd + 4);
        if (!header.startsWith("HTTP/1.1 101") && !header.startsWith("HTTP/1.0 101")) {
          finish(() => reject(new Error("CDP WebSocket upgrade failed.")));
          socket.destroy();
          return;
        }
        finish(() => resolve(new CdpConnection(socket, remaining)));
      });
      socket.on("error", (error) => finish(() => reject(error)));
    });
  }

  on(method, handler) {
    const handlers = this.handlers.get(method) ?? [];
    handlers.push(handler);
    this.handlers.set(method, handlers);
  }

  send(method, params = {}) {
    if (this.closed) return Promise.reject(new Error("CDP WebSocket connection is closed."));
    const id = this.nextCommandId++;
    const payload = JSON.stringify({ id, method, params });
    this.socket.write(encodeTextFrame(payload));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
    });
  }

  read(chunk) {
    try {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      const decoded = decodeTextFrames(this.buffer, this.fragments);
      this.buffer = decoded.remaining;
      this.fragments = decoded.fragments;
      for (const message of decoded.messages) {
        const parsed = JSON.parse(message);
        if (typeof parsed.id === "number") {
          const pending = this.pending.get(parsed.id);
          if (!pending) continue;
          this.pending.delete(parsed.id);
          if (parsed.error) {
            pending.reject(new Error(parsed.error.message ?? "CDP command failed."));
          } else {
            pending.resolve(parsed.result);
          }
        } else if (typeof parsed.method === "string") {
          for (const handler of this.handlers.get(parsed.method) ?? []) {
            Promise.resolve(handler(parsed.params)).catch((error) => {
              console.error(`[codex-runtime] handler failed: ${error.message}`);
            });
          }
        }
      }
    } catch (error) {
      this.rejectAll(error);
      this.socket.destroy();
    }
  }

  rejectAll(error) {
    this.closed = true;
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }
}

async function waitForPageTarget(port) {
  const deadline = Date.now() + connectTimeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const targets = await httpGetJson(`http://127.0.0.1:${port}/json/list`);
      const target = targets.find((item) => item.type === "page" && item.webSocketDebuggerUrl);
      if (target) return target;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`Timed out waiting for Codex CDP target.${lastError ? ` ${lastError.message}` : ""}`);
}

async function enableInterception(cdp) {
  await cdp.send("Page.enable");
  await waitForInitialPageLoad(cdp);
  await cdp.send("Fetch.enable", {
    patterns: [
      { urlPattern: "app://*/assets/*.js", requestStage: "Response" },
      { urlPattern: "app://*/webview/assets/*.js", requestStage: "Response" },
    ],
  });
  await cdp.send("Page.reload", { ignoreCache: true });
}

function waitForInitialPageLoad(cdp) {
  return new Promise((resolve) => {
    let settled = false;
    const resolveOnce = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      resolve();
    };
    const timeout = setTimeout(resolveOnce, initialLoadSettleMs);
    cdp.on("Page.loadEventFired", resolveOnce);
    cdp.on("Page.frameStoppedLoading", resolveOnce);
  });
}

async function main() {
  const options = parseArgs();
  const executable = path.join(options.app, "Contents", "MacOS", "Codex");
  if (!existsSync(executable)) {
    throw new Error(`Codex executable not found: ${executable}`);
  }

  const child = spawn(executable, [
    `--remote-debugging-port=${options.port}`,
    "--remote-debugging-address=127.0.0.1",
  ], { stdio: "ignore", env: process.env });

  child.on("error", (error) => {
    console.error(`[codex-runtime] Codex launch failed: ${error.message}`);
    process.exitCode = 1;
  });

  const target = await waitForPageTarget(options.port);
  const cdp = await CdpConnection.connect(target.webSocketDebuggerUrl);
  const observed = new Set();
  cdp.on("Fetch.requestPaused", async (params) => {
    const requestId = params.requestId;
    const resourceUrl = params.request?.url ?? "";
    if (!isRuntimeJavaScriptResource(resourceUrl)) {
      await cdp.send("Fetch.continueRequest", { requestId });
      return;
    }

    let bodyResult;
    try {
      bodyResult = await cdp.send("Fetch.getResponseBody", { requestId });
    } catch {
      await cdp.send("Fetch.continueRequest", { requestId });
      return;
    }
    const body = bodyResult.base64Encoded
      ? Buffer.from(bodyResult.body ?? "", "base64").toString("utf8")
      : (bodyResult.body ?? "");
    const patchResult = applyPatches(resourceUrl, body, options.features);
    for (const label of patchResult.labels) {
      if (!observed.has(label)) {
        observed.add(label);
        console.log(`[codex-runtime] patched ${label}`);
      }
    }
    if (patchResult.content === body) {
      await cdp.send("Fetch.continueRequest", { requestId });
      return;
    }
    await cdp.send("Fetch.fulfillRequest", {
      requestId,
      responseCode: params.responseStatusCode ?? 200,
      responseHeaders: [{ name: "content-type", value: "application/javascript; charset=utf-8" }],
      body: Buffer.from(patchResult.content, "utf8").toString("base64"),
    });
  });
  await enableInterception(cdp);
  console.log("[codex-runtime] ready");

  const heartbeat = setInterval(() => {
    cdp.send("Page.getFrameTree").catch(() => {
      clearInterval(heartbeat);
      console.error("[codex-runtime] CDP session closed; lazy runtime patches are no longer active.");
    });
  }, 5000);

  child.on("exit", (code, signal) => {
    clearInterval(heartbeat);
    console.log(`[codex-runtime] Codex exited code=${code ?? "null"} signal=${signal ?? "null"}`);
    process.exit(code ?? 0);
  });
}

main().catch((error) => {
  console.error(`[codex-runtime] ${error.message}`);
  process.exit(1);
});
