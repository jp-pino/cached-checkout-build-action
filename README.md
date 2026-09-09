# cached-checkout-build-action

Check out a CMake repository, build it, install it, and cache the install tree so the next run only
copies files. Builds can declare which earlier builds in the job they depend on, so a change in a
dependency invalidates everything downstream of it, and pull requests can point individual
dependencies at a branch or pull request with a `Depends on …` line in their description.

## Usage

```yaml
- uses: jp-pino/cached-checkout-build-action@v5
  with:
    # Repository name with owner. For example, actions/checkout
    # Default: ${{ github.repository }}
    repository: ''

    # The branch, tag or SHA to checkout. When checking out the repository that
    # triggered a workflow, this defaults to the SHA for that event. Otherwise,
    # uses the default branch.
    ref: ''

    # Personal access token (PAT) used to fetch the repository and query the
    # GitHub API. Needs read access to the repository (and to pull requests
    # referenced by dependency overrides).
    #
    # Default: ${{ github.token }}
    token: ''

    # Token for the repository running the workflow, used only by
    # `dependency-overrides: auto` to look up the branch's open pull request.
    # Default: ${{ github.token }}
    github-token: ''

    # Whether to checkout submodules: `true` to checkout submodules or `recursive`
    # to recursively checkout submodules. Passed straight through to
    # actions/checkout, which fetches them with the same token.
    #
    # Default: false
    submodules: ''

    # Flags to pass to cmake on configure. Evaluated as shell text, so quoting
    # works like on a command line: -DFOO="a b"
    cmake-flags: ''

    # Flags to pass to cmake --build
    build-flags: ''

    # Command to run in the build shell before configuring, e.g.
    # source /opt/ros/jazzy/setup.zsh
    pre-build-command: ''

    # Shell used to run pre-build-command and the build.
    # Default: bash
    shell: ''

    # Builds done earlier in this job by this action that this build depends on.
    # Comma or newline separated `owner/repo` or bare `repo` names, or `all`.
    # See "Dependency chains".
    depends-on: ''

    # Text scanned for `Depends on <link>` lines that replace `ref`, or `auto`
    # for the description of the pull request (from the event, or looked up for
    # the pushed branch). See "Overriding refs from a pull request description".
    # Default: auto
    dependency-overrides: ''

    # Extra text mixed into the cache key. Change it to force a rebuild, or put
    # e.g. a toolchain version in it so the cache follows it.
    cache-key-extra: ''

    # Where the built tree is installed after the build or cache restore.
    # Default: /usr/local
    install-prefix: ''

    # Run the build and the install as root (via sudo when the runner user is
    # not root).
    # Default: true
    sudo: ''
```

### Outputs

| Output | Description |
| --- | --- |
| `cache-hit` | `true` when the install tree was restored from the cache, empty when it was built. `cache-restore-hit` is an alias. |
| `cache-key` | The cache key used for this build. |
| `fingerprint` | SHA-256 of everything that identifies this build: commit, flags, submodules and the fingerprints of its `depends-on` dependencies. |
| `latest-ref` | The commit SHA that was built. |
| `ref` | The ref that was built, after any dependency override (for example `refs/pull/424/head`). |
| `ref-overridden` | `true` when a `Depends on` line replaced `ref`. |
| `source-path` | Absolute path of the checked out sources. Only exists on a cache miss. |
| `install-path` | Absolute path of the install tree that was copied into `install-prefix`. |

## How it works

1. Resolve the ref to a commit SHA through the GitHub API (no API call when `ref` is already a full
   SHA, or when building the repository that triggered the workflow).
2. Compute a **fingerprint** from the commit, `cmake-flags`, `build-flags`, `pre-build-command`,
   `submodules`, `cache-key-extra` and the fingerprints of the builds named in `depends-on`.
   The cache key is `cached-build-<os>-<arch>-<repo>-<sha>-<fingerprint>`.
3. Restore the install tree from the cache. On a miss, remove any leftover work directory, check out
   the sources under `.cached-checkout-build/` in the workspace, run
   `cmake <cmake-flags> && cmake --build . --target install -j <cpus> <build-flags>` in the
   requested shell, and save the install tree to the cache.
4. Copy the install tree into `install-prefix` and run `ldconfig`.

## Dependency chains

When a job builds several repositories in sequence, later builds usually link against earlier ones.
If only the changed repository is rebuilt, the packages downstream of it keep their cached build
against the old version and the final build fails with mismatched versions. `depends-on` fixes that:

```yaml
- name: Build and install protocol definitions
  uses: jp-pino/cached-checkout-build-action@v5
  with:
    repository: BluEye-Robotics/ProtocolDefinitions
    token: ${{ secrets.BLUEYE_ROS_GITHUB }}

- name: Build and install tyndall
  uses: jp-pino/cached-checkout-build-action@v5
  with:
    shell: zsh
    repository: BluEye-Robotics/tyndall
    token: ${{ secrets.BLUEYE_ROS_GITHUB }}
    pre-build-command: source /opt/ros/jazzy/setup.zsh

- name: Build and install libblunux
  uses: jp-pino/cached-checkout-build-action@v5
  with:
    repository: BluEye-Robotics/libblunux
    token: ${{ secrets.BLUEYE_ROS_GITHUB }}
    submodules: true
    depends-on: ProtocolDefinitions

- name: Build and install libguestport
  id: libguestport
  uses: jp-pino/cached-checkout-build-action@v5
  with:
    repository: BluEye-Robotics/libguestport
    token: ${{ secrets.BLUEYE_ROS_GITHUB }}
    cmake-flags: -DENABLE_TRITECH=OFF
    depends-on: |
      BluEye-Robotics/ProtocolDefinitions
      libblunux
```

