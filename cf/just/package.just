set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments
set working-directory := '..'

[default]
[private]
default:
    @just --list package

# Publish or resume a release in local or cloud storage with bounded multipart concurrency.
publish destination release size="4096" concurrency="4":
    @args=(); \
    case "$1" in local) args+=(--local) ;; cloud) ;; *) printf 'Destination must be local or cloud.\n' >&2; exit 1 ;; esac; \
    just check; \
    npm run publish --workspace @sunoh/tools -- \
        "${args[@]}" \
        --release-id "$2" \
        --part-size-mib "$3" \
        --concurrency "$4"

# Explicitly abort the checkpointed multipart publication in local or cloud storage.
abort destination:
    @args=(); \
    case "$1" in local) args+=(--local) ;; cloud) ;; *) printf 'Destination must be local or cloud.\n' >&2; exit 1 ;; esac; \
    just check; \
    npm run publish --workspace @sunoh/tools -- "${args[@]}" --abort

# Verify package hashes against a local or cloud release's manifest, object set and metadata.
verify destination release:
    @args=(); \
    case "$1" in local) args+=(--local) ;; cloud) ;; *) printf 'Destination must be local or cloud.\n' >&2; exit 1 ;; esac; \
    just check; \
    npm run verify --workspace @sunoh/tools -- "${args[@]}" --release-id "$2"
