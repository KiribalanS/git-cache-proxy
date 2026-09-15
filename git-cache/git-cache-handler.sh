#!/bin/sh

set -e

# Set thread counts for various Git operations. This is what git-http-backend
# itself (exec'd unconfigured at the bottom of this script) actually relies
# on for its own pack-generation performance -- the operation script sets
# pack.threads too, but only for the clone/fetch/repack it runs, not for
# git-http-backend's own process.
thread_count=$(getconf _NPROCESSORS_ONLN)
git config --global pack.threads $thread_count
git config --global fetch.parallel $thread_count
git config --global submodule.fetchJobs $thread_count
git config --global grep.threads $thread_count
git config --global pack.readThreads $thread_count
git config --global pack.writeThreads $thread_count

# Set log file path
PROGRESS_LOG=/var/log/git-cache/progress.log

# Convert PATH_INFO back to original URL
# Remove /info/refs and other git suffixes first
CLEAN_PATH=$(echo "$PATH_INFO" | sed -E 's/(\/info\/refs|\/git-upload-pack)$//' | sed 's/^\/*//')
REPO_URL="https://$CLEAN_PATH"

# Use full path structure
REPO_PATH="/repo-cache/$CLEAN_PATH"
LOCK_FILE="${REPO_PATH}.lock"

# Only do clone/fetch for info/refs requests. This is the freshness
# guarantee: every info/refs live-checks upstream before any ref is served,
# there is no time-based staleness window. Concurrent requests for the
# *same* repo serialize behind this flock rather than all hitting upstream
# at once -- each still does its own small fetch, just one at a time
# instead of N-at-once.
if echo "$PATH_INFO" | grep -q "/info/refs$"; then
    mkdir -p "$(dirname "$REPO_PATH")"
    touch "$LOCK_FILE"

    # Try the clone/fetch inside an exclusive lock
    if ! flock -x "$LOCK_FILE" /usr/local/bin/git-cache-operation.sh "$REPO_PATH" "$REPO_URL" "$PROGRESS_LOG"; then
        echo "Failed to acquire lock or operation failed for $REPO_URL" >> "$PROGRESS_LOG"
        # Never serve a cache we couldn't just confirm is current -- fail
        # the request instead of silently falling back to last-known-good.
        # Same failure mode a client would hit cloning upstream directly,
        # not a worse one.
        echo "Status: 502 Bad Gateway"
        echo
        exit 0
    fi
fi

if [ ! -d "$REPO_PATH" ]; then
    echo "Status: 404 Not Found"
    echo
    exit 0
fi

# Set required vars for git-http-backend
export GIT_PROJECT_ROOT=/repo-cache
export GIT_HTTP_EXPORT_ALL=1
export PATH=/usr/libexec/git-core:$PATH

# Pack-byte cache for git-upload-pack: many clients in a CI burst send the
# exact same negotiation (same branch, same tip commit -> same wants/haves)
# within seconds of each other. git-http-backend recomputes the pack fresh
# for every one of them; this reuses one computation across all of them.
#
# Keyed on a hash of the raw POST body, not a semantic parse of the
# pkt-line protocol. A "want" is always a full object SHA, never a branch
# name, so a cached pack for a given negotiation is eternally valid
# regardless of what else happens in the repo later -- no invalidation
# needed on new pushes, entries just become irrelevant once a branch moves
# on and age out below. Narrower than a semantic parse (only catches
# byte-identical requests, not equivalent-but-differently-encoded ones),
# but correct, and avoids writing a pkt-line parser in shell.
if echo "$PATH_INFO" | grep -q "/git-upload-pack$" && [ "${GIT_CACHE_PACK_CACHE_ENABLED:-true}" = "true" ]; then
    BODY_FILE=$(mktemp /tmp/upload-pack-body.XXXXXX)
    cat > "$BODY_FILE"

    REPO_HASH=$(printf '%s' "$CLEAN_PATH" | sha256sum | cut -c1-16)
    BODY_HASH=$(sha256sum "$BODY_FILE" | cut -d' ' -f1)
    PACK_CACHE_DIR="/repo-cache/.pack-cache/${REPO_HASH}"
    PACK_CACHE_ENTRY="${PACK_CACHE_DIR}/${BODY_HASH}"

    if [ ! -f "$PACK_CACHE_ENTRY" ]; then
        mkdir -p "$PACK_CACHE_DIR"
        # Opportunistic cleanup, scoped to this one repo's cache dir only --
        # bounded cost, only runs on a miss (i.e. rarely, once warm).
        find "$PACK_CACHE_DIR" -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null

        # On a miss, fully buffer git-http-backend's output to disk and
        # check its exit code *before* the entry is published or served --
        # never stream-while-caching, which risks persisting a truncated
        # pack if a client disconnects mid-transfer (a corrupted shared
        # cache entry would break every *other* client's clone too,
        # silently, until it ages out -- worse than no cache at all).
        PACK_CACHE_TMP=$(mktemp "${PACK_CACHE_DIR}/.tmp.XXXXXX")
        if /usr/libexec/git-core/git-http-backend < "$BODY_FILE" > "$PACK_CACHE_TMP"; then
            mv -f "$PACK_CACHE_TMP" "$PACK_CACHE_ENTRY"
        else
            echo "pack cache miss failed for $REPO_URL hash=$BODY_HASH" >> "$PROGRESS_LOG"
            rm -f "$PACK_CACHE_TMP" "$BODY_FILE"
            echo "Status: 502 Bad Gateway"
            echo
            exit 0
        fi
    fi

    rm -f "$BODY_FILE"
    cat "$PACK_CACHE_ENTRY"
    exit 0
fi

# info/refs (or pack cache disabled) is never cached -- always live, per the
# freshness guarantee above.
exec /usr/libexec/git-core/git-http-backend
