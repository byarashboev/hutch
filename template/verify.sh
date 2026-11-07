# Project checks for hutch verify. Runs with bash -euo pipefail in the project image, with no network, from a plain
# tree of the task branch at /work. $1 is a file listing the changed paths, one per line. Run only the checks for the
# areas the diff touches; every check must pass offline.
changed="$1"
cd /work
touches() { grep -qE -- "$1" "$changed"; }

# Example:
# if touches '^src/'; then
#   npm ci --offline
#   npm run lint
#   npm test
# fi
echo "verify.sh has no checks yet: fill it in (hutch AGENTS.md, Project setup)" >&2
exit 1
