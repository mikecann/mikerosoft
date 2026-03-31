import type { RPCSchema } from "electrobun/bun";

export type SwapParams = {
  jobId: string;
  targetDataUrl: string;
  sourceDataUrl: string;
  targetOriginalPath?: string;
};

export type SwapResult = {
  imageId: string;
  serveUrl: string;
  tempPath: string;
  autoSavedPath: string;
};

export type FaceSwapRPC = {
  bun: RPCSchema<{
    requests: {
      getConfig: {
        params: void;
        response: {
          initialTargetDataUrl?: string;
          initialTargetPath?: string;
          eventsUrl: string;
          modelMissing: boolean;
          modelPath: string;
          pythonMissing: boolean;
        };
      };
      swap: { params: SwapParams; response: { jobId: string } };
      download: { params: { imageId: string }; response: { savedPath: string } };
      downloadModel: { params: void; response: void };
      closeWindow: { params: void; response: void };
    };
    messages: {};
  }>;
  webview: RPCSchema<{}>;
};

export type SseEvent =
  | { kind: "swapping"; jobId: string }
  | { kind: "swapLog"; jobId: string; message: string }
  | { kind: "swapResult"; jobId: string; image: SwapResult }
  | { kind: "swapError"; jobId: string; error: string }
  | { kind: "modelDownloadProgress"; percent: number; mbDone: number; mbTotal: number }
  | { kind: "modelDownloadDone" }
  | { kind: "modelDownloadError"; error: string };