Every build registers itself for the rest of the job (in the `CACHED_BUILD_REGISTRY` environment
variable). `depends-on` looks up the named builds there, and their fingerprints become part of this
build's fingerprint. The effect is transitive: libguestport depends on libblunux, whose fingerprint
already includes ProtocolDefinitions, so a new ProtocolDefinitions commit rebuilds all three, while a
new tyndall commit rebuilds only tyndall.

- Names are matched case-insensitively, as `owner/repo` or as the bare repository name. If the same
  repository is built more than once in a job, the most recent build is used.
- `depends-on: all` depends on every build registered so far in the job.
- Naming a dependency that has not been built earlier in the job fails the step with the list of
  what is registered.
- To make your own final build follow the chain, put the last fingerprint in your cache key:
  `key: ${{ runner.os }}-mybuild-${{ steps.libguestport.outputs.fingerprint }}-${{ hashFiles('**/CMakeLists.txt') }}`.

## Overriding refs from a pull request description

A pull request that needs an unmerged change in a dependency can say so in its description:

```
Depends on https://github.com/BluEye-Robotics/libblunux/pull/424
Depends on https://github.com/BluEye-Robotics/ProtocolDefinitions/tree/new-messages
```

Each step of this action scans `dependency-overrides` (the pull request description by default) for
lines starting with `Depends on` and, when a link points at the step's own `repository`, builds that
instead of `ref`:

| Link | What is built |
| --- | --- |
| `https://github.com/owner/repo/pull/424` or `owner/repo#424` | The pull request's head commit, checked out as `refs/pull/424/head`. |
| `https://github.com/owner/repo/tree/branch` or `owner/repo@branch` | That branch (or tag). Branch names may contain slashes; do not append a path. |
| `https://github.com/owner/repo/commit/abc1234` | That commit. |

Details:

- Matching is case-insensitive. `Depends on:`, `depends-on`, a leading `-` or `**` and markdown links
  are all fine. Links to other repositories, and links in lines that do not start with `Depends on`,
  are ignored.
- The first matching line for a repository wins; later ones produce a warning.
- The action prints a `::notice::` annotation with the swapped ref, and warns when the referenced pull
  request is already merged or closed.
- The swap changes the commit, so the cache key changes, and every build that `depends-on` it is
  rebuilt as well.
- The default, `auto`, finds the description itself. On `pull_request` events it comes from the event
  payload. On other events (`push`, `workflow_dispatch`) the action looks up the open pull request
  whose head is the current branch, so a workflow that only runs `on: [push]` gets the same
  overrides. The lookup happens once per job and is shared by every step of the action; its outcome
  is printed by the "Resolve repository, ref and commit" step. A branch with several open pull
  requests uses the most recently created one and warns. The lookup uses `github-token` (the
  workflow's own token, which needs `pull-requests: read`) and falls back to `token`; if both are
  refused, the step warns and nothing is overridden.
- To take the text from somewhere else, set `dependency-overrides` explicitly, for example to the head
  commit message. Set it to `''` to disable the feature for a step.
- Pull request heads are fetched from the base repository, so a pull request from a fork works too
  and the fork itself is never contacted.

## Migrating from v4

- `depends-on`, `dependency-overrides`, `cache-key-extra`, `install-prefix` and `sudo` are new inputs;
  `fingerprint`, `cache-key`, `ref`, `ref-overridden`, `source-path` and `install-path` are new outputs.
- The cache key now includes the build flags, `pre-build-command`, `submodules` and the dependency
  chain, so the first run after upgrading rebuilds everything once. In v4, changing `cmake-flags` did
  not invalidate the cache.
- With an empty `ref`, building the repository that triggered the workflow now uses the event's commit
  (as the documentation always said) instead of the default branch.
- Sources are checked out under `.cached-checkout-build/<repo>-<fingerprint>/git` instead of
  `<repo><ref>/git`. Use the `source-path` output rather than the path.
- The `cache-save-hit` output was removed. It was always empty because `actions/cache/save` has no such
  output.
- The bundled `actions/cache` and `actions/checkout` were bumped to versions that run on Node 24.
- Errors from the GitHub API (missing ref, no access, rate limit) now fail with the API's message
  instead of a `null` ref later in the step.

## Development

```
tests/run.sh          # unit tests for the scripts (needs bash, jq, cmake; zsh optional)
shellcheck scripts/*.sh tests/*.sh tests/mock/curl
```

The workflow in `.github/workflows/test.yml` additionally builds a real fmt → spdlog chain with the
action, verifies that a newer fmt changes spdlog's fingerprint, that a `Depends on` line swaps the
ref, and that a second job restores the chain from the cache.
