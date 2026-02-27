import { useEffect, useMemo } from "react";
import { useLoader } from "@react-three/fiber";
import { useBounds } from "@react-three/drei";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { Mesh } from "three";
import fs from "node:fs";

interface ModelProps {
  filePath: string;
  onLoaded: () => void;
}

export function Model({ filePath, onLoaded }: ModelProps) {
  const bounds = useBounds();

  const blobUrl = useMemo(() => {
    const buffer = fs.readFileSync(filePath);
    return URL.createObjectURL(new Blob([buffer], { type: "model/gltf-binary" }));
  }, [filePath]);

  useEffect(() => () => URL.revokeObjectURL(blobUrl), [blobUrl]);

  const { scene } = useLoader(GLTFLoader, blobUrl);

  useEffect(() => {
    scene.traverse((obj) => {
      if ((obj as Mesh).isMesh) {
        obj.castShadow = true;
        obj.receiveShadow = true;
      }
    });
    bounds.refresh().fit();
    onLoaded();
  }, [scene]);

  return <primitive object={scene} />;
}
