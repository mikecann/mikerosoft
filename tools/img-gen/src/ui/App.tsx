import { useState, useRef, useEffect } from "react";
import { Electroview } from "electrobun/view";
import type { ImgGenRPC, SseEvent } from "../shared/types.js";
import { AnnotationModal } from "./AnnotationModal.js";

// ---------------------------------------------------------------------------
// RPC setup
// ---------------------------------------------------------------------------

const rpc = Electroview.defineRPC<ImgGenRPC>({ handlers: { requests: {}, messages: {} } });
void new Electroview({ rpc });

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type ChatMessage =
  | { id: string; role: "user"; prompt: string; attachedImageDataUrl?: string }
  | {
      id: string;
      role: "assistant";
      jobId: string;
      imageId?: string;
      serveUrl?: string;
      tempPath?: string;
      modelComment?: string;
      isGenerating: boolean;
      error?: string;
    };

const MODELS = [
  { label: "Gemini 3.1 Flash (fast)", value: "google/gemini-3.1-flash-image-preview" },
  { label: "Gemini 2.5 Flash", value: "google/gemini-2.5-flash-image" },
  { label: "Gemini 3 Pro (best)", value: "google/gemini-3-pro-image-preview" },
];

const ASPECT_RATIOS = [
  { label: "auto", value: "auto" },
  { label: "1:1", value: "1:1" },
  { label: "16:9", value: "16:9" },
  { label: "9:16", value: "9:16" },
  { label: "4:3", value: "4:3" },
  { label: "3:4", value: "3:4" },
  { label: "3:2", value: "3:2" },
  { label: "21:9", value: "21:9" },
];

const IMAGE_SIZES = [
  { label: "auto", value: "auto" },
  { label: "1K", value: "1K" },
  { label: "2K", value: "2K" },
  { label: "4K", value: "4K" },
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function randomId() {
  return Math.random().toString(36).slice(2);
}

function dataUrlFromBlob(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result as string);
    reader.onerror = reject;
    reader.readAsDataURL(blob);
  });
}

// ---------------------------------------------------------------------------
// Sub-components
// ---------------------------------------------------------------------------

function Spinner() {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8, color: "#888", fontSize: 13 }}>
      <div style={spinnerStyle} />
      Generating...
    </div>
  );
}

function ImageBubble({
  msg,
  onAnnotate,
  onDownload,
}: {
  msg: Extract<ChatMessage, { role: "assistant" }>;
  onAnnotate: (dataUrl: string, imageId: string) => void;
  onDownload: (imageId: string) => void;
}) {
  if (msg.isGenerating && !msg.serveUrl) return <Spinner />;
  if (msg.error) return <div style={{ color: "#e07070", fontSize: 13 }}>{msg.error}</div>;
  if (!msg.serveUrl) return null;

  const handleDragStart = (e: React.DragEvent<HTMLImageElement>) => {
    if (!msg.tempPath) return;
    const fileUrl = "file:///" + msg.tempPath.replace(/\\/g, "/");
    e.dataTransfer.effectAllowed = "copy";
    e.dataTransfer.setData("text/uri-list", fileUrl);
    e.dataTransfer.setData(
      "DownloadURL",
      `image/png:${msg.imageId}.png:${fileUrl}`,
    );
  };

  const handleAnnotateClick = () => {
    if (!msg.serveUrl || !msg.imageId) return;
    // Fetch image as data URL for the canvas
    fetch(msg.serveUrl)
      .then((r) => r.blob())
      .then((blob) => {
        const reader = new FileReader();
        reader.onload = () => onAnnotate(reader.result as string, msg.imageId!);
        reader.readAsDataURL(blob);
      });
  };

  return (
    <div>
      <div style={{ position: "relative", display: "inline-block" }}>
        <img
          src={msg.serveUrl}
          draggable
          onDragStart={handleDragStart}
          style={{
            maxWidth: "100%",
            maxHeight: 480,
            borderRadius: 8,
            display: "block",
            cursor: "grab",
          }}
          title="Drag to Explorer to save"
        />
        <div style={imageActionsStyle}>
          <button style={iconBtnStyle} onClick={handleAnnotateClick} title="Annotate">
            ✏
          </button>
          <button
            style={iconBtnStyle}
            onClick={() => { if (msg.imageId) onDownload(msg.imageId); }}
            title="Download to folder"
          >
            ⬇
          </button>
        </div>
      </div>
      {msg.modelComment && (
        <p style={{ color: "#888", fontSize: 12, marginTop: 6, maxWidth: 520 }}>
          {msg.modelComment}
        </p>
      )}
    </div>
  );
}

