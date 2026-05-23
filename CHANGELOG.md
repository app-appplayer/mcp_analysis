## [0.1.1] - 2026-05-23 - mcp_bundle 0.4.0 cascade

### Changed (cascade)
- `mcp_bundle` caret bumped from `^0.3.0` to `^0.4.0`. mcp_analysis does not touch `UiSection.pages` directly, so this release is a caret-only cascade. Consumers should bump to `^0.1.1`.

## [0.1.0] - 2026-04-28 - Initial Release

### Added
- Spec subsystem — validator, parameter resolver, spec manager.
- Artifact subsystem — builder, store, provenance tracker.
- Execution subsystem — execution engine, batch / ad-hoc / stream executors, job manager, retry policy, step logger.
- DataSource subsystem with pluggable adapters for multi-source integration.
- Pluggable analysis functions and transforms.
- Alert evaluation.
- MCP integration via tools.
- Standard port adapter implementing `mcp_bundle` analysis Contract Layer.
