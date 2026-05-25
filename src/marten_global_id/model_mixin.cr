module MartenGlobalId
  # Instance-side mixin for participating Marten models. Adds:
  #
  # - `record.global_id` — the unsigned `gid://marten/<class>/<pk>` URI.
  #   Stable, safe for cache keys or internal comparisons, **not** safe
  #   to accept from the outside world.
  # - `record.signed_global_id(purpose:, expires_in:)` — the HMAC-signed
  #   token. Pass through `MartenGlobalId.locate` on the receiving end
  #   to materialise the record.
  #
  # Mirrors Rails' `GlobalID::Identification` (which adds `to_global_id`
  # + `to_signed_global_id`).
  #
  # Include in every model class that needs to issue signed tokens — and
  # remember to also add the class to `config.global_id.allowed_classes`
  # so the locator will accept tokens that reference it.
  #
  # **Namespace pollution warning:** including this mixin defines
  # `global_id` and `signed_global_id` as instance methods on the host
  # class. Do **not** include `MartenGlobalId::ModelMixin` on a model
  # that already defines either of those names (e.g. a `global_id`
  # string field imported from an external system) — the mixin's
  # methods will shadow the field accessor silently.
  #
  # ```
  # class Book < Marten::Model
  #   include MartenGlobalId::ModelMixin
  # end
  #
  # book.global_id                                    # => "gid://marten/Book/3"
  # book.signed_global_id(purpose: "markdown_upload") # => "eyJjI..."
  # ```
  module ModelMixin
    # Unsigned global id — a stable `(class_name, pk)` URI. Use this for
    # cache keys or internal comparisons. Do **not** accept these from
    # untrusted input — use `signed_global_id` for that.
    def global_id : ::String
      ::MartenGlobalId.to_global_id(self)
    end

    # HMAC-signed global id, scoped by `purpose` and optionally expiring
    # after `expires_in`. Pass the resulting token through
    # `MartenGlobalId.locate(token, purpose: ...)` to resolve back to a
    # record.
    def signed_global_id(
      *,
      purpose : ::String,
      expires_in : ::Time::Span? = nil,
    ) : ::String
      ::MartenGlobalId.sign(self, purpose: purpose, expires_in: expires_in)
    end
  end
end
