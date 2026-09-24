#!/bin/bash
# Attach to the running server console. Shared attach, so several admins can be in at once.
# Detach without stopping the server: Ctrl+A, then D
exec screen -x "${SCREEN_NAME:-pz-server}"
