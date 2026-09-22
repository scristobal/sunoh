set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments
set working-directory := '..'

[default]
[private]
default:
    @just --list terraform

# Initialize the private R2 backend and pinned Cloudflare provider.
init *args:
    npm run --silent terraform --workspace @sunoh/tools -- init "$@"

# Plan infrastructure against the built Worker, checking for out-of-band deployments.
plan *args:
    just check
    npm run --silent terraform --workspace @sunoh/tools -- plan "$@"

# Back up state and apply exactly the previously saved plan.
apply:
    npm run --silent terraform --workspace @sunoh/tools -- apply

# Compare the prepared bundle/configuration with production (exit 2 means changes).
audit:
    npm run --silent terraform --workspace @sunoh/tools -- audit

# Save a uniquely named private copy of remote state in R2.
backup:
    npm run --silent terraform --workspace @sunoh/tools -- backup

# Run an explicit Terraform command with the project account and state credentials.
run +args:
    npm run --silent terraform --workspace @sunoh/tools -- run "$@"
