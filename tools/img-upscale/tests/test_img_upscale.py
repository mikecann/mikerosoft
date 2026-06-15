import importlib.util
import pathlib
import tempfile
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "img-upscale.py"


def load_module():
    spec = importlib.util.spec_from_file_location("img_upscale", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class ImgUpscaleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_normalize_scale_choice_accepts_common_inputs(self):
        self.assertEqual(2, self.module.normalize_scale_choice("2"))
        self.assertEqual(2, self.module.normalize_scale_choice("x2"))
        self.assertEqual(4, self.module.normalize_scale_choice(" 4 "))
        self.assertEqual(8, self.module.normalize_scale_choice("8"))
        self.assertEqual(16, self.module.normalize_scale_choice("x16"))
        self.assertEqual(2, self.module.normalize_scale_choice(""))

    def test_normalize_scale_choice_rejects_other_values(self):
        with self.assertRaises(ValueError):
            self.module.normalize_scale_choice("3")

    def test_default_output_path_appends_scale_suffix(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            image_path = pathlib.Path(temp_dir) / "photo.png"
            image_path.write_bytes(b"fake")

            output_path = self.module.build_default_output_path(
                input_path=image_path,
                scale=4,
            )

            self.assertEqual(image_path.with_name("photo_x4.png"), output_path)

    def test_default_output_path_avoids_overwriting_existing_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            image_path = pathlib.Path(temp_dir) / "photo.jpg"
            image_path.write_bytes(b"fake")
            image_path.with_name("photo_x2.jpg").write_bytes(b"existing")

            output_path = self.module.build_default_output_path(
                input_path=image_path,
                scale=2,
            )

            self.assertEqual(image_path.with_name("photo_x2_2.jpg"), output_path)

    def test_normalize_backend_name_defaults_to_quality(self):
        self.assertEqual("quality", self.module.normalize_backend_name(""))
        self.assertEqual("quality", self.module.normalize_backend_name("QUALITY"))
        self.assertEqual("fast", self.module.normalize_backend_name(" fast "))

    def test_normalize_backend_name_rejects_other_values(self):
        with self.assertRaises(ValueError):
            self.module.normalize_backend_name("weird")

    def test_quality_backend_uses_expected_model_id(self):
        self.assertEqual(
            "caidas/swin2SR-lightweight-x2-64",
            self.module.get_quality_model_id(),
        )

    def test_quality_backend_uses_progressive_x2_steps(self):
        self.assertEqual([2], self.module.build_quality_scale_plan(scale=2))
        self.assertEqual([2, 2], self.module.build_quality_scale_plan(scale=4))
        self.assertEqual([2, 2, 2], self.module.build_quality_scale_plan(scale=8))
        self.assertEqual([2, 2, 2, 2], self.module.build_quality_scale_plan(scale=16))

    def test_quality_backend_default_tile_size_is_less_conservative(self):
        self.assertEqual(512, self.module.DEFAULT_TILE_SIZE)

    def test_estimate_quality_tile_counts_accounts_for_progressive_steps(self):
        counts = self.module.estimate_quality_tile_counts(
            size=(1672, 941),
            scale_plan=[2, 2],
            tile_size=512,
            tile_overlap=32,
        )

        self.assertEqual([8, 40], counts)

    def test_convert_reconstruction_to_image_handles_inference_tensor(self):
        if importlib.util.find_spec("torch") is None:
            self.skipTest("torch is not installed")
        if importlib.util.find_spec("numpy") is None:
            self.skipTest("numpy is not installed")
        if importlib.util.find_spec("PIL") is None:
            self.skipTest("Pillow is not installed")

        import torch

        with torch.inference_mode():
            reconstruction = torch.tensor(
                [
                    [
                        [[1.2, -0.2], [0.5, 0.0]],
                        [[0.0, 0.5], [1.0, 1.2]],
                        [[0.25, 0.75], [0.1, 0.9]],
                    ]
                ]
            )

        image = self.module.convert_reconstruction_to_image(reconstruction=reconstruction)

        self.assertEqual("RGB", image.mode)
        self.assertEqual((2, 2), image.size)
        self.assertEqual((255, 0, 64), image.getpixel((0, 0)))

    def test_run_quality_step_crops_processor_padding_to_x2_size(self):
        if importlib.util.find_spec("torch") is None:
            self.skipTest("torch is not installed")
        if importlib.util.find_spec("numpy") is None:
            self.skipTest("numpy is not installed")
        if importlib.util.find_spec("PIL") is None:
            self.skipTest("Pillow is not installed")

        import torch
        from PIL import Image

        class FakePixelValues:
            def to(self, _device):
                return self

        class FakeProcessorOutput:
            pixel_values = FakePixelValues()

        class FakeProcessor:
            def __call__(self, _image, return_tensors):
                self.return_tensors = return_tensors
                return FakeProcessorOutput()

        class FakeModelOutput:
            def __init__(self):
                self.reconstruction = torch.ones((1, 3, 6, 8))

        class FakeModel:
            def __call__(self, _pixel_values):
                return FakeModelOutput()

        output = self.module.run_quality_step(
            model=FakeModel(),
            processor=FakeProcessor(),
            device="cpu",
            input_image=Image.new("RGB", (3, 2)),
            torch_module=torch,
        )

        self.assertEqual((6, 4), output.size)

    def test_normalize_tile_size_accepts_auto_and_multiples_of_eight(self):
        self.assertIsNone(self.module.normalize_tile_size_choice("auto"))
        self.assertIsNone(self.module.normalize_tile_size_choice(""))
        self.assertEqual(256, self.module.normalize_tile_size_choice("256"))

    def test_normalize_tile_size_rejects_invalid_values(self):
        with self.assertRaises(ValueError):
            self.module.normalize_tile_size_choice("250")

    def test_build_tile_starts_covers_dimension(self):
        self.assertEqual([0], self.module.build_tile_starts(length=128, tile_size=256, tile_overlap=32))
        self.assertEqual([0, 144], self.module.build_tile_starts(length=400, tile_size=256, tile_overlap=32))
        self.assertEqual([0, 192, 384, 576, 744], self.module.build_tile_starts(length=1000, tile_size=256, tile_overlap=32))

    def test_build_fast_command_uses_expected_binary_and_model(self):
        command = self.module.build_fast_upscale_command(
            exe_dir=pathlib.Path(r"C:\dev\tools"),
            input_path=pathlib.Path("input.png"),
            output_path=pathlib.Path("output.png"),
            scale=4,
        )

        self.assertEqual(pathlib.Path(r"C:\dev\tools\realesrgan-ncnn-vulkan.exe"), command[0])
        self.assertIn("-n", command)
        self.assertIn("realesrgan-x4plus", command)
        self.assertEqual("4", command[-1])


if __name__ == "__main__":
    unittest.main()
