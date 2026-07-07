#!/usr/bin/env bash
# Push the GitHub Actions secrets the Release workflow needs.
#
# You provide the material that can only be minted in Apple's portals/Keychain;
# this script base64-encodes it and stores each secret via `gh`.
#
# Prerequisites:
#   - `gh` authenticated with admin on the repo (gh auth status)
#   - Two exported Developer ID certs as .p12 (Keychain Access > right-click the
#     identity > Export…), both protected with the SAME password.
#   - An App Store Connect API key: the AuthKey_XXXX.p8 plus its Key ID and
#     Issuer ID (App Store Connect > Users and Access > Integrations).
#
# Usage (all values via env):
#   APP_P12=DeveloperID_Application.p12 \
#   INSTALLER_P12=DeveloperID_Installer.p12 \
#   P12_PASSWORD='the-export-password' \
#   API_KEY_P8=AuthKey_494J62TB47.p8 \
#   API_KEY_ID=494J62TB47 \
#   API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
#   ./packaging/setup-ci-secrets.sh
set -euo pipefail

REPO="${REPO:-timschmolka/hush}"

die() { echo "error: $*" >&2; exit 1; }
need_file() { [[ -f "${!1:-}" ]] || die "\$$1 must point to an existing file (got '${!1:-}')"; }
need_val()  { [[ -n "${!1:-}" ]] || die "\$$1 must be set"; }

need_file APP_P12
need_file INSTALLER_P12
need_file API_KEY_P8
need_val  P12_PASSWORD
need_val  API_KEY_ID
need_val  API_ISSUER_ID

command -v gh >/dev/null || die "gh not found"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

echo "Repo: $REPO"

set_secret()      { echo "  - $1"; gh secret set "$1" -R "$REPO" -b "$2"; }
set_secret_b64()  { echo "  - $1 (base64 of $2)"; base64 -i "$2" | gh secret set "$1" -R "$REPO"; }

echo "Setting secrets:"
set_secret_b64 DEVELOPER_ID_APP_CERT_P12_BASE64       "$APP_P12"
set_secret_b64 DEVELOPER_ID_INSTALLER_CERT_P12_BASE64 "$INSTALLER_P12"
set_secret     CERT_P12_PASSWORD                      "$P12_PASSWORD"
set_secret_b64 NOTARY_API_KEY_P8_BASE64               "$API_KEY_P8"
set_secret     NOTARY_API_KEY_ID                      "$API_KEY_ID"
set_secret     NOTARY_API_ISSUER_ID                   "$API_ISSUER_ID"

# Random unlock password for the disposable CI keychain (only overwrite if unset).
if ! gh secret list -R "$REPO" | grep -q '^KEYCHAIN_PASSWORD'; then
  set_secret KEYCHAIN_PASSWORD "$(openssl rand -base64 24)"
fi

echo
echo "Done. Current secrets:"
gh secret list -R "$REPO"
echo
echo "Cut a release with:  git tag v1.0.1 && git push origin v1.0.1"
