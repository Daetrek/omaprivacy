# OmaPrivacy 1.0 test matrix

## Automated checks

Run from the repository root:

```bash
python -m unittest discover -s tests -v
python -m py_compile bin/omaprivacy
qmllint OmaPrivacy.qml
omarchy plugin validate .
git diff --check
```

## Browser Location Shield

Test Chromium, Sidra, and Zen separately:

1. Record each browser's location default and saved site decisions.
2. Enable Location Shield and approve browser closure.
3. Confirm precise geolocation is blocked after reopening the browser.
4. Confirm camera defaults and camera site decisions did not change.
5. Confirm Maps may still show a rough IP-derived region, but not precise
   browser geolocation.
6. Disable the shield and confirm every recorded location setting is restored.
7. Repeat with no saved grants, multiple profiles, and Privacy Mode enabled.

## Capture and app rules

For microphone, camera, and screen sharing:

1. Start one real capture and confirm the bar lock opens once and remains still.
2. Stop capture and confirm the lock closes with the reverse motion.
3. Confirm Overview, Findings, and Activity name the application and kind.
4. Test Default, Always alert, and Auto-stop independently.
5. Confirm failed Auto-stop leaves the stream visible as active.
6. Confirm playback-only streams never appear as microphone capture.

## Lifecycle

1. Validate and install a clean Git checkout with `omarchy plugin add`.
2. Upgrade an installation containing older config and Privacy Mode state.
3. Confirm settings and activity survive an update.
4. Disable Privacy Mode and Location Shield, then remove the plugin.
5. Reinstall and confirm state is still readable.
6. Confirm the shell starts cleanly and the widget appears once in the selected
   bar section.

## UI regression

- Open every view at the minimum supported panel size.
- Verify scrolling, keyboard Escape, `R` refresh, confirmation dialogs, and
  error wrapping.
- Verify urgent colors remain readable on light and dark themes.
- Verify the panel remains stable while three-second background scans complete.
