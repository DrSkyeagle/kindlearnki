#!/usr/bin/env bash
# Run one shell command inside the emulated Kindle.
#
#   wsl -d KO-test -- bash /mnt/d/ankindle/harness/emu/guest.sh 'uname -a'
#   .../emu.cmd guest 'ls /mnt/us/koreader/plugins'
#
# stdin is forwarded, so pipes work:
#   tar -cf - -C dir x | .../guest.sh 'tar -C /mnt/us -xf -'
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=env.sh
source "$here/env.sh"

if [ "$#" -eq 0 ]; then
    exec ssh "${SSH_OPTS[@]}" "$GUEST"
fi
guest_ssh "$@"
