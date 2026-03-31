export default {
  app: {
    name: "Face Swap",
    identifier: "com.mikerosoft.face-swap",
    version: "1.0.0",
  },
  build: {
    bun: {
      entrypoint: "src/bun/index.ts",
    },
    views: {
      "face-swap-ui": {
        entrypoint: "src/ui/index.tsx",
      },
    },
    copy: {
      "src/ui/index.html": "views/face-swap-ui/index.html",
    },
  },
};
