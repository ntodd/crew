"""The default runtime must respect a container's own registry configuration."""
import runpy
import tempfile
import unittest
from pathlib import Path


add_mirrors = runpy.run_path(str(Path(__file__).with_name("crew-cache-runc")))["add_mirrors"]


class MirrorMountTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.bundle = Path(tmp.name)
        self.ca = self.bundle / "crew-cache.crt"
        self.ca.touch()
        self.mirrors = self.bundle / "mirrors"
        for host in ["public.ecr.aws", "docker.io"]:
            (self.mirrors / host).mkdir(parents=True)
            (self.mirrors / host / "hosts.toml").touch()
        self.spec = {"root": {"path": "rootfs"}, "mounts": [],
                     "process": {"args": ["/sbin/docker-init", "--", "dockerd-entrypoint.sh"]}}
        self.rootfs = self.bundle / "rootfs"
        self.rootfs.mkdir()

    def configure(self):
        return add_mirrors(self.spec, self.bundle, self.mirrors, self.ca)

    def test_dind_mounts_only_public_files_read_only_and_only_once(self):
        (self.mirrors / "docker.io/client.key").touch()
        self.assertTrue(self.configure())
        self.assertFalse(self.configure())
        mounts = self.spec["mounts"]
        self.assertEqual({m["source"] for m in mounts},
                         {str(self.ca), *(str(p) for p in self.mirrors.glob("*/hosts.toml"))})
        self.assertTrue(all("ro" in m["options"] for m in mounts))

    def test_job_mount_and_baked_config_take_precedence(self):
        self.spec["process"]["args"] = ["/usr/bin/dockerd"]
        self.spec["mounts"].append({"destination": "/etc/docker/certs.d/docker.io"})
        baked = self.rootfs / "etc/docker/certs.d/public.ecr.aws/hosts.toml"
        baked.parent.mkdir(parents=True)
        baked.write_text("custom")
        self.assertFalse(self.configure())
        baked.unlink()
        self.assertTrue(self.configure())
        self.assertEqual(self.spec["mounts"][1]["destination"],
                         "/etc/docker/certs.d/public.ecr.aws/hosts.toml")

    def test_keeps_other_containers_and_image_symlinks_untouched(self):
        for args in [["sh"], ["dockerd-entrypoint.sh", "docker", "version"]]:
            self.spec["process"]["args"] = args
            self.assertFalse(self.configure())
        self.spec["process"]["args"] = ["dockerd-entrypoint.sh", "--debug"]
        (self.rootfs / "etc").symlink_to("/etc")
        self.assertFalse(self.configure())
        self.assertEqual(self.spec["mounts"], [])


if __name__ == "__main__":
    unittest.main()
