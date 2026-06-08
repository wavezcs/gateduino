# Gateduino — ESPHome Migration Guide

## Why Migrate

Three bugs in the Arduino firmware caused the gate to stop opening:

1. **Blocking BLE scan** — `pBLEScan->start(1, false)` blocks the main loop for 1 second per scan. `mqttClient.loop()` starves and loses messages.

2. **RETAIN-less ENABLE command** — `mqttClient.publish("gateduino/all/command", "ENABLE_BLE_SCANNING")` has no retain flag. If a node is mid-scan (loop blocked), it misses the command. On next reboot, it reads NVS and stays disabled forever.

3. **Publish-only-if-changed** — RSSI is only published when it changes. When the mower is absent, RSSI stays at -100 and the dashboard freezes. Dashboard appears broken.

**Root cause of recent gate failure**: Someone (or some trigger) sent DISABLE_BLE_SCANNING. The ENABLE that followed had no retain and was dropped by front/back during their blocking scan. They rebooted (power cycle, OTA, etc.) and loaded `blescanning=false` from NVS. Gate never re-enabled.

## New Architecture

```
 [gateduino-front]  [gateduino-back]  [gateduino-gate]
  passive BLE scan   passive BLE scan   passive BLE scan + relay
  |                  |                  |
  +------ HA Native API (primary) ------+
  |                  |                  |
  +------ MQTT (for dashboard/Hubitat) -+
                     |
              [Home Assistant]
               Gate logic:
               - Combine 3x RSSI
               - Check mower state (Mammotion integration)
               - Check BLE proxy state
               - Open/close via ESPHome service call
```

**Key changes:**
- Gate decision moved to HA automations (not distributed across nodes)
- Passive BLE scan (never blocks MQTT)
- MAC-based scanning: `C8:FE:0F:1D:0A:F8` (not name-based, more reliable)
- 5-sample RSSI average in ESPHome filter (replaces 2-sample rolling average)
- `heartbeat: 5s` filter forces publish every 5s even if RSSI unchanged
- MQTT commands published with `retain: true` (won't be dropped)
- GPIO wires kept as hardware fallback when HA is offline
- BLE proxy conflict handled explicitly in HA conditions

## Luba Info
- BLE MAC: `C8:FE:0F:1D:0A:F8`
- WiFi MAC: `c8:fe:0f:1d:0a:f7`
- BLE Name: `Luba-VSVUUEXM`
- HA integration: Mammotion (HACS), entity `lawn_mower.luba_vsvuuexm`

## BLE Proxy Conflict

When `binary_sensor.attic_proxy_mower_ble_connected` or
`binary_sensor.luba_proxy_garage_mower_ble_connected` turns ON:
- The mower stops broadcasting BLE advertisements
- All scanner nodes lose RSSI (they'll report "unavailable" within 30s)
- Auto-gate is **automatically disabled** via the HA automation condition
- Dashboard shows the proxy-active state via MQTT log
- Manual open/close still works via dashboard commands

Note: `automation.mower_ble_connect_via_closest_proxy` is currently ON.
If this fires automatically during mowing, it will block gate auto-open.
Consider disabling it or making it conditional on gate-not-needed state.

## Migration Steps

### Step 1: Prepare ESPHome secrets
Edit `secrets.yaml`:
- Generate API keys: run `esphome generate-api-key` for each node (3 times)
- Replace `YOUR_API_KEY_*` placeholders

### Step 2: Flash front and back nodes first
These are safe to flash first — they're scanners only, gate stays closed.

```bash
esphome run gateduino-front.yaml  # 192.168.0.200
esphome run gateduino-back.yaml   # 192.168.0.250
```

Verify in HA that these appear as new ESPHome devices with RSSI sensors.

### Step 3: Create HA helper
Settings > Devices & Services > Helpers > Toggle
- Name: `Gate Auto-Open Enabled`
- Entity ID: `input_boolean.gate_auto_open_enabled`
- Icon: `mdi:gate-open`
- Start enabled (on)

### Step 4: Add HA automations
Copy the 5 automations from `ha_automations.yaml` into HA.
Either:
- Settings > Automations > three-dot menu > Import blueprint
- Or paste into `automations.yaml` and reload

### Step 5: Flash gate node
```bash
esphome run gateduino-gate.yaml
```

Verify gate relay switch appears in HA as `switch.gateduino_gate_gate`.

### Step 6: Test
1. Manually trigger `esphome.gateduino_gate_open_gate` from HA Developer Tools
2. Verify gate opens
3. Drive mower near gate — verify RSSI rises in HA
4. Verify auto-open triggers when RSSI > -76 sustained 3s
5. Verify gate closes after mower moves away

### Step 7: Decommission Arduino firmware
Once ESPHome is verified stable, you can remove the old Arduino OTA entries.
The MQTT topic structure is preserved so the web dashboard continues to work.

## GPIO Wiring (unchanged from Arduino)
| Wire | From | To |
|------|------|----|
| Front→Gate | Front GPIO10 (D10) | Gate GPIO8 (D8) |
| Back→Gate | Back GPIO10 (D10) | Gate GPIO10 (D10) |

These wires are the hardware fallback. Normal operation uses HA via native API.

## RSSI Thresholds (same as original)
- `areaRssi`: -87 dBm — outer zone, mower approaching
- `triggerRssi`: -76 dBm — inner zone, gate should open
- Auto-close delay: 15s after all nodes drop below areaRssi
- Minimum open time: 30s before auto-close activates

Tune these via the `substitutions:` block in each YAML if needed.

## Dashboard Compatibility
MQTT topics preserved:
- `gateduino/{node}/status` — JSON with rssiAvg, gateState
- `gateduino/{node}/config` — JSON config (published every 30s, retained)
- `gateduino/{node}/lwt` — online/offline (retained)
- `gateduino/{node}/log` — log messages
- `gateduino/{node}/command` — OPEN, CLOSE, PING, RESTART (gate node)
- `gateduino/all/command` — broadcast commands

The web dashboard at gateduino.csdyn.com should work without changes.
RSSI will now update continuously (every 5s) rather than only on change.
