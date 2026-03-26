import { describe, it, expect } from "bun:test";
import {
  buildRequestBody,
  extractImage,
  filterImageModels,
  buildFallbackOrder,
  generateWithFallback,
  MODELS,
} from "../src/bun/generation.js";

// ---------------------------------------------------------------------------
// buildRequestBody
// ---------------------------------------------------------------------------

describe("buildRequestBody", () => {
  it("includes text prompt as the only content when no image", () => {
    const body = buildRequestBody({ prompt: "a cat", model: "model/x" });
    const msgs = body.messages as Array<{ role: string; content: unknown[] }>;
    expect(msgs[0].content).toHaveLength(1);
    expect((msgs[0].content[0] as { type: string }).type).toBe("text");
  });

  it("prepends image_url when inputDataUrl is provided", () => {
    const body = buildRequestBody({ prompt: "edit it", inputDataUrl: "data:image/png;base64,abc", model: "model/x" });
    const content = (body.messages as Array<{ content: unknown[] }>)[0].content;
    expect(content).toHaveLength(2);
    expect((content[0] as { type: string }).type).toBe("image_url");
    expect((content[1] as { type: string }).type).toBe("text");
  });

  it("omits image_config when both aspect and size are auto", () => {
    const body = buildRequestBody({ prompt: "x", model: "m", aspectRatio: "auto", imageSize: "auto" });
    expect(body.image_config).toBeUndefined();
  });

  it("sets aspect_ratio in image_config when not auto", () => {
    const body = buildRequestBody({ prompt: "x", model: "m", aspectRatio: "16:9" });
    expect((body.image_config as Record<string, string>).aspect_ratio).toBe("16:9");
  });

  it("sets image_size in image_config when not auto", () => {
    const body = buildRequestBody({ prompt: "x", model: "m", imageSize: "2K" });
    expect((body.image_config as Record<string, string>).image_size).toBe("2K");
  });

  it("always sets modalities to [image, text]", () => {
    const body = buildRequestBody({ prompt: "x", model: "m" });
    expect(body.modalities).toEqual(["image", "text"]);
  });
});

// ---------------------------------------------------------------------------
// extractImage
// ---------------------------------------------------------------------------

describe("extractImage", () => {
  it("extracts base64 data from response", () => {
    const data = {
      choices: [{
        message: {
          images: [{ image_url: { url: "data:image/png;base64,iVBORw0KGgo=" } }],
          content: "Here is your image",
        },
      }],
    };
    const result = extractImage(data);
    expect(result.b64).toBe("iVBORw0KGgo=");
    expect(result.comment).toBe("Here is your image");
  });

  it("returns empty comment when message content is missing", () => {
    const data = {
      choices: [{
        message: { images: [{ image_url: { url: "data:image/png;base64,abc" } }] },
      }],
    };
    expect(extractImage(data).comment).toBe("");
  });

  it("throws when no images in response", () => {
    const data = {
      choices: [{ message: { images: [], content: "I cannot do that" } }],
    };
    expect(() => extractImage(data)).toThrow("No image in response");
  });

  it("throws with model comment when images array missing entirely", () => {
    const data = { choices: [{ message: { content: "blocked" } }] };
    expect(() => extractImage(data)).toThrow("blocked");
  });
});

// ---------------------------------------------------------------------------
// filterImageModels
// ---------------------------------------------------------------------------

describe("filterImageModels", () => {
  it("keeps models whose output modality includes image", () => {
    const models = [
      { id: "a/img", name: "A", architecture: { modality: "text->text+image" } },
      { id: "b/txt", name: "B", architecture: { modality: "text->text" } },
    ];
    const result = filterImageModels(models);
    expect(result).toHaveLength(1);
    expect(result[0].id).toBe("a/img");
  });

  it("excludes openrouter/auto even if it has image output", () => {
    const models = [
      { id: "openrouter/auto", name: "Auto", architecture: { modality: "text->text+image" } },
    ];
    expect(filterImageModels(models)).toHaveLength(0);
  });

  it("returns empty array when no image models", () => {
    expect(filterImageModels([{ id: "x", name: "X", architecture: { modality: "text->text" } }])).toHaveLength(0);
  });

  it("handles missing architecture gracefully", () => {
    expect(filterImageModels([{ id: "x", name: "X" }])).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// buildFallbackOrder
// ---------------------------------------------------------------------------

describe("buildFallbackOrder", () => {
  it("puts preferred model first", () => {
    const order = buildFallbackOrder("b", ["a", "b", "c"]);
    expect(order[0]).toBe("b");
  });

  it("excludes preferred from the rest of the list", () => {
    const order = buildFallbackOrder("b", ["a", "b", "c"]);
    expect(order).toEqual(["b", "a", "c"]);
  });

  it("works when preferred is not in the list", () => {
    const order = buildFallbackOrder("x", ["a", "b"]);
    expect(order).toEqual(["x", "a", "b"]);
  });
});

// ---------------------------------------------------------------------------
// generateWithFallback - mock fetch
// ---------------------------------------------------------------------------

describe("generateWithFallback", () => {
  const okResponse = {
    choices: [{
      message: {
        images: [{ image_url: { url: "data:image/png;base64,abc123" } }],
        content: "done",
      },
    }],
  };

  function mockFetch(response: unknown, status = 200): typeof fetch {
    return async () => ({
      ok: status >= 200 && status < 300,
      status,
      json: async () => response,
      text: async () => JSON.stringify(response),
    } as Response);
  }

  it("returns image on success", async () => {
    const result = await generateWithFallback(
      { prompt: "a cat", apiKey: "key" },
      MODELS,
      mockFetch(okResponse),
    );
    expect(result.b64).toBe("abc123");
    expect(result.comment).toBe("done");
  });

  it("uses preferred model when specified", async () => {
    const calls: string[] = [];
    const trackingFetch: typeof fetch = async (url, opts) => {
      const body = JSON.parse((opts?.body as string) ?? "{}");
      calls.push(body.model);
      return mockFetch(okResponse)(url, opts);
    };
    await generateWithFallback(
      { prompt: "x", apiKey: "key", model: MODELS[2] },
      MODELS,
      trackingFetch,
    );
    expect(calls[0]).toBe(MODELS[2]);
  });

  it("falls back to next model on 429", async () => {
    const calls: string[] = [];
    let attempt = 0;
    const trackingFetch: typeof fetch = async (url, opts) => {
      const body = JSON.parse((opts?.body as string) ?? "{}");
      calls.push(body.model);
      attempt++;
      if (attempt === 1) return mockFetch("rate limited", 429)(url, opts);
      return mockFetch(okResponse)(url, opts);
    };
    const result = await generateWithFallback({ prompt: "x", apiKey: "key" }, MODELS, trackingFetch);
    expect(calls).toHaveLength(2);
    expect(result.b64).toBe("abc123");
  });

  it("throws immediately on non-429 errors", async () => {
    const failFetch = mockFetch("server error", 500);
    await expect(
      generateWithFallback({ prompt: "x", apiKey: "key" }, MODELS, failFetch),
    ).rejects.toThrow("HTTP 500");
  });

  it("throws after all models are rate-limited", async () => {
    const rateLimitFetch = mockFetch("rate limited", 429);
    await expect(
      generateWithFallback({ prompt: "x", apiKey: "key" }, MODELS, rateLimitFetch),
    ).rejects.toThrow("All models rate-limited");
  });
});
