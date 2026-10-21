#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Logi Toggle
# @raycast.mode compact

# Optional parameters:
# @raycast.icon 🔦
# @raycast.packageName Logiminus
# @raycast.description Toggle Logiminus

exec "$HOME/.local/bin/logiminus" toggle
