set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments
set working-directory := '..'

[default]
[private]
default:
    @just --list configure

# Save the directory containing local Wrangler runtime state.
runtime path:
    npm run configure --workspace @sunoh/tools -- --runtime-path "$1"

# Save the directory containing the completed map package.
package path:
    npm run configure --workspace @sunoh/tools -- --package-path "$1"

# Save the selected Cloudflare account and optional R2 location.
account id location="":
    @args=(--account "$1"); \
    if [[ -n "$2" ]]; then args+=(--r2-location "$2"); fi; \
    npm run configure --workspace @sunoh/tools -- "${args[@]}"

# Authenticate Wrangler and display the available Cloudflare accounts.
login:
    npm exec --workspace @sunoh/worker -- wrangler login
    npm exec --workspace @sunoh/worker -- wrangler whoami

# Review resource changes through Terraform; apply explicitly after reviewing.
provision:
    just terraform plan

# Securely save bucket-scoped R2 credentials entered at the prompts.
authorize:
    @read -r -p "R2 Access Key ID: " access; \
    read -r -s -p "R2 Secret Access Key: " secret; \
    printf '\n'; \
    R2_ACCESS_KEY_ID="$access" R2_SECRET_ACCESS_KEY="$secret" npm run authorize --workspace @sunoh/tools

# Save the Cloudflare management API token for Terraform.
management:
    @read -r -s -p "Cloudflare management API token: " credential; \
    printf '\n'; \
    CLOUDFLARE_API_TOKEN="$credential" npm run --silent credentials --workspace @sunoh/tools
