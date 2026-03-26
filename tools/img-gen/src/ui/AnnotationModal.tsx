import { useRef, useState, useEffect, useCallback } from "react";

type Tool = "pen" | "rect" | "circle" | "arrow" | "text";

type Annotation =
  | { kind: "pen"; points: [number, number][] }
  | { kind: "rect"; x: number; y: number; w: number; h: number }
  | { kind: "circle"; cx: number; cy: number; rx: number; ry: number }
  | { kind: "arrow"; x1: number; y1: number; x2: number; y2: number }
  | { kind: "text"; x: number; y: number; text: string };

const ANNO_COLOR = "#ff3333";
const LINE_WIDTH = 2.5;

// ---------------------------------------------------------------------------
// Drawing helpers
// ---------------------------------------------------------------------------

function drawArrow(
  ctx: CanvasRenderingContext2D,
  x1: number,
  y1: number,
  x2: number,
  y2: number,
) {
  const headLen = 14;
  const angle = Math.atan2(y2 - y1, x2 - x1);
  ctx.beginPath();
  ctx.moveTo(x1, y1);
  ctx.lineTo(x2, y2);
  ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(x2, y2);
  ctx.lineTo(x2 - headLen * Math.cos(angle - Math.PI / 6), y2 - headLen * Math.sin(angle - Math.PI / 6));
  ctx.moveTo(x2, y2);
  ctx.lineTo(x2 - headLen * Math.cos(angle + Math.PI / 6), y2 - headLen * Math.sin(angle + Math.PI / 6));
  ctx.stroke();
}

