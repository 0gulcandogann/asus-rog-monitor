#!/bin/bash
# Optional: keep the keyboard effect chosen in ASUS ROG Monitor when the Omarchy theme changes.
# Omarchy resets the keyboard colour on every theme change. Remove with:
#   rm ~/.config/omarchy/hooks/theme-set.d/asus-rog-monitor-keyboard
set -euo pipefail
plugin="$(cd "$(dirname "$0")" && pwd)"
hook="$HOME/.config/omarchy/hooks/theme-set.d/asus-rog-monitor-keyboard"
mkdir -p "$(dirname "$hook")"
# %q shell-quotes the path, so a checkout path with shell syntax stays data.
printf '#!/bin/bash\nexec python3 -I %q keyboard-reapply\n' "$plugin/actions.py" > "$hook"
chmod +x "$hook"
echo "Installed $hook"
