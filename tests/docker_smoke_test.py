import importlib.util
import io
import pathlib
import unittest
from unittest.mock import patch

path = pathlib.Path(__file__).resolve().parents[1] / ".github/scripts/docker_smoke.py"
spec = importlib.util.spec_from_file_location("docker_smoke", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class StartupTest(unittest.TestCase):
    def test_initial_docker_proxy_connection_reset_is_retried(self):
        responses = iter([
            ConnectionResetError(104, "Connection reset by peer"),
            b'<script src="/assets/store-fixture.js"></script>',
            b'{"code":200,"data":{}}',
            b'"../lang/zh-CN/entry.ts":()=>import("./entry-fixture.js")',
            "下载和复制链接 短链接".encode(),
        ])

        def response(*args, **kwargs):
            item = next(responses)
            if isinstance(item, Exception):
                raise item
            return io.BytesIO(item)

        with patch.object(module.urllib.request, "urlopen", side_effect=response) as request:
            with patch.object(module.time, "sleep") as sleep:
                module.check("http://127.0.0.1:5244")
        self.assertEqual(request.call_count, 5)
        sleep.assert_called_once_with(1)

    def test_non_fixture_origin_is_rejected(self):
        with self.assertRaises(ValueError):
            module.check("https://example.test")


if __name__ == "__main__":
    unittest.main()
