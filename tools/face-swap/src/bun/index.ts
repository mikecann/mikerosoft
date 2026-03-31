import { BrowserWindow, BrowserView } from "electrobun/bun";
import type {
  FaceSwapRPC,
  SwapParams,
  SseEvent,
  SwapResult,
} from "../shared/types.js";
import * as path from "path";
import * as fs from "fs";
import * as crypto from "crypto";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const folderPath =
  process.env["FOLDER_PATH"] ?? process.env["USERPROFILE"] + "\\Downloads";
const sessionId = crypto.randomUUID();

// TOOL_DIR is set by face-swap.vbs to the directory containing face-swap.vbs itself.
// Fall back to walking up from import.meta.url in case of direct dev runs.
const toolDir =
  process.env["TOOL_DIR"] ??
  path.resolve(
    path.dirname(
      new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"),
    ),
    "..",
    "..",
    "..",
    "..",
    "..",
    "..",
  );
// face-swap-runner.bat does: python face-swap.py %* — same pattern as img-upscale.bat in this repo
const runnerBat = path.join(toolDir, "face-swap-runner.bat");

const localAppData =
  process.env["LOCALAPPDATA"] ??
  process.env["USERPROFILE"] + "\\AppData\\Local";
const modelPath = path.join(
  localAppData,
  "face-swap",
  "models",
  "inswapper_128.onnx",
);

// ---------------------------------------------------------------------------
// Python check - same pattern as img-upscale.bat / backup-phone.ps1 in this repo:
// always invoke Python through a .bat file so cmd.exe handles Windows Store
// app-execution-alias resolution. Never try to spawn python.exe directly.
// ---------------------------------------------------------------------------

