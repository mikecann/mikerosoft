import "./styles.css";
import { createRoot } from "react-dom/client";
import path from "node:path";
import { App } from "./App.js";

const filePath = process.env["GLB_FILE"];

if (filePath) {
  document.title = `${path.basename(filePath, ".glb")} - 3D Viewer`;
}

createRoot(document.getElementById("root")!).render(
  filePath ? (
    <App filePath={filePath} />
  ) : (
    <div className="overlay">
      <span className="status error">
        No GLB file specified. Right-click a .glb file and choose &quot;View in
        3D Viewer&quot;.
      </span>
    </div>
  )
);
