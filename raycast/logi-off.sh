#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Logi Off
# @raycast.mode compact

# Optional parameters:
# @raycast.icon 🔦
# @raycast.packageName Logiminus
# @raycast.description Disable Logiminus (remote falls back to its built-in behaviour)

exec "$HOME/.local/bin/logiminus" disable
