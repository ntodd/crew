"""The default runtime must respect a container's own registry configuration."""
import runpy
import tempfile
import unittest
from pathlib import Path


runtime = runpy.run_path(str(Path(__file__).with_name("crew-cache-runc")))
add_mirrors = runtime["add_mirrors"]


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

    def test_systemd_host_with_docker_volumes(self):
        self.spec["process"]["args"] = ["/sbin/init"]
        self.spec["mounts"] = [{"destination": path} for path in
                               ("/run", "/run/lock", "/var/lib/docker", "/var/lib/containerd")]
        self.assertTrue(self.configure())
        self.assertIn("/etc/docker/certs.d/docker.io/hosts.toml",
                      [mount["destination"] for mount in self.spec["mounts"]])
        self.assertFalse(self.configure())

    def test_strict_buildkit_transport_applies_only_to_builder_daemons(self):
        restrict = runtime["restrict_buildkit"]
        proc = self.spec["process"]
        proc["args"] = ["/usr/bin/buildkitd-entrypoint"]
        proc["env"] = ["no_proxy=*", "https_proxy=http://custom", "KEEP=1"]
        self.assertFalse(restrict(self.spec, self.mirrors))
        (self.mirrors / "_default").mkdir()
        (self.mirrors / "_default/hosts.toml").touch()
        for args in [["sh"], ["/sbin/init"]]:
            proc["args"] = args
            self.assertFalse(restrict(self.spec, self.mirrors))
        for args in [["/usr/bin/buildkitd-entrypoint"], ["buildkitd"], ["rootlesskit", "buildkitd"]]:
            proc["args"] = args
            proc["env"] = ["no_proxy=*", "https_proxy=http://custom", "KEEP=1"]
            self.assertTrue(restrict(self.spec, self.mirrors))
            self.assertIn("HTTPS_PROXY=http://127.0.0.1:0", proc["env"])
            self.assertIn("KEEP=1", proc["env"])
            self.assertNotIn("no_proxy=*", proc["env"])
            self.assertFalse(restrict(self.spec, self.mirrors))

    def test_strict_dind_hides_baked_and_mounted_fallback(self):
        (self.mirrors / "_default").mkdir()
        (self.mirrors / "_default/hosts.toml").touch()
        (self.mirrors / "docker.io/client.key").touch()
        self.spec["mounts"].extend([{"destination": str(self.ca)},
                                    {"destination": "/etc/docker/certs.d/unknown.example"}])
        self.assertTrue(self.configure())
        mounts = self.spec["mounts"]
        self.assertEqual(mounts[0]["type"], "tmpfs")
        self.assertEqual(mounts[0]["destination"], "/etc/docker/certs.d")
        self.assertTrue(all("ro" in mount["options"] for mount in mounts))
        self.assertEqual({m["source"] for m in mounts[1:]},
                         {str(self.ca), *(str(p) for p in self.mirrors.glob("*/hosts.toml"))})
        self.assertFalse(self.configure())

    def test_keeps_other_containers_and_image_symlinks_untouched(self):
        for args in [["sh"], ["/sbin/init"], ["dockerd-entrypoint.sh", "docker", "version"]]:
            self.spec["process"]["args"] = args
            self.assertFalse(self.configure())
        self.spec["process"]["args"] = ["dockerd-entrypoint.sh", "--debug"]
        (self.rootfs / "etc").symlink_to("/etc")
        self.assertFalse(self.configure())
        self.assertEqual(self.spec["mounts"], [])


if __name__ == "__main__":
    unittest.main()
