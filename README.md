Provides a transparent git caching proxy that:

1. Is easy to use - simply slightly modify the `.git` url being cloned
2. Intercepts git clone/fetch requests via git's HTTP protocol
3. On first request for a repository:
   - Creates a `--bare` clone of the upstream repository
   - Stores it in a Docker volume (`repo-cache`)
   - Serves the clone request from this local copy
4. On subsequent requests:
   - First updates the cached bare repo with `git fetch`
   - Then serves the request from the local cache
   - Results in significantly faster clones

The proxy is transparent to git clients - they interact with it just like any git HTTP server

The caching happens automatically without any special configuration needed on the client side aside from the adjusted url

# Try it

Start it:

`./start`

Then, instead of cloning the repo's url directly like this:

`git clone http://gerrit.wikimedia.org/r/mediawiki/skins/Vector.git`

Do this:

`git clone http://localhost:8765/gerrit.wikimedia.org/r/mediawiki/skins/Vector.git`

^ Note the url starts with `http://localhost:8765`, followed by the repo url

# Benefits
- Faster repeat clones of large repositories
- Reduces load on upstream git servers
- Works with any git HTTP URL
- Maintains a single source of truth via the bare repository
- Preserves all git functionality (branches, tags, etc)
- Implemented using a super lightweight Alpine image
- A per-repo locking mechanism ensures concurrent clone requests for the same repo wait for any in-progress cache clone/fetch to complete before being served from the cache
- Pack bitmaps and a locked pack-byte cache keep CPU/time bounded when many clients request the same repo/commit at once — see [Performance under concurrent load](#performance-under-concurrent-load)
- Optional header-based upstream auth for git servers that reject URL-embedded credentials — see [Authenticating to upstream](#authenticating-to-upstream)

# Scripts

* `./print-cache` 

  Displays the current contents of the cache using `tree`, showing all cached repositories and their internal structure

* `./reset-cache`

  Clears repositories from the cache. When run without arguments, removes all cached repositories. Can also remove a specific repository by passing its URL

  Clear entire cache:

  `./reset-cache`

  Remove specific repo cache:

  `./reset-cache http://example.com/repo.git`

* `./start`

  Brings up the caching proxy:

  - Removes any existing containers and images
  - Starts the service on port 8765 
  - Shows container logs for monitoring

  You can uncomment the last line to debug the `git-cache-handler.sh` script instead

* `./test` 

  Runs integration tests to verify the cache is working correctly:

  - Starts the proxy
  - Performs two clones of the same repository
  - Validates that the second clone is faster than the first
  - Cleans up test repositories and containers

# Authenticating to upstream

Some upstream git servers (on-prem Azure DevOps Server / TFS, confirmed empirically) reject URL-embedded Basic-auth credentials outright, regardless of username format — only a Basic-auth header sent via `-c http.extraHeader` works. To cover that case (and to avoid the cache depending on whatever credential a given client happens to send), the cache can authenticate to upstream itself with one dedicated service credential:

1. Copy `.env.example` to `.env` (already gitignored — never commit it)
2. Set `GIT_CACHE_UPSTREAM_USERNAME` and `GIT_CACHE_UPSTREAM_PAT` to a dedicated, read-only credential
3. `docker-compose.yml` picks it up via `env_file: .env`

Leave both blank to run anonymous (works only against a fully public upstream).

# Performance under concurrent load

Two additions on top of the base clone/fetch caching above, aimed at CI-style bursts where many clients request the same repo/commit within seconds of each other:

- **Pack bitmaps** — every clone, and every fetch that lands on a repack (debounced via `GIT_CACHE_REPACK_DEBOUNCE_S`, default 600s), runs with `--write-bitmap-index`. Without this, `git-http-backend` re-walks the object graph from scratch for every concurrent `git-upload-pack` request, which is what saturates CPU under a burst of simultaneous clones.
- **Pack-byte cache** — the actual computed pack bytes for `git-upload-pack` are cached, keyed on a hash of the raw negotiation body. A `want` line is always a full object SHA, never a branch name, so a cached entry stays correct forever regardless of what happens in the repo later — no invalidation needed when upstream gets a new commit, entries simply stop being requested once a branch moves on, and age out via `GIT_CACHE_PACK_CACHE_RETENTION_MIN` (default 240 minutes / 4h — see `.env.example` for the reasoning). The *first* request for a given negotiation still pays the full cost; every identical request after that (and before it ages out) is served straight from disk.
  - Concurrent *first* requests for the same negotiation (e.g. many pipelines firing off the same new commit at once) are serialized behind a lock rather than each independently recomputing the pack — without this, a simultaneous-miss burst gets zero benefit from the cache, since every request loses the race the same way.
  - Set `GIT_CACHE_PACK_CACHE_ENABLED=false` to disable this and always recompute fresh.

# Notes

While the cache maintains full-depth clones internally, clients can still use options like `--depth` to create shallow clones from the cached repository. This gives you the best of both worlds - the cache has all history available, but clients can choose how much they want to fetch from the cache

# Debugging

After running `./start` you can tail `progress.log`:

`docker compose exec git-cache tail -f /var/log/git-cache/progress.log`