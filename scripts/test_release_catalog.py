import unittest
from release_catalog import render


class CatalogTests(unittest.TestCase):
    def test_multiple_projects_and_hidden_entries(self):
        project = lambda name, files: {"name": name, "description": "说明", "build": {"branch": "main", "commit": "abc123"}, "files": files}
        result = render({"projects": {
            "a": project("项目 A", [{"name": "firmware.bin", "url": "https://github.com/test/a"}, {"name": "sha256sums", "url": "https://github.com/test/sha256sums"}]),
            "b": project("项目 B", [{"name": "imagebuilder.tar.zst", "url": "https://github.com/test/b"}]),
            "empty": project("隐藏空项目", []),
            "blank": project("隐藏空链接", [{"name": "empty", "url": ""}]),
            "checksum": project("隐藏校验项目", [{"name": "sha256sums", "url": "https://github.com/test/sums"}]),
        }})
        self.assertIn("## 项目 A", result)
        self.assertIn("## 项目 B", result)
        self.assertIn("[下载](<https://github.com/test/a>)", result)
        self.assertIn("源码提交：abc123", result)
        self.assertNotIn("隐藏", result)
        self.assertNotIn("| sha256sums |", result)


if __name__ == "__main__":
    unittest.main()
