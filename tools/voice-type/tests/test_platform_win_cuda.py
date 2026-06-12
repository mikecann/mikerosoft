import importlib.util
import os
import pathlib
import tempfile
import unittest
from unittest import mock


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "platform_win.py"


def load_module():
    spec = importlib.util.spec_from_file_location("platform_win", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class PlatformWinCudaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_candidate_cuda_dll_dirs_includes_nvidia_package_bins(self):
        with tempfile.TemporaryDirectory() as tmp:
            site_root = pathlib.Path(tmp) / "site-packages"
            cublas_bin = site_root / "nvidia" / "cublas" / "bin"
            cudnn_bin = site_root / "nvidia" / "cudnn" / "bin"
            cublas_bin.mkdir(parents=True)
            cudnn_bin.mkdir(parents=True)

            with mock.patch.object(self.module.site, "getsitepackages", return_value=[str(site_root)]):
                with mock.patch.object(self.module.site, "getusersitepackages", return_value=str(site_root)):
                    dirs = self.module._candidate_cuda_dll_dirs()

            normalized = {os.path.normcase(os.path.abspath(path)) for path in dirs}
            self.assertIn(os.path.normcase(os.path.abspath(cublas_bin)), normalized)
            self.assertIn(os.path.normcase(os.path.abspath(cudnn_bin)), normalized)


if __name__ == "__main__":
    unittest.main()
