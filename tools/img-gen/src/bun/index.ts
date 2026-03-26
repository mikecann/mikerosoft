import { BrowserWindow, BrowserView } from "electrobun/bun";
import type { ImgGenRPC, GenerateParams, SseEvent, GeneratedImage } from "../shared/types.js";
import {
  MODELS,
  generateWithFallback,
  fetchImageModels,
} from "./generation.js";
import * as path from "path";
import * as fs from "fs";
import * as crypto from "crypto";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const folderPath = process.env["FOLDER_PATH"] ?? process.cwd();
const sessionId = crypto.randomUUID();
const apiKey = process.env["OPENROUTER_API_KEY"];

// ---------------------------------------------------------------------------
// Temp directory
// ---------------------------------------------------------------------------

const tempDir = path.join(process.env["TEMP"] ?? "/tmp", "img-gen", sessionId);
fs.mkdirSync(tempDir, { recursive: true });

const imageStore = new Map<string, { tempPath: string }>();

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
            try { ctrl.enqueue(new TextEncoder().encode(": ping\n\n")); }
            catch { clearInterval(ping); }
          }, 15_000);
        },
        cancel() { sseClients.delete(ctrl); },
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
// Background generation task
// ---------------------------------------------------------------------------

async function runGeneration(params: GenerateParams) {
  const { jobId } = params;
  const count = Math.min(Math.max(params.variations ?? 1, 1), 4);

  broadcastSse({ kind: "generating", jobId });

  for (let i = 0; i < count; i++) {
    try {
      const { b64, comment } = await generateWithFallback(
        {
          prompt: params.prompt,
          inputDataUrl: params.inputImageDataUrl,
          aspectRatio: params.aspectRatio,
          imageSize: params.imageSize,
          model: params.model,
          apiKey: apiKey ?? "",
        },
        MODELS,
      );

      const imageId = crypto.randomUUID();
      const filename = `${imageId}.png`;
      const tempPath = path.join(tempDir, filename);
      fs.writeFileSync(tempPath, Buffer.from(b64, "base64"));
      imageStore.set(imageId, { tempPath });

      const image: GeneratedImage = {
        imageId,
        serveUrl: `${baseUrl}/images/${filename}`,
        tempPath,
        modelComment: comment,
      };
      broadcastSse({ kind: "imageResult", jobId, image });
    } catch (err) {
      broadcastSse({ kind: "imageError", jobId, error: String(err) });
    }
  }
}

// ---------------------------------------------------------------------------
// RPC
// ---------------------------------------------------------------------------

const rpc = BrowserView.defineRPC<ImgGenRPC>({
  maxRequestTime: 15_000,
  handlers: {
    requests: {
      getConfig: () => ({ workingDir: folderPath, eventsUrl: `${baseUrl}/events` }),

      getModels: async () => {
        if (!apiKey) return MODELS.map((id) => ({ id, name: id }));
        try {
          return await fetchImageModels(apiKey);
        } catch (err) {
          console.warn(`getModels failed: ${err}`);
          return MODELS.map((id) => ({ id, name: id }));
        }
      },

      generate: (params) => {
        if (!apiKey)
          throw new Error("OPENROUTER_API_KEY is not set. Add it to .env in the repo root.");
        // Fire-and-forget - result arrives via SSE, not via RPC response
        runGeneration(params).catch(console.error);
        return { jobId: params.jobId };
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
