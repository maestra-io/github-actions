#!/usr/bin/env bash
#
# Create an ECR repository whose release tags can never be overwritten.
#
# WHY. On 2026-10-09 GitLab re-minted release numbers after a restore and CI
# silently OVERWROTE already-released images in MUTABLE repositories; only a
# later check caught the collision. That day every app repository in
# 515260921971 / us-west-2 was flipped to IMMUTABLE_WITH_EXCLUSION, so a
# repository created here must not reopen the hole.
#
# Re-pushing the IDENTICAL image to an existing tag still succeeds (ECR answers
# 201, verified on a throwaway repository); a DIFFERENT image is rejected with
# TAG_INVALID. Only `latest` stays overwritable: it is the one moving tag the
# callers push (or mirror) today. These actions do not cosign-sign, so the
# `sha256-*` exclusion the live repositories also carry is not needed here.
#
# A runner whose aws-cli predates the exclusion filters (an old self-hosted
# image) gets a plain create plus a workflow WARNING that the repository stayed
# MUTABLE, rather than a red release. Every other failure is fatal.
#
# Usage: create-repository.sh <repository> [extra aws args, e.g. --region X]
set -euo pipefail

repo="$1"
shift

if err=$(aws ecr create-repository --repository-name "$repo" "$@" \
      --image-tag-mutability IMMUTABLE_WITH_EXCLUSION \
      --image-tag-mutability-exclusion-filters 'filterType=WILDCARD,filter=latest' \
      2>&1 >/dev/null); then
  echo "Created ECR repository ${repo} (IMMUTABLE_WITH_EXCLUSION)"
  exit 0
fi

case "$err" in
  *"Unknown options"*|*"Unknown parameter"*)
    echo "::warning::$(aws --version 2>&1) cannot create ${repo} with tag-immutability exclusions, so it is created MUTABLE. Flip it by hand: aws ecr put-image-tag-mutability --repository-name ${repo} --image-tag-mutability IMMUTABLE_WITH_EXCLUSION --image-tag-mutability-exclusion-filters ..."
    aws ecr create-repository --repository-name "$repo" "$@" >/dev/null
    ;;
  *)
    echo "$err" >&2
    exit 1
    ;;
esac
