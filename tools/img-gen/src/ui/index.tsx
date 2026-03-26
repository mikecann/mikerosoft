import { createRoot } from "react-dom/client";
import { App } from "./App.js";

// Global styles for animations
const style = document.createElement("style");
style.textContent = `
  @keyframes spin { to { transform: rotate(360deg); } }
  ::-webkit-scrollbar { width: 6px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: #2a2a2a; border-radius: 3px; }
  select option { background: #1e1e1e; }
`;
document.head.appendChild(style);

const rootEl = document.getElementById("root");
if (!rootEl) throw new Error("Missing #root element");
createRoot(rootEl).render(<App />);
