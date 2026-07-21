#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SPARSE_PATHS=(
  src
  runtime/lua
  manifest.xml
  manifest.cfg
)

resolve_default_branch() {
  local repo_url="$1"
  git ls-remote --symref "${repo_url}" HEAD | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }'
}

ensure_clean_checkout() {
  local target_dir="$1"
  if [[ -n "$(git -C "${target_dir}" status --porcelain)" ]]; then
    echo "Refusing to update ${target_dir}: local changes detected." >&2
    exit 1
  fi
}

sync_checkout() {
  local label="$1"
  local repo_url="$2"
  local target_dir="$3"
  local default_branch

  default_branch="$(resolve_default_branch "${repo_url}")"
  if [[ -z "${default_branch}" ]]; then
    echo "Failed to resolve default branch for ${repo_url}." >&2
    exit 1
  fi

  if [[ -e "${target_dir}" && ! -d "${target_dir}/.git" ]]; then
    echo "Refusing to use ${target_dir}: it exists but is not a git checkout." >&2
    exit 1
  fi

  if [[ -d "${target_dir}/.git" ]]; then
    ensure_clean_checkout "${target_dir}"
  else
    git clone --filter=blob:none --no-checkout "${repo_url}" "${target_dir}"
  fi

  git -C "${target_dir}" remote set-url origin "${repo_url}"
  git -C "${target_dir}" sparse-checkout init --cone >/dev/null 2>&1 || true
  git -C "${target_dir}" sparse-checkout set --skip-checks "${SPARSE_PATHS[@]}"
  git -C "${target_dir}" fetch --depth=1 origin "${default_branch}"
  git -C "${target_dir}" checkout --force -B local-dev-sync FETCH_HEAD

  echo "${label}: $(git -C "${target_dir}" rev-parse --short=12 HEAD)"
}

cd "${REPO_ROOT}"

sync_checkout "PoE1" "https://github.com/PathOfBuildingCommunity/PathOfBuilding.git" "${REPO_ROOT}/PathOfBuilding"
sync_checkout "PoE2" "https://github.com/PathOfBuildingCommunity/PathOfBuilding-PoE2.git" "${REPO_ROOT}/PathOfBuilding-PoE2"
