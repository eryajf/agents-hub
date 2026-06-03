#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
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
    feature: "fast",
    label: "Fast mode",
    file: "use-is-fast-mode-enabled-BCZ3vDoA.js",
    search: "c?.authMethod!==`chatgpt`||u",
    replacement: "false                    ||u",
  },
  {
    feature: "fast",
    label: "Fast mode",
    file: "use-is-fast-mode-enabled-CnM6Q1N9.js",
    search: "c?.authMethod!==`chatgpt`||u",
    replacement: "false                    ||u",
  },
  {
    feature: "fast",
    label: "Fast mode detail",
    file: "use-is-fast-mode-enabled-BCZ3vDoA.js",
    search: "d?.authMethod!==`chatgpt`||g",
    replacement: "false                    ||g",
  },
  {
    feature: "fast",
    label: "Fast mode detail",
    file: "use-is-fast-mode-enabled-CnM6Q1N9.js",
    search: "d?.authMethod!==`chatgpt`||g",
    replacement: "false                    ||g",
  },
  {
    feature: "fast",
    label: "Fast mode model tiers",
    file: "use-is-fast-mode-enabled-BCZ3vDoA.js",
    search: "v?.models.some(m)??!1",
    replacement: "true                 ",
  },
  {
    feature: "fast",
    label: "Fast mode model tiers",
    file: "use-is-fast-mode-enabled-CnM6Q1N9.js",
    search: "v?.models.some(m)??!1",
    replacement: "true                 ",
  },
  {
    feature: "fast",
    label: "Fast mode service tiers",
    file: "app-server-manager-signals-Bpaj8VHp.js",
    search:
      "function Mp(e){return e?.serviceTiers?.find(e=>Ep(e.id,e.name)===`fast`||e.name.trim().toLowerCase()===`priority`)??null}",
    replacement:
      "function Mp(e){return e?.serviceTiers?.find(e=>Ep(e.id,e.name)===`fast`||e.name===wp)??{id:wp}}                          ",
  },
  {
    feature: "fast",
    label: "Fast mode service tiers",
    file: "app-server-manager-signals-BOGyjFm3.js",
    search:
      "function uA(e){return e?.serviceTiers?.find(e=>rA(e.id,e.name)===`fast`||e.name.trim().toLowerCase()===`priority`)??null}",
    replacement:
      "function uA(e){return e?.serviceTiers?.find(e=>rA(e.id,e.name)===`fast`||e.name===tA.fastLabel)??{id:tA.fastLabel}}      ",
  },
  {
    feature: "fast",
    label: "Fast mode settings",
    file: "general-settings-Bt2lh7rT.js",
    search:
      "n=je(),{serviceTierSettings:r,setServiceTier:i}=_e();if(!n||r.availableOptions.length<=1)return null;",
    replacement:
      "n=je(),{serviceTierSettings:r,setServiceTier:i}=_e();if(!1||r.availableOptions.length<=1)return null;",
  },
  {
    feature: "fast",
    label: "Fast slash command",
    file: "composer-CwxGJF3C.js",
    search:
      "id:l,title:u,description:d,requiresEmptyComposer:!1,enabled:n,Icon:c,onSelect:m,dependencies:h}",
    replacement:
      "id:l,title:u,description:d,requiresEmptyComposer:!1,enabled:1,Icon:c,onSelect:m,dependencies:h}",
  },
  {
    feature: "fast",
    label: "Composer Intelligence Speed menu",
    file: "composer-CwxGJF3C.js",
    search:
      "Me=_&&m.availableOptions.length>1?(0,Q.jsx)(Rp,{options:m.availableOptions,selectedServiceTier:I,isLoading:m.isLoading,setServiceTier:h,onSelectComplete:B}):null,",
    replacement:
      "Me=1&&m.availableOptions.length>1?(0,Q.jsx)(Rp,{options:m.availableOptions,selectedServiceTier:I,isLoading:m.isLoading,setServiceTier:h,onSelectComplete:B}):null,",
  },
  {
    feature: "fast",
    label: "Composer Intelligence Speed menu",
    file: "composer-CUO1FiyC.js",
    search: "ae=_&&m.availableOptions.length>1",
    replacement: "ae=1&&m.availableOptions.length>1",
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
    label: "Plugins sidebar",
    file: "app-main-BxvNtdQT.js",
    search: "u=e&&c&&l,d=mc({hostId:mr}),f=e&&d&&!l,",
    replacement: "u=!1     ,d=mc({hostId:mr}),f=e&&d    ,",
  },
  {
    feature: "plugins",
    label: "Plugins sidebar",
    file: "app-main-BwpsB7rB.js",
    search: "u=e&&c&&l,d=hc({hostId:mr}),f=e&&d&&!l,",
    replacement: "u=!1     ,d=hc({hostId:mr}),f=e&&d    ,",
  },
  {
    feature: "plugins",
    label: "Plugins sidebar",
    file: "app-main-C3VNTc8v.js",
    search:
      "h=e&&n&&m&&r&&!c&&l!=null&&s!=null&&o&&!tl(s)&&!u,t[3]=s,t[4]=e,t[5]=m,t[6]=u,t[7]=n,t[8]=c,t[9]=r,t[10]=o,t[11]=l,t[12]=h",
    replacement:
      "h=e&&n&&m&&r&&!c&&l!=null&&s!=null&&o        &&!u,t[3]=s,t[4]=e,t[5]=m,t[6]=u,t[7]=n,t[8]=c,t[9]=r,t[10]=o,t[11]=l,t[12]=h",
  },
  {
    feature: "plugins",
    label: "Plugins enabled",
    file: "use-is-plugins-enabled-DudZfU21.js",
    search: "c?.enabled??!0",
    replacement: "true          ",
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
    label: "Plugins page",
    file: "skills-page-Cqn6vECJ.js",
    search: "s&&!h)",
    replacement: "s&&!1)",
  },
  {
    feature: "plugins",
    label: "Plugins page",
    file: "skills-page-BIZqKbZI.js",
    search: "s&&!h)",
    replacement: "s&&!1)",
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
    label: "Plugin detail",
    file: "plugin-detail-page-CETDWYs4.js",
    search: "{authMethod:i}=ae();if(Be(i)){",
    replacement: "{authMethod:i}=ae();if(!1   ){",
  },
  {
    feature: "plugins",
    label: "Plugin detail",
    file: "plugin-detail-page-uf22h4TJ.js",
    search: "{authMethod:i}=ae();if(De(i)){",
    replacement: "{authMethod:i}=ae();if(!1   ){",
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
    label: "Plugin availability",
    file: "check-plugin-availability-fTZpqnCL.js",
    search:
      "let F=b.length>0&&N===b.length?M?`disabled-by-admin`:`connector-unavailable`:null,I;",
    replacement:
      "let F=b.length>0&&N===b.length?M?`disabled-by-admin`:null                   :null,I;",
  },
  {
    feature: "plugins",
    label: "Plugin availability",
    file: "check-plugin-availability-CDJyCxkN.js",
    search:
      "let F=b.length>0&&N===b.length?M?`disabled-by-admin`:`connector-unavailable`:null,I;",
    replacement:
      "let F=b.length>0&&N===b.length?M?`disabled-by-admin`:null                   :null,I;",
  },
  {
    feature: "plugins",
    label: "Plugin availability",
    file: "check-plugin-availability-C1II8bXB.js",
    search:
      "let F=b.length>0&&N===b.length?M?`disabled-by-admin`:`connector-unavailable`:null,I;",
    replacement:
      "let F=b.length>0&&N===b.length?M?`disabled-by-admin`:null                   :null,I;",
  },
  {
    feature: "plugins",
    label: "Plugin install flow",
    file: "use-plugin-install-flow-IT_xMrDV.js",
    search: "let g=m,_=(u?.apps.length??0)>0&&u?.summary.authPolicy===`ON_INSTALL`,v;",
    replacement: "let g=m,_=(u?.apps.length??0)>0&&!1                                  ,v;",
  },
  {
    feature: "plugins",
    label: "Plugin install flow",
    file: "use-plugin-install-flow-BXFieYft.js",
    search: "A=s.kind===`details`&&s.plugin.plugin.authPolicy===`ON_INSTALL`,",
    replacement: "A=!1,                                                           ",
  },
  {
    feature: "plugins",
    label: "Plugin install flow",
    file: "use-plugin-install-flow-DpUQcozA.js",
    search: "let h=m,g=(u?.apps.length??0)>0&&u?.summary.authPolicy===`ON_INSTALL`,_;",
    replacement: "let h=m,g=(u?.apps.length??0)>0&&!1                                  ,_;",
  },
  {
    feature: "plugins",
    label: "Plugin install flow",
    file: "use-plugin-install-flow-C0YRtVkW.js",
    search: "U=d.kind===`details`&&d.plugin.plugin.authPolicy===`ON_INSTALL`,",
    replacement: "U=!1,                                                           ",
  },
  {
    feature: "plugins",
    label: "Plugin auth flow",
    file: "plugin-detail-page-CETDWYs4.js",
    search: "enabled:Y?.summary.installed===!0&&Y.summary.authPolicy===`ON_INSTALL`",
    replacement: "enabled:!1                                                            ",
  },
  {
    feature: "plugins",
    label: "Plugin auth flow",
    file: "plugin-detail-page-uf22h4TJ.js",
    search: "enabled:Y?.summary.installed===!0&&Y.summary.authPolicy===`ON_INSTALL`",
    replacement: "enabled:!1                                                            ",
  },
  {
    feature: "plugins",
    label: "Plugin auth flow",
    file: "plugin-detail-page-BS2Xbdl4.js",
    search: "enabled:J?.summary.installed===!0&&J.summary.authPolicy===`ON_INSTALL`",
    replacement: "enabled:!1                                                            ",
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
    label: "Appshot availability",
    file: "use-is-appshot-available-BuzGfUqU.js",
    search: "return n===`macOS`&&r",
    replacement: "return n===`macOS`   ",
  },
  {
    feature: "appshot",
    label: "Appshot availability",
    file: "use-is-appshot-available-B6eTO-q8.js",
    search: "return n===`macOS`&&r",
    replacement: "return n===`macOS`   ",
  },
  {
    feature: "appshot",
    label: "Appshot availability",
    file: "appshot-availability-CHEIX-Tb.js",
    search: "if(t(o)!==`macOS`||!t(i,`1304276663`))return!1;",
    replacement: "if(t(o)!==`macOS`                    )return!1;",
  },
  {
    feature: "appshot",
    label: "Appshot service enablement",
    file: "app-main-DG-Mf4Wj.js",
    search: "appshotsEnabled:r,artifactsPane:!0",
    replacement: "appshotsEnabled:!0,artifactsPane:1",
  },
  {
    feature: "appshot",
    label: "Appshot service enablement",
    file: "app-main-BxvNtdQT.js",
    search: "appshotsEnabled:r,artifactsPane:!0",
    replacement: "appshotsEnabled:!0,artifactsPane:1",
  },
  {
    feature: "appshot",
    label: "Appshot service enablement",
    file: "app-main-BwpsB7rB.js",
    search: "appshotsEnabled:r,artifactsPane:!0",
    replacement: "appshotsEnabled:!0,artifactsPane:1",
  },
  {
    feature: "appshot",
    label: "Appshot service enablement",
    file: "app-main-C3VNTc8v.js",
    search: "appshotsEnabled:r,codexChronicleConfig:s",
    replacement: "appshotsEnabled:1,codexChronicleConfig:s",
  },
];

