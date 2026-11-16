# Choose a time zone in a light theme (Linux)

Choose one value from a long list in a window restyled with `--css`, and use it in the next
command. Script:
[examples/pick-timezone.sh](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/pick-timezone.sh)
with [css/light.css](https://github.com/nativehtmlkit/nativehtmlkit-cli/blob/main/examples/css/light.css)
(needs `timedatectl` or `/usr/share/zoneinfo`).

The examples run in the `examples` directory of a clone of this repository and were run
against the released CLI 0.1.2 by `scripts/test-docs.py`
([how](../index.md#how-the-examples-are-verified)).

## Run it

<!-- test: exit=124 calls="124@*x1" -->
```bash
./pick-timezone.sh
```

The list holds every zone `timedatectl list-timezones` knows (about 600; at most the first
2,000 are offered). Use the choice for one command:

<!-- test: exit=0 calls="124@*x1" -->
```bash
zone=$(./pick-timezone.sh) && TZ=$zone date '+%H:%M in '"$zone"
echo "status $?"
```

<!-- replay: call=1 exit=0 expect=0 -->
```text
Asia/Tokyo
```

## How it works

The whole script is a list and one `select` with a style sheet:

<!-- test: exit=124 calls="124@4x1" -->
```bash
printf '%s\n' Europe/Prague Europe/London America/New_York Asia/Tokyo |
  nativehtmlkit select --title 'Time zone' --css css/light.css
```

<!-- submit: pick=4 -->
```text
Asia/Tokyo
```

`css/light.css` overrides the page's colour custom properties and a few fixed colours
([CSS and forms](../css-and-forms.md)). Single choice is the default, so exactly one zone
comes back.

Windows: [Choose a time zone (Windows)](../../windows/recipes/timezone.md).
