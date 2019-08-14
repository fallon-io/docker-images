#!/bin/sh

SCRIPT_DIR="$( cd "$( dirname "$0" )" >/dev/null 2>&1 && pwd )"

set -eo posix

isNumber(){ test "${1:-1}" -eq "${1:-0}" 2>/dev/null; }

###
# die [<exit code>] <error message string...>
###
die(){
    # if not provided, default exit code, set code and shift args
    isNumber "$1" && exit_code="${1}" && shift || exit_code="1"
    message="$*"

    printf >&2 '%s\n' "$message"; exit "$exit_code";
}

pathrequire(){ command -v "$1" 2>/dev/null || die 1 "Command '$1' not found: ${2:-"Please install and add this to the path."}"; }

JQ="$(pathrequire "${JQ_CMD:-jq}" 'Use $JQ_CMD to set its location or add it to your path.')"

LIBRARY_PATH=${LIBRARY_PATH:-${SCRIPT_DIR}/../external}
REPO=${1}
test -n "$NAMESPACE" || die "Output namespace must be defined with environment variable"

REPO_FILE="$LIBRARY_PATH/$REPO"

cat "$REPO_FILE"|"$JQ" -Rsrj '.|splits("\\n+(?=[^\\n\\t\\s])")|([.|splits(":")|sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")]|join(":")) + "\u0000"' \
    | while IFS=": " read -d '' field body; do
        case $field in
        DockerRepo) SOURCE_REPO="$body" ;;
        Architectures) ;;# Do nothing for now
        Tags)
            test -z "$TAG_LIST" && TAG_LIST="$body" || TAG_LIST="$TAG_LIST, $body"
            ;;
        DockerImageDigest)
            IMAGE_DIGEST="$body"
            IMAGE="$SOURCE_REPO@$IMAGE_DIGEST"
            docker pull "$IMAGE"
            printf '%s\n' "$TAG_LIST" | \
                "$JQ" -Rr '.|sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")|split(",[[:space:]]*";"l")|.[]' \
                | while read tag; do
                    docker tag "$IMAGE" "$NAMESPACE/$REPO:$tag"
                done

            # Clean Up TAG_LIST for next image
            TAG_LIST=
            ;;
        esac
    done