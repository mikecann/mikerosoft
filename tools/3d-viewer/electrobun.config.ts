export default {
  app: {
    name: "3D Viewer",
    identifier: "com.mikerosoft.3d-viewer",
    version: "0.1.0",
  },
  build: {
    bun: {
      entrypoint: "src/bun/index.ts",
    },
    views: {
      "viewer-ui": {
        entrypoint: "src/viewer-ui/index.ts",
      },
    },
    copy: {
      "src/viewer-ui/index.html": "views/viewer-ui/index.html",
    },
  },
};
