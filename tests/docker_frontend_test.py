import importlib.util
import pathlib
import unittest

path = pathlib.Path(__file__).resolve().parents[1] / ".github/scripts/docker_frontend.py"
spec = importlib.util.spec_from_file_location("docker_frontend", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FrontendTest(unittest.TestCase):
    def release(self):
        return {"draft": False, "assets": [{
            "name": "openlist-frontend-dist-v4.2.9-8795d2e.tar.gz",
            "digest": "sha256:" + "a" * 64,
            "browser_download_url": "https://github.com/v200dd/OpenList-Frontend/releases/download/edge/web.tar.gz",
        }, {
            "name": "i18n.tar.gz",
        }]}

    def test_published_archive_is_pinned(self):
        result = module.resolve_frontend(self.release())
        self.assertEqual(result["frontend_version"], "v4.2.9-8795d2e")
        self.assertEqual(result["frontend_sha256"], "a" * 64)

    def test_draft_is_rejected(self):
        release = self.release()
        release["draft"] = True
        with self.assertRaises(ValueError):
            module.resolve_frontend(release)

    def test_missing_digest_is_rejected(self):
        release = self.release()
        release["assets"][0]["digest"] = None
        with self.assertRaises(ValueError):
            module.resolve_frontend(release)

    def test_ambiguous_archives_are_rejected(self):
        release = self.release()
        release["assets"].append(dict(release["assets"][0]))
        with self.assertRaises(ValueError):
            module.resolve_frontend(release)

    def test_unchanged_schedule_is_skipped(self):
        labels = {"org.opencontainers.image.revision": "revision",
                  "org.opencontainers.image.frontend.sha256": "digest"}
        self.assertFalse(module.needs_rebuild("schedule", "revision", "digest", labels))

    def test_new_frontend_rebuilds_without_backend_changes(self):
        labels = {"org.opencontainers.image.revision": "revision",
                  "org.opencontainers.image.frontend.sha256": "old"}
        self.assertTrue(module.needs_rebuild("schedule", "revision", "new", labels))

    def test_new_backend_rebuilds(self):
        labels = {"org.opencontainers.image.revision": "old",
                  "org.opencontainers.image.frontend.sha256": "digest"}
        self.assertTrue(module.needs_rebuild("schedule", "new", "digest", labels))

    def test_manual_and_push_builds_are_not_skipped(self):
        labels = {"org.opencontainers.image.revision": "revision",
                  "org.opencontainers.image.frontend.sha256": "digest"}
        for event in ("push", "workflow_dispatch", "pull_request"):
            self.assertTrue(module.needs_rebuild(event, "revision", "digest", labels))


if __name__ == "__main__":
    unittest.main()
