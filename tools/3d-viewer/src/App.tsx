import { Component, Suspense, useState } from "react";
import type { ErrorInfo, ReactNode } from "react";
import { useEffect, useMemo } from "react";
import { Canvas } from "@react-three/fiber";
import { OrbitControls } from "@react-three/drei";
import * as THREE from "three";
import path from "node:path";
import fs from "node:fs";
import { Model } from "./components/Model.js";
import { logError, logInfo } from "./log.js";

interface AppProps {
  filePath: string;
}

interface ErrorBoundaryProps {
  onError: (msg: string) => void;
  children: ReactNode;
}

class SceneErrorBoundary extends Component<ErrorBoundaryProps> {
  componentDidCatch(error: Error, _info: ErrorInfo) {
    const msg = error?.message || String(error);
    logError(`model render error: ${msg}`);
    this.props.onError(msg);
  }
  render() {
    return this.props.children;
  }
}

export function App({ filePath }: AppProps) {
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const modelBlob = useMemo(() => {
    try {
      const buffer = fs.readFileSync(filePath);
      logInfo(`read model bytes: ${buffer.length}`);
      const blobUrl = URL.createObjectURL(
        new Blob([buffer], { type: "model/gltf-binary" })
      );
      logInfo("created model blob URL");
      return { blobUrl, error: null as string | null };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      logError(`file read failed: ${msg}`);
      return { blobUrl: null as string | null, error: msg };
    }
  }, [filePath]);

  useEffect(() => {
    return () => {
      if (modelBlob.blobUrl) {
        URL.revokeObjectURL(modelBlob.blobUrl);
        logInfo("revoked model blob URL");
      }
    };
  }, [modelBlob.blobUrl]);

  const overlayError = error ?? modelBlob.error;

  return (
    <div style={{ width: "100vw", height: "100vh", position: "relative", overflow: "hidden" }}>
      {!loaded && !overlayError && (
        <div className="overlay">
          <div className="spinner" />
          <span className="status">Loading model...</span>
        </div>
      )}
      {overlayError && (
        <div className="overlay">
          <span className="status error">Failed to load: {overlayError}</span>
        </div>
      )}

      <Canvas
        style={{ width: "100vw", height: "100vh", display: "block" }}
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

        <SceneErrorBoundary onError={setError}>
          <Suspense fallback={null}>
            {modelBlob.blobUrl ? (
              <Model blobUrl={modelBlob.blobUrl} onLoaded={() => setLoaded(true)} />
            ) : null}
          </Suspense>
        </SceneErrorBoundary>

        <OrbitControls enableDamping dampingFactor={0.07} screenSpacePanning makeDefault />
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

