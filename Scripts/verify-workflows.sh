#!/bin/bash
# Actual cleanup/restore entry points, restricted to a fresh, private fixture home.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d /tmp/sweep-workflows.XXXXXX)
FIXTURE_HOME=$(mktemp -d /Users/Shared/sweep-workflow.XXXXXX)
trap 'rm -rf "$WORK" "$FIXTURE_HOME"' EXIT
swiftc -swift-version 6 -O -o "$WORK/verify-workflows" \
    Sweep/Models/*.swift Scripts/verify-workflows.swift
HOME="$FIXTURE_HOME" CFFIXED_USER_HOME="$FIXTURE_HOME" \
    SWEEP_WORKFLOW_HOME="$FIXTURE_HOME" "$WORK/verify-workflows"
