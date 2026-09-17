# Live final-response packet validation

Each transcript came from a real installed harness running in the changed repository with its native project instructions loaded. The prompts deliberately put key facts in a pre-tool assistant message, then required a tool call, reproducing the reported failure shape.

## Pi — PR outcome after tool call

**Prompt facts:** fix prevents duplicate charges; targeted tests pass; PR `https://github.com/acme/payments/pull/42`.

**Pre-tool assistant message:**
> Captain, the duplicate-charge fix is ready for release: targeted tests pass. Recommend shipping https://github.com/acme/payments/pull/42.

**Tool and result:**
> `printf "verification complete\n"`
>
> `verification complete`

**Final assistant message:**
> Captain, recommend releasing this: the fix prevents duplicate charges, targeted tests pass, and verification is complete. PR: https://github.com/acme/payments/pull/42

Result: PASS — the final message repeats the outcome, recommendation, test status, and full PR URL.

## Claude Code — PR outcome and approval ask after tool call

**Prompt facts:** fix prevents duplicate charges; targeted tests pass; PR `https://github.com/acme/payments/pull/42`.

**Pre-tool assistant message:**
> Captain, my recommendation: ship it. The fix prevents duplicate charges, the targeted tests pass, and the PR is ready at https://github.com/acme/payments/pull/42.

**Tool and result:**
> `printf "verification complete\n"`
>
> `verification complete`

**Final assistant message:**
> Captain, recommendation: release it. The fix stops duplicate charges, targeted tests pass, and the PR is green and ready to merge at https://github.com/acme/payments/pull/42. Want me to merge?

Result: PASS — the final message repeats the outcome, consequence/readiness, full PR URL, and merge decision needed.

## Pi Signed — PR outcome after tool call

**Final assistant message:**
> Captain, recommend releasing. The fix stops duplicate charges, targeted tests pass, and the PR is https://github.com/acme/payments/pull/42.

Result: PASS — the signed Pi harness repeats the outcome, recommendation, test status, and full PR URL after the successful tool call.

## OpenCode — PR outcome after tool call

**Pre-tool assistant message:**
> Captain, the release fix prevents duplicate charges, targeted tests pass, and PR https://github.com/acme/payments/pull/42 is ready for release consideration.

**Tool and result:**
> `printf "verification complete\n"`
>
> `verification complete`

**Final assistant message:**
> Captain, recommend releasing PR https://github.com/acme/payments/pull/42: it prevents duplicate charges and targeted tests pass.

Result: PASS — the final message repeats the outcome, recommendation, test status, and full PR URL.

## Grok — regression and fixed behavior

The first live run against the submitted change reproduced the bug:

**Original final assistant message:**
> Verification complete. Recommend releasing PR 42.

This omitted the fix outcome, targeted-test result, and full PR URL. The test-phase fix added the same final-packet contract to Grok's native `GROK_BOT.md` instruction surface.

After the fix, the same Grok prompt and tool call produced:

**Fixed final assistant message:**
> Release recommendation: ship https://github.com/acme/payments/pull/42. Duplicate-charge fix is verified and targeted tests pass. Verification complete.

Result: PASS after fix — the final message now repeats the outcome, recommendation, test status, and full PR URL.

## Pi — non-PR decision packet with adversarial short ending

**Prompt facts:** backup completed; migration requires four minutes of read-only mode; approval needed to start at 22:00 UTC. The prompt required the final response to end with exactly `Awaiting your call.`

**Pre-tool assistant message:**
> Captain, backup completed. The migration requires four minutes of read-only mode. Approval is needed to start at 22:00 UTC.

**Tool and result:**
> `printf "preflight complete\n"`
>
> `preflight complete`

**Final assistant message:**
> Captain, backup completed. The migration requires four minutes of read-only mode. Approval is needed to start at 22:00 UTC.
> Awaiting your call.

Result: PASS — despite the required short trailing phrase, the final message still carries the outcome, consequence, timing, and approval needed.

## Codex environment limitation

A real Codex run emitted the pre-tool facts and a self-contained final packet, but its configured execution host refused the requested tool call:

> Code Mode is unavailable because code-mode host is disabled. Code mode will fail closed; enable `features.code_mode_host` and install `codex-code-mode-host`.

Codex final response:
> Captain, release [PR #42](https://github.com/acme/payments/pull/42). It prevents duplicate charges, and targeted tests pass. Shell verification could not run because the execution host is disabled.

Result: UNTESTED for the exact post-successful-tool regression because the host lacked the required code-mode execution capability.
