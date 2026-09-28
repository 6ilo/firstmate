# Today contract, version 1

Today is the admin portal's control centre for the captain, and it replaces the bearings board.
This page is the single owner of the contract between firstmate and the portal: the four published shapes, how they travel, how the bridge authenticates, what may leave the captain's machine, and how the contract changes.
The machine-checkable shapes live in [`today-contract/`](today-contract/) as JSON Schema draft 2020-12 documents.

| Schema constant | File | Direction |
| --- | --- | --- |
| `fm-today-snapshot.v1` | [`fm-today-snapshot.v1.schema.json`](today-contract/fm-today-snapshot.v1.schema.json) | firstmate to portal |
| `fm-today-card.v1` | [`fm-today-card.v1.schema.json`](today-contract/fm-today-card.v1.schema.json) | firstmate to portal, inside the snapshot |
| `fm-today-answer.v1` | [`fm-today-answer.v1.schema.json`](today-contract/fm-today-answer.v1.schema.json) | portal to firstmate |
| `fm-today-receipt.v1` | [`fm-today-receipt.v1.schema.json`](today-contract/fm-today-receipt.v1.schema.json) | firstmate to portal |

Every document names its shape in its `schema` field.
Valid and invalid example documents for every shape live in [`today-contract/examples/`](today-contract/examples/).
[`tests/fm-today-contract.test.sh`](../tests/fm-today-contract.test.sh) checks every example, and [`tests/fm-today-contract-check.py`](../tests/fm-today-contract-check.py) is a standard-library reference implementation of the schema check, `card_hash`, and the passkey challenge.

## Who owns what

Firstmate stays the truth for every call.
The portal shows calls and carries answers; firstmate alone records, merges, or closes a call.
Every kind of answer may be given from the portal, and the merge word and the go to build also carry the captain's passkey signature, which firstmate checks itself.
Every answer gets exactly one receipt from firstmate.
A note sent with an answer carries no authority: firstmate records it as the captain's words and never acts on it as an instruction.

## Travel

A bridge on the captain's machine sends the fleet's snapshot out and long-polls the portal for answers.
Nothing ever calls into the captain's machine: every connection is opened by the bridge, outward, to the portal.
The portal has no address for the captain's machine and never needs one.

The bridge calls exactly two endpoints on the portal.

| Method and path | Request body | Success response |
| --- | --- | --- |
| `POST /api/fleet/snapshot` | one `fm-today-snapshot.v1` document, at most 512 KiB | `200` with the portal's `heard_at` stamp |
| `POST /api/fleet/answers` | `{"receipts": [<fm-today-receipt.v1>...], "wait_seconds": <0-25>}` | `200` with `{"answers": [<fm-today-answer.v1>...]}` |

**Snapshot.**
The portal refuses a body over 512 KiB with `413` before reading further, and a body that fails the snapshot schema with `400`.
It keeps the newest snapshot by `generated_at` and answers `409` to one older than the snapshot it holds, such as a delayed retry.
Each snapshot replaces the previous one whole; there are no partial updates.
The time the portal last accepted a snapshot is the portal's own `heard_at` stamp, returned in the `200` body; the bridge reads nothing else from that body.
An error body is `{"code", "message", "request_id"}`, and a `400` lists at most the paths of the failing fields, never their values, which may be call text.

**Answers and receipts.**
One call does both jobs.
The portal first stores every receipt in the request, ignoring any whose `answer_id` it does not know, and treats each stored receipt as closing its answer.
It then returns, oldest `answered_at` first, every answer that has no receipt yet.
When there is none, it holds the request open for up to `wait_seconds` and returns as soon as one arrives, or returns `{"answers": []}` when the wait ends.
An answer is delivered again on every call until its receipt arrives, so delivery is at least once.
Firstmate recognizes a repeated `answer_id` and replies `duplicate`, so a repeat never acts twice.
The portal validates every answer against the answer schema before it becomes deliverable.