const startupTargets = [
  {
    feature: "appshot",
    label: "Appshot capture worker",
    path: ".vite/build/main-DVEWN1ng.js",
    search: "T&&t.O.isInternal(a)&&P.startComputerUseCaptureWorker()",
    replacement: "T&&true             &&P.startComputerUseCaptureWorker()",
  },
  {
    feature: "appshot",
    label: "Appshot capture worker",
    path: ".vite/build/main-B260eRdI.js",
    search: "O&&n.j.isInternal(s)&&ae.startComputerUseCaptureWorker()",
    replacement: "O&&true             &&ae.startComputerUseCaptureWorker()",
  },
  {
    feature: "appshot",
    label: "Appshot capture worker",
    path: ".vite/build/main-DowL6vN4.js",
    search: "O&&n.j.isInternal(s)&&ae.startComputerUseCaptureWorker()",
    replacement: "O&&true             &&ae.startComputerUseCaptureWorker()",
  },
  {
    feature: "appshot",
    label: "Appshot capture worker",
    path: ".vite/build/main-BJ6Uf5yA.js",
    search: "E&&r.M.isInternal(o)&&ie.startComputerUseCaptureWorker()",
    replacement: "E&&true             &&ie.startComputerUseCaptureWorker()",
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

function sha256Hex(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

function readUInt32LE(buffer, offset) {
  return buffer.readUInt32LE(offset);
}

function getAsarEntry(header, filePath) {
  let node = header;
  for (const component of filePath.split("/")) {
    node = node.files?.[component];
    if (!node) return null;
  }
  return node;
}

function asarFileRange(data, headerSize, entry) {
  const start = 8 + headerSize + Number(entry.offset);
  const end = start + entry.size;
  if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || end > data.length) {
    throw new Error("Invalid asar file range.");
  }
  return { start, end };
}

function blockHashes(buffer, blockSize) {
  const size = blockSize > 0 ? blockSize : buffer.length;
  if (buffer.length === 0) return [sha256Hex(buffer)];
  const hashes = [];
  for (let offset = 0; offset < buffer.length; offset += size) {
    hashes.push(sha256Hex(buffer.subarray(offset, Math.min(offset + size, buffer.length))));
  }
  return hashes;
}

function applyAsarStartupPatches(asarPath, features) {
  const selectedTargets = startupTargets.filter((target) => features.has(target.feature));
  if (selectedTargets.length === 0) return [];

  let data = readFileSync(asarPath);
  let headerSize = readUInt32LE(data, 4);
  let jsonSize = readUInt32LE(data, 12);
  let headerStart = 16;
  let headerEnd = headerStart + jsonSize;
  let headerString = data.subarray(headerStart, headerEnd).toString("utf8");
  let header = JSON.parse(headerString);
  const labels = [];

  for (const target of selectedTargets) {
    if (Buffer.byteLength(target.search) !== Buffer.byteLength(target.replacement)) {
      throw new Error(`Startup patch length mismatch for ${target.path}.`);
    }

    const entry = getAsarEntry(header, target.path);
    if (!entry) continue;

    const range = asarFileRange(data, headerSize, entry);
    let content = Buffer.from(data.subarray(range.start, range.end));
    const search = Buffer.from(target.search, "utf8");
    const replacement = Buffer.from(target.replacement, "utf8");
    const first = content.indexOf(search);
    if (first < 0) {
      if (content.includes(replacement)) {
        labels.push(target.label);
        continue;
      }
      continue;
    }
    if (content.indexOf(search, first + 1) >= 0) {
      throw new Error(`Startup patch marker is ambiguous for ${target.path}.`);
    }

    replacement.copy(content, first);
    content.copy(data, range.start);

    const integrity = entry.integrity ?? {};
    const oldHash = integrity.hash;
    const newHash = sha256Hex(content);
    if (oldHash) headerString = headerString.replaceAll(oldHash, newHash);

    const oldBlocks = Array.isArray(integrity.blocks) ? integrity.blocks : [];
    const newBlocks = blockHashes(content, integrity.blockSize ?? content.length);
    for (let index = 0; index < Math.min(oldBlocks.length, newBlocks.length); index += 1) {
      headerString = headerString.replaceAll(oldBlocks[index], newBlocks[index]);
    }

    const newHeader = Buffer.from(headerString, "utf8");
    if (newHeader.length !== jsonSize) {
      throw new Error("Asar header size changed after startup patch.");
    }
    newHeader.copy(data, headerStart);
    header = JSON.parse(headerString);
    labels.push(target.label);
  }

  writeFileSync(asarPath, data);
  return labels;
}

function updateInfoPlistAsarHash(appPath) {
  const asarPath = path.join(appPath, "Contents", "Resources", "app.asar");
  const infoPlistPath = path.join(appPath, "Contents", "Info.plist");
  const newHash = sha256Hex(readFileSync(asarPath));
  const plist = readFileSync(infoPlistPath, "utf8");
  const hashPattern = /(<key>hash<\/key>\s*<string>)([a-f0-9]{64})(<\/string>)/;
  if (!hashPattern.test(plist)) {
    throw new Error("Could not update ElectronAsarIntegrity hash in Info.plist.");
  }
  writeFileSync(infoPlistPath, plist.replace(hashPattern, `$1${newHash}$3`));
}

function signTemporaryApp(appPath) {
  const result = spawnSync("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", appPath], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || "codesign failed").trim());
  }
}

