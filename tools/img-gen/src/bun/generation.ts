// Pure generation logic - no Bun/Electrobun dependencies, fully testable.

export const MODELS = [
  "google/gemini-3.1-flash-image-preview",
  "google/gemini-2.5-flash-image",
  "google/gemini-3-pro-image-preview",
];

export const API_URL = "https://openrouter.ai/api/v1/chat/completions";
export const MODELS_URL = "https://openrouter.ai/api/v1/models";

export type GenerateOneArgs = {
  prompt: string;
  inputDataUrl?: string;
  aspectRatio?: string;
  imageSize?: string;
  model: string;
  apiKey: string;
};

export type GenerateOneResult = { b64: string; comment: string };

export type OpenRouterModel = {
  id: string;
  name: string;
  architecture?: { modality?: string };
};

// ---------------------------------------------------------------------------
// Pure helpers - these are tested directly
// ---------------------------------------------------------------------------

export function buildRequestBody({
  prompt,
  inputDataUrl,
  aspectRatio,
  imageSize,
  model,
}: Omit<GenerateOneArgs, "apiKey">): Record<string, unknown> {
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
  return body;
}

export function extractImage(data: {
  choices: Array<{
    message: { images?: Array<{ image_url: { url: string } }>; content?: string };
  }>;
}): GenerateOneResult {
  const message = data.choices[0].message;
  if (!message.images?.length)
    throw new Error(`No image in response. Model said: ${message.content ?? "(nothing)"}`);
  return {
    b64: message.images[0].image_url.url.split(",", 2)[1],
    comment: message.content?.trim() ?? "",
  };
}

export function filterImageModels(models: OpenRouterModel[]): { id: string; name: string }[] {
  return models
    .filter((m) => {
      if (m.id === "openrouter/auto") return false;
      const output = m.architecture?.modality?.split("->")[1] ?? "";
      return output.includes("image");
    })
    .map((m) => ({ id: m.id, name: m.name }));
}

export function buildFallbackOrder(preferred: string, allModels: string[]): string[] {
  return [preferred, ...allModels.filter((m) => m !== preferred)];
}

// ---------------------------------------------------------------------------
// Network calls - injected fetch for testability
// ---------------------------------------------------------------------------

const REQUEST_TIMEOUT_MS = 90_000;

export async function generateOne(
  args: GenerateOneArgs,
  fetchFn: typeof fetch = fetch,
): Promise<GenerateOneResult> {
  const body = buildRequestBody(args);
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), REQUEST_TIMEOUT_MS);

  let res: Response;
  try {
    res = await fetchFn(API_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${args.apiKey}`,
        "Content-Type": "application/json",
        "HTTP-Referer": "https://github.com/mikecann/mikerosoft",
        "X-Title": "mikerosoft/img-gen",
      },
      body: JSON.stringify(body),
      signal: abort.signal,
    });
  } finally {
    clearTimeout(timer);
  }

  if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);
  return extractImage(await res.json() as Parameters<typeof extractImage>[0]);
}

export async function fetchImageModels(
  apiKey: string,
  fetchFn: typeof fetch = fetch,
): Promise<{ id: string; name: string }[]> {
  const res = await fetchFn(MODELS_URL, {
    headers: { Authorization: `Bearer ${apiKey}` },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const json = (await res.json()) as { data: OpenRouterModel[] };
  return filterImageModels(json.data);
}

export async function generateWithFallback(
  args: Omit<GenerateOneArgs, "model"> & { model?: string },
  fallbackModels: string[],
  fetchFn: typeof fetch = fetch,
): Promise<GenerateOneResult> {
  const preferred = args.model ?? fallbackModels[0];
  const order = buildFallbackOrder(preferred, fallbackModels);

  for (const model of order) {
    try {
      return await generateOne({ ...args, model }, fetchFn);
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
