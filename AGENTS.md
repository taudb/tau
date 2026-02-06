# Tau Agent Guide

## Scope

This file applies to the entire repository.

## Build And Test

- Run `zig build` after code changes that touch executable targets.
- Run `zig build test` before finishing code changes.
- For docs/workflow-only changes, run targeted validation (for example `zig build` or `podman build`) when relevant.

## Command Surface

- Prefer snake_case names in user-facing docs and examples.
- Keep compatibility aliases where they prevent breaking existing scripts.

## Release Expectations

- Release artifacts should include `server`, `repl`, `bench`, and `sim` by default.
- Optional release modes (for smaller bundles) must remain clearly documented.

## Profiling

- Use `zig build profile_bench`, `zig build profile_sim`, or `zig build profile_server` for reproducible local profiling runs.
- Save generated profiling outputs under `profiles/` (already gitignored).
