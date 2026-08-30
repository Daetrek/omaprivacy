import importlib.machinery
import importlib.util
import pathlib
import json
import sqlite3
import tempfile
import unittest
from unittest import mock


BACKEND_PATH = pathlib.Path(__file__).parents[1] / "bin" / "omaprivacy"
loader = importlib.machinery.SourceFileLoader("omaprivacy_backend", str(BACKEND_PATH))
spec = importlib.util.spec_from_loader(loader.name, loader)
backend = importlib.util.module_from_spec(spec)
loader.exec_module(backend)


class BackendTests(unittest.TestCase):
    def test_identical_json_is_not_rewritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "state.json"
            value = {"same": True}
            backend.write_json(path, value)
            with mock.patch.object(backend.os, "replace") as replace:
                backend.write_json(path, value)
            replace.assert_not_called()

    def test_malformed_state_shapes_fall_back_safely(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            backend.write_json(root / "privacy.json", ["invalid"])
            backend.write_json(root / "shield.json", ["invalid"])
            backend.write_json(root / "captures.json", {"invalid": True})
            backend.write_json(root / "history.json", {"invalid": True})
            with mock.patch.multiple(
                backend,
                PRIVACY_STATE_FILE=root / "privacy.json",
                LOCATION_SHIELD_FILE=root / "shield.json",
                CAPTURE_STATE_FILE=root / "captures.json",
                HISTORY_FILE=root / "history.json",
                CONFIG_FILE=root / "config.json",
                microphone_muted=mock.Mock(return_value=None),
                dnd_enabled=mock.Mock(return_value=None),
                location_enabled=mock.Mock(return_value=None),
            ):
                self.assertFalse(backend.privacy_status()["enabled"])
                self.assertFalse(backend.location_shield_status()["enabled"])
                self.assertEqual(backend.update_history([]), [])

    def test_capture_classification(self):
        self.assertEqual(backend.capture_kind({"media.class": "Stream/Input/Audio"}), "microphone")
        self.assertEqual(backend.capture_kind({"media.class": "Stream/Input/Video"}), "camera")
        self.assertEqual(
            backend.capture_kind({"media.class": "Stream/Input/Video", "media.role": "Screen"}),
            "screen",
        )

    def test_missing_default_microphone_is_unknown_not_unmuted(self):
        result = backend.subprocess.CompletedProcess(
            ["wpctl"], 0, stdout="", stderr="Translate ID error: '-1' is not a valid ID"
        )
        with mock.patch.multiple(
            backend,
            shutil_which=mock.Mock(return_value="/usr/bin/wpctl"),
            run=mock.Mock(return_value=result),
        ):
            self.assertIsNone(backend.microphone_muted())

    def test_scan_captures_excludes_audio_playback(self):
        nodes = [
            {
                "id": 10,
                "type": "PipeWire:Interface:Node",
                "info": {
                    "state": "running",
                    "props": {
                        "media.class": "Stream/Output/Audio",
                        "application.name": "Chromium",
                        "media.name": "Playback",
                    },
                },
            },
            {
                "id": 11,
                "type": "PipeWire:Interface:Node",
                "info": {
                    "state": "running",
                    "props": {
                        "media.class": "Stream/Input/Audio",
                        "application.name": "Recorder",
                        "media.name": "Microphone capture",
                    },
                },
            },
        ]
        result = backend.subprocess.CompletedProcess(
            ["pw-dump"], 0, stdout=json.dumps(nodes), stderr=""
        )
        with mock.patch.object(backend, "run", return_value=result):
            captures = backend.scan_captures()
        self.assertEqual(len(captures), 1)
        self.assertEqual(captures[0]["app"], "Recorder")
        self.assertEqual(captures[0]["kind"], "microphone")
        self.assertEqual(captures[0]["nodeId"], 11)

    def test_microphone_rule_is_case_insensitive_and_persisted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with mock.patch.multiple(
                backend,
                CONFIG_FILE=root / "config.json",
                HISTORY_FILE=root / "history.json",
                current_wifi=mock.Mock(return_value=""),
                session_locked=mock.Mock(return_value=False),
            ):
                backend.set_privacy_rule("microphone", "Chromium", "stop")
                self.assertEqual(backend.capture_rule("microphone", "chromium"), "stop")
                backend.set_privacy_rule("microphone", "CHROMIUM", "default")
                self.assertEqual(backend.capture_rule("microphone", "Chromium"), "default")

    def test_camera_and_screen_rules_are_stored_separately(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with mock.patch.multiple(
                backend,
                CONFIG_FILE=root / "config.json",
                HISTORY_FILE=root / "history.json",
                current_wifi=mock.Mock(return_value=""),
                session_locked=mock.Mock(return_value=False),
            ):
                backend.set_privacy_rule("camera", "Chromium", "alert")
                backend.set_privacy_rule("screen", "Chromium", "stop")
                self.assertEqual(backend.capture_rule("camera", "chromium"), "alert")
                self.assertEqual(backend.capture_rule("screen", "chromium"), "stop")
                self.assertEqual(backend.capture_rule("microphone", "chromium"), "default")

    def test_auto_stop_destroys_only_matching_microphone_stream(self):
        captures = [
            {"id": "1", "nodeId": 41, "kind": "microphone", "app": "Chromium", "detail": "Mic"},
            {"id": "2", "nodeId": 42, "kind": "microphone", "app": "Recorder", "detail": "Mic"},
            {"id": "3", "nodeId": 43, "kind": "camera", "app": "Chromium", "detail": "Cam"},
        ]
        completed = backend.subprocess.CompletedProcess(["pw-cli"], 0, stdout="", stderr="")
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with mock.patch.multiple(
                backend,
                CONFIG_FILE=root / "config.json",
                HISTORY_FILE=root / "history.json",
                RULE_ACTION_FILE=root / "rule-actions.json",
                config=mock.Mock(return_value={"microphoneRules": {"Chromium": "stop"}}),
                shutil_which=mock.Mock(return_value="/usr/bin/pw-cli"),
                run=mock.Mock(return_value=completed),
                notify=mock.Mock(),
            ):
                kept = backend.enforce_capture_rules(captures)
                backend.run.assert_called_once_with(["pw-cli", "destroy", "41"])
        self.assertEqual([row["id"] for row in kept], ["2", "3"])

    def test_auto_stop_failure_keeps_capture_visible(self):
        capture = {"id": "1", "nodeId": 41, "kind": "microphone", "app": "Chromium", "detail": "Mic"}
        failed = backend.subprocess.CompletedProcess(["pw-cli"], 1, stdout="", stderr="denied")
        with mock.patch.multiple(
            backend,
            config=mock.Mock(return_value={"microphoneRules": {"Chromium": "stop"}}),
            shutil_which=mock.Mock(return_value="/usr/bin/pw-cli"),
            run=mock.Mock(return_value=failed),
        ):
            kept = backend.enforce_capture_rules([capture])
        self.assertEqual(kept, [capture])

    def test_attribution_precedence(self):
        props = {
            "application.name": "Firefox",
            "application.process.binary": "firefox-bin",
            "node.description": "WebRTC capture",
        }
        self.assertEqual(backend.capture_label(props), "Firefox")

    def test_history_records_transitions_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with mock.patch.multiple(
                backend,
                CAPTURE_STATE_FILE=root / "captures.json",
                HISTORY_FILE=root / "history.json",
                CONFIG_FILE=root / "config.json",
                notify=mock.Mock(),
            ):
                capture = {"id": "1", "kind": "microphone", "app": "Recorder", "detail": ""}
                first = backend.update_history([capture])
                second = backend.update_history([capture])
                stopped = backend.update_history([])
                self.assertEqual([row["event"] for row in first], ["started"])
                self.assertEqual(len(second), 1)
                self.assertEqual([row["event"] for row in stopped], ["stopped", "started"])

    def test_history_removes_legacy_playback_false_positives(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            old = [
                {"time": backend.now_iso(), "event": "started", "id": "old", "kind": "microphone", "app": "Chromium", "detail": "Playback"},
                {"time": backend.now_iso(), "event": "checked", "app": "OmaPrivacy", "kind": "network", "detail": "Public IP checked"},
            ]
            backend.write_json(root / "history.json", old)
            with mock.patch.multiple(
                backend,
                CAPTURE_STATE_FILE=root / "captures.json",
                HISTORY_FILE=root / "history.json",
                CONFIG_FILE=root / "config.json",
            ):
                rows = backend.update_history([])
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["event"], "checked")

    def test_privacy_mode_restores_previous_states(self):
        with tempfile.TemporaryDirectory() as directory:
            state_file = pathlib.Path(directory) / "privacy-mode.json"
            calls = []
            with mock.patch.multiple(
                backend,
                PRIVACY_STATE_FILE=state_file,
                HISTORY_FILE=pathlib.Path(directory) / "history.json",
                microphone_muted=mock.Mock(return_value=False),
                dnd_enabled=mock.Mock(return_value=False),
                location_enabled=mock.Mock(return_value=True),
                close_all_browsers=mock.Mock(side_effect=lambda: calls.append(("browsers", "close"))),
                browser_location_snapshot=mock.Mock(return_value=[{"family": "test"}]),
                set_browser_location_blocked=mock.Mock(side_effect=lambda value: calls.append(("browser-location", "block"))),
                restore_browser_location=mock.Mock(side_effect=lambda value: calls.append(("browser-location", "restore"))),
                set_microphone=mock.Mock(side_effect=lambda value: calls.append(("mic", value))),
                set_dnd=mock.Mock(side_effect=lambda value: calls.append(("dnd", value))),
                set_location=mock.Mock(side_effect=lambda value: calls.append(("location", value))),
            ):
                backend.privacy_enable()
                backend.privacy_disable()
            self.assertEqual(calls, [
                ("browsers", "close"),
                ("mic", True), ("dnd", True), ("location", False), ("browser-location", "block"),
                ("browsers", "close"),
                ("mic", False), ("dnd", False), ("location", True), ("browser-location", "restore"),
            ])

    def test_meeting_preset_only_changes_dnd(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            calls = []
            with mock.patch.multiple(
                backend,
                PRIVACY_STATE_FILE=root / "privacy.json",
                HISTORY_FILE=root / "history.json",
                microphone_muted=mock.Mock(return_value=False),
                dnd_enabled=mock.Mock(return_value=False),
                location_enabled=mock.Mock(return_value=True),
                close_all_browsers=mock.Mock(side_effect=lambda: calls.append("browsers")),
                set_microphone=mock.Mock(side_effect=lambda value: calls.append(("mic", value))),
                set_dnd=mock.Mock(side_effect=lambda value: calls.append(("dnd", value))),
                set_location=mock.Mock(side_effect=lambda value: calls.append(("location", value))),
            ):
                result = backend.privacy_enable("meeting")
            self.assertEqual(result["preset"], "meeting")
            self.assertEqual(calls, [("dnd", True)])

    def test_browser_health_reports_blocked_defaults(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "chromium/Default/Preferences"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps({"profile": {"default_content_setting_values": {
                "geolocation": 2, "media_stream_camera": 2,
            }}}))
            with mock.patch.object(backend, "browser_permission_files", return_value=([path], [])):
                rows = backend.browser_health()
        self.assertEqual(rows[0]["location"], "blocked")
        self.assertEqual(rows[0]["camera"], "blocked")

    def test_chromium_location_block_is_reversible(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "chromium/Default/Preferences"
            path.parent.mkdir(parents=True)
            original = {
                "profile": {
                    "default_content_setting_values": {"notifications": 2, "media_stream_camera": 1},
                    "content_settings": {"exceptions": {
                        "geolocation": {"https://maps.example:443,*": {"setting": 1}},
                        "media_stream_camera": {"https://meet.example:443,*": {"setting": 1}},
                    }},
                }
            }
            path.write_text(json.dumps(original))
            with mock.patch.object(backend, "browser_permission_files", return_value=([path], [])):
                snapshots = backend.browser_location_snapshot()
                backend.set_browser_location_blocked(snapshots)
                blocked = json.loads(path.read_text())
                backend.restore_browser_location(snapshots)
                restored = json.loads(path.read_text())
        self.assertEqual(blocked["profile"]["default_content_setting_values"]["geolocation"], 2)
        self.assertEqual(blocked["profile"]["default_content_setting_values"]["media_stream_camera"], 2)
        self.assertEqual(blocked["profile"]["content_settings"]["exceptions"]["geolocation"], {})
        self.assertEqual(blocked["profile"]["content_settings"]["exceptions"]["media_stream_camera"], {})
        self.assertEqual(restored, original)

    def test_geolocation_shield_does_not_change_camera(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "chromium/Default/Preferences"
            path.parent.mkdir(parents=True)
            original = {
                "profile": {
                    "default_content_setting_values": {"geolocation": 1, "media_stream_camera": 1},
                    "content_settings": {"exceptions": {
                        "geolocation": {"https://maps.example:443,*": {"setting": 1}},
                        "media_stream_camera": {"https://meet.example:443,*": {"setting": 1}},
                    }},
                }
            }
            path.write_text(json.dumps(original))
            with mock.patch.object(backend, "browser_permission_files", return_value=([path], [])):
                snapshots = backend.browser_location_snapshot()
                backend.set_browser_geolocation_blocked(snapshots)
                blocked = json.loads(path.read_text())
                backend.restore_browser_geolocation(snapshots)
                restored = json.loads(path.read_text())
        defaults = blocked["profile"]["default_content_setting_values"]
        exceptions = blocked["profile"]["content_settings"]["exceptions"]
        self.assertEqual(defaults["geolocation"], 2)
        self.assertEqual(defaults["media_stream_camera"], 1)
        self.assertEqual(exceptions["geolocation"], {})
        self.assertEqual(exceptions["media_stream_camera"], original["profile"]["content_settings"]["exceptions"]["media_stream_camera"])
        self.assertEqual(restored, original)

    def test_location_shield_enable_and_disable_are_reversible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            snapshot = [{"family": "test"}]
            calls = []
            with mock.patch.multiple(
                backend,
                LOCATION_SHIELD_FILE=root / "location-shield.json",
                HISTORY_FILE=root / "history.json",
                browser_permission_files=mock.Mock(return_value=([pathlib.Path("profile")], [])),
                close_all_browsers=mock.Mock(side_effect=lambda: calls.append("close")),
                browser_location_snapshot=mock.Mock(return_value=snapshot),
                set_browser_geolocation_blocked=mock.Mock(side_effect=lambda value: calls.append(("block", value))),
                restore_browser_geolocation=mock.Mock(side_effect=lambda value: calls.append(("restore", value))),
                privacy_status=mock.Mock(return_value={"enabled": False}),
            ):
                self.assertTrue(backend.location_shield_enable()["enabled"])
                self.assertFalse(backend.location_shield_disable()["enabled"])
            self.assertEqual(calls, ["close", ("block", snapshot), "close", ("restore", snapshot)])

    def test_location_shield_repeated_actions_are_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with mock.patch.multiple(
                backend,
                LOCATION_SHIELD_FILE=root / "location-shield.json",
                HISTORY_FILE=root / "history.json",
                browser_permission_files=mock.Mock(return_value=([pathlib.Path("profile")], [])),
                close_all_browsers=mock.Mock(),
                browser_location_snapshot=mock.Mock(return_value=[{"family": "test"}]),
                set_browser_geolocation_blocked=mock.Mock(),
                restore_browser_geolocation=mock.Mock(),
                privacy_status=mock.Mock(return_value={"enabled": False}),
            ):
                backend.location_shield_enable()
                backend.location_shield_enable()
                backend.location_shield_disable()
                backend.location_shield_disable()
                self.assertEqual(backend.close_all_browsers.call_count, 2)
                backend.set_browser_geolocation_blocked.assert_called_once()
                backend.restore_browser_geolocation.assert_called_once()

    def test_location_shield_refuses_empty_profile_set(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with mock.patch.multiple(
                backend,
                LOCATION_SHIELD_FILE=root / "location-shield.json",
                browser_permission_files=mock.Mock(return_value=([], [])),
                close_all_browsers=mock.Mock(),
                browser_location_snapshot=mock.Mock(return_value=[]),
                privacy_status=mock.Mock(return_value={"enabled": False}),
            ):
                with self.assertRaisesRegex(RuntimeError, "No supported browser profiles"):
                    backend.location_shield_enable()
                backend.close_all_browsers.assert_not_called()
                self.assertFalse(backend.location_shield_status()["enabled"])

    def test_location_shield_failed_enable_rolls_back_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            snapshot = [{"family": "test"}]
            with mock.patch.multiple(
                backend,
                LOCATION_SHIELD_FILE=root / "location-shield.json",
                HISTORY_FILE=root / "history.json",
                browser_permission_files=mock.Mock(return_value=([pathlib.Path("profile")], [])),
                close_all_browsers=mock.Mock(),
                browser_location_snapshot=mock.Mock(return_value=snapshot),
                set_browser_geolocation_blocked=mock.Mock(side_effect=RuntimeError("write failed")),
                restore_browser_geolocation=mock.Mock(side_effect=RuntimeError("restore also failed")),
                privacy_status=mock.Mock(return_value={"enabled": False}),
            ):
                with self.assertRaisesRegex(RuntimeError, "write failed"):
                    backend.location_shield_enable()
                self.assertFalse(backend.location_shield_status()["enabled"])

    def test_location_shield_cannot_enable_over_privacy_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with mock.patch.multiple(
                backend,
                LOCATION_SHIELD_FILE=root / "location-shield.json",
                privacy_status=mock.Mock(return_value={"enabled": True}),
                browser_permission_files=mock.Mock(return_value=([pathlib.Path("profile")], [])),
                close_all_browsers=mock.Mock(),
            ):
                with self.assertRaisesRegex(RuntimeError, "Turn off Privacy Mode"):
                    backend.location_shield_enable()
                backend.close_all_browsers.assert_not_called()

    def test_location_shield_recovers_interrupted_enable_before_resnapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            old_snapshot = [{"family": "old"}]
            new_snapshot = [{"family": "new"}]
            backend.write_json(root / "location-shield.json", {
                "enabled": False,
                "applying": True,
                "browserLocation": old_snapshot,
            })
            calls = []
            with mock.patch.multiple(
                backend,
                LOCATION_SHIELD_FILE=root / "location-shield.json",
                HISTORY_FILE=root / "history.json",
                privacy_status=mock.Mock(return_value={"enabled": False}),
                browser_permission_files=mock.Mock(return_value=([pathlib.Path("profile")], [])),
                close_all_browsers=mock.Mock(),
                restore_browser_geolocation=mock.Mock(side_effect=lambda value: calls.append(("restore", value))),
                browser_location_snapshot=mock.Mock(return_value=new_snapshot),
                set_browser_geolocation_blocked=mock.Mock(side_effect=lambda value: calls.append(("block", value))),
            ):
                result = backend.location_shield_enable()
            self.assertTrue(result["enabled"])
            self.assertEqual(calls, [("restore", old_snapshot), ("block", new_snapshot)])

    def test_location_shield_cannot_restore_over_privacy_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            backend.write_json(root / "location-shield.json", {
                "enabled": True,
                "browserLocation": [{"family": "test"}],
            })
            with mock.patch.multiple(
                backend,
                LOCATION_SHIELD_FILE=root / "location-shield.json",
                privacy_status=mock.Mock(return_value={"enabled": True}),
                close_all_browsers=mock.Mock(),
                restore_browser_geolocation=mock.Mock(),
            ):
                with self.assertRaisesRegex(RuntimeError, "Turn off Privacy Mode"):
                    backend.location_shield_disable()
                backend.close_all_browsers.assert_not_called()
                backend.restore_browser_geolocation.assert_not_called()
                self.assertTrue(backend.location_shield_status()["enabled"])

    def test_firefox_location_and_camera_block_are_reversible(self):
        with tempfile.TemporaryDirectory() as directory:
            database = pathlib.Path(directory) / "zen/profile/permissions.sqlite"
            database.parent.mkdir(parents=True)
            prefs = database.parent / "prefs.js"
            prefs.write_text(
                'user_pref("permissions.default.geo", 0);\n'
                'user_pref("permissions.default.camera", 1);\n'
            )
            connection = sqlite3.connect(database)
            connection.execute("CREATE TABLE moz_perms (origin TEXT, type TEXT, permission INTEGER)")
            connection.executemany("INSERT INTO moz_perms VALUES (?, ?, ?)", [
                ("https://maps.example", "geo", 1),
                ("https://meet.example", "camera", 1),
            ])
            connection.commit()
            connection.close()
            with mock.patch.object(backend, "browser_permission_files", return_value=([], [database])):
                snapshots = backend.browser_location_snapshot()
                backend.set_browser_location_blocked(snapshots)
                blocked_prefs = prefs.read_text()
                connection = sqlite3.connect(database)
                blocked_permissions = dict(connection.execute("SELECT type, permission FROM moz_perms"))
                connection.close()
                backend.restore_browser_location(snapshots)
                restored_prefs = prefs.read_text()
                connection = sqlite3.connect(database)
                restored_permissions = dict(connection.execute("SELECT type, permission FROM moz_perms"))
                connection.close()
        self.assertIn('user_pref("permissions.default.geo", 2);', blocked_prefs)
        self.assertIn('user_pref("permissions.default.camera", 2);', blocked_prefs)
        self.assertEqual(blocked_permissions, {"geo": 2, "camera": 2})
        self.assertIn('user_pref("permissions.default.geo", 0);', restored_prefs)
        self.assertIn('user_pref("permissions.default.camera", 1);', restored_prefs)
        self.assertEqual(restored_permissions, {"geo": 1, "camera": 1})

    def test_firefox_geolocation_shield_preserves_camera(self):
        with tempfile.TemporaryDirectory() as directory:
            database = pathlib.Path(directory) / "zen/profile/permissions.sqlite"
            database.parent.mkdir(parents=True)
            prefs = database.parent / "prefs.js"
            prefs.write_text(
                'user_pref("permissions.default.geo", 0);\n'
                'user_pref("permissions.default.camera", 1);\n'
            )
            connection = sqlite3.connect(database)
            connection.execute("CREATE TABLE moz_perms (origin TEXT, type TEXT, permission INTEGER)")
            connection.executemany("INSERT INTO moz_perms VALUES (?, ?, ?)", [
                ("https://maps.example", "geo", 1),
                ("https://meet.example", "camera", 1),
            ])
            connection.commit()
            connection.close()
            with mock.patch.object(backend, "browser_permission_files", return_value=([], [database])):
                snapshots = backend.browser_location_snapshot()
                backend.set_browser_geolocation_blocked(snapshots)
                blocked_prefs = prefs.read_text()
                connection = sqlite3.connect(database)
                blocked_permissions = dict(connection.execute("SELECT type, permission FROM moz_perms"))
                connection.close()
                backend.restore_browser_geolocation(snapshots)
                restored_prefs = prefs.read_text()
                connection = sqlite3.connect(database)
                restored_permissions = dict(connection.execute("SELECT type, permission FROM moz_perms"))
                connection.close()
        self.assertIn('user_pref("permissions.default.geo", 2);', blocked_prefs)
        self.assertIn('user_pref("permissions.default.camera", 1);', blocked_prefs)
        self.assertEqual(blocked_permissions, {"geo": 2, "camera": 1})
        self.assertIn('user_pref("permissions.default.geo", 0);', restored_prefs)
        self.assertIn('user_pref("permissions.default.camera", 1);', restored_prefs)
        self.assertEqual(restored_permissions, {"geo": 1, "camera": 1})

    def test_revoke_rejects_unknown_table(self):
        with self.assertRaisesRegex(RuntimeError, "unknown permission table"):
            backend.revoke("not-a-real-table", "object", "app")

    def test_chromium_site_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "chromium" / "Default" / "Preferences"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps({
                "profile": {"content_settings": {"exceptions": {
                    "geolocation": {
                        "https://maps.apple.com:443,*": {"setting": 1},
                        "https://blocked.example:443,*": {"setting": 2},
                    },
                    "media_stream_mic": {"https://ask.example:443,*": {"setting": 3}},
                }}}
            }))
            rows = backend.chromium_permissions(path)
        self.assertEqual(rows, [
            {"browser": "Chromium", "profile": str(path), "kind": "location", "origin": "maps.apple.com:443", "decision": "allow"},
            {"browser": "Chromium", "profile": str(path), "kind": "location", "origin": "blocked.example:443", "decision": "block"},
        ])

    def test_firefox_site_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "zen" / "profile" / "permissions.sqlite"
            path.parent.mkdir(parents=True)
            connection = sqlite3.connect(path)
            connection.execute("CREATE TABLE moz_perms (origin TEXT, type TEXT, permission INTEGER)")
            connection.executemany("INSERT INTO moz_perms VALUES (?, ?, ?)", [
                ("https://maps.apple.com", "geo", 1),
                ("https://example.com", "desktop-notification", 2),
                ("https://ignored.example", "cookie", 1),
            ])
            connection.commit()
            connection.close()
            rows = backend.firefox_permissions(path)
        self.assertEqual(rows, [
            {"browser": "Zen", "profile": str(path), "kind": "location", "origin": "maps.apple.com", "decision": "allow"},
            {"browser": "Zen", "profile": str(path), "kind": "notifications", "origin": "example.com", "decision": "block"},
        ])

    def test_revoke_chromium_permission_removes_only_matching_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / ".config/chromium/Default/Preferences"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps({
                "profile": {"content_settings": {"exceptions": {"geolocation": {
                    "https://maps.apple.com:443,*": {"setting": 1},
                    "https://keep.example:443,*": {"setting": 2},
                }}}}
            }))
            state = root / "state"
            with mock.patch.multiple(
                backend,
                STATE_DIR=state,
                HISTORY_FILE=state / "history.json",
                browser_permission_files=mock.Mock(return_value=([path], [])),
                browser_profile_running=mock.Mock(return_value=False),
            ):
                backend.revoke_browser_permission(str(path), "location", "maps.apple.com:443")
            remaining = backend.chromium_permissions(path)
        self.assertEqual([row["origin"] for row in remaining], ["keep.example:443"])

    def test_revoke_browser_permission_refuses_running_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "chromium/Default/Preferences"
            path.parent.mkdir(parents=True)
            path.write_text("{}")
            with mock.patch.multiple(
                backend,
                browser_permission_files=mock.Mock(return_value=([path], [])),
                browser_profile_running=mock.Mock(return_value=True),
            ):
                with self.assertRaisesRegex(RuntimeError, "Close Chromium"):
                    backend.revoke_browser_permission(str(path), "location", "example.com")

    def test_browser_scan_reports_profiles_even_without_saved_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            chromium = root / ".config/chromium/Default/Preferences"
            chromium.parent.mkdir(parents=True)
            chromium.write_text("{}")
            zen = root / ".config/zen/profile/permissions.sqlite"
            zen.parent.mkdir(parents=True)
            connection = sqlite3.connect(zen)
            connection.execute("CREATE TABLE moz_perms (origin TEXT, type TEXT, permission INTEGER)")
            connection.close()
            rows, profiles, error = backend.scan_browser_permissions(root)
        self.assertEqual(rows, [])
        self.assertEqual(profiles, ["Chromium", "Zen"])
        self.assertEqual(error, "")


if __name__ == "__main__":
    unittest.main()
