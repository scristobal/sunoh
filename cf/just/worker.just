set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments
set working-directory := '..'

[default]
[private]
default:
    @just --list worker

# Build the Worker bundle for Terraform without uploading or deploying it.
build:
    npm run build --workspace @sunoh/worker

# Serve the local map API for the app in debug mode on a loopback port.
serve port="":
    @if [[ -n "$1" ]]; then export PORT="$1"; fi; \
    runtime_path="$(npm run --silent environment --workspace @sunoh/tools -- --scope serve --name RUNTIME_PATH)"; \
    port="$(npm run --silent environment --workspace @sunoh/tools -- --scope serve --name PORT)"; \
    release="$(npm run --silent environment --workspace @sunoh/tools -- --scope serve --name LOCAL_RELEASE_ID)"; \
    exec npm run dev --workspace @sunoh/worker -- \
        --port "$port" \
        --persist-to "$runtime_path/wrangler" \
        --var "LOCAL_RELEASE_ID:$release"
