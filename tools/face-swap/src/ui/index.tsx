import { createRoot } from "react-dom/client";
import { App } from "./App.js";

const style = document.createElement("style");
style.textContent = `
  @keyframes spin { to { transform: rotate(360deg); } }
  @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.5; } }
  ::-webkit-scrollbar { width: 6px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: #2a2a2a; border-radius: 3px; }
`;
document.head.appendChild(style);

const rootEl = document.getElementById("root");
if (!rootEl) throw new Error("Missing #root element");
createRoot(rootEl).render(<App />);

// Electrobun/WebView2 on Windows: the initial layout is calculated before the
// webview knows its real size, so everything is clipped at the bottom. A resize
// fixes it. We force a reflow by briefly changing the root height, then
// restoring it. Repeated at increasing intervals to catch late layout.
for (const delay of [100, 300, 600, 1000]) {
  setTimeout(() => {
    document.documentElement.style.height = "99.9%";
    requestAnimationFrame(() => {
      document.documentElement.style.height = "100%";
    });
  }, delay);
}