**Authentication.**
Both calls send `Authorization: Bearer <token>`.
The token lives only in the main firstmate home's gitignored `.env`, as `FM_TODAY_BRIDGE_TOKEN`.
The portal stores only the token's SHA-256 digest, as lowercase hex, in `FLEET_BRIDGE_TOKEN_SHA256`.
The portal hashes the presented token and compares the two digests in constant time, answering `401` on any mismatch, a missing header, another scheme, or a missing or malformed configured digest.
One token serves both endpoints, and rotating it means writing a new token into `.env` and its digest into the portal together.

## The snapshot

The snapshot is the whole fleet as Today shows it: every piece of the fleet's work, the main home and every secondmate home together.
Its top level carries `generator_version` (the bridge's version), `generated_at` (UTC), `home` (the label of the home the bridge runs in, as bearings labels it), and `sections`.
Where a fact already exists in the bearings snapshot (`bin/fm-bearings-snapshot.sh`) or the `fm-bearings-board.v1` payload (`bin/fm-bearings-board.sh`), the field keeps that name and meaning.

| Section | Rows | Meaning |
| --- | --- | --- |
| `calls` | `fm-today-card.v1` | Every open captain call, each once; at most 200. |
| `underway` | `id`, `title`, `kind`, `state`, `doing`, optional `repo`, `owner`, `pr_url` | Work being done now, as the board's Underway: `title` is the task title or its id, and `pr_url` its open pull request. |
| `charted_next` | `id`, `title`, `reason`, `dispatchable`, optional `repo`, `kind`, `filed`, `blocked_by`, `owner` | Work filed but not started, as the board's Charted Next; `kind` is `queued` or `warning`, and a `warning` row is never dispatchable. |
| `landed` | `id`, `title`, `owner`, optional `repo`, `pr_url`, `landed_at`, `subject` | Recently finished work, as the board's landed rows; `owner` is `(main)` or the secondmate home that recorded it. |
| `health` | `supervision`, `unhealthy[]` | `supervision` is `live`, `lapsed`, or `unknown`; each unhealthy row is a worker id with `endpoint_exists` and `agent_alive` (`null` when unknown), as bearings' unhealthy endpoints without their machine detail. |
| `boards` | `owner_task`, `state`, `round`, `last_changed`, `link` | Open review boards: the owning task, `listening`, `round-open`, or `owner-gone`, the count of captured rounds, when the board last changed, and its local address on the captain's machine. |
| `day` | `date`, `ends_at`, `blocks[]` of `id`, `title`, `starts_at`, `ends_at` | The captain's calendar for one day, as the board's Today lane: `ends_at` is the instant the day is over in the captain's own time zone, each block's `id` is stable across snapshots, and its times are instants with an explicit UTC offset, ending at or after they start; at most 200 blocks. |

`repo` is `owner/name`, and absent when the work has no repository.
Every work `id` appears once across `underway`, `charted_next`, and `landed`, and the three hold at most 1000 rows together.
Every other timestamp in the contract is UTC with a `Z` suffix.
A board's `link` opens only where the captain's private network reaches the captain's machine.

Underway and Charted Next rows may also carry optional fields that the backlog will record when work is filed.
Their absence means firstmate has not recorded the fact, never that the answer is none.

| Field | Values |
| --- | --- |
| `size` | `S`, `M`, `L`, `XL` |
| `urgency` | integer 0 to 4, 0 the most urgent, as the backlog's priority |
| `type` | `ship`, `scout`, `docs`, `fix`, `upkeep` |
| `waits_on` | up to 20 of `{"kind": "work" or "call", "ref"}` or `{"kind": "event", "ref", "label"}`: `ref` is the work or call id, or the outside event's own id, and `label` names the event |
| `order` | Charted Next only: integer 0 to 100000, the dispatch order, 0 first |

## The card

A card is one captain call exactly as the portal shows it.
Firstmate composes every card; the portal renders it and never edits it.

| Field | Meaning |
| --- | --- |
| `task_id` | The held task's id; the key of the call. |
| `kind` | `decision`, `merge`, `credential`, or `go`. |
| `title`, `question` | The call's heading and its full question; `question` may span lines. |
| `options` | Up to 12 `{value, label, hint?, recommended}`, in the order shown; at most one is recommended, values are unique, and none is `later`. |
| `repo` | `owner/name`, absent when the call has no repository. |
| `pr_url` | The pull request a call is about; required on a `merge` card. |
| `due` | The date the call must be settled by, `YYYY-MM-DD`. |
| `text_check` | `verdict` (`pass` or `withheld`), `checker` (`name@x.y.z`), and `checked_at`. |
| `card_hash` | The hash of the card as shown, defined below. |

A `withheld` verdict means the check refused the call's own words, and firstmate replaced the title, question, and every option label and hint with neutral text of its own; the portal should tell the captain to read the call on the machine.
Every card carries at least one option except a `credential` card, which carries none and is answered only `seen` or `later`: the portal never holds, asks for, or creates a key.
A decision card may carry a `reconcile` option, meaning "already settled, re-check", with the meaning [`captain-hold-lifecycle.md`](captain-hold-lifecycle.md) gives it.

**`card_hash`.**
Take the card's `schema`, `task_id`, `kind`, `title`, `question`, `options`, `repo`, `pr_url`, and `due` fields, leaving out any optional field the card does not carry.
Serialize that object with the JSON Canonicalization Scheme, RFC 8785: keys sorted, no whitespace, strings in UTF-8 with only the escapes RFC 8785 requires.
`card_hash` is the SHA-256 of those bytes, as 64 lowercase hex characters.
`text_check` and `card_hash` are left out, so re-running the check or re-sending the snapshot does not change the hash of an unchanged call.
Every hashed value is a string, boolean, null, array, or object, so no number serialization rule is involved.

## The answer

An answer is what the portal sends back for one card.

| Field | Meaning |
| --- | --- |
| `answer_id` | The portal's id for this answer, 8 to 64 of `A-Z a-z 0-9 _ -`; the key for receipts and duplicates. |
| `task_id`, `kind` | Copied from the card answered. |
| `value` | One option value from the card, or `later`; on a `credential` card, `seen` or `later`. |
| `later_until` | Required with `later` and allowed only with it: when to ask again, UTC. |
| `note` | Optional words, up to 512 characters; firstmate also refuses more than 512 UTF-8 bytes. |
| `card_hash` | The `card_hash` of the card as the person saw it. |
| `answered_at` | When the person answered, UTC. |
| `person`, `device` | The portal's ids for who answered and on which device. |
| `passkey` | Required on `merge` and `go` answers and forbidden on the others. |

**The passkey challenge.**
Join these seven strings with a single line feed, with no trailing line feed: the literal `fm-today-passkey.v1`, `answer_id`, `task_id`, `kind`, `card_hash`, `value`, and `later_until` or the empty string when absent.
The WebAuthn challenge is the 32-byte SHA-256 of that UTF-8 text, so the signature binds this answer, this option, and this card as shown.
None of those fields can contain a line feed, so the joined text is unambiguous.
The `note` is not signed.

**The passkey assertion.**
`passkey` carries `credential_id`, `authenticator_data`, `client_data_json`, and `signature`, each base64url without padding, exactly as the browser's assertion returned them.
Firstmate accepts the signature only when all of these hold:

- `credential_id` names a public key firstmate holds for the captain.
- `client_data_json` has `type` `webauthn.get`, a `challenge` equal to the base64url of the derived challenge, and the portal's `origin`.
- `authenticator_data` carries the portal's relying-party id hash and has the user-present and user-verified flags set.
- `signature` verifies over `authenticator_data` followed by the SHA-256 of `client_data_json`.

## The receipt

Firstmate sends one receipt per answer, through the next answers call.

| `outcome` | Meaning |
| --- | --- |
| `applied` | The answer was recorded for the call through firstmate's own hold lifecycle. |
| `set-aside` | The call changed after it was shown: `current_card_hash` is the hash of the call as it stands, and the call is asked again in the next snapshot. |
| `refused` | The answer was not taken, and `reason` says why, such as a call that is no longer open, a value the card did not offer, or a signature that did not verify. |
| `duplicate` | This `answer_id` was already received; nothing further happened. |

Every receipt also carries `answer_id`, `task_id`, and `recorded_at`.

## Rules the schemas cannot state

The reference checker enforces these beside the schemas:

- Every `card_hash` recomputes from its card.
- Option values are unique within a card, and a call appears once in a snapshot.
- A work id appears once across the three work sections, which hold at most 1000 rows together.
- Each day block's `id` is unique, its `starts_at` and `ends_at` name real instants (not, say, February 30), and its `ends_at` is at or after its `starts_at`.
- A passkey assertion's `client_data_json` carries the challenge derived from its answer.

## Privacy

- Everything the portal receives through this contract lives in captain-only tables, enforced on the server, never shown to staff.
- The text of a call leaves the captain's machine only as a card, after firstmate's text check.
- Every other free-text field in a snapshot passes the same check before the bridge sends it.
- No document ever carries learner, family, fee, or legal detail.
- A board row carries no board title or body, only the fields listed above.
- Calendar titles appear only in the `day` section, and a day block carries only its id, times, and title.
- The portal deletes block titles once the day's `ends_at` has passed, and stores none from a day already over.
- Every shape is closed: a field this page does not define fails validation, so a task body, path, host, or attendee list cannot ride along.

## Alignment with the portal's draft

relay-platform built its first slice against internal draft shapes before v1 was published, and the draft expects to change to match v1.
Where the draft already named or shaped a fact, v1 takes its shape: work titles, `waits_on`, `order`, `landed_at`, `pr_url` on work, an absent rather than null `repo`, a credential card with no options, the day's `ends_at` and blocks as instants with ids, the limits, the snapshot path, and its status codes.
These differences are deliberate:

| v1 | Draft | Reason |
| --- | --- | --- |
| `schema` naming the shape | `contract` and `version` | Every shape names itself in one field, and the version is part of that name. |
| `generated_at` | `sent_at` | The bearings snapshot's name for when the snapshot was built. |
| `home` | - | The home the bridge runs in; the fleet spans the main home and every secondmate home. |
| `sections` with `underway`, `charted_next`, `landed` | one `work` array with `state` | Each state carries facts the others lack, such as `doing`, `reason` and `dispatchable`, or `subject`, and each section is closed to the others' fields; the section name gives the draft's `state`. |
| `health`, `boards` | - | Today shows supervision health and open review boards. |
| Card `task_id` | Call `id` | The key is the held task's id, under the same name in the answer and the receipt. |
| Option `value` | Option `id` | The answer carries it back as `value`, beside the reserved `later`. |
| Card `schema`, `question`, `hint`, `repo`, `pr_url`, `due`, `text_check` | - | The full call as shown, and the proof that its text was checked before it left. |
| Kind `go` | - | The go to build is signed with the captain's passkey, like the merge word. |
| `size`, and Underway and Charted Next's bearings fields | - | Recorded by firstmate when it files the work, or already on the bearings board. |
| Tighter limits | Wider limits | Task ids are at most 128 characters without `:` or `/`, titles at most 200, and timestamps outside the day are UTC; each still fits the draft's limit. |
| An `event` wait requires `label` | Optional | An unnamed outside event tells the captain nothing. |
| Answers, receipts, and `POST /api/fleet/answers` | - | The draft covers the snapshot only. |

## Versioning

This is version 1, and every schema constant ends in `.v1`.
An additive change keeps v1: a new optional field whose absence keeps today's meaning.
Because the shapes are closed, the receiving side adopts the new schema before the sending side starts sending the field.
Anything else is v2: a new required field, a removed or renamed field, a new enum value, a changed type, pattern, or meaning, or any change to how `card_hash` or the passkey challenge is computed.
A v2 shape gets new `.v2` schema constants beside the v1 files, and both sides accept both versions until the change is complete.
