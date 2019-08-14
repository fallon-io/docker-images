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
HUB_REQUEST="$(pathrequire "$SCRIPT_DIR/docker_hub_request.sh" 'Please place this in the script directory.')"

build_regex(){
    printf '%s\n' "$*" \
        | "$JQ" -Rr '[.|splits("[\\s]+")
            |gsub("\\\\";"\\\\")
            |gsub("\\.";"\\.")
            |gsub("\\*";".+")
            |gsub("\\?";".{1}")
            ] | join(")|(?:") | "^((?:\(.)))$"'
}

fetch_image_digest(){
    manifest_url=$(printf '%s\n' "$1" | "$JQ" -Rr '.|split(":")
        |{name:.[0],reference:.[1]}
        |"https://registry.hub.docker.com/v2/\(.name)/manifests/\(.reference)"')
    "$HUB_REQUEST" \
        "$manifest_url" --head -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    | jq -r '.headers["Docker-Content-Digest"]'
}

fetch_image_tags(){
    "$HUB_REQUEST" \
        "https://registry.hub.docker.com/v2/${1}/tags/list" \
    | jq -r '.body | fromjson | .tags[]'
}

build_image_mirror_library(){
    docker_repo="${1}" && shift
    tag_regex=$(build_regex $@)
    docker_tags=$(fetch_image_tags "$docker_repo" | "$JQ" -rR --arg regex "${tag_regex}" '.|select(.|test($regex))')

    # Emit Docker Repo, won't change
    printf 'DockerRepo: docker.io/%s\n\n' "$docker_repo"

    # For each docker tag, get the current image digest
    printf '%s\n' "$docker_tags" | while read tag; do
        printf '%s %s\n' \
            "$(fetch_image_digest "$docker_repo:$tag")" \
            "$tag"
    done | sort --unique | while true; do
        # Seed the loop
        if test -z "$cur_digest"; then read cur_digest cur_digest_tags; fi;
        # printf '# Loop Start [%s] (%s)\n' "$cur_digest" "$cur_digest_tags"
        read digest tag || loop_done=1
        # printf '# New Entry [%s] (%s)\n' "$digest" "$tag"
        if test "${loop_done:-0}" != "1" && test "$cur_digest" == "$digest"; then
            cur_digest_tags="$cur_digest_tags, $tag"
        else
            # Done with digest, emit section
            printf 'Tags: %s\n' "$cur_digest_tags"
            printf 'Architectures: %s\n' "amd64" # Hardcoded for now 
            printf 'DockerImageDigest: %s\n\n' "$cur_digest"
            
            # Set up for the next loop if we have one
            cur_digest="${digest:-}"
            cur_digest_tags="${tag:-}"
        fi
    done
}

build_image_mirror_library "library/postgres" "9.5" "latest" "11" "11.5" "10-alpine" "10"
