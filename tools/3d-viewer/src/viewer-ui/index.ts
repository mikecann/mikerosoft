import { Electroview } from "electrobun/view";
import type { ViewerRPC } from "../shared/types.js";
import * as THREE from "three";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";

// Set up RPC connection to main process
const rpc = Electroview.defineRPC<ViewerRPC>({
  handlers: {
    requests: {},
    messages: {},
  },
});
const electrobun = new Electroview({ rpc });

const canvas = document.getElementById("canvas") as HTMLCanvasElement;
const loadingEl = document.getElementById("loading") as HTMLElement;
const errorEl = document.getElementById("error") as HTMLElement;
const hintEl = document.getElementById("hint") as HTMLElement;

// Three.js setup
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
renderer.setPixelRatio(window.devicePixelRatio);
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.0;
renderer.outputColorSpace = THREE.SRGBColorSpace;

const scene = new THREE.Scene();
scene.background = new THREE.Color(0x111111);

const camera = new THREE.PerspectiveCamera(45, window.innerWidth / window.innerHeight, 0.001, 100000);
camera.position.set(5, 4, 5);

const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.dampingFactor = 0.07;
controls.screenSpacePanning = true;

// Lights
const ambient = new THREE.AmbientLight(0xffffff, 0.7);
scene.add(ambient);

const dirLight1 = new THREE.DirectionalLight(0xffffff, 1.5);
dirLight1.position.set(5, 10, 7);
dirLight1.castShadow = true;
scene.add(dirLight1);

const dirLight2 = new THREE.DirectionalLight(0x8cb4ff, 0.5);
dirLight2.position.set(-5, -3, -5);
scene.add(dirLight2);

// Render loop
function animate() {
  requestAnimationFrame(animate);
  controls.update();
  renderer.render(scene, camera);
}
animate();

// Resize
window.addEventListener("resize", () => {
  camera.aspect = window.innerWidth / window.innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(window.innerWidth, window.innerHeight);
});

function showError(msg: string) {
  loadingEl.style.display = "none";
  errorEl.textContent = `Failed to load: ${msg}`;
  errorEl.style.display = "flex";
}

async function loadModel() {
  let modelUrl: string;
  try {
    modelUrl = await rpc.request.getModelUrl();
  } catch (e) {
    showError("Could not reach main process");
    return;
  }

  if (!modelUrl) {
    loadingEl.style.display = "none";
    // No file - show placeholder / empty scene
    return;
  }

  const loader = new GLTFLoader();
  loader.load(
    modelUrl,
    (gltf) => {
      const model = gltf.scene;

      model.traverse((obj) => {
        if ((obj as THREE.Mesh).isMesh) {
          obj.castShadow = true;
          obj.receiveShadow = true;
        }
      });

      // Fit camera to model bounds
      const box = new THREE.Box3().setFromObject(model);
      const center = box.getCenter(new THREE.Vector3());
      const size = box.getSize(new THREE.Vector3());
      const maxDim = Math.max(size.x, size.y, size.z, 1e-3);
      model.position.sub(center);
      scene.add(model);

      const fovRad = THREE.MathUtils.degToRad(camera.fov);
      const distance = (maxDim * 0.5) / Math.tan(fovRad * 0.5) * 1.8;
      const dir = new THREE.Vector3(1, 0.8, 1).normalize();
      camera.position.copy(dir.clone().multiplyScalar(distance));
      camera.near = Math.max(distance / 1000, 0.001);
      camera.far = Math.max(distance * 1000, 1000);
      camera.lookAt(0, 0, 0);
      camera.updateProjectionMatrix();
      controls.update();

      loadingEl.style.display = "none";
      hintEl.style.display = "block";
    },
    undefined,
    (err) => {
      showError((err as Error).message || String(err));
    }
  );
}

loadModel();

// Prevent unused variable warning - electrobun handles RPC transport setup
void electrobun;