function UserBubble({ msg }: { msg: Extract<ChatMessage, { role: "user" }> }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "flex-end", gap: 4 }}>
      {msg.attachedImageDataUrl && (
        <img
          src={msg.attachedImageDataUrl}
          style={{ maxWidth: 160, maxHeight: 160, borderRadius: 6, objectFit: "cover" }}
        />
      )}
      <div style={userBubbleStyle}>{msg.prompt}</div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main App
// ---------------------------------------------------------------------------

export function App() {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [prompt, setPrompt] = useState("");
  const [attachedImage, setAttachedImage] = useState<{ dataUrl: string; name: string } | null>(null);
  const [model, setModel] = useState(MODELS[0].value);
  const [aspectRatio, setAspectRatio] = useState("auto");
  const [imageSize, setImageSize] = useState("auto");
  const [isGenerating, setIsGenerating] = useState(false);
  const [workingDir, setWorkingDir] = useState("");
  const [downloadStatus, setDownloadStatus] = useState<Record<string, string>>({});
  const [annotateTarget, setAnnotateTarget] = useState<{
    dataUrl: string;
    imageId: string;
  } | null>(null);
  const [pendingAnnotatedInput, setPendingAnnotatedInput] = useState<string | null>(null);

  const fileInputRef = useRef<HTMLInputElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const messagesEndRef = useRef<HTMLDivElement>(null);

  // Connect RPC + SSE on mount
  useEffect(() => {
    let es: EventSource | null = null;

    rpc.request.getConfig().then(({ workingDir: wd, eventsUrl }) => {
      setWorkingDir(wd);
      es = new EventSource(eventsUrl);
      es.onmessage = (ev) => {
        const event = JSON.parse(ev.data) as SseEvent;
        if (event.kind === "generating") {
          setIsGenerating(true);
        } else if (event.kind === "imageResult") {
          setMessages((prev) =>
            prev.map((m) =>
              m.role === "assistant" && m.jobId === event.jobId
                ? { ...m, imageId: event.imageId, serveUrl: event.serveUrl, tempPath: event.tempPath, modelComment: event.modelComment, isGenerating: false }
                : m,
            ),
          );
          setIsGenerating(false);
        } else if (event.kind === "imageError") {
          setMessages((prev) =>
            prev.map((m) =>
              m.role === "assistant" && m.jobId === event.jobId
                ? { ...m, error: event.error, isGenerating: false }
                : m,
            ),
          );
          setIsGenerating(false);
        }
      };
    });

    return () => { es?.close(); };
  }, []);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  const getLastServeUrl = (): string | undefined => {
    for (let i = messages.length - 1; i >= 0; i--) {
      const m = messages[i];
      if (m.role === "assistant" && m.serveUrl && !m.error) return m.serveUrl;
    }
    return undefined;
  };

  const handleSend = async () => {
    const trimmed = prompt.trim();
    if (!trimmed || isGenerating) return;

    const jobId = randomId();
    const userMsgId = randomId();
    const assistantMsgId = randomId();

    // Resolve the input image: prefer pending annotated, then last generated, then attached
    let inputDataUrl: string | undefined;
    if (pendingAnnotatedInput) {
      inputDataUrl = pendingAnnotatedInput;
      setPendingAnnotatedInput(null);
    } else if (attachedImage) {
      inputDataUrl = attachedImage.dataUrl;
    } else {
      const lastUrl = getLastServeUrl();
      if (lastUrl) {
        try {
          const blob = await fetch(lastUrl).then((r) => r.blob());
          inputDataUrl = await dataUrlFromBlob(blob);
        } catch {
          // no input image
        }
      }
    }

    const userMsg: ChatMessage = {
      id: userMsgId,
      role: "user",
      prompt: trimmed,
      attachedImageDataUrl: attachedImage?.dataUrl ?? (pendingAnnotatedInput ?? undefined),
    };
    const assistantMsg: ChatMessage = {
      id: assistantMsgId,
      role: "assistant",
      jobId,
      isGenerating: true,
    };

    setMessages((prev) => [...prev, userMsg, assistantMsg]);
    setPrompt("");
    setAttachedImage(null);
    setIsGenerating(true);

    try {
      await rpc.request.generate({
        jobId,
        prompt: trimmed,
        inputImageDataUrl: inputDataUrl,
        aspectRatio,
        imageSize,
        model,
      });
    } catch (err) {
      setMessages((prev) =>
        prev.map((m) =>
          m.id === assistantMsgId
            ? { ...m, error: String(err), isGenerating: false }
            : m,
        ),
      );
      setIsGenerating(false);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSend();
    }
  };

  const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    const dataUrl = await dataUrlFromBlob(file);
    setAttachedImage({ dataUrl, name: file.name });
    e.target.value = "";
  };

  const handleDownload = async (imageId: string) => {
    setDownloadStatus((s) => ({ ...s, [imageId]: "saving..." }));
    try {
      const { savedPath } = await rpc.request.download({ imageId });
      const filename = savedPath.split("\\").pop() ?? savedPath.split("/").pop() ?? savedPath;
      setDownloadStatus((s) => ({ ...s, [imageId]: `Saved: ${filename}` }));
      setTimeout(
        () => setDownloadStatus((s) => { const n = { ...s }; delete n[imageId]; return n; }),
        3000,
      );
    } catch (err) {
      setDownloadStatus((s) => ({ ...s, [imageId]: `Error: ${err}` }));
    }
  };

  const handleAnnotateDone = (annotatedDataUrl: string) => {
    setPendingAnnotatedInput(annotatedDataUrl);
    setAnnotateTarget(null);
  };

  const hasContent = messages.length > 0;

  return (
    <div style={rootStyle}>
      {/* Header */}
      <div style={headerStyle}>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <span style={{ fontWeight: 600, fontSize: 15 }}>Image Gen</span>
          {workingDir && (
            <span style={{ color: "#555", fontSize: 11, fontFamily: "monospace" }}>
              {workingDir}
            </span>
          )}
        </div>
        <select
          value={model}
          onChange={(e) => setModel(e.target.value)}
          style={selectStyle}
        >
          {MODELS.map((m) => (
            <option key={m.value} value={m.value}>
              {m.label}
            </option>
          ))}
        </select>
      </div>

      {/* Messages */}
      <div style={messagesStyle}>
        {!hasContent && (
          <div style={emptyStateStyle}>
            <div style={{ fontSize: 32, marginBottom: 12 }}>🎨</div>
            <div style={{ color: "#555", fontSize: 13 }}>
              Describe what you want to generate, or attach an image to start.
            </div>
          </div>
        )}

        {messages.map((msg) => (
          <div
            key={msg.id}
            style={{
              display: "flex",
              flexDirection: "column",
              alignItems: msg.role === "user" ? "flex-end" : "flex-start",
              marginBottom: 16,
            }}
          >
            {msg.role === "user" ? (
              <UserBubble msg={msg} />
            ) : (
              <div style={assistantBubbleStyle}>
                <ImageBubble
                  msg={msg}
                  onAnnotate={(dataUrl, imageId) => setAnnotateTarget({ dataUrl, imageId })}
                  onDownload={handleDownload}
                />
                {downloadStatus[msg.imageId ?? ""] && (
                  <div style={{ color: "#6b9", fontSize: 11, marginTop: 4 }}>
                    {downloadStatus[msg.imageId ?? ""]}
                  </div>
                )}
              </div>
            )}
          </div>
        ))}
        <div ref={messagesEndRef} />
      </div>

      {/* Pending annotation notice */}
      {pendingAnnotatedInput && (
        <div style={annotationNoticeStyle}>
          <img src={pendingAnnotatedInput} style={{ width: 40, height: 40, objectFit: "cover", borderRadius: 4 }} />
          <span style={{ fontSize: 12, color: "#aaa" }}>Annotated image will be used as input</span>
          <button
            style={{ ...iconBtnStyle, fontSize: 11, padding: "2px 6px" }}
            onClick={() => setPendingAnnotatedInput(null)}
          >
            clear
          </button>
        </div>
      )}

      {/* Attached image preview */}
      {attachedImage && (
        <div style={annotationNoticeStyle}>
          <img src={attachedImage.dataUrl} style={{ width: 40, height: 40, objectFit: "cover", borderRadius: 4 }} />
          <span style={{ fontSize: 12, color: "#aaa" }}>{attachedImage.name}</span>
          <button
            style={{ ...iconBtnStyle, fontSize: 11, padding: "2px 6px" }}
            onClick={() => setAttachedImage(null)}
          >
            clear
          </button>
        </div>
      )}

      {/* Input area */}
      <div style={inputAreaStyle}>
        <div style={inputRowStyle}>
          <button
            style={attachBtnStyle}
            onClick={() => fileInputRef.current?.click()}
            title="Attach image"
          >
            📎
          </button>
          <textarea
            ref={textareaRef}
            value={prompt}
            onChange={(e) => setPrompt(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Describe what you want..."
            rows={2}
            disabled={isGenerating}
            style={textareaStyle}
          />
          <button
            onClick={handleSend}
            disabled={isGenerating || !prompt.trim()}
            style={sendBtnStyle}
          >
            {isGenerating ? <div style={spinnerStyle} /> : "Generate"}
          </button>
        </div>
        <div style={toolbarStyle}>
          <label style={toolbarLabelStyle}>Aspect</label>
          <select value={aspectRatio} onChange={(e) => setAspectRatio(e.target.value)} style={selectSmallStyle}>
            {ASPECT_RATIOS.map((r) => (
              <option key={r.value} value={r.value}>{r.label}</option>
            ))}
          </select>
          <label style={toolbarLabelStyle}>Size</label>
          <select value={imageSize} onChange={(e) => setImageSize(e.target.value)} style={selectSmallStyle}>
            {IMAGE_SIZES.map((s) => (
              <option key={s.value} value={s.value}>{s.label}</option>
            ))}
          </select>
        </div>
      </div>

      <input
        ref={fileInputRef}
        type="file"
        accept="image/*"
        style={{ display: "none" }}
        onChange={handleFileChange}
      />

      {annotateTarget && (
        <AnnotationModal
          imageDataUrl={annotateTarget.dataUrl}
          onDone={handleAnnotateDone}
          onCancel={() => setAnnotateTarget(null)}
        />
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

const rootStyle: React.CSSProperties = {
  display: "flex",
  flexDirection: "column",
  height: "100vh",
  overflow: "hidden",
  background: "#111",
};

const headerStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  justifyContent: "space-between",
  padding: "10px 16px",
  borderBottom: "1px solid #222",
  flexShrink: 0,
  background: "#161616",
};

const messagesStyle: React.CSSProperties = {
  flex: 1,
  overflowY: "auto",
  padding: "16px",
  display: "flex",
  flexDirection: "column",
};

const emptyStateStyle: React.CSSProperties = {
  flex: 1,
  display: "flex",
  flexDirection: "column",
  alignItems: "center",
  justifyContent: "center",
  color: "#444",
  textAlign: "center",
};

const userBubbleStyle: React.CSSProperties = {
  background: "#1e3a5f",
  color: "#c8ddf5",
  padding: "8px 12px",
  borderRadius: "12px 12px 2px 12px",
  maxWidth: 480,
  fontSize: 14,
  lineHeight: 1.5,
};

const assistantBubbleStyle: React.CSSProperties = {
  maxWidth: 560,
};

const imageActionsStyle: React.CSSProperties = {
  position: "absolute",
  top: 6,
  right: 6,
  display: "flex",
  gap: 4,
};

const iconBtnStyle: React.CSSProperties = {
  background: "rgba(0,0,0,0.6)",
  border: "1px solid #333",
  borderRadius: 6,
  color: "#ccc",
  cursor: "pointer",
  fontSize: 14,
  padding: "4px 8px",
  lineHeight: 1,
};

const inputAreaStyle: React.CSSProperties = {
  borderTop: "1px solid #222",
  padding: "10px 16px 12px",
  background: "#161616",
  flexShrink: 0,
};

const inputRowStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "flex-end",
  gap: 8,
};

const textareaStyle: React.CSSProperties = {
  flex: 1,
  background: "#1e1e1e",
  border: "1px solid #2a2a2a",
  borderRadius: 8,
  color: "#e8e8e8",
  fontSize: 14,
  padding: "8px 12px",
  resize: "none",
  outline: "none",
  lineHeight: 1.5,
};

const sendBtnStyle: React.CSSProperties = {
  background: "#2563eb",
  border: "none",
  borderRadius: 8,
  color: "#fff",
  cursor: "pointer",
  fontSize: 14,
  fontWeight: 600,
  padding: "8px 18px",
  height: 52,
  minWidth: 90,
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
};

const attachBtnStyle: React.CSSProperties = {
  background: "transparent",
  border: "1px solid #2a2a2a",
  borderRadius: 8,
  color: "#aaa",
  cursor: "pointer",
  fontSize: 18,
  padding: "8px 10px",
  height: 52,
};

const toolbarStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  gap: 8,
  marginTop: 6,
};

const toolbarLabelStyle: React.CSSProperties = {
  fontSize: 11,
  color: "#555",
};

const selectStyle: React.CSSProperties = {
  background: "#1e1e1e",
  border: "1px solid #2a2a2a",
  borderRadius: 6,
  color: "#aaa",
  fontSize: 12,
  padding: "4px 8px",
};

const selectSmallStyle: React.CSSProperties = {
  ...selectStyle,
  padding: "3px 6px",
};

const annotationNoticeStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  gap: 8,
  padding: "6px 16px",
  background: "#1a1a1a",
  borderTop: "1px solid #222",
};

const spinnerStyle: React.CSSProperties = {
  width: 16,
  height: 16,
  border: "2px solid rgba(255,255,255,0.2)",
  borderTopColor: "#fff",
  borderRadius: "50%",
  animation: "spin 0.7s linear infinite",
  display: "inline-block",
};
