#!/bin/bash
# Optional: keep the keyboard effect chosen in ASUS ROG Monitor when the Omarchy theme changes.
# Omarchy resets the keyboard colour on every theme change. Remove with:
#   rm ~/.config/omarchy/hooks/theme-set.d/asus-rog-monitor-keyboard
set -euo pipefail
plugin="$(cd "$(dirname "$0")" && pwd)"
hook="$HOME/.config/omarchy/hooks/theme-set.d/asus-rog-monitor-keyboard"
mkdir -p "$(dirname "$hook")"
printf '#!/bin/bash\nexec python3 -I "%s/actions.py" keyboard-reapply\n' "$plugin" > "$hook"
chmod +x "$hook"
echo "Installed $hook"
