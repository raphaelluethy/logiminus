#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title Disable Spotlight
# @raycast.mode compact
# @raycast.packageName Logiminus
# @raycast.icon 🔦
# @raycast.description Disable the Logitech Spotlight driver

exec "$HOME/.local/bin/logiminus" disable