async function checkPython(): Promise<boolean> {
  try {
    const p = Bun.spawn(["cmd", "/c", runnerBat, "--help"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    // exit 0 = python found and script ran; exit 2 = argparse --help = also fine
    const code = await p.exited;
    return code === 0 || code === 2;
  } catch {
    return false;
  }
}

// Fire-and-forget - resolves after window is already open
const pythonOkPromise = checkPython();

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

const logPath = path.join(localAppData, "face-swap", "face-swap.log");
fs.mkdirSync(path.dirname(logPath), { recursive: true });

function log(msg: string) {
  const line = `${new Date().toISOString()} ${msg}\n`;
  fs.appendFileSync(logPath, line);
  console.log(msg);
}

// ---------------------------------------------------------------------------
// Temp directory
// ---------------------------------------------------------------------------

const tempDir = path.join(localAppData, "face-swap", "sessions", sessionId);
fs.mkdirSync(tempDir, { recursive: true });

const imageStore = new Map<string, { tempPath: string }>();

// ---------------------------------------------------------------------------
// Initial target image (when launched from context menu on an image)
// ---------------------------------------------------------------------------

function loadInitialTargetDataUrl(): string | undefined {
  const targetPath = process.env["TARGET_IMAGE"];
  if (!targetPath || !fs.existsSync(targetPath)) return undefined;

  const ext = path.extname(targetPath).slice(1).toLowerCase();
  const mimeType =
    ext === "jpg" || ext === "jpeg"
      ? "image/jpeg"
      : ext === "png"
        ? "image/png"
        : ext === "webp"
          ? "image/webp"
          : "image/jpeg";

  const b64 = fs.readFileSync(targetPath).toString("base64");
  return `data:${mimeType};base64,${b64}`;
}

function createAutoSavedPath(targetOriginalPath?: string): string {
  if (!targetOriginalPath) {
    return path.join(folderPath, `face-swapped-${crypto.randomUUID()}.png`);
  }

  const dir = path.dirname(targetOriginalPath);
  const ext = path.extname(targetOriginalPath) || ".png";
  const base = path.basename(targetOriginalPath, ext);
  let savedPath = path.join(dir, `${base}_face-swapped${ext}`);
  let counter = 1;

  while (fs.existsSync(savedPath)) {
    savedPath = path.join(dir, `${base}_face-swapped-${counter}${ext}`);
    counter += 1;
  }

  return savedPath;
}

// ---------------------------------------------------------------------------
// SSE - bun -> webview
// ---------------------------------------------------------------------------

const sseClients = new Set<ReadableStreamDefaultController<Uint8Array>>();

function broadcastSse(event: SseEvent) {
  const bytes = new TextEncoder().encode(`data: ${JSON.stringify(event)}\n\n`);
  for (const ctrl of sseClients) {
    try {
      ctrl.enqueue(bytes);
    } catch {
      sseClients.delete(ctrl);
    }
  }
}

// ---------------------------------------------------------------------------
// HTTP server - images + SSE
// ---------------------------------------------------------------------------

const server = Bun.serve({
  port: 0,
  fetch(req) {
    const url = new URL(req.url);

    if (url.pathname === "/events") {
      let ctrl: ReadableStreamDefaultController<Uint8Array>;
      const stream = new ReadableStream<Uint8Array>({
        start(c) {
          ctrl = c;
          sseClients.add(ctrl);
          const ping = setInterval(() => {
            try {
              ctrl.enqueue(new TextEncoder().encode(": ping\n\n"));
            } catch {
              clearInterval(ping);
            }
          }, 15_000);
        },
        cancel() {
          sseClients.delete(ctrl);
        },
      });
      return new Response(stream, {
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          "Access-Control-Allow-Origin": "*",
        },
      });
    }

    const match = url.pathname.match(/^\/images\/([^/]+\.png)$/);
    if (match) {
      const filePath = path.join(tempDir, match[1]);
      if (fs.existsSync(filePath))
        return new Response(Bun.file(filePath), {
          headers: {
            "Content-Type": "image/png",
            "Access-Control-Allow-Origin": "*",
          },
        });
    }

    return new Response("Not found", { status: 404 });
  },
});

const baseUrl = `http://127.0.0.1:${server.port}`;
log(
  `face-swap server at ${baseUrl} | model=${fs.existsSync(modelPath) ? "found" : "MISSING"}`,
);

// ---------------------------------------------------------------------------
// Write data URL to a temp file, return its path
// ---------------------------------------------------------------------------

function dataUrlToTempFile(dataUrl: string, suffix: string): string {
  const match = dataUrl.match(/^data:image\/[^;]+;base64,(.+)$/);
  if (!match) throw new Error("Invalid data URL");
  const buf = Buffer.from(match[1], "base64");
  const filePath = path.join(tempDir, `${suffix}-${crypto.randomUUID()}.png`);
  fs.writeFileSync(filePath, buf);
  return filePath;
}

// ---------------------------------------------------------------------------
// Face swap job
// ---------------------------------------------------------------------------

async function runSwap(params: SwapParams) {
  const { jobId, targetDataUrl, sourceDataUrl, targetOriginalPath } = params;
  log(`[${jobId}] Starting face swap`);
  broadcastSse({ kind: "swapping", jobId });

  const targetFile = dataUrlToTempFile(targetDataUrl, "target");
  const sourceFile = dataUrlToTempFile(sourceDataUrl, "source");
  const outputId = crypto.randomUUID();
  const outputFile = path.join(tempDir, `${outputId}.png`);

  try {
    if (!(await pythonOkPromise)) {
      broadcastSse({
        kind: "swapError",
        jobId,
        error:
          "Python not found. Install Python from https://python.org and restart Face Swap.",
      });
      return;
    }

    // Invoke via the .bat runner — same pattern as img-upscale.bat in this repo
    const scriptArgs = [
      "--target",
      targetFile,
      "--source",
      sourceFile,
      "--output",
      outputFile,
      "--model",
      modelPath,
    ];
    const spawnArgs = ["cmd", "/c", runnerBat, ...scriptArgs];
    log(`[${jobId}] spawn: ${spawnArgs.join(" ")}`);

    const proc = Bun.spawn(spawnArgs, { stdout: "pipe", stderr: "pipe" });

    // Stream stdout and stderr to the frontend in real-time
    let fullLog = "";
    const streamToFrontend = async (stream: ReadableStream, prefix: string) => {
      const reader = stream.getReader();
      const decoder = new TextDecoder();
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const text = decoder.decode(value);
        fullLog += text;
        const lines = text.split("\n");
        for (const line of lines) {
          const trimmed = line.trim();
          if (trimmed) {
            broadcastSse({ kind: "swapLog", jobId, message: trimmed });
            log(`[${jobId}] ${prefix}: ${trimmed}`);
          }
        }
      }
    };

    const [exitCode] = await Promise.all([
      proc.exited,
      streamToFrontend(proc.stdout, "stdout"),
      streamToFrontend(proc.stderr, "stderr"),
    ]);

    log(`[${jobId}] python exit=${exitCode}`);

    if (exitCode !== 0) {
      broadcastSse({
        kind: "swapError",
        jobId,
        error: `Process exited with code ${exitCode}. Check logs above.`,
      });
      return;
    }

    if (!fs.existsSync(outputFile)) {
      broadcastSse({
        kind: "swapError",
        jobId,
        error: "Output file not created",
      });
      return;
    }

    const autoSavedPath = createAutoSavedPath(targetOriginalPath);
    fs.copyFileSync(outputFile, autoSavedPath);
    log(`[${jobId}] auto-saved to: ${autoSavedPath}`);

    const filename = `${outputId}.png`;
    imageStore.set(outputId, { tempPath: outputFile });

    const image: SwapResult = {
      imageId: outputId,
      serveUrl: `${baseUrl}/images/${filename}`,
      tempPath: outputFile,
      autoSavedPath,
    };

    broadcastSse({ kind: "swapResult", jobId, image });
  } catch (err) {
    log(`[${jobId}] Unexpected error: ${err}`);
    broadcastSse({ kind: "swapError", jobId, error: String(err) });
  } finally {
    fs.rmSync(targetFile, { force: true });
    fs.rmSync(sourceFile, { force: true });
  }
}

