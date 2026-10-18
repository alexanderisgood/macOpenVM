# SPDX-License-Identifier: Apache-2.0
"""Pure installed-metadata fixtures; no APK application, helpers or guest execution."""
import base64
import unittest

from support_media_live import (
    DeliveryFailure, SIMULATION_ROOTS, parse_installed_projection, parse_prepared_world,
)


class APKRootParserTests(unittest.TestCase):
    versions = {"alpha": "1.0-r0", "beta": "2.0-r1"}
    alpha_c = "Q1" + base64.b64encode(bytes(range(20))).decode("ascii")
    beta_c = "Q1" + base64.b64encode(bytes(reversed(range(20)))).decode("ascii")
    identities = {
        "alpha": {"C": alpha_c, "signedControlArchitecture": "aarch64", "indexArchitecture": "aarch64"},
        # Repository installation retains the authenticated index architecture;
        # the noarch control declaration remains a distinct observation.
        "beta": {"C": beta_c, "signedControlArchitecture": "noarch", "indexArchitecture": "aarch64"},
    }

    def installed(self):
        return ("alpha\t1.0-r0\taarch64\t" + self.alpha_c + "\n"
                + "beta\t2.0-r1\taarch64\t" + self.beta_c + "\n").encode()

    def reject_installed(self, data):
        with self.assertRaisesRegex(DeliveryFailure, "^apkRootObservation$"):
            parse_installed_projection(data, self.versions, self.identities)

    def test_installed_exact_signed_identity_and_architecture(self):
        rows = parse_installed_projection(self.installed(), self.versions, self.identities)
        self.assertEqual(set(rows), set(self.versions))
        self.assertEqual(rows["alpha"]["packageIdentity"], self.alpha_c)
        self.assertEqual(rows["beta"]["architecture"], "aarch64")
        self.assertEqual(rows["beta"]["signedControlArchitecture"], "noarch")

    def test_installed_duplicate_missing_unknown_or_wrong_version_reject(self):
        for data in (
                self.installed().replace(b"beta\t2.0-r1\taarch64", b"alpha\t1.0-r0\taarch64"),
                self.installed().splitlines(keepends=True)[0],
                self.installed().replace(b"beta\t", b"gamma\t"),
                self.installed().replace(b"2.0-r1", b"2.0-r2")):
            with self.subTest(data=data):
                self.reject_installed(data)

    def test_installed_allowed_but_wrong_architecture_or_identity_reject(self):
        for data in (
                self.installed().replace(b"\taarch64\t", b"\tnoarch\t", 1),
                self.installed().replace(b"beta\t2.0-r1\taarch64\t", b"beta\t2.0-r1\tnoarch\t"),
                self.installed().replace(self.beta_c.encode(), self.alpha_c.encode()),
                self.installed().replace(b"\taarch64\t", b"\tx86_64\t")):
            with self.subTest(data=data):
                self.reject_installed(data)

    def test_installed_malformed_fields_controls_and_bounds_reject(self):
        for data in (self.installed().replace(b"\taarch64\t", b"\taarch64\textra\t", 1),
                     self.installed().replace(b"alpha", b"al\x00pha"),
                     self.installed() + b"x" * 32769):
            with self.subTest(size=len(data)):
                self.reject_installed(data)

    def test_world_exact_six_unique_lines(self):
        data = ("\n".join(sorted(SIMULATION_ROOTS)) + "\n").encode()
        rows = parse_prepared_world(data)
        self.assertEqual(len(rows), 6)
        self.assertEqual(len(set(rows)), 6)
        self.assertEqual(set(rows), set(SIMULATION_ROOTS))

    def test_world_duplicates_unknown_missing_extra_or_no_final_newline_reject(self):
        roots = list(SIMULATION_ROOTS)
        valid = ("\n".join(roots) + "\n").encode()
        duplicate = roots.copy()
        duplicate[-1] = duplicate[0]
        for data in (("\n".join(duplicate) + "\n").encode(),
                     valid.replace(roots[-1].encode(), b"unexpected=1-r0"),
                     ("\n".join(roots[:-1]) + "\n").encode(),
                     valid + roots[0].encode() + b"\n", valid[:-1]):
            with self.subTest(data=data):
                with self.assertRaisesRegex(DeliveryFailure, "^apkRootObservation$"):
                    parse_prepared_world(data)

    def test_world_blank_lines_nonascii_and_controls_reject(self):
        valid = ("\n".join(SIMULATION_ROOTS) + "\n").encode()
        for data in (valid + b"\n", valid.replace(b"\n", b"\r\n"),
                     valid.replace(b"\n", b"\x0b", 1),
                     valid.replace(b"alpine-base", b"alpine-\xffbase"),
                     valid.replace(b"sfdisk", b"sf\x00disk"),
                     valid.replace(b"=3.24.2-r0", b"=3.24.2-r0\t")):
            with self.subTest(data=data):
                with self.assertRaisesRegex(DeliveryFailure, "^apkRootObservation$"):
                    parse_prepared_world(data)


if __name__ == "__main__":
    unittest.main()
