# marten-global-id

Generates and verifies HMAC-signed tokens that encode a `(model_class, pk)` tuple — a port of Rails' `GlobalID::Locator.locate_signed`. Use it when one endpoint needs to resolve to *any* of several models (e.g. a single markdown-upload endpoint that attaches files to whatever record owns the markdown).

Built on `Marten::Core::Signer` (HMAC-SHA256, Marten's `secret_key` by default).

## What this replaces

Rails ships [`GlobalID`](https://github.com/rails/globalid), which encodes a polymorphic record reference (`(class_name, pk)`) into a URI and optionally HMAC-signs it. The signed variant — `GlobalID::Locator.locate_signed(token, for: purpose)` — backs anything that needs to round-trip a record reference through user input: ActionText image uploads, ActiveJob's polymorphic arguments, signed link tokens, etc.

The wire format on the Rails side is:

```
SignedGlobalID  =  base64(JSON({c: "User", i: "3", p: "transfer"})) + "--" + HMAC-SHA256
```

`marten-global-id` ships the same idea with the same wire shape, plus one wrinkle: Crystal can't `constantize` a runtime string into a class (the class set is closed at compile time). So instead of letting any class get instantiated from a token, the host app registers an explicit allowlist of participating classes. Tokens that name a class not on the allowlist are rejected the same way an invalid signature is.

| Rails | marten-global-id |
|---|---|
| `record.to_global_id` | `record.global_id` |
| `record.to_signed_global_id(for: "x", expires_in: 1.hour)` | `record.signed_global_id(purpose: "x", expires_in: 1.hour)` |
| `GlobalID::Locator.locate_signed(token, for: "x")` | `MartenGlobalId.locate(token, purpose: "x")` |
| (implicit — any AR class) | `config.global_id.allowed_classes = [Foo, Bar]` |
| `GlobalID::Locator::InvalidSignedGlobalIDError` | (none — `locate` returns `nil` on any failure) |

## Installation

```yaml
# shard.yml
dependencies:
  marten_global_id:
    github: stevegeek/marten-global-id
```

```bash
shards install
```

```crystal
# src/project.cr (or wherever you wire deps)
require "marten_global_id"
```

## Configure

Register the participating classes from your host app's settings — this is the runtime allowlist the locator consults when resolving a token:

```crystal
# config/settings/base.cr
Marten.configure do |config|
  config.global_id.allowed_classes = [
    MyApp::Book,
    MyApp::Markdown,
    MyApp::Leafables::Page,
  ]
end
```

The list defaults to empty. Until you populate it, `MartenGlobalId.locate` will reject every token (class not registered).

## Usage

Include the mixin on any model whose instances need to issue tokens:

```crystal
class MyApp::Book < Marten::Model
  include MartenGlobalId::ModelMixin

  field :id, :big_int, primary_key: true, auto: true
  field :title, :string, max_size: 64
end
```

Sign on the issuing side:

```crystal
token : String = book.signed_global_id(purpose: "markdown_upload", expires_in: 1.hour)
# => "eyJjI...--abc123..."
```

Or the class-method form, if you don't want the mixin:

```crystal
token : String = MartenGlobalId.sign(book, purpose: "markdown_upload", expires_in: 1.hour)
```

Locate on the receiving side:

```crystal
record : Marten::DB::Model? = MartenGlobalId.locate(token, purpose: "markdown_upload")
# => nil on any rejection
```

`locate` accepts a `String?` token so handlers can pipe `params["token"]?`
straight through without an extra nil guard.

The receiving side gets back a `Marten::DB::Model?`. Cast or pattern-match to the concrete class you expect:

```crystal
case record = MartenGlobalId.locate(token, purpose: "markdown_upload")
when MyApp::Book          then attach_to_book(record)
when MyApp::Leafables::Page then attach_to_page(record)
else
  render_404
end
```

### Unsigned global ids

The mixin also exposes `record.global_id` (Rails' `to_global_id`), an *unsigned* `gid://marten/<class>/<pk>` URI. Use it for cache keys or internal comparisons. Both segments are URL-encoded, so namespaced class names round-trip through `URI.parse`:

```crystal
book.global_id            # => "gid://marten/MyApp%3A%3ABook/3"
URI.parse(book.global_id) # => parsable, host="marten", path="/MyApp%3A%3ABook/3"
```

**Don't accept unsigned gids from the outside world.** They're not tamper-resistant. Use `signed_global_id` for anything that round-trips through user input.

## Rejection paths

`MartenGlobalId.locate` returns `nil` for every failure mode (no exceptions, no opaque signalling — the caller decides what each `nil` means in context). The cases:

1. **Bad signature** — token was tampered with, or signed with a different secret.
2. **Expired** — `expires_in` elapsed before the token was redeemed.
3. **Purpose mismatch** — token was issued with `purpose: "transfer"`, redeemed with `purpose: "password_reset"`.
4. **Class not in allowlist** — token names a class the host didn't register via `config.global_id.allowed_classes`.
5. **Record not found** — the record was deleted (or never existed) between sign and locate.
6. **Malformed payload** — a holder of the signing key hand-built a payload with the wrong shape (e.g. `"i"` is a number, `"p"` is null, the `_marten` `expires` field isn't ISO-8601). Reachable only if the signing key is in the wrong hands; still collapses to `nil` so the contract holds.
7. **Abstract model class in the allowlist** — included in case a host registers a base model by accident; the class is treated as "not registered".

These all collapse to `nil`. If you need to distinguish expired-vs-invalid for UX (e.g. "this link has expired, request a new one"), you'll need to wrap `MartenGlobalId.sign` / unsign at the call site — out of scope for the shard.

**Sign-side errors that are *not* swallowed:** `MartenGlobalId.sign` raises `MartenGlobalId::Error` if you hand it an unpersisted record (there's no stable pk to encode). Same for `MartenGlobalId.to_global_id`. Other than that, both methods only raise if the underlying `Marten::Core::Signer` does (which shouldn't happen with a valid `secret_key`).

## Purpose scoping

`purpose:` acts as a domain separator. A token issued for `"markdown_upload"` cannot be redeemed with `purpose: "session_transfer"` even though both use the same signing key. This prevents tokens leaked from one flow being reused in another.

`purpose:` is **required** on both `sign` and `locate` — there is no implicit default, because issuing a token without thinking about which flow it belongs to is the canonical way to ship a cross-flow replay bug. Single-flow apps should still pass something meaningful (`purpose: "default"`, `purpose: "<app-name>"`, etc.). The constant `MartenGlobalId::PURPOSE_DEFAULT == "default"` is exposed for callers who want Rails parity:

```crystal
MartenGlobalId.sign(book, purpose: MartenGlobalId::PURPOSE_DEFAULT)
```

## Expiry

`expires_in:` accepts any `Time::Span`. Omit for non-expiring tokens (use sparingly — anything user-redeemable should have an expiry).

```crystal
book.signed_global_id(purpose: "markdown_upload", expires_in: 1.hour)
book.signed_global_id(purpose: "magic_link",      expires_in: 15.minutes)
book.signed_global_id(purpose: "permanent_token")
```

## What's in the token (confidentiality)

Signed tokens are **tamper-resistant, not confidential**. The payload is HMAC-signed but **not encrypted** — any holder of the token can Base64-decode the first half and recover the `(class_name, pk, purpose)` tuple in plaintext:

```
echo "eyJjI...--abc123..." | cut -d'-' -f1 | base64 -d
# => {"c":"User","i":"42","p":"password_reset"}
```

This matches Rails' `SignedGlobalID` and is fine for most uses, but it means **anywhere a signed token can be observed, the encoded record reference is observable too**:

- A signed reset link emailed to a user discloses the user's primary key and the model class name to anyone who reads the email — including any MTA hop in transit, the user's mail client, an attacker who later phishes the mailbox, etc.
- Browser history, HTTP referrer leaks, web server access logs, third-party analytics that capture URLs — all expose the same data.
- The `purpose` string is also visible — useful reconnaissance for an attacker (it tells them which flow the token was minted for).

If you need confidentiality (the *contents* of the token must stay opaque), don't use signed gids for the transport. Options:

- Issue an opaque server-side token (random bytes, looked up in a database row that owns the `(class, pk, purpose, expires_at)` record) instead. This is what most password-reset / magic-link flows actually want.
- Pre-encrypt the payload yourself before signing if you must use this shard's wire format.

## Key rotation

`Marten::Core::Signer` takes a single signing key (`Marten.settings.secret_key`). Rotating that key **invalidates every outstanding signed gid in flight** — anything mailed out as a password-reset link, magic link, signed callback URL, etc. will stop verifying the moment the key flips. Plan rotations around the longest-lived token you've issued (the `expires_in` you pass to `sign`):

- If your longest signed-gid TTL is 1 hour, schedule a window where the old key keeps running for at least that long after you mint the last token with it.
- If you need overlapping-key rotation (Rails' `MessageVerifier#rotate("old_secret")`), this shard doesn't provide it — `Marten::Core::Signer` only knows one key at a time. You'd need to either (a) keep TTLs short enough that "rotate + wait for TTL" is acceptable, or (b) wrap the signer call site to try the old key on `nil` returns during a rotation window.

## How it works

1. `sign(record, purpose:, expires_in:)` builds a JSON payload `{"c": "<class>", "i": "<pk>", "p": "<purpose>"}`, plus an optional absolute expiry timestamp.
2. The payload is signed via `Marten::Core::Signer#sign(value, expires:)` — HMAC-SHA256 with Marten's `secret_key`. The signer Base64-encodes the payload and appends an HMAC digest separated by `--`.
3. `locate(token, purpose:)` unsigns the token (rejecting tampered or expired ones), parses the JSON, verifies the purpose matches, looks up the class name in `config.global_id.allowed_classes`, and (if found) does a regular `klass.get(pk: id)` to materialise the record.

### Wire format

- Signed: `base64(JSON({"c","i","p"}))` (+ an optional `_marten` envelope carrying the expiry timestamp) + `"--"` + `HMAC-SHA256` hex digest.
- Unsigned (`to_global_id` / `record.global_id`): `gid://marten/<URL-encoded class name>/<URL-encoded pk>`. Both segments are URL-encoded so namespaced class names (`Foo::Bar` -> `Foo%3A%3ABar`) and pks containing reserved URI characters round-trip through `URI.parse`.

## Relationship to marten-signed-id

[`marten-signed-id`](https://github.com/stevegeek/marten-signed-id) is the single-class variant — when the receiving side knows the model class at compile time (`User.find_signed(token)`), it doesn't need to encode the class name in the token. Use that one for password-reset / magic-link / invitation flows.

`marten-global-id` is the polymorphic variant — when the receiving side doesn't know the class until the token is decoded (e.g. one markdown-upload endpoint serving many record types). Both shards share the same `Marten::Core::Signer` substrate; the difference is whether the class identity is part of the signed payload.

## License

MIT