// ---------------------------------------------------------------------------
// Model auto-download
// ---------------------------------------------------------------------------

const MODEL_URLS = [
  "https://huggingface.co/thebiglaskowski/inswapper_128.onnx/resolve/main/inswapper_128.onnx?download=true",
  "https://huggingface.co/Patil/inswapper/resolve/main/inswapper_128.onnx?download=true",
  "https://huggingface.co/ezioruan/inswapper_128.onnx/resolve/main/inswapper_128.onnx",
];

async function downloadModelFile() {
  const modelsDir = path.dirname(modelPath);
  fs.mkdirSync(modelsDir, { recursive: true });

  const partPath = modelPath + ".part";

  let res: Response | null = null;
  let usedUrl = "";
  for (const url of MODEL_URLS) {
    log(`[model] Trying ${url}`);
    try {
      const r = await fetch(url, { redirect: "follow" });
      if (r.ok) {
        res = r;
        usedUrl = url;
        break;
      }
      log(`[model] ${url} -> HTTP ${r.status}`);
    } catch (err) {
      log(`[model] ${url} -> ${err}`);
    }
  }

  if (!res) {
    broadcastSse({
      kind: "modelDownloadError",
      error: "All download sources failed - check the log for details.",
    });
    return;
  }

  log(`[model] Downloading from ${usedUrl}`);

  try {
    if (!res.body) throw new Error("No response body");

    const total = Number(res.headers.get("content-length") ?? 0);
    const mbTotal = total ? Math.round(total / 1024 / 1024) : 0;
    let received = 0;
    let lastPct = -1;

    const out = fs.createWriteStream(partPath);
    const reader = res.body.getReader();

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      out.write(value);
      received += value.length;
      if (total > 0) {
        const pct = Math.floor((received / total) * 100);
        if (pct !== lastPct) {
          lastPct = pct;
          const mbDone = Math.round(received / 1024 / 1024);
          broadcastSse({
            kind: "modelDownloadProgress",
            percent: pct,
            mbDone,
            mbTotal,
          });
        }
      }
    }

    await new Promise<void>((resolve, reject) =>
      out.end((err?: Error | null) => (err ? reject(err) : resolve())),
    );
    fs.renameSync(partPath, modelPath);
    log(`[model] Download complete: ${modelPath}`);
    broadcastSse({ kind: "modelDownloadDone" });
  } catch (err) {
    log(`[model] Download failed: ${err}`);
    fs.rmSync(partPath, { force: true });
    broadcastSse({ kind: "modelDownloadError", error: String(err) });
  }
}

// ---------------------------------------------------------------------------
// RPC
// ---------------------------------------------------------------------------

const rpc = BrowserView.defineRPC<FaceSwapRPC>({
  maxRequestTime: 15_000,
  handlers: {
    requests: {
      getConfig: async () => ({
        initialTargetDataUrl: loadInitialTargetDataUrl(),
        initialTargetPath: process.env["TARGET_IMAGE"],
        eventsUrl: `${baseUrl}/events`,
        modelMissing: !fs.existsSync(modelPath),
        modelPath,
        pythonMissing: !(await pythonOkPromise),
      }),

      swap: (params) => {
        runSwap(params).catch(console.error);
        return { jobId: params.jobId };
      },

      closeWindow: () => {
        win.close();
      },

      downloadModel: () => {
        downloadModelFile().catch(console.error);
      },

      download: ({ imageId }) => {
        const entry = imageStore.get(imageId);
        if (!entry) throw new Error(`Unknown imageId: ${imageId}`);

        const filename = path.basename(entry.tempPath);
        let destPath = path.join(folderPath, filename);
        let counter = 1;
        while (fs.existsSync(destPath)) {
          const ext = path.extname(filename);
          const base = path.basename(filename, ext);
          destPath = path.join(folderPath, `${base}-${counter++}${ext}`);
        }

        fs.copyFileSync(entry.tempPath, destPath);
        log(`Downloaded to: ${destPath}`);
        return { savedPath: destPath };
      },
    },
  },
});

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

const win = new BrowserWindow({
  title: "Face Swap",
  url: "views://face-swap-ui/index.html",
  frame: { width: 860, height: 640, x: 140, y: 80 },
  titleBarStyle: "hiddenInset",
  rpc,
});

// Electrobun/WebView2 on Windows sometimes paints the initial webview before
// the native window finishes settling into its final client size. Manually
// nudging the native window size reproduces the user's manual resize fix.
function pulseWindowSize() {
  try {
    const { width, height } = win.getFrame();
    win.setSize(width + 1, height + 1);
    setTimeout(() => {
      try {
        win.setSize(width, height);
      } catch (err) {
        log(`[window] resize restore failed: ${err}`);
      }
    }, 40);
  } catch (err) {
    log(`[window] resize pulse failed: ${err}`);
  }
}

for (const delay of [150, 500, 1000]) {
  setTimeout(() => {
    log(`[window] resize pulse at ${delay}ms`);
    pulseWindowSize();
  }, delay);
}
