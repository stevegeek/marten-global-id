require "marten"
require "json"

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
# MartenGlobalId.locate(token, purpose: "markdown_upload")  # => MyApp::Book?
# ```
#
# Built on `Marten::Core::Signer` (HMAC-SHA256, Marten's `secret_key` by
# default).
module MartenGlobalId
  VERSION = "0.1.0"

  # Default purpose used when none is supplied. Mirrors Rails'
  # `SignedGlobalID::DEFAULT_PURPOSE`.
  PURPOSE_DEFAULT = "default"

  # Sign a `(class_name, pk)` tuple with HMAC + optional expiry, namespaced
  # by `purpose`. Mirrors Rails `SignedGlobalID#to_s` (which calls
  # `verifier.generate(uri, purpose:, expires_at:)`).
  def self.sign(
    record : Marten::DB::Model,
    purpose : String = PURPOSE_DEFAULT,
    expires_in : Time::Span? = nil,
  ) : String
    payload = {"c" => record.class.name, "i" => record.pk!.to_s, "p" => purpose}.to_json
    expires = expires_in.try { |span| Time.utc + span }
    Marten::Core::Signer.new.sign(payload, expires: expires)
  end

  # Build the unsigned wire-format string for a record. Equivalent to
  # Rails' `record.to_global_id.to_s` — a `(class_name, pk)` URI without
  # an HMAC. Useful for stable cache keys or comparisons; **not** safe to
  # accept from the outside world. Prefer `sign` for anything that
  # round-trips through user input.
  def self.to_global_id(record : Marten::DB::Model) : String
    "gid://marten/#{record.class.name}/#{record.pk!}"
  end

  # Verify + decode a signed token, returning the resolved record (or nil
  # on any failure: bad signature, expired token, purpose mismatch,
  # class not in the allowlist, record no longer exists). Mirrors Rails'
  # `GlobalID::Locator.locate_signed`.
  def self.locate(token : String?, purpose : String = PURPOSE_DEFAULT) : Marten::DB::Model?
    return nil if token.nil? || token.empty?

    data = Marten::Core::Signer.new.unsign(token)
    return nil if data.nil?

    parsed = begin
      JSON.parse(data).as_h?
    rescue JSON::ParseException
      nil
    end
    return nil if parsed.nil?

    return nil unless parsed["p"]?.try(&.as_s) == purpose

    class_name = parsed["c"]?.try(&.as_s)
    id_str = parsed["i"]?.try(&.as_s)
    return nil if class_name.nil? || id_str.nil?

    klass = resolve_class(class_name)
    return nil if klass.nil?

    klass.get(pk: id_str)
  end

  # Look up a class by name in the configured allowlist. Returns nil if
  # the name doesn't match any registered class — i.e. the resolver
  # never instantiates a class the host app didn't explicitly opt in.
  private def self.resolve_class(name : String) : Marten::DB::Model.class | Nil
    Marten.settings.global_id.allowed_classes.find { |klass| klass.name == name }
  end
end
