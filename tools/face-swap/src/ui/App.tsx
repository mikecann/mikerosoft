import { useState, useRef, useEffect, useCallback } from "react";
import { Electroview } from "electrobun/view";
import type { FaceSwapRPC, SseEvent, SwapResult } from "../shared/types.js";

// ---------------------------------------------------------------------------
// RPC setup
// ---------------------------------------------------------------------------

const rpc = Electroview.defineRPC<FaceSwapRPC>({ handlers: { requests: {}, messages: {} } });
void new Electroview({ rpc });

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function randomId() {
  return Math.random().toString(36).slice(2);
}

async function fileToDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result as string);
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
}

function isImageFile(file: File) {
  return file.type.startsWith("image/");
}

type SelectedImage = {
  dataUrl: string;
  name: string;
  originalPath?: string;
};

function getFilePath(file: File): string | undefined {
  const desktopFile = file as File & { path?: string };
  return desktopFile.path;
}

// ---------------------------------------------------------------------------
// DropZone component
// ---------------------------------------------------------------------------

function DropZone({
  label,
  sublabel,
  dataUrl,
  onImage,
  disabled,
}: {
  label: string;
  sublabel: string;
  dataUrl: string | null;
  onImage: (image: SelectedImage | null) => void;
  disabled: boolean;
}) {
  const [isDragOver, setIsDragOver] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  const handleDrop = useCallback(
    async (e: React.DragEvent) => {
      e.preventDefault();
      setIsDragOver(false);
      if (disabled) return;

      const file = e.dataTransfer.files[0];
      if (!file || !isImageFile(file)) return;
      onImage({
        dataUrl: await fileToDataUrl(file),
        name: file.name,
        originalPath: getFilePath(file),
      });
    },
    [disabled, onImage],
  );

  const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    onImage({
      dataUrl: await fileToDataUrl(file),
      name: file.name,
      originalPath: getFilePath(file),
    });
    e.target.value = "";
  };

  return (
    <div style={dropPanelStyle}>
      <div style={{ fontSize: 11, color: "#555", textTransform: "uppercase", letterSpacing: "0.08em", marginBottom: 8 }}>
        {label}
      </div>

      <div
        style={{
          ...dropZoneStyle,
          borderColor: isDragOver ? "#2563eb" : dataUrl ? "#2a2a2a" : "#222",
          background: isDragOver ? "#0f1e3a" : dataUrl ? "transparent" : "#141414",
          cursor: disabled ? "not-allowed" : "pointer",
        }}
        onDragOver={(e) => { e.preventDefault(); if (!disabled) setIsDragOver(true); }}
        onDragLeave={() => setIsDragOver(false)}
        onDrop={handleDrop}
        onClick={() => { if (!disabled) inputRef.current?.click(); }}
      >
        {dataUrl ? (
          <img
            src={dataUrl}
            style={{ maxWidth: "100%", maxHeight: "100%", objectFit: "contain", borderRadius: 6, display: "block" }}
          />
        ) : (
          <div style={dropPlaceholderStyle}>
            <div style={{ fontSize: 28, marginBottom: 8, opacity: 0.3 }}>⬆</div>
            <div style={{ fontSize: 13, color: "#444" }}>Drop image here</div>
            <div style={{ fontSize: 11, color: "#333", marginTop: 4 }}>or click to browse</div>
          </div>
        )}
      </div>

      <div style={{ fontSize: 11, color: "#444", marginTop: 6, textAlign: "center" }}>{sublabel}</div>

      {dataUrl && (
        <button
          style={clearBtnStyle}
          onClick={(e) => { e.stopPropagation(); onImage(null); }}
          disabled={disabled}
        >
          clear
        </button>
      )}

      <input
        ref={inputRef}
        type="file"
        accept="image/*"
        style={{ display: "none" }}
        onChange={handleFileChange}
      />
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main App
// ---------------------------------------------------------------------------

export function App() {
  const [eventsUrl, setEventsUrl] = useState("");
  const [modelMissing, setModelMissing] = useState(false);
  const [modelPath, setModelPath] = useState("");
  const [pythonMissing, setPythonMissing] = useState(false);
  const [modelDownload, setModelDownload] = useState<
    | { kind: "idle" }
    | { kind: "downloading"; percent: number; mbDone: number; mbTotal: number }
    | { kind: "done" }
    | { kind: "error"; error: string }
  >({ kind: "idle" });

  const [targetImage, setTargetImage] = useState<SelectedImage | null>(null);
  const [sourceImage, setSourceImage] = useState<SelectedImage | null>(null);

  const [step, setStep] = useState<1 | 2 | 3>(1);
  const [result, setResult] = useState<SwapResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [logs, setLogs] = useState<string[]>([]);
  const logsEndRef = useRef<HTMLDivElement>(null);

  // Connect SSE + load initial config
  useEffect(() => {
    let es: EventSource | null = null;

    rpc.request.getConfig().then(({ initialTargetDataUrl, initialTargetPath, eventsUrl: url, modelMissing: missing, modelPath: mp, pythonMissing: pyMissing }) => {
      if (initialTargetDataUrl) {
        setTargetImage({
          dataUrl: initialTargetDataUrl,
          name: initialTargetPath?.split("\\").pop() ?? "target image",
          originalPath: initialTargetPath,
        });
      }
      setModelMissing(missing);
      setModelPath(mp);
      setPythonMissing(pyMissing);
      setEventsUrl(url);

      es = new EventSource(url);
      es.onmessage = (ev) => {
        const event = JSON.parse(ev.data) as SseEvent;
        if (event.kind === "swapping") {
          setStep(2);
          setError(null);
          setResult(null);
          setLogs([]);
        } else if (event.kind === "swapLog") {
          setLogs((prev) => [...prev, event.message]);
        } else if (event.kind === "swapResult") {
          setResult(event.image);
          setStep(3);
        } else if (event.kind === "swapError") {
          setError(event.error);
        } else if (event.kind === "modelDownloadProgress") {
          setModelDownload({ kind: "downloading", percent: event.percent, mbDone: event.mbDone, mbTotal: event.mbTotal });
        } else if (event.kind === "modelDownloadDone") {
          setModelDownload({ kind: "done" });
          setModelMissing(false);
        } else if (event.kind === "modelDownloadError") {
          setModelDownload({ kind: "error", error: event.error });
        }
      };
      es.onerror = () => console.warn("SSE lost, reconnecting...");
    });

    return () => { es?.close(); };
  }, []);

  // Auto-scroll logs
  useEffect(() => {
    if (logsEndRef.current) {
      logsEndRef.current.scrollIntoView({ behavior: "smooth" });
    }
  }, [logs]);

  const handleSwap = () => {
    if (!targetImage || !sourceImage || step !== 1) return;
    const jobId = randomId();
    setStep(2);
    setError(null);
    setResult(null);
    setLogs([]);
    rpc.request
      .swap({
        jobId,
        targetDataUrl: targetImage.dataUrl,
        sourceDataUrl: sourceImage.dataUrl,
        targetOriginalPath: targetImage.originalPath,
      })
      .catch((err: unknown) => {
        setError(String(err));
      });
  };

  const handleResultDragStart = (e: React.DragEvent<HTMLImageElement>) => {
    if (!result) return;
    const fileUrl = "file:///" + result.tempPath.replace(/\\/g, "/");
    e.dataTransfer.effectAllowed = "copy";
    e.dataTransfer.setData("text/uri-list", fileUrl);
    e.dataTransfer.setData("DownloadURL", `image/png:face-swap-result.png:${fileUrl}`);
  };

  const canSwap = Boolean(targetImage) && Boolean(sourceImage) && step === 1;

  return (
    <div style={rootStyle}>
      {/* Header */}
      <div style={headerStyle} className="electrobun-webkit-app-region-drag">
        <span style={{ fontWeight: 600, fontSize: 15 }}>Face Swap</span>
        <button
          className="electrobun-webkit-app-region-no-drag"
          style={closeBtnStyle}
          onClick={() => {
            rpc.request.closeWindow().catch(console.error);
          }}
          title="Close"
        >
          ×
        </button>
      </div>

      {/* Setup warnings */}
      {(pythonMissing || modelMissing) && (
        <div style={setupBannerStyle}>
          {pythonMissing && (
            <div style={setupRowStyle}>
              <span style={setupBadgeStyle}>Python missing</span>
              <span style={setupTextStyle}>
                Install Python from{" "}
                <span style={setupLinkStyle}>https://python.org</span>
                {" "}and make sure it is on your PATH, then restart Face Swap.
              </span>
            </div>
          )}
          {modelMissing && (
            <div style={setupRowStyle}>
              <span style={setupBadgeStyle}>Model missing</span>
              <div style={{ ...setupTextStyle, flex: 1 }}>
                <div style={{ marginBottom: 6 }}>
                  <strong style={{ color: "#c8a060" }}>inswapper_128.onnx</strong> (~555 MB) needs to be downloaded once.
                </div>

                {modelDownload.kind === "idle" && (
                  <button
                    style={downloadModelBtnStyle}
                    onClick={() => {
                      setModelDownload({ kind: "downloading", percent: 0, mbDone: 0, mbTotal: 0 });
                      rpc.request.downloadModel().catch(() => {});
                    }}
                  >
                    Download model now
                  </button>
                )}

                {modelDownload.kind === "downloading" && (
                  <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
                    <div style={progressBarTrackStyle}>
                      <div style={{ ...progressBarFillStyle, width: `${modelDownload.percent}%` }} />
                    </div>
                    <span style={{ fontSize: 11, color: "#a0875a" }}>
                      {modelDownload.percent}%
                      {modelDownload.mbTotal > 0 ? ` — ${modelDownload.mbDone} / ${modelDownload.mbTotal} MB` : ""}
                    </span>
                  </div>
                )}

                {modelDownload.kind === "error" && (
                  <div>
                    <div style={{ color: "#e07070", marginBottom: 4 }}>Download failed: {modelDownload.error}</div>
                    <button
                      style={downloadModelBtnStyle}
                      onClick={() => {
                        setModelDownload({ kind: "downloading", percent: 0, mbDone: 0, mbTotal: 0 });
                        rpc.request.downloadModel().catch(() => {});
                      }}
                    >
                      Retry
                    </button>
                  </div>
                )}

                {modelDownload.kind !== "downloading" && modelDownload.kind !== "done" && (
                  <div style={{ marginTop: 6, color: "#5a4a30", fontSize: 11 }}>
                    Save path: <span style={{ fontFamily: "monospace" }}>{modelPath}</span>
                  </div>
                )}
              </div>
            </div>
          )}
        </div>
      )}

      {/* Step 1: Choose Images */}
      {step === 1 && (
        <div style={stepContainerStyle}>
          <div style={panelsRowStyle}>
            <DropZone
              label="Target Image"
              sublabel="Face in this image gets replaced"
              dataUrl={targetImage?.dataUrl ?? null}
              onImage={setTargetImage}
              disabled={false}
            />

            <div style={arrowDividerStyle}>→</div>

            <DropZone
              label="Source Face"
              sublabel="Face to use from this image"
              dataUrl={sourceImage?.dataUrl ?? null}
              onImage={setSourceImage}
              disabled={false}
            />
          </div>

          <div style={swapRowStyle}>
            <button
              style={{
                ...swapBtnStyle,
                opacity: canSwap ? 1 : 0.4,
                cursor: canSwap ? "pointer" : "not-allowed",
              }}
              onClick={handleSwap}
              disabled={!canSwap}
            >
              Swap Faces
            </button>
          </div>
        </div>
      )}

      {/* Step 2: Generating */}
      {step === 2 && (
        <div style={stepContainerStyle}>
          <div style={generatingHeaderStyle}>
            {!error ? (
              <>
                <div style={largeSpinnerStyle} />
                <div style={{ fontSize: 18, fontWeight: 600, marginTop: 16 }}>Generating Image...</div>
                <div style={{ fontSize: 13, color: "#888", marginTop: 8 }}>This may take 10-30 seconds.</div>
              </>
            ) : (
              <>
                <div style={{ fontSize: 24, marginBottom: 12 }}>⚠️</div>
                <div style={{ fontSize: 18, fontWeight: 600, color: "#e07070" }}>Swap Failed</div>
                <button style={{ ...secondaryBtnStyle, marginTop: 16 }} onClick={() => setStep(1)}>Back</button>
              </>
            )}
          </div>
          <div style={{ padding: "0 24px 24px", flex: 1, display: "flex", flexDirection: "column", minHeight: 0 }}>
            <div style={{ fontSize: 11, color: "#555", textTransform: "uppercase", letterSpacing: "0.08em", marginBottom: 8 }}>
              Logs
            </div>
            <div style={{ ...logBoxStyle, flex: 1, marginBottom: 0, maxHeight: "none" }}>
              {logs.map((log, i) => (
                <div key={i} style={{ color: log.includes("ERROR") || log.includes("WARNING") ? "#e07070" : "#888" }}>
                  {log}
                </div>
              ))}
              <div ref={logsEndRef} />
            </div>
            {error && (
              <div style={{ ...errorBoxStyle, marginTop: 12 }}>
                <strong>Error:</strong> {error}
              </div>
            )}
          </div>
        </div>
      )}

      {/* Step 3: Result */}
      {step === 3 && result && (
        <div style={stepContainerStyle}>
          <div style={{ flex: 1, minHeight: 0, padding: 24, display: "flex", alignItems: "center", justifyContent: "center" }}>
            <img
              src={result.serveUrl}
              style={{ maxWidth: "100%", maxHeight: "100%", objectFit: "contain", borderRadius: 8, boxShadow: "0 4px 24px rgba(0,0,0,0.4)" }}
              draggable
              onDragStart={handleResultDragStart}
              title="Drag to save"
            />
          </div>
          <div style={resultActionsStyle}>
            <button style={secondaryBtnStyle} onClick={() => { setStep(1); setResult(null); }}>
              Start Over
            </button>
            <span style={{ fontSize: 12, color: "#6b9", maxWidth: 520, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
              Saved automatically: {result.autoSavedPath}
            </span>
          </div>
        </div>
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
  flex: 1,
  minHeight: 0,
  width: "100%",
  overflow: "hidden",
  background: "#111",
};

const headerStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  justifyContent: "space-between",
  padding: "8px 8px 8px 16px",
  borderBottom: "1px solid #1e1e1e",
  flexShrink: 0,
  background: "#161616",
  minHeight: 38,
};

const panelsRowStyle: React.CSSProperties = {
  display: "flex",
  flex: "1 1 auto",
  minHeight: 180,
  padding: "16px",
  gap: 12,
  alignItems: "stretch",
  overflow: "hidden",
};

const dropPanelStyle: React.CSSProperties = {
  flex: 1,
  display: "flex",
  flexDirection: "column",
  minWidth: 0,
};

const dropZoneStyle: React.CSSProperties = {
  flex: 1,
  border: "2px dashed #222",
  borderRadius: 10,
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  overflow: "hidden",
  transition: "border-color 0.15s, background 0.15s",
  padding: 8,
};

const dropPlaceholderStyle: React.CSSProperties = {
  display: "flex",
  flexDirection: "column",
  alignItems: "center",
  justifyContent: "center",
  userSelect: "none",
};

const arrowDividerStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  fontSize: 24,
  color: "#333",
  flexShrink: 0,
  paddingTop: 24,
};

const clearBtnStyle: React.CSSProperties = {
  marginTop: 4,
  background: "transparent",
  border: "1px solid #2a2a2a",
  borderRadius: 5,
  color: "#555",
  fontSize: 11,
  padding: "2px 8px",
  cursor: "pointer",
  alignSelf: "center",
};

const swapRowStyle: React.CSSProperties = {
  display: "flex",
  justifyContent: "center",
  padding: "4px 16px 12px",
  flexShrink: 0,
};

const swapBtnStyle: React.CSSProperties = {
  background: "#2563eb",
  border: "none",
  borderRadius: 8,
  color: "#fff",
  cursor: "pointer",
  fontSize: 15,
  fontWeight: 600,
  padding: "10px 32px",
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
};

const stepContainerStyle: React.CSSProperties = {
  display: "flex",
  flexDirection: "column",
  flex: 1,
  minHeight: 0,
  overflowY: "auto",
  WebkitOverflowScrolling: "touch",
};

const generatingHeaderStyle: React.CSSProperties = {
  display: "flex",
  flexDirection: "column",
  alignItems: "center",
  justifyContent: "center",
  padding: "40px 20px",
  flexShrink: 0,
};

const largeSpinnerStyle: React.CSSProperties = {
  width: 32,
  height: 32,
  border: "3px solid rgba(255,255,255,0.1)",
  borderTopColor: "#2563eb",
  borderRadius: "50%",
  animation: "spin 0.8s linear infinite",
};

const secondaryBtnStyle: React.CSSProperties = {
  background: "#1e1e1e",
  border: "1px solid #333",
  borderRadius: 8,
  color: "#ccc",
  cursor: "pointer",
  fontSize: 14,
  fontWeight: 600,
  padding: "8px 24px",
};

const closeBtnStyle: React.CSSProperties = {
  width: 30,
  height: 30,
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  background: "transparent",
  border: "none",
  borderRadius: 6,
  color: "#bbb",
  cursor: "pointer",
  fontSize: 20,
  lineHeight: 1,
  padding: 0,
};

const resultActionsStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  gap: 16,
  padding: "16px",
  background: "#161616",
  borderTop: "1px solid #222",
  flexShrink: 0,
};

const logBoxStyle: React.CSSProperties = {
  background: "#0a0a0a",
  border: "1px solid #222",
  borderRadius: 6,
  padding: "8px 12px",
  fontFamily: "monospace",
  fontSize: 11,
  color: "#888",
  maxHeight: 120,
  overflowY: "auto",
  marginBottom: 12,
  whiteSpace: "pre-wrap",
  wordBreak: "break-all",
};

const errorBoxStyle: React.CSSProperties = {
  background: "#2a1212",
  border: "1px solid #5a2020",
  borderRadius: 6,
  color: "#e07070",
  fontSize: 12,
  padding: "8px 12px",
  whiteSpace: "pre-wrap",
  wordBreak: "break-word",
};

const setupBannerStyle: React.CSSProperties = {
  background: "#1a1008",
  borderBottom: "1px solid #3a2a10",
  padding: "10px 16px",
  display: "flex",
  flexDirection: "column",
  gap: 8,
  flexShrink: 0,
};

const setupRowStyle: React.CSSProperties = {
  display: "flex",
  gap: 10,
  alignItems: "flex-start",
};

const setupBadgeStyle: React.CSSProperties = {
  background: "#5a3010",
  color: "#e0a070",
  fontSize: 10,
  fontWeight: 700,
  textTransform: "uppercase",
  letterSpacing: "0.06em",
  padding: "2px 6px",
  borderRadius: 4,
  flexShrink: 0,
  marginTop: 2,
};

const setupTextStyle: React.CSSProperties = {
  fontSize: 12,
  color: "#a0875a",
  lineHeight: 1.6,
};

const setupLinkStyle: React.CSSProperties = {
  color: "#6aabdf",
  wordBreak: "break-all",
};

const downloadModelBtnStyle: React.CSSProperties = {
  background: "#3a2a10",
  border: "1px solid #6a4a20",
  borderRadius: 6,
  color: "#e0a060",
  cursor: "pointer",
  fontSize: 12,
  fontWeight: 600,
  padding: "5px 14px",
};

const progressBarTrackStyle: React.CSSProperties = {
  width: "100%",
  maxWidth: 320,
  height: 6,
  background: "#2a1a08",
  borderRadius: 3,
  overflow: "hidden",
};

const progressBarFillStyle: React.CSSProperties = {
  height: "100%",
  background: "#e0a060",
  borderRadius: 3,
  transition: "width 0.3s ease",
};

const spinnerStyle: React.CSSProperties = {
  width: 14,
  height: 14,
  border: "2px solid rgba(255,255,255,0.2)",
  borderTopColor: "#fff",
  borderRadius: "50%",
  animation: "spin 0.7s linear infinite",
  display: "inline-block",
  flexShrink: 0,
};
