import type { RPCSchema } from "electrobun/bun";

export type ViewerRPC = {
  bun: RPCSchema<{
    requests: {
      getModelUrl: {
        params: void;
        response: string;
      };
    };
    messages: {};
  }>;
  webview: RPCSchema<{}>;
};
