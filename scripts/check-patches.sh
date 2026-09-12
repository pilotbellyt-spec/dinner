#!/usr/bin/env bash
set -euo pipefail

for path in "$@"; do
	if [ -d "$path" ]; then
		while IFS= read -r -d '' patch; do
			git apply --numstat "$patch" >/dev/null
		done < <(find "$path" -type f -name '*.patch' -print0)
	else
		git apply --numstat "$path" >/dev/null
	fi
done
