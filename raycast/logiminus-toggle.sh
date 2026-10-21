#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title Toggle Spotlight
# @raycast.mode compact
# @raycast.packageName Logiminus
# @raycast.icon 🔦
# @raycast.description Toggle the Logitech Spotlight driver

exec "$HOME/.local/bin/logiminus" toggle
