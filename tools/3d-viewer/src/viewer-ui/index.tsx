import { Electroview } from "electrobun/view";
import type { ViewerRPC } from "../shared/types.js";
import { createRoot } from "react-dom/client";
import { Suspense, useEffect, useState } from "react";
import { Canvas, useThree } from "@react-three/fiber";
import { Grid, OrbitControls, useGLTF } from "@react-three/drei";
import * as THREE from "three";

// Set up RPC connection to main process
const rpc = Electroview.defineRPC<ViewerRPC>({
  handlers: {
    requests: {},
    messages: {},
  },
});
const electrobun = new Electroview({ rpc });
void electrobun;

// ---- Model component --------------------------------------------------------

function Model({ url, onGridY }: { url: string; onGridY: (y: number) => void }) {
  const { scene } = useGLTF(url);
  const { camera, controls } = useThree();

  useEffect(() => {
    // Measure the unmodified bounding box before any positioning
    scene.position.set(0, 0, 0);
    const box = new THREE.Box3().setFromObject(scene);
    const center = box.getCenter(new THREE.Vector3());
    const size = box.getSize(new THREE.Vector3());
    const maxDim = Math.max(size.x, size.y, size.z, 1e-3);

    // Centre the model fully at the world origin
    scene.position.set(-center.x, -center.y, -center.z);

    // Grid sits at the bottom of the centred model
    onGridY(-size.y / 2);

    // Replicate the original vanilla camera setup exactly
    const cam = camera as THREE.PerspectiveCamera;
    const fovRad = THREE.MathUtils.degToRad(cam.fov);
    const distance = ((maxDim * 0.5) / Math.tan(fovRad * 0.5)) * 1.8;
    const dir = new THREE.Vector3(1, 0.8, 1).normalize();
    cam.position.copy(dir.multiplyScalar(distance));
    cam.near = Math.max(distance / 1000, 0.001);
    cam.far = Math.max(distance * 1000, 1000);
    cam.lookAt(0, 0, 0);
    cam.updateProjectionMatrix();

    // Sync OrbitControls target to the world origin where the model is centred.
    // Controls may not be registered yet on first render (it's a sibling), so we
    // guard and let the effect re-run when controls becomes available.
    if (controls) {
      (controls as THREE.EventDispatcher & { target: THREE.Vector3; update(): void }).target.set(
        0,
        0,
        0,
      );
      (controls as THREE.EventDispatcher & { update(): void }).update();
    }

    scene.traverse((obj) => {
      if ((obj as THREE.Mesh).isMesh) {
        obj.castShadow = true;
        obj.receiveShadow = true;
      }
    });
  }, [scene, camera, controls, onGridY]);

  return <primitive object={scene} />;
}

// ---- Scene -----------------------------------------------------------------

function Scene({ modelUrl }: { modelUrl: string }) {
  const [gridY, setGridY] = useState(0);

  return (
    <>
      <ambientLight intensity={0.7} />
      <directionalLight position={[5, 10, 7]} intensity={1.5} castShadow />
      <directionalLight position={[-5, -3, -5]} intensity={0.5} color="#8cb4ff" />

      <Model url={modelUrl} onGridY={setGridY} />

      <OrbitControls makeDefault enableDamping dampingFactor={0.07} screenSpacePanning />

      <Grid
        args={[200, 200]}
        position={[0, gridY, 0]}
        cellSize={0.5}
        cellThickness={0.6}
        cellColor="#2a2a2a"
        sectionSize={5}
        sectionThickness={1}
        sectionColor="#3a3a3a"
        fadeDistance={80}
        fadeStrength={1}
        infiniteGrid
      />
    </>
  );
}

// ---- App -------------------------------------------------------------------

function App() {
  const [modelUrl, setModelUrl] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    rpc.request
      .getModelUrl()
      .then((url) => {
        setModelUrl(url || null);
        setLoading(false);
      })
      .catch(() => {
        setError("Could not reach main process");
        setLoading(false);
      });
  }, []);

  if (error) {
    return (
      <div style={overlayStyle}>
        <span style={{ color: "#e07070", fontSize: 13 }}>Failed to load: {error}</span>
      </div>
    );
  }

  return (
    <>
      <Canvas
        shadows
        gl={{ antialias: true, toneMapping: THREE.ACESFilmicToneMapping, toneMappingExposure: 1.0 }}
        onCreated={({ gl }) => {
          gl.outputColorSpace = THREE.SRGBColorSpace;
        }}
        style={{ width: "100vw", height: "100vh", background: "#111" }}
      >
        {modelUrl && (
          <Suspense fallback={null}>
            <Scene modelUrl={modelUrl} />
          </Suspense>
        )}
        {!modelUrl && !loading && (
          // Empty scene - no file provided
          <ambientLight intensity={0.5} />
        )}
      </Canvas>

      {loading && (
        <div style={overlayStyle}>
          <div style={spinnerStyle} />
          <span style={{ color: "#888", fontSize: 13 }}>Loading model...</span>
        </div>
      )}

      {!loading && modelUrl && (
        <div style={hintStyle}>
          Left drag: orbit
          <br />
          Right drag: pan
          <br />
          Scroll: zoom
        </div>
      )}
    </>
  );
}

// ---- Styles ----------------------------------------------------------------

const overlayStyle: React.CSSProperties = {
  position: "fixed",
  inset: 0,
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  flexDirection: "column",
  gap: 16,
  background: "#111",
  zIndex: 10,
};

const hintStyle: React.CSSProperties = {
  position: "fixed",
  bottom: 14,
  right: 14,
  fontSize: 11,
  color: "rgba(255,255,255,0.25)",
  pointerEvents: "none",
  userSelect: "none",
  textAlign: "right",
  lineHeight: 1.8,
};

const spinnerKeyframes = `
  @keyframes spin { to { transform: rotate(360deg); } }
`;

const spinnerStyle: React.CSSProperties = {
  width: 44,
  height: 44,
  border: "3px solid #2a2a2a",
  borderTopColor: "#5b9bd5",
  borderRadius: "50%",
  animation: "spin 0.7s linear infinite",
};

// ---- Mount -----------------------------------------------------------------

const styleEl = document.createElement("style");
styleEl.textContent = `* { margin: 0; padding: 0; box-sizing: border-box; } body { overflow: hidden; } ${spinnerKeyframes}`;
document.head.appendChild(styleEl);

const root = document.getElementById("root")!;
createRoot(root).render(<App />);
