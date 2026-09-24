#!/bin/bash
# Attach to the running server console.
# Detach without stopping the server: Ctrl+A, then D
exec screen -r "${SCREEN_NAME:-pz-server}"