function copyAppBundle(sourceAppPath, destinationAppPath) {
  const result = spawnSync("/usr/bin/ditto", [sourceAppPath, destinationAppPath], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error((result.stderr || result.stdout || "ditto copy failed").trim());
  }
}

function prepareLaunchApp(appPath, features) {
  if (!features.has("appshot")) {
    return { appPath, cleanup: () => {} };
  }

  const selectedTargets = startupTargets.filter((target) => features.has(target.feature));
  if (selectedTargets.length === 0) {
    return { appPath, cleanup: () => {} };
  }

  const tempRoot = mkdtempSync(path.join(os.tmpdir(), "agentshub-codex-runtime-"));
  const tempAppPath = path.join(tempRoot, path.basename(appPath));
  try {
    copyAppBundle(appPath, tempAppPath);

    const asarPath = path.join(tempAppPath, "Contents", "Resources", "app.asar");
    const labels = applyAsarStartupPatches(asarPath, features);
    if (labels.length > 0) {
      updateInfoPlistAsarHash(tempAppPath);
      signTemporaryApp(tempAppPath);
      for (const label of labels) console.log(`[codex-runtime] startup patched ${label}`);
    }
  } catch (error) {
    rmSync(tempRoot, { recursive: true, force: true });
    throw error;
  }

  return {
    appPath: tempAppPath,
    cleanup: () => rmSync(tempRoot, { recursive: true, force: true }),
  };
}

