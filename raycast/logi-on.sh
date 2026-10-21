#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Logi On
# @raycast.mode compact

# Optional parameters:
# @raycast.icon 🔦
# @raycast.packageName Logiminus
# @raycast.description Enable Logiminus for the Spotlight 2 (starts the app if needed)

exec "$HOME/.local/bin/logiminus" enable
