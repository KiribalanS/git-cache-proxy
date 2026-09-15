#!/bin/sh

set -e

REPO_PATH="$1"
REPO_URL="$2"
PROGRESS_LOG="$3"

# One dedicated service credential for the cache to authenticate to
# upstream on behalf of every client -- not each client's own credential.
# Some upstreams (on-prem Azure DevOps Server / TFS confirmed empirically)
# reject URL-embedded Basic-auth outright, regardless of username format --
# only a Basic auth header sent via `-c http.extraHeader` works. Using one
# service credential the cache owns also means the cache doesn't depend on
# whatever a given client happened to send.
NPROC=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
if [ -n "$GIT_CACHE_UPSTREAM_PAT" ]; then
    # `tr -d '\n'` rather than relying on `base64 -w0` -- not every base64
    # implementation (this image's Alpine/busybox one included) supports
    # -w, and a wrapped value here would silently corrupt the header.
    AUTH_B64=$(printf '%s:%s' "$GIT_CACHE_UPSTREAM_USERNAME" "$GIT_CACHE_UPSTREAM_PAT" | base64 | tr -d '\n')
    set -- -c "http.extraHeader=Authorization: Basic ${AUTH_B64}" -c "pack.threads=${NPROC}"
else
    set -- -c "pack.threads=${NPROC}"
fi

start=$(date +%s)

REPACK_MARKER="${REPO_PATH}.last-repack"
# Debounce repacking on the warm (fetch) path -- only every
# GIT_CACHE_REPACK_DEBOUNCE_S seconds at most, so a burst of concurrent or
# rapid fetches for an unchanged repo doesn't each pay a repack. The
# clone path below always repacks once, unconditionally: that first repack
# is what makes every subsequent concurrent git-upload-pack cheap (see
# below), so it's worth paying up front rather than debouncing it away.
REPACK_DEBOUNCE_S="${GIT_CACHE_REPACK_DEBOUNCE_S:-600}"

if [ ! -d "$REPO_PATH" ]; then
   echo -e "\nStarting cache git clone of '$REPO_URL'" >> "$PROGRESS_LOG"
   git "$@" clone --bare --no-tags --progress "$REPO_URL" "$REPO_PATH" 2>> "$PROGRESS_LOG"
   echo "Finished cache git clone" >> "$PROGRESS_LOG"

   # Without bitmaps, git-http-backend re-walks the object graph from
   # scratch for every concurrent git-upload-pack request -- this is the
   # single biggest lever for surviving a burst of identical concurrent
   # clones without saturating CPU. Best-effort: a failed repack shouldn't
   # take an already-good clone down.
   if git -C "$REPO_PATH" "$@" repack -a -d --write-bitmap-index >> "$PROGRESS_LOG" 2>&1; then
       date +%s > "$REPACK_MARKER"
   else
       echo "repack failed after clone, serving without bitmaps" >> "$PROGRESS_LOG"
   fi
else
   echo -e "\nStarting cache git fetch of '$REPO_URL'" >> "$PROGRESS_LOG"
   cd "$REPO_PATH" && git "$@" fetch --no-tags --progress 2>> "$PROGRESS_LOG"
   echo "Finished cache git fetch" >> "$PROGRESS_LOG"

   LAST_REPACK=0
   [ -f "$REPACK_MARKER" ] && LAST_REPACK=$(cat "$REPACK_MARKER" 2>/dev/null || echo 0)
   NOW=$(date +%s)
   if [ $((NOW - LAST_REPACK)) -ge "$REPACK_DEBOUNCE_S" ]; then
       if git -C "$REPO_PATH" "$@" repack -a -d --write-bitmap-index >> "$PROGRESS_LOG" 2>&1; then
           date +%s > "$REPACK_MARKER"
       else
           echo "repack failed after fetch, serving without fresh bitmaps" >> "$PROGRESS_LOG"
       fi
   fi
fi

end=$(date +%s)

echo "Duration: $((end - start)) seconds" >> "$PROGRESS_LOG"