function redraw(
  ctx: CanvasRenderingContext2D,
  annotations: Annotation[],
  brushSize: number,
) {
  ctx.save();
  ctx.strokeStyle = ANNO_COLOR;
  ctx.fillStyle = ANNO_COLOR;
  ctx.lineWidth = brushSize;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";

  for (const a of annotations) {
    if (a.kind === "pen") {
      if (a.points.length < 2) continue;
      ctx.beginPath();
      ctx.moveTo(a.points[0][0], a.points[0][1]);
      for (let i = 1; i < a.points.length; i++) ctx.lineTo(a.points[i][0], a.points[i][1]);
      ctx.stroke();
    } else if (a.kind === "rect") {
      ctx.strokeRect(a.x, a.y, a.w, a.h);
    } else if (a.kind === "circle") {
      ctx.beginPath();
      ctx.ellipse(a.cx, a.cy, Math.abs(a.rx), Math.abs(a.ry), 0, 0, Math.PI * 2);
      ctx.stroke();
    } else if (a.kind === "arrow") {
      drawArrow(ctx, a.x1, a.y1, a.x2, a.y2);
    } else if (a.kind === "text") {
      ctx.font = `bold ${brushSize * 7}px system-ui, sans-serif`;
      ctx.fillText(a.text, a.x, a.y);
    }
  }

  ctx.restore();
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

export function AnnotationModal({
  imageDataUrl,
  onDone,
  onCancel,
}: {
  imageDataUrl: string;
  onDone: (annotatedDataUrl: string) => void;
  onCancel: () => void;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const imageRef = useRef<HTMLImageElement | null>(null);
  const [tool, setTool] = useState<Tool>("pen");
  const [brushSize, setBrushSize] = useState(2.5);
  const [annotations, setAnnotations] = useState<Annotation[]>([]);
  const [isDrawing, setIsDrawing] = useState(false);
  const [imgSize, setImgSize] = useState({ w: 800, h: 600 });
  const [textInput, setTextInput] = useState("");
  const [pendingText, setPendingText] = useState<{ x: number; y: number } | null>(null);
  const dragStart = useRef<{ x: number; y: number } | null>(null);
  const currentPenPoints = useRef<[number, number][]>([]);

  // Load image and size canvas
  useEffect(() => {
    const img = new Image();
    img.onload = () => {
      const maxW = window.innerWidth * 0.85;
      const maxH = window.innerHeight * 0.75;
      const scale = Math.min(1, maxW / img.naturalWidth, maxH / img.naturalHeight);
      const w = Math.round(img.naturalWidth * scale);
      const h = Math.round(img.naturalHeight * scale);
      setImgSize({ w, h });
      imageRef.current = img;
    };
    img.src = imageDataUrl;
  }, [imageDataUrl]);

  // Redraw canvas whenever annotations change
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || !imageRef.current) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    redraw(ctx, annotations, brushSize);
  }, [annotations, brushSize, imgSize]);

  const getPos = (e: React.MouseEvent<HTMLCanvasElement>): [number, number] => {
    if (!canvasRef.current) return [0, 0] as [number, number];
    const rect = canvasRef.current.getBoundingClientRect();
    return [e.clientX - rect.left, e.clientY - rect.top];
  };

  const handleMouseDown = (e: React.MouseEvent<HTMLCanvasElement>) => {
    const [x, y] = getPos(e);

    if (tool === "text") {
      setPendingText({ x, y });
      setTextInput("");
      return;
    }

    setIsDrawing(true);
    dragStart.current = { x, y };

    if (tool === "pen") {
      currentPenPoints.current = [[x, y]];
    }
  };

  const handleMouseMove = useCallback(
    (e: React.MouseEvent<HTMLCanvasElement>) => {
      if (!isDrawing || !dragStart.current) return;
      const [x, y] = getPos(e);
      const { x: sx, y: sy } = dragStart.current;

      if (tool === "pen") {
        currentPenPoints.current.push([x, y]);
        // Preview: draw latest stroke segment on canvas directly
        const ctx = canvasRef.current?.getContext("2d");
        if (ctx && currentPenPoints.current.length > 1) {
          const pts = currentPenPoints.current;
          ctx.save();
          ctx.strokeStyle = ANNO_COLOR;
          ctx.lineWidth = brushSize;
          ctx.lineCap = "round";
          ctx.lineJoin = "round";
          ctx.beginPath();
          ctx.moveTo(pts[pts.length - 2][0], pts[pts.length - 2][1]);
          ctx.lineTo(x, y);
          ctx.stroke();
          ctx.restore();
        }
        return;
      }

      // For shape tools, re-render all committed annotations + current preview
      const canvas = canvasRef.current;
      const ctx = canvas?.getContext("2d");
      if (!ctx || !canvas) return;
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      redraw(ctx, annotations, brushSize);

      ctx.save();
      ctx.strokeStyle = ANNO_COLOR;
      ctx.lineWidth = brushSize;
      ctx.lineCap = "round";
      ctx.lineJoin = "round";

      if (tool === "rect") {
        ctx.strokeRect(sx, sy, x - sx, y - sy);
      } else if (tool === "circle") {
        ctx.beginPath();
        ctx.ellipse(sx + (x - sx) / 2, sy + (y - sy) / 2, Math.abs(x - sx) / 2, Math.abs(y - sy) / 2, 0, 0, Math.PI * 2);
        ctx.stroke();
      } else if (tool === "arrow") {
        drawArrow(ctx, sx, sy, x, y);
      }

      ctx.restore();
    },
    [isDrawing, tool, brushSize, annotations],
  );

  const handleMouseUp = (e: React.MouseEvent<HTMLCanvasElement>) => {
    if (!isDrawing || !dragStart.current) return;
    const [x, y] = getPos(e);
    const { x: sx, y: sy } = dragStart.current;
    setIsDrawing(false);

    if (tool === "pen") {
      const pts = [...currentPenPoints.current, [x, y] as [number, number]];
      setAnnotations((prev) => [...prev, { kind: "pen", points: pts }]);
      currentPenPoints.current = [];
    } else if (tool === "rect") {
      setAnnotations((prev) => [...prev, { kind: "rect", x: sx, y: sy, w: x - sx, h: y - sy }]);
    } else if (tool === "circle") {
      setAnnotations((prev) => [
        ...prev,
        { kind: "circle", cx: sx + (x - sx) / 2, cy: sy + (y - sy) / 2, rx: (x - sx) / 2, ry: (y - sy) / 2 },
      ]);
    } else if (tool === "arrow") {
      setAnnotations((prev) => [...prev, { kind: "arrow", x1: sx, y1: sy, x2: x, y2: y }]);
    }

    dragStart.current = null;
  };

  const handleTextConfirm = () => {
    if (!pendingText || !textInput.trim()) {
      setPendingText(null);
      return;
    }
    setAnnotations((prev) => [
      ...prev,
      { kind: "text", x: pendingText.x, y: pendingText.y, text: textInput.trim() },
    ]);
    setPendingText(null);
    setTextInput("");
  };

  const handleUndo = () => setAnnotations((prev) => prev.slice(0, -1));
  const handleClear = () => setAnnotations([]);

  const handleDone = () => {
    const img = imageRef.current;
    if (!img) return onDone(imageDataUrl);

    // Composite: draw original image then annotations onto a full-res canvas
    const out = document.createElement("canvas");
    out.width = imgSize.w;
    out.height = imgSize.h;
    const ctx = out.getContext("2d");
    if (!ctx) return onDone(imageDataUrl);
    ctx.drawImage(img, 0, 0, imgSize.w, imgSize.h);
    redraw(ctx, annotations, brushSize);
    onDone(out.toDataURL("image/png"));
  };

  const toolBtn = (t: Tool, label: string) => (
    <button
      style={{ ...toolBtnStyle, background: tool === t ? "#2563eb" : "#1e1e1e" }}
      onClick={() => setTool(t)}
    >
      {label}
    </button>
  );

  return (
    <div style={overlayStyle}>
      <div style={modalStyle}>
        {/* Toolbar */}
        <div style={modalHeaderStyle}>
          <div style={{ display: "flex", gap: 4, alignItems: "center" }}>
            {toolBtn("pen", "✏ Pen")}
            {toolBtn("rect", "▭ Rect")}
            {toolBtn("circle", "◯ Circle")}
            {toolBtn("arrow", "→ Arrow")}
            {toolBtn("text", "T Text")}
          </div>
          <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
            <label style={{ fontSize: 11, color: "#777" }}>Size</label>
            <input
              type="range"
              min={1}
              max={8}
              step={0.5}
              value={brushSize}
              onChange={(e) => setBrushSize(parseFloat(e.target.value))}
              style={{ width: 80 }}
            />
            <button style={smallBtnStyle} onClick={handleUndo} disabled={annotations.length === 0}>
              Undo
            </button>
            <button style={smallBtnStyle} onClick={handleClear} disabled={annotations.length === 0}>
              Clear
            </button>
          </div>
          <div style={{ display: "flex", gap: 6 }}>
            <button style={smallBtnStyle} onClick={onCancel}>
              Cancel
            </button>
            <button
              style={{ ...smallBtnStyle, background: "#2563eb", borderColor: "#2563eb", color: "#fff" }}
              onClick={handleDone}
            >
              Done
            </button>
          </div>
        </div>

        {/* Canvas area */}
        <div style={{ position: "relative", display: "inline-block" }}>
          <img
            src={imageDataUrl}
            width={imgSize.w}
            height={imgSize.h}
            style={{ display: "block", userSelect: "none", pointerEvents: "none" }}
          />
          <canvas
            ref={canvasRef}
            width={imgSize.w}
            height={imgSize.h}
            style={{
              position: "absolute",
              inset: 0,
              cursor: tool === "text" ? "text" : "crosshair",
            }}
            onMouseDown={handleMouseDown}
            onMouseMove={handleMouseMove}
            onMouseUp={handleMouseUp}
            onMouseLeave={handleMouseUp}
          />
        </div>

        {/* Text input popup */}
        {pendingText && (
          <div style={textPopupStyle}>
            <input
              autoFocus
              value={textInput}
              onChange={(e) => setTextInput(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") handleTextConfirm();
                if (e.key === "Escape") setPendingText(null);
              }}
              placeholder="Type label..."
              style={textInputStyle}
            />
            <button style={{ ...smallBtnStyle, background: "#2563eb", borderColor: "#2563eb", color: "#fff" }} onClick={handleTextConfirm}>
              Add
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

const overlayStyle: React.CSSProperties = {
  position: "fixed",
  inset: 0,
  background: "rgba(0,0,0,0.85)",
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  zIndex: 100,
  padding: 24,
  overflow: "auto",
};

const modalStyle: React.CSSProperties = {
  background: "#161616",
  borderRadius: 12,
  border: "1px solid #2a2a2a",
  overflow: "hidden",
  display: "flex",
  flexDirection: "column",
  maxWidth: "90vw",
  maxHeight: "90vh",
};

const modalHeaderStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  justifyContent: "space-between",
  padding: "10px 14px",
  borderBottom: "1px solid #222",
  gap: 12,
  flexWrap: "wrap",
};

const toolBtnStyle: React.CSSProperties = {
  border: "1px solid #2a2a2a",
  borderRadius: 6,
  color: "#ccc",
  cursor: "pointer",
  fontSize: 12,
  padding: "4px 10px",
};

const smallBtnStyle: React.CSSProperties = {
  background: "#1e1e1e",
  border: "1px solid #2a2a2a",
  borderRadius: 6,
  color: "#ccc",
  cursor: "pointer",
  fontSize: 12,
  padding: "4px 10px",
};

const textPopupStyle: React.CSSProperties = {
  padding: "10px 14px",
  borderTop: "1px solid #222",
  display: "flex",
  gap: 8,
  alignItems: "center",
  background: "#1a1a1a",
};

const textInputStyle: React.CSSProperties = {
  flex: 1,
  background: "#1e1e1e",
  border: "1px solid #2a2a2a",
  borderRadius: 6,
  color: "#e8e8e8",
  fontSize: 13,
  padding: "5px 10px",
  outline: "none",
};
