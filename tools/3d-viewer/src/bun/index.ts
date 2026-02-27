import { BrowserWindow, BrowserView } from "electrobun/bun";
import type { ViewerRPC } from "../shared/types.js";
import * as path from "path";

const filePath = process.env["GLB_FILE"];
const fileName = filePath ? path.basename(filePath) : "3D Viewer";

// Serve the GLB over a local HTTP server so the webview can fetch it via a URL.
// The webview can't access the filesystem directly, and passing bytes over RPC
// would be fine but this is cleaner for Three.js's GLTFLoader.
let modelUrl = "";
if (filePath) {
  const server = Bun.serve({
    port: 0, // random ephemeral port
    fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/model.glb") {
        return new Response(Bun.file(filePath), {
          headers: {
            "Content-Type": "model/gltf-binary",
            "Access-Control-Allow-Origin": "*",
          },
        });
      }
      return new Response("Not found", { status: 404 });
    },
  });
  modelUrl = `http://127.0.0.1:${server.port}/model.glb`;
  console.log(`Serving GLB from ${modelUrl}`);
}

const rpc = BrowserView.defineRPC<ViewerRPC>({
  maxRequestTime: 10000,
  handlers: {
    requests: {
      getModelUrl: () => modelUrl,
    },
    messages: {},
  },
});

const win = new BrowserWindow({
  title: fileName,
  url: "views://viewer-ui/index.html",
  frame: {
    width: 1200,
    height: 800,
    x: 100,
    y: 100,
  },
  rpc,
});
