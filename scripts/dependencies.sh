missing=()

need() {
	command -v "$1" >/dev/null || missing+=("$2")
}

require_dependencies() {
	[ "${#missing[@]}" -eq 0 ] && return
	echo "ERROR: The following dependencies are not installed: ${missing[*]}" >&2
	exit 1
}
