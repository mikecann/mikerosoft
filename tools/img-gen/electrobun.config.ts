export default {
  app: {
    name: "Image Gen",
    identifier: "com.mikerosoft.img-gen",
    version: "1.0.0",
  },
  build: {
    bun: {
      entrypoint: "src/bun/index.ts",
    },
    views: {
      "img-gen-ui": {
        entrypoint: "src/ui/index.tsx",
      },
    },
    copy: {
      "src/ui/index.html": "views/img-gen-ui/index.html",
    },
  },
};
