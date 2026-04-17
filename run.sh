#!/usr/bin/env bash
# Launch Cine Immersive Stabilizer — picks a Python 3.13 interpreter that
# has the deps installed and runs stabilize.py from this directory so
# relative paths (braw_helper) resolve correctly.

set -euo pipefail
cd "$(dirname "$0")"

for py in \
    /usr/local/bin/python3.13 \
    /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 \
    /opt/homebrew/bin/python3.13 \
    python3.13 \
    python3; do
    if command -v "$py" >/dev/null 2>&1; then
        PYTHON="$py"
        break
    fi
done

if [ -z "${PYTHON:-}" ]; then
    echo "No Python 3.13 interpreter found." >&2
    echo "Install Python 3.13 and the deps in requirements.txt:" >&2
    echo "  python3.13 -m pip install -r requirements.txt" >&2
    exit 1
fi

exec "$PYTHON" stabilize.py "$@"