function installCleanupHandlers(cleanup) {
  let cleaned = false;
  const runCleanup = () => {
    if (cleaned) return;
    cleaned = true;
    cleanup();
  };
  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.once(signal, () => {
      runCleanup();
      process.exit(signal === "SIGINT" ? 130 : 143);
    });
  }
  process.once("exit", runCleanup);
  return runCleanup;
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
  const launchApp = prepareLaunchApp(options.app, options.features);
  const cleanupLaunchApp = installCleanupHandlers(launchApp.cleanup);
  const executable = path.join(launchApp.appPath, "Contents", "MacOS", "Codex");
  if (!existsSync(executable)) {
    throw new Error(`Codex executable not found: ${executable}`);
  }

  const child = spawn(executable, [
    `--remote-debugging-port=${options.port}`,
    "--remote-debugging-address=127.0.0.1",
  ], { stdio: "ignore", env: process.env });

  child.on("error", (error) => {
    cleanupLaunchApp();
    console.error(`[codex-runtime] Codex launch failed: ${error.message}`);
    process.exitCode = 1;
  });

  let cdp;
  try {
    const target = await waitForPageTarget(options.port);
    cdp = await CdpConnection.connect(target.webSocketDebuggerUrl);
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
  } catch (error) {
    if (child.exitCode == null) child.kill();
    cleanupLaunchApp();
    throw error;
  }
  console.log("[codex-runtime] ready");

  const heartbeat = setInterval(() => {
    cdp.send("Page.getFrameTree").catch(() => {
      clearInterval(heartbeat);
      console.error("[codex-runtime] CDP session closed; lazy runtime patches are no longer active.");
    });
  }, 5000);

  child.on("exit", (code, signal) => {
    clearInterval(heartbeat);
    cleanupLaunchApp();
    console.log(`[codex-runtime] Codex exited code=${code ?? "null"} signal=${signal ?? "null"}`);
    process.exit(code ?? 0);
  });
}

main().catch((error) => {
  console.error(`[codex-runtime] ${error.message}`);
  process.exit(1);
});
