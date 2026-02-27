import * as THREE from "three";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import fs from "node:fs";
import { el, hideOverlay, setStatus, showError } from "./ui.js";

export class Viewer {
  private readonly scene: THREE.Scene;
  private readonly camera: THREE.PerspectiveCamera;
  private readonly renderer: THREE.WebGLRenderer;
  private readonly controls: OrbitControls;
  private readonly grid: THREE.GridHelper;
  private readonly savedPosition = new THREE.Vector3();
  private readonly savedTarget = new THREE.Vector3();

  constructor() {
    this.scene = this.createScene();
    this.camera = this.createCamera();
    this.renderer = this.createRenderer();
    this.grid = this.createGrid();
    this.controls = this.createControls();
    this.setupEventListeners();
    this.animate();
  }

  private createScene(): THREE.Scene {
    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x111111);

    scene.add(new THREE.AmbientLight(0xffffff, 0.7));

    const sun = new THREE.DirectionalLight(0xffffff, 1.5);
    sun.position.set(5, 10, 7);
    sun.castShadow = true;
    scene.add(sun);

    const fill = new THREE.DirectionalLight(0x8cb4ff, 0.5);
    fill.position.set(-5, -3, -5);
    scene.add(fill);

    return scene;
  }

  private createCamera(): THREE.PerspectiveCamera {
    return new THREE.PerspectiveCamera(
      45,
      window.innerWidth / window.innerHeight,
      0.001,
      100000
    );
  }

  private createRenderer(): THREE.WebGLRenderer {
    const renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setSize(window.innerWidth, window.innerHeight);
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 1.0;
    document.body.appendChild(renderer.domElement);
    return renderer;
  }

  private createGrid(): THREE.GridHelper {
    const grid = new THREE.GridHelper(100, 100, 0x2a2a2a, 0x1e1e1e);
    this.scene.add(grid);
    return grid;
  }

  private createControls(): OrbitControls {
    const controls = new OrbitControls(this.camera, this.renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.07;
    controls.screenSpacePanning = true;
    controls.minDistance = 0.001;
    controls.maxDistance = 100000;
    return controls;
  }

  loadGlb(filePath: string): void {
    let blobUrl: string;
    try {
      const buffer = fs.readFileSync(filePath);
      blobUrl = URL.createObjectURL(
        new Blob([buffer], { type: "model/gltf-binary" })
      );
    } catch (err) {
      showError(`Could not read file: ${(err as Error).message ?? String(err)}`);
      return;
    }

    new GLTFLoader().load(
      blobUrl,
      (gltf) => {
        const model = gltf.scene;
        this.scene.add(model);

        model.traverse((obj) => {
          if ((obj as THREE.Mesh).isMesh) {
            obj.castShadow = true;
            obj.receiveShadow = true;
          }
        });

        this.fitCameraToModel(model);
        URL.revokeObjectURL(blobUrl);
        hideOverlay();
        el<HTMLButtonElement>("reset-btn").style.display = "";
      },
      ({ loaded, total }) => {
        if (total > 0)
          setStatus(`Loading... ${Math.round((loaded / total) * 100)}%`);
      },
      (err) => {
        showError(`Failed to load: ${(err as Error).message ?? String(err)}`);
      }
    );
  }

  private fitCameraToModel(model: THREE.Object3D): void {
    const box = new THREE.Box3().setFromObject(model);
    const size = box.getSize(new THREE.Vector3());
    const center = box.getCenter(new THREE.Vector3());
    const maxDim = Math.max(size.x, size.y, size.z);

    const fov = this.camera.fov * (Math.PI / 180);
    const dist = (maxDim / 2 / Math.tan(fov / 2)) * 2.2;

    this.camera.near = dist / 1000;
    this.camera.far = dist * 1000;
    this.camera.updateProjectionMatrix();

    this.camera.position.set(
      center.x + dist * 0.6,
      center.y + dist * 0.4,
      center.z + dist * 0.8
    );
    this.controls.target.copy(center);
    this.controls.update();

    this.grid.position.y = box.min.y;
    this.savedPosition.copy(this.camera.position);
    this.savedTarget.copy(this.controls.target);
  }

  resetCamera(): void {
    this.camera.position.copy(this.savedPosition);
    this.controls.target.copy(this.savedTarget);
    this.controls.update();
  }

  private setupEventListeners(): void {
    el<HTMLButtonElement>("reset-btn").addEventListener("click", () =>
      this.resetCamera()
    );

    window.addEventListener("resize", () => {
      this.camera.aspect = window.innerWidth / window.innerHeight;
      this.camera.updateProjectionMatrix();
      this.renderer.setSize(window.innerWidth, window.innerHeight);
    });
  }

  private animate(): void {
    requestAnimationFrame(() => this.animate());
    this.controls.update();
    this.renderer.render(this.scene, this.camera);
  }
}
