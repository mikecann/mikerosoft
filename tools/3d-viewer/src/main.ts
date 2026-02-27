import "./styles.css";
import path from "node:path";
import { Viewer } from "./viewer.js";
import { showError } from "./ui.js";

const filePath = process.env["GLB_FILE"];

if (!filePath) {
  showError(
    'No GLB file specified. Right-click a .glb file and choose "View in 3D Viewer".'
  );
} else {
  const el = document.getElementById("filename");
  if (el) el.textContent = path.basename(filePath);
  document.title = `${path.basename(filePath, ".glb")} - 3D Viewer`;

  const viewer = new Viewer();
  viewer.loadGlb(filePath);
}
