import { BrowserWindow, BrowserView } from "electrobun/bun";
import type { ImgGenRPC, GenerateParams, SseEvent } from "../shared/types.js";
import * as path from "path";
import * as fs from "fs";
import * as crypto from "crypto";

// ---------------------------------------------------------------------------
// Config + env
// ---------------------------------------------------------------------------

const MODELS = [
  "google/gemini-3.1-flash-image-preview",
  "google/gemini-2.5-flash-image",
  "google/gemini-3-pro-image-preview",
];
const API_URL = "https://openrouter.ai/api/v1/chat/completions";

const folderPath = process.env["FOLDER_PATH"] ?? process.cwd();
const sessionId = crypto.randomUUID();

// Load .env from repo root: src/bun -> src -> img-gen -> tools -> repo
const envPath = path.join(import.meta.dirname, "..", "..", "..", "..", ".env");
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, "utf-8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    const val = trimmed.slice(eq + 1).trim().replace(/^["']|["']$/g, "");
    if (!process.env[key]) process.env[key] = val;
  }
}

const apiKey = process.env["OPENROUTER_API_KEY"];

// ---------------------------------------------------------------------------
// Temp directory for generated images
// ---------------------------------------------------------------------------

const tempDir = path.join(process.env["TEMP"] ?? "/tmp", "img-gen", sessionId);
fs.mkdirSync(tempDir, { recursive: true });

const imageStore = new Map<string, { tempPath: string }>();

// ---------------------------------------------------------------------------
// SSE - bun -> webview real-time events
// ---------------------------------------------------------------------------

const sseClients = new Set<ReadableStreamDefaultController<Uint8Array>>();

function broadcastSse(event: SseEvent) {
  const line = `data: ${JSON.stringify(event)}\n\n`;
  const bytes = new TextEncoder().encode(line);
  for (const ctrl of sseClients) {
    try {
      ctrl.enqueue(bytes);
    } catch {
      sseClients.delete(ctrl);
    }
  }
}

// ---------------------------------------------------------------------------
// Local HTTP server - images + SSE
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
          // Keep-alive ping every 15s
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
          headers: { "Content-Type": "image/png", "Access-Control-Allow-Origin": "*" },
        });
    }

    return new Response("Not found", { status: 404 });
  },
});

const baseUrl = `http://127.0.0.1:${server.port}`;
console.log(`img-gen server at ${baseUrl}`);

// ---------------------------------------------------------------------------
// OpenRouter generation
// ---------------------------------------------------------------------------

type GenerateOneArgs = {
  prompt: string;
  inputDataUrl: string | undefined;
  aspectRatio: string | undefined;
  imageSize: string | undefined;
  model: string;
};

async function generateOne({
  prompt,
  inputDataUrl,
  aspectRatio,
  imageSize,
  model,
}: GenerateOneArgs): Promise<{ b64: string; comment: string }> {
  const content: unknown[] = [];
  if (inputDataUrl) content.push({ type: "image_url", image_url: { url: inputDataUrl } });
  content.push({ type: "text", text: prompt });

  const imageConfig: Record<string, string> = {};
  if (aspectRatio && aspectRatio !== "auto") imageConfig.aspect_ratio = aspectRatio;
  if (imageSize && imageSize !== "auto") imageConfig.image_size = imageSize;

  const body: Record<string, unknown> = {
    model,
    modalities: ["image", "text"],
    messages: [{ role: "user", content }],
  };
  if (Object.keys(imageConfig).length > 0) body.image_config = imageConfig;

  const res = await fetch(API_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      "HTTP-Referer": "https://github.com/mikecann/mikerosoft",
      "X-Title": "mikerosoft/img-gen",
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);

  const data = (await res.json()) as {
    choices: Array<{
      message: { images?: Array<{ image_url: { url: string } }>; content?: string };
    }>;
  };

  const message = data.choices[0].message;
  if (!message.images?.length)
    throw new Error(`No image in response. Model said: ${message.content ?? "(nothing)"}`);

  return {
    b64: message.images[0].image_url.url.split(",", 2)[1],
    comment: message.content?.trim() ?? "",
  };
}

async function generateWithFallback(params: GenerateParams): Promise<{ b64: string; comment: string }> {
  const preferred = params.model ?? MODELS[0];
  const order = [preferred, ...MODELS.filter((m) => m !== preferred)];

  for (const model of order) {
    try {
      return await generateOne({
        prompt: params.prompt,
        inputDataUrl: params.inputImageDataUrl,
        aspectRatio: params.aspectRatio,
        imageSize: params.imageSize,
        model,
      });
    } catch (err) {
      if (String(err).includes("429")) {
        console.warn(`Model ${model} rate-limited, trying next...`);
        continue;
      }
      throw err;
    }
  }
  throw new Error("All models rate-limited. Try again later.");
}

// ---------------------------------------------------------------------------
// RPC
// ---------------------------------------------------------------------------

const rpc = BrowserView.defineRPC<ImgGenRPC>({
  maxRequestTime: 120_000,
  handlers: {
    requests: {
      getConfig: () => ({ workingDir: folderPath, eventsUrl: `${baseUrl}/events` }),

      generate: async (params) => {
        const { jobId } = params;

        if (!apiKey)
          throw new Error("OPENROUTER_API_KEY is not set. Add it to .env in the repo root.");

        broadcastSse({ kind: "generating", jobId });

        try {
          const { b64, comment } = await generateWithFallback(params);

          const imageId = crypto.randomUUID();
          const filename = `${imageId}.png`;
          const tempPath = path.join(tempDir, filename);
          fs.writeFileSync(tempPath, Buffer.from(b64, "base64"));
          imageStore.set(imageId, { tempPath });

          const serveUrl = `${baseUrl}/images/${filename}`;
          broadcastSse({ kind: "imageResult", jobId, imageId, serveUrl, tempPath, modelComment: comment });

          return { imageId, serveUrl, tempPath, modelComment: comment };
        } catch (err) {
          broadcastSse({ kind: "imageError", jobId, error: String(err) });
          throw err;
        }
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
        console.log(`Downloaded to: ${destPath}`);
        return { savedPath: destPath };
      },
    },
  },
});

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

new BrowserWindow({
  title: "Image Gen",
  url: "views://img-gen-ui/index.html",
  frame: { width: 900, height: 720, x: 120, y: 80 },
  rpc,
});
