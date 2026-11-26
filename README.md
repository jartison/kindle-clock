# Kindle Clock

A customizable e-ink clock for jailbroken Kindle devices.

Kindle Clock uses FBInk to render a digital clock directly on the Kindle display. The application runs entirely locally on the Kindle — it does not rely on a remote service or web page to render the clock. It can also display the date, weather, and battery status, periodically synchronize system time, and use RTC wake alarms to reduce power consumption between screen updates.

The project is currently developed and tested primarily on the Kindle 7 (WP63GW). Other Kindle models may also be compatible, depending on their hardware, firmware, and available system components.

## Features

- **Digital clock** — Displays the current hour and minute using a customizable font.
- **12/24-hour format** — Supports both 12-hour and 24-hour clock formats.
- **Display mode** — Supports light mode, dark mode, and following the Kindle system display mode.
- **Date and weekday** — Displays the weekday and day of the month with localization support.
- **Weather** — Retrieves current weather information from [wttr.in](https://wttr.in/).
- **Battery status** — Displays battery level and charging status with customizable icons.
- **Time synchronization** — Synchronizes system time using NTP.
- **Customizable layout** — Adjusts the relative sizes of the status, time, and information areas.
- **Customizable fonts** — Supports separate fonts and font scaling for different display areas.
- **Power management** — Uses RTC wake alarms and memory suspend to reduce power consumption.
- **Configurable refresh** — Supports periodic screen flashing to help maintain e-ink display quality.
- **Wireless management** — Controls wireless connectivity for network tasks and can restore its original state on exit.

## Installation

1. Copy the project directory to the Kindle:

   ```text
   /mnt/us/extensions/kindle-clock
   ```

2. Ensure that `main.sh` and the FBInk executable are accessible.

3. Configure a KUAL menu entry to launch the script:

   ```sh
   sh /mnt/us/extensions/kindle-clock/main.sh
   ```

4. Launch Kindle Clock from KUAL.

## Usage

Kindle Clock accepts command-line arguments for configuring its behavior and appearance.

Example:

```sh
sh /mnt/us/extensions/kindle-clock/main.sh \
    --language zh-Hans \
    --timezone UTC-8 \
    --weather-location Changsha
```

### Command-line Options

| Option | Default | Description |
|---|---|---|
| `--verbose` | `0` | Enable debug logging (`1` to enable). |
| `--delay` | `0` | Delay before starting the main loop, in seconds. |
| `--language` | `en` | Localization language. |
| `--use-24-hour` | `1` | Use the 24-hour clock format (`0` to use the 12-hour format). |
| `--display-mode` | `system` | Display mode: `light`, `dark`, or `system` to follow the Kindle system setting. |
| `--max-cycles` | `-1` | Maximum number of display cycles. Values less than or equal to zero mean unlimited cycles. |
| `--suspend-seconds` | `60` | Base suspend interval, in seconds. |
| `--resume-tolerance` | `1` | Allowed early-resume tolerance, in seconds. |
| `--screen-flash-interval` | `30` | Flash the screen every N display cycles. |
| `--timezone` | `UTC-0` | Time zone used for displaying timestamps in logs and the clock. |
| `--status-font` | `fonts/Inter_24pt-Regular.ttf` | Font used in the status area. |
| `--time-font` | `fonts/digital-7 (mono).ttf` | Font used for the clock. |
| `--info-font` | `fonts/NotoSans-Regular.ttf` | Font used in the information area. |
| `--status-size-factor` | `1` | Relative size factor of the status area. |
| `--time-size-factor` | `9` | Relative size factor of the time area. |
| `--info-size-factor` | `1` | Relative size factor of the information area. |
| `--time-layout-density` | `66` | Controls the internal layout density of the time area. |
| `--status-image-size-scale` | `75` | Battery icon size as a percentage of the status area size. |
| `--status-font-size-scale` | `60` | Status font size as a percentage of the status area size. |
| `--time-font-size-scale` | `90` | Clock font size as a percentage of the time area size. |
| `--info-font-size-scale` | `90` | Information font size as a percentage of the information area size. |
| `--battery-image-unknown` | `images/battery-unknown.png` | Battery icon used when the battery state is unknown. |
| `--battery-image-charging` | `images/battery-charging.png` | Battery icon used while charging. |
| `--battery-image-full` | `images/battery-full.png` | Battery icon used for a high battery level. |
| `--battery-image-medium` | `images/battery-medium.png` | Battery icon used for a medium battery level. |
| `--battery-image-low` | `images/battery-low.png` | Battery icon used for a low battery level. |
| `--battery-image-warning` | `images/battery-warning.png` | Battery icon used for a critically low or unknown battery level. |
| `--keep-wireless-enabled` | `1` | Keep wireless enabled after network tasks (`0` to restore the disabled state). |
| `--wireless-connect-timeout` | `30` | Connection wait interval, in seconds. |
| `--wireless-reconnect-count` | `2` | Maximum number of wireless reconnect attempts. |
| `--enable-time-update` | `1` | Enable periodic NTP synchronization (`0` to disable). |
| `--time-update-interval` | `86400` | Time synchronization interval, in seconds. |
| `--ntp-server` | `pool.ntp.org` | NTP server hostname. |
| `--enable-weather-update` | `1` | Enable periodic weather updates (`0` to disable). |
| `--weather-update-interval` | `3600` | Weather update interval, in seconds. |
| `--weather-update-timeout` | `30` | Weather request timeout, in seconds. |
| `--weather-location` | Empty | Location used for weather queries. |

## Localization

Kindle Clock uses its own localization files instead of relying on system locale settings.

Localization files are stored in the `languages/` directory and use key-value pairs.

The weather service has a separate language mapping file:

```text
config/wttr-languages.txt
```

This maps the application's language identifier to a language code supported by wttr.in.

## Network Tasks

Network tasks are performed after each screen update when their respective update intervals have elapsed.

### Time Synchronization

System time is synchronized using `ntpdate` and the configured NTP server.

Default interval: **24 hours**.

### Weather Updates

Weather information is retrieved from wttr.in using `curl`.

Default interval: **1 hour**.

If a weather request fails, the last successfully retrieved weather information is retained.

Wireless connectivity is checked before network tasks are performed. Kindle Clock can attempt to reconnect when the connection remains in the pending state.