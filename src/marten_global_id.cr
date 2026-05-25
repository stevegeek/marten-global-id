require "marten"
require "json"
require "uri"

require "./marten_global_id/configuration"
require "./marten_global_id/model_mixin"

# Port of Rails' `GlobalID::Locator.locate_signed` for Marten. Encodes a
# `(model_class_name, pk)` tuple inside an HMAC-signed token so a single
# endpoint can resolve to *any* of the host app's models without knowing
# the concrete class at compile time.
#
# Rails relies on `String.constantize` to turn the class-name in the token
# back into a class at runtime. Crystal's class set is closed at compile
# time, so the host app must register an explicit allowlist of classes
# that participate. The allowlist also doubles as a safety boundary: a
# tampered token that names some other model class is rejected the same
# way a bad signature is.
#
# Usage:
#
# ```
# # 1. Register participating classes from the host app's settings:
# Marten.configure do |config|
#   config.global_id.allowed_classes = [
#     MyApp::Book,
#     MyApp::Markdown,
#     MyApp::Leafables::Page,
#   ]
# end
#
# # 2. (Optional) Include the mixin on models that issue tokens:
# class MyApp::Book < Marten::Model
#   include MartenGlobalId::ModelMixin
# end
#
# # 3. Sign + locate:
# token = book.signed_global_id(purpose: "markdown_upload", expires_in: 1.hour)
# MartenGlobalId.locate(token, purpose: "markdown_upload") # => MyApp::Book?
# ```
#
# `purpose:` is required on both `sign` and `locate` — there is no
# implicit default. Pass `purpose: MartenGlobalId::PURPOSE_DEFAULT` for
# Rails parity if you really want it. See the README's "Purpose
# scoping" section.
#
# **Confidentiality:** signed tokens are tamper-resistant but **not
# encrypted** — the `(class, pk, purpose)` triple is recoverable by
# anyone who sees the token (mail logs, browser history, referrer
# leaks, etc.). Use opaque server-side tokens if confidentiality
# matters. See the README's "What's in the token" section.
#
# Built on `Marten::Core::Signer` (HMAC-SHA256, Marten's `secret_key` by
# default).
module MartenGlobalId
  VERSION = "0.1.0"

  # Mirrors Rails' `SignedGlobalID::DEFAULT_PURPOSE`. Available as an
  # explicit opt-in for callers who want Rails parity — `purpose` is
  # **required** on `sign` and `locate` (no implicit default) precisely
  # because issuing or accepting a token without thinking about which
  # flow it belongs to is a footgun. Pass `purpose: MartenGlobalId::PURPOSE_DEFAULT`
  # if you really want the Rails default.
  PURPOSE_DEFAULT = "default"

  # Raised by `sign` for caller-visible failure modes that aren't
  # appropriate to silently swallow (e.g. attempting to sign an
  # unpersisted record). `locate`'s rejection modes still all collapse
  # to `nil`.
  class Error < Exception; end

  # Sign a `(class_name, pk)` tuple with HMAC + optional expiry, namespaced
  # by `purpose`. Mirrors Rails `SignedGlobalID#to_s` (which calls
  # `verifier.generate(uri, purpose:, expires_at:)`).
  #
  # Raises `MartenGlobalId::Error` if `record` has not been persisted
  # (i.e. `record.pk` is `nil`) — there is no stable identifier to put
  # in the token.
  #
  # Raises `ArgumentError` if `purpose` is blank (a forgotten
  # interpolation would otherwise produce a token redeemable by any
  # other code path that also forgot — same footgun as the implicit
  # default purpose). Matches sister shard `marten-signed-id`.
  #
  # Raises `ArgumentError` if `expires_in` is non-positive — a negative
  # or zero expiry produces a token that's expired the instant it's
  # minted, which is almost certainly a bug. Use `nil` for "no expiry".
  def self.sign(
    record : Marten::DB::Model,
    *,
    purpose : String,
    expires_in : Time::Span? = nil,
  ) : String
    raise ArgumentError.new("purpose must be non-blank") if purpose.blank?
    raise ArgumentError.new("expires_in must be positive") if expires_in && !expires_in.positive?

    pk = record.pk
    raise Error.new("Cannot sign an unpersisted record (#{record.class.name})") if pk.nil?

    payload = {"c" => record.class.name, "i" => pk.to_s, "p" => purpose}.to_json
    expires = expires_in.try { |span| Time.utc + span }
    signer.sign(payload, expires: expires)
  end

  # Build the unsigned wire-format string for a record. Equivalent to
  # Rails' `record.to_global_id.to_s` — a `(class_name, pk)` URI without
  # an HMAC. Useful for stable cache keys or comparisons; **not** safe to
  # accept from the outside world. Prefer `sign` for anything that
  # round-trips through user input.
  #
  # Wire format: `gid://marten/<url-encoded class name>/<url-encoded pk>`.
  # Both segments are URL-encoded so the result round-trips through
  # `URI.parse` even for namespaced classes (`Foo::Bar` -> `Foo%3A%3ABar`)
  # or pks containing reserved URI characters.
  def self.to_global_id(record : Marten::DB::Model) : String
    pk = record.pk
    raise Error.new("Cannot build a global_id for an unpersisted record (#{record.class.name})") if pk.nil?

    "gid://marten/#{URI.encode_path_segment(record.class.name)}/#{URI.encode_path_segment(pk.to_s)}"
  end

  # Verify + decode a signed token, returning the resolved record (or nil
  # on any failure: bad signature, expired token, malformed payload,
  # purpose mismatch, class not in the allowlist, abstract class in the
  # allowlist, record no longer exists). Mirrors Rails'
  # `GlobalID::Locator.locate_signed`.
  #
  # Documented contract: never raises. All known failure modes from
  # `Marten::Core::Signer#unsign` (`Time::Format::Error` on a malformed
  # `expires` field, `TypeCastError` on a malformed embedded value) are
  # caught and translated to `nil`. Same for `as_s?` on payload fields
  # that are present but not strings.
  def self.locate(token : String?, *, purpose : String) : Marten::DB::Model?
    raise ArgumentError.new("purpose must be non-blank") if purpose.blank?
    return nil if token.nil? || token.empty?

    data = safe_unsign(token)
    return nil if data.nil?

    parsed = parse_payload(data)
    return nil if parsed.nil?

    # `as_s?` (not `as_s`) so a payload field that is present but not a
    # string — e.g. `"i": 3` instead of `"i": "3"`, or `"p": null` —
    # collapses to nil rather than raising `TypeCastError`. The signer
    # has already authenticated the payload, so this only fires for
    # tokens that the holder of the key built by hand with the wrong
    # shape.
    return nil unless parsed["p"]?.try(&.as_s?) == purpose

    class_name = parsed["c"]?.try(&.as_s?)
    id_str = parsed["i"]?.try(&.as_s?)
    return nil if class_name.nil? || id_str.nil?

    klass = resolve_class(class_name)
    return nil if klass.nil?

    safe_get(klass, id_str)
  end

  # `Marten::Core::Signer#unsign` only catches `Base64::Error` itself.
  # A holder of the signing key can hand-craft envelope shapes the
  # signer wasn't written defensively against, and they bubble out as:
  #
  #   * `Time::Format::Error` — `_marten.expires` isn't ISO-8601
  #   * `TypeCastError` — `_marten` is present but not a hash, or its
  #     `value` field isn't a string (`dig(...).as_s` in the signer)
  #   * `KeyError` — `_marten` hash is missing `value` or `expires`
  #     (`dig("_marten", "value")` raises)
  #
  # We translate the known set explicitly. `InvalidSignatureError` is
  # listed defensively: `unsign` returns nil on a bad signature today
  # (only `unsign!` raises), but the contract has flipped before and
  # `locate`'s "never raises" promise shouldn't depend on which side it
  # lands on next. A final unanticipated-`Exception` rescue keeps the
  # contract intact and surfaces the shape via `Marten::Log.debug` so
  # we notice rather than silently swallow.
  private def self.safe_unsign(token : String) : String?
    signer.unsign(token)
  rescue Time::Format::Error | TypeCastError | KeyError | Marten::Core::Signer::InvalidSignatureError
    nil
  rescue ex
    Marten::Log.debug(exception: ex) { "Unexpected error in MartenGlobalId.safe_unsign: #{ex.message}" }
    nil
  end

  # `.as_h?` (not `.as_h`) so a non-object top-level JSON value
  # (`null`, an array, a bare string) collapses to nil rather than
  # raising `TypeCastError` — same pattern as `as_s?` in `locate`.
  private def self.parse_payload(data : String) : Hash(String, JSON::Any)?
    JSON.parse(data).as_h?
  rescue JSON::ParseException
    nil
  end

  # Translate the documented "no such record" path to nil while still
  # surfacing genuine failures (DB connection drop, malformed query,
  # etc.) via `Marten::Log.debug`. The bare `rescue` this used to be
  # made a connection failure indistinguishable from "record not found"
  # to the caller; logging keeps the documented "locate returns nil on
  # any failure" contract intact but leaves diagnostics for operators.
  #
  # `resolve_class` already filters abstract classes out, so the
  # historical "abstract model class raises from .get" path is dead;
  # the bare rescue's other only consumer was that path.
  private def self.safe_get(klass : Marten::DB::Model.class, id_str : String) : Marten::DB::Model?
    klass.get(pk: id_str)
  rescue Marten::DB::Errors::RecordNotFound
    nil
  rescue ex
    Marten::Log.debug(exception: ex) do
      "Unexpected error in MartenGlobalId.locate(#{klass.name}, pk: #{id_str}): #{ex.message}"
    end
    nil
  end

  # Memoised signer. `Marten::Core::Signer.new` is cheap, but reusing
  # the instance is slightly clearer about the invariant: every call
  # signs/verifies with the same key.
  protected def self.signer : Marten::Core::Signer
    @@signer ||= Marten::Core::Signer.new
  end

  # Look up a class by name in the configured allowlist. Returns nil if
  # the name doesn't match any registered class — i.e. the resolver
  # never instantiates a class the host app didn't explicitly opt in.
  # Abstract classes are skipped (`klass.get` raises on abstract model
  # classes; we treat that as "not registered").
  #
  # Note: the simple `name ==` lookup presumes class names don't collide
  # under URL-encoding (they shouldn't — Crystal class names are
  # `[A-Za-z0-9_:]+`), and that the chosen URI separator (`/`) never
  # appears in a class name.
  private def self.resolve_class(name : String) : Marten::DB::Model.class | Nil
    Marten.settings.global_id.allowed_classes.find { |klass| klass.name == name && !klass.abstract? }
  end
end
