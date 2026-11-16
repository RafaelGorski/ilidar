import tempfile
import unittest
from pathlib import Path

from PIL import Image, UnidentifiedImageError

from read_depth_data import read_color_image


class ColorImageTests(unittest.TestCase):
    def test_only_accepts_jpeg_data(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.jpg"
            Image.new("RGB", (2, 2), "red").save(path, format="JPEG")
            self.assertEqual(read_color_image(path).shape, (2, 2, 3))
            Image.new("RGB", (2, 2), "red").save(path, format="PNG")
            with self.assertRaises(UnidentifiedImageError):
                read_color_image(path)


if __name__ == "__main__":
    unittest.main()
