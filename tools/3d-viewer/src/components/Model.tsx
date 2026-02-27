import { useEffect, useRef } from "react";
import { useLoader, useThree } from "@react-three/fiber";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { Box3, MathUtils, Mesh, PerspectiveCamera, Vector3 } from "three";
import { logInfo } from "../log.js";

interface ModelProps {
  blobUrl: string;
  onLoaded: () => void;
}

export function Model({ blobUrl, onLoaded }: ModelProps) {
  const camera = useThree((state) => state.camera);
  const settledRef = useRef(false);

  const { scene } = useLoader(GLTFLoader, blobUrl);

  useEffect(() => {
    if (settledRef.current) {
      return;
    }
    settledRef.current = true;
    logInfo("GLTF parsed");

    scene.traverse((obj) => {
      if ((obj as Mesh).isMesh) {
        obj.castShadow = true;
        obj.receiveShadow = true;
      }
    });

    // Manual fit without drei Bounds. We center the model and place camera
    // at a distance derived from its largest dimension.
    const box = new Box3().setFromObject(scene);
    const center = box.getCenter(new Vector3());
    const size = box.getSize(new Vector3());
    const maxDim = Math.max(size.x, size.y, size.z, 1e-3);
    scene.position.sub(center);

    if ((camera as PerspectiveCamera).isPerspectiveCamera) {
      const perspectiveCamera = camera as PerspectiveCamera;
      const fovRad = MathUtils.degToRad(perspectiveCamera.fov);
      const distance = (maxDim * 0.5) / Math.tan(fovRad * 0.5) * 1.8;
      const dir = new Vector3(1, 0.8, 1).normalize();
      perspectiveCamera.position.copy(dir.multiplyScalar(distance));
      perspectiveCamera.near = Math.max(distance / 1000, 0.001);
      perspectiveCamera.far = Math.max(distance * 1000, 1000);
      perspectiveCamera.lookAt(0, 0, 0);
      perspectiveCamera.updateProjectionMatrix();
    }

    onLoaded();
    logInfo("model ready and onLoaded fired");
  }, [scene, camera, onLoaded]);

  return <primitive object={scene} />;
}
