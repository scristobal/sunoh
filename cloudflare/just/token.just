set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments
set working-directory := '..'

[default]
[private]
default:
    @just --list token

# Declare a finite service token in Terraform; review and apply its plan separately.
create name hours="720":
    npm run --silent token --workspace @sunoh/tools -- create "$1" "$2"

# Display one service credential pair from private Terraform state.
show name:
    @npm run --silent token --workspace @sunoh/tools -- show "$1"
