import { Component, Suspense, useState } from "react";
import type { ReactNode, ErrorInfo } from "react";
import { Canvas } from "@react-three/fiber";
import { OrbitControls, Grid, Bounds } from "@react-three/drei";
import * as THREE from "three";
import path from "node:path";
import { Model } from "./components/Model.js";

// ─── Error boundary ────────────────────────────────────────────────────────

interface ErrorBoundaryProps {
  onError: (msg: string) => void;
  children: ReactNode;
}

class SceneErrorBoundary extends Component<ErrorBoundaryProps> {
  componentDidCatch(error: Error, _info: ErrorInfo) {
    this.props.onError(error.message || String(error));
  }
  render() {
    return this.props.children;
  }
}

// ─── App ───────────────────────────────────────────────────────────────────

interface AppProps {
  filePath: string;
}

export function App({ filePath }: AppProps) {
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState<string | null>(null);

  return (
    <div style={{ width: "100vw", height: "100vh", position: "relative" }}>
      {/* Loading / error overlay */}
      {!loaded && !error && (
        <div className="overlay">
          <div className="spinner" />
          <span className="status">Loading model...</span>
        </div>
      )}
      {error && (
        <div className="overlay">
          <span className="status error">Failed to load: {error}</span>
        </div>
      )}

      <Canvas
        shadows
        camera={{ fov: 45, near: 0.001, far: 100000 }}
        gl={{
          antialias: true,
          toneMapping: THREE.ACESFilmicToneMapping,
          toneMappingExposure: 1.0,
          outputColorSpace: THREE.SRGBColorSpace,
        }}
      >
        <ambientLight intensity={0.7} />
        <directionalLight position={[5, 10, 7]} intensity={1.5} castShadow />
        <directionalLight position={[-5, -3, -5]} intensity={0.5} color="#8cb4ff" />

        <Grid
          cellSize={0.5}
          cellColor="#222"
          sectionSize={5}
          sectionColor="#333"
          fadeDistance={60}
          infiniteGrid
        />

        <Bounds fit clip observe margin={1.5}>
          <SceneErrorBoundary onError={setError}>
            <Suspense fallback={null}>
              <Model filePath={filePath} onLoaded={() => setLoaded(true)} />
            </Suspense>
          </SceneErrorBoundary>
        </Bounds>

        <OrbitControls
          enableDamping
          dampingFactor={0.07}
          screenSpacePanning
          makeDefault
        />
      </Canvas>

      {loaded && (
        <>
          <div className="filename">{path.basename(filePath)}</div>
          <div className="controls-hint">
            Left drag: orbit
            <br />
            Right drag: pan
            <br />
            Scroll: zoom
          </div>
        </>
      )}
    </div>
  );
}
