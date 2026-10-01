# F3 bridge wiring — live validation evidence

F3 (passkey-proof bridge wiring): verify-then-release, nonce minting/re-minting,
head_sha passed to fm-pr-merge.sh as a required match, and the PR comment + chat
line naming the passkey and answer.

The artifacts here come from driving the REAL shipped product binaries
(bin/fm-today-bridge.sh, bin/fm-today-passkey-verify.py, the hold lifecycle) end
to end against a fixture home, a local python http.server stub portal, a stub gh
forge, and the software authenticator's real ES256 passkey signatures. External
forge/passkey/portal services are stubbed because no live GitHub account or
iCloud passkey credential is available in this environment; the product code
under change executes for real and its persisted state and outputs are captured.

- snapshot-1.json / scenario-1.txt : merge+go cards carry head_sha / subject_sha256,
  128-bit proof nonce + expires_at, and the passkeys block; nonce reused while unexpired.
- scenario-2.txt : verify-then-release; signed merge bound to the signed head
  (--head-sha), released with recorded words, PR comment + announce line naming
  passkey and answer; nonce re-minted after the verified merge; signed go released+announced.
- scenario-3.txt : a signed merge whose head moved is never merged and the call is
  re-raised with the new head and a fresh nonce (driven by the automated behavior
  suite plus a direct re-snapshot observation).
- The remainder of the required paths (replay=duplicate, unknown credential,
  expired nonce, no-active-credential refusal, enrolment left at the machine,
  signed-later fresh nonce, refused-merge re-raise incl. unreadable PR state) are
  driven end-to-end by tests/fm-today-bridge.test.sh against the same real product.
