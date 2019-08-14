#!/bin/sh

set -eo posix

SCRIPT_DIR="$( cd "$( dirname "$0" )" >/dev/null 2>&1 && pwd )"

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
CURL="$(pathrequire "${CURL_CMD:-curl}" 'Use $CURL_CMD to set its location or add it to your path.')"

# Make a temporary files and try to clean them up
TEMP_DIR=$(mktemp -d --tmpdir "$(basename $0).XXXXXXX")
trap "rm -rf '$TEMP_DIR'" ERR EXIT

HEADER_FILE="$TEMP_DIR/headers.mime"
RESPONSE_JSON="$TEMP_DIR/response.json"
TOKEN_FILE="$TEMP_DIR/token.txt"
CONTENTS="$TEMP_DIR/content.bin"


parse_response_code(){
    "$JQ" -r '.response|match("^HTTP/[0-9]+\\.[0-9]+ ([1-5][0-9]{2})")|.captures[0].string' "$RESPONSE_JSON"
}

parse_response(){
    {
        "$JQ" -Rs '[.|splits("\\r\\n(?=[^\\r\\n\\t\\s])")]|
            {response: 
                (.[0]),
            headers:
                ([.[1:]|.[]|match("([^\\x00-\\x1F\\x7f\\x20:]+):[\\t\\x20]+(.*)[\\r\\n\\t]*$")|
                    {key:.captures[0].string,value:.captures[1].string}]|from_entries)}' \
            "$HEADER_FILE";
        "$JQ" -Rs '{body: .}' "$CONTENTS";
    } | "$JQ" -s '.|add' >"$RESPONSE_JSON"
}

cleanup_request(){
    rm "$CONTENTS" && \
    rm "$HEADER_FILE"
}

request(){
    "$CURL" --silent \
        --dump-header "$HEADER_FILE" \
        -o "$CONTENTS" \
        "$@" && \
    parse_response && \
    cleanup_request && \
    parse_response_code
}

token_request(){
    "$CURL" --silent \
        --dump-header "$HEADER_FILE" \
        -H "Authorization: Bearer $(cat $TOKEN_FILE)" \
        -o "$CONTENTS" \
        "$@" && \
    parse_response && \
    cleanup_request && \
    parse_response_code
    
}

anonymous_auth(){
    auth_uri=$("$JQ" -r '.headers["Www-Authenticate"] |
        match("^Bearer[\\s]+realm=\\\"([^\\\"]+)\\\",service=\\\"([^\\\"]+)\\\",scope=\\\"([^\\\"]+)\\\"") | {
            uri: .captures[0].string,
            params: {
                service: .captures[1].string,
                scope: .captures[2].string
                }
        } | "\(.uri)?" + (@uri "service=\(.params.service)&scope=\(.params.scope)")' "$RESPONSE_JSON")
    "$CURL" --silent \
        "$auth_uri" | \
    "$JQ" -r '.token' >"$TOKEN_FILE"
}

request_flow(){
    if test "401" == $(request "$@" 2>/dev/null ); then
        anonymous_auth 2>&1 >/dev/null && \
            token_request "$@" 2>&1 >/dev/null && \
            cat "$RESPONSE_JSON"
    else
        cat "$RESPONSE_JSON"
    fi
}



request_flow "$@"