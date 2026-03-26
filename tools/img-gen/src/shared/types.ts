import type { RPCSchema } from "electrobun/bun";

export type GenerateParams = {
  jobId: string;
  prompt: string;
  inputImageDataUrl?: string;
  aspectRatio?: string;
  imageSize?: string;
  model?: string;
  variations?: number;
};

export type GeneratedImage = {
  imageId: string;
  serveUrl: string;
  tempPath: string;
  modelComment: string;
};

export type GenerateResult = GeneratedImage[];

export type ImageModel = { id: string; name: string };

export type ImgGenRPC = {
  bun: RPCSchema<{
    requests: {
      getConfig: { params: void; response: { workingDir: string; eventsUrl: string } };
      getModels: { params: void; response: ImageModel[] };
      generate: { params: GenerateParams; response: GenerateResult };
      download: { params: { imageId: string }; response: { savedPath: string } };
    };
    messages: {};
  }>;
  webview: RPCSchema<{}>;
};

// SSE event types sent from Bun to the webview via the HTTP server
export type SseEvent =
  | { kind: "generating"; jobId: string }
  | { kind: "imageResult"; jobId: string; image: GeneratedImage }
  | { kind: "imageError"; jobId: string; error: string };
