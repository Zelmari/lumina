## Summary

-

Call out user-visible behavior and config-key changes.

## Test plan

- [ ] `swift test --filter LuminaLayoutTests`
- [ ] `swift test --filter LuminaIPCTests`
- [ ] `scripts/harness.sh` (macOS agent, menu extra, or CLI changes)

Note anything CI cannot see. The Linux workflow does not build the macOS targets and does not run the harness.
