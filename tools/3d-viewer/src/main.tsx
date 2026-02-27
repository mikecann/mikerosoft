import "./styles.css";
import { createRoot } from "react-dom/client";
import path from "node:path";
import { App } from "./App.js";
import { getLogFilePath, logError, logInfo, logWarn } from "./log.js";

const filePath = process.env["GLB_FILE"];
logInfo(`booting renderer, log file: ${getLogFilePath()}`);

if (filePath) {
  document.title = `${path.basename(filePath, ".glb")} - 3D Viewer`;
  logInfo(`GLB_FILE received: ${filePath}`);
} else {
  logWarn("GLB_FILE not provided");
}

window.addEventListener("error", (event) => {
  const message = event.error?.stack || event.message || "unknown window error";
  logError(`window error: ${message}`);
});

window.addEventListener("unhandledrejection", (event) => {
  const reason =
    typeof event.reason === "string"
      ? event.reason
      : event.reason?.stack || JSON.stringify(event.reason);
  logError(`unhandled rejection: ${reason}`);
});

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
