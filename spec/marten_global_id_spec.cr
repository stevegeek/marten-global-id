require "./spec_helper"

# Port of Rails' GlobalID::Locator.locate_signed. Covers the sign →
# locate round-trip + every reason a token can be rejected, plus the
# host-driven `config.global_id.allowed_classes` opt-in surface.
describe MartenGlobalId do
  describe ".sign and .locate" do
    it "round-trips a record through an explicit purpose" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class

      widget = Widget.create!(name: "Handbook")
      token = MartenGlobalId.sign(widget, purpose: "default")

      found = MartenGlobalId.locate(token, purpose: "default")
      found.should_not be_nil
      found.as(Widget).pk.should eq(widget.pk)
    end

    it "round-trips a record through the PURPOSE_DEFAULT constant" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class

      widget = Widget.create!(name: "Handbook")
      token = MartenGlobalId.sign(widget, purpose: MartenGlobalId::PURPOSE_DEFAULT)
      found = MartenGlobalId.locate(token, purpose: MartenGlobalId::PURPOSE_DEFAULT)
      found.as(Widget).pk.should eq(widget.pk)
    end

    it "namespaces tokens by purpose — wrong purpose returns nil" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class

      widget = Widget.create!(name: "Handbook")
      token = MartenGlobalId.sign(widget, purpose: "markdown_upload")

      MartenGlobalId.locate(token, purpose: "session_transfer").should be_nil
      MartenGlobalId.locate(token, purpose: "markdown_upload").not_nil!.pk.should eq(widget.pk)
    end

    it "rejects an expired token" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class

      widget = Widget.create!(name: "Handbook")
      # Sign with a 1-second expiry, then sleep past it. We used to use
      # a negative span (immediate expiry) but `sign` now rejects
      # non-positive `expires_in` as a misuse-by-construction footgun
      # (MGR-N3); the only way to exercise the expired-token branch
      # without poking the signer directly is to wait it out.
      token = MartenGlobalId.sign(widget, purpose: "default", expires_in: 1.second)
      sleep 1.1.seconds
      MartenGlobalId.locate(token, purpose: "default").should be_nil
    end

    it "returns nil on a tampered/garbage token" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class

      MartenGlobalId.locate("garbage", purpose: "default").should be_nil
      MartenGlobalId.locate("", purpose: "default").should be_nil
      MartenGlobalId.locate(nil, purpose: "default").should be_nil
    end

    it "returns nil when the resolved class isn't in the allowlist" do
      # Allowlist is empty (per before_each). Construct a payload that
      # signs cleanly but names a class the host hasn't registered.
      payload = {"c" => "Widget", "i" => "1", "p" => "default"}.to_json
      forged = Marten::Core::Signer.new.sign(payload, expires: nil)
      MartenGlobalId.locate(forged, purpose: "default").should be_nil
    end

    it "returns nil when the resolved record no longer exists" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class

      widget = Widget.create!(name: "Handbook")
      token = MartenGlobalId.sign(widget, purpose: "default")
      widget.delete
      MartenGlobalId.locate(token, purpose: "default").should be_nil
    end

    it "round-trips a namespaced model class" do
      Marten.settings.global_id.allowed_classes = [Gadgets::Page] of Marten::DB::Model.class

      page = Gadgets::Page.create!(title: "P")

      token = MartenGlobalId.sign(page, purpose: "markdown_upload")
      found = MartenGlobalId.locate(token, purpose: "markdown_upload")
      found.as(Gadgets::Page).pk.should eq(page.pk)
    end

    it "resolves across multiple registered classes" do
      Marten.settings.global_id.allowed_classes = [Widget, Gadgets::Page] of Marten::DB::Model.class

      widget = Widget.create!(name: "w")
      page = Gadgets::Page.create!(title: "p")

      MartenGlobalId.locate(MartenGlobalId.sign(widget, purpose: "default"), purpose: "default")
        .as(Widget).pk.should eq(widget.pk)
      MartenGlobalId.locate(MartenGlobalId.sign(page, purpose: "default"), purpose: "default")
        .as(Gadgets::Page).pk.should eq(page.pk)
    end

    it "rejects a class that *was* registered but is no longer" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class
      widget = Widget.create!(name: "still here")
      token = MartenGlobalId.sign(widget, purpose: "default")

      # Host de-registers Widget before the token is redeemed (e.g. config
      # was reloaded). Locator should treat it like any other unknown class.
      Marten.settings.global_id.allowed_classes = [] of Marten::DB::Model.class
      MartenGlobalId.locate(token, purpose: "default").should be_nil
    end

    # H1: a hand-crafted payload (only reachable to a holder of the
    # signing key) whose `i` field is a number rather than a string used
    # to raise `TypeCastError` instead of returning nil.
    it "returns nil on a payload whose 'i' field is not a string" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class
      payload = %({"c":"Widget","i":3,"p":"default"})
      forged = Marten::Core::Signer.new.sign(payload, expires: nil)
      MartenGlobalId.locate(forged, purpose: "default").should be_nil
    end

    it "returns nil on a payload whose 'p' field is null" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class
      payload = %({"c":"Widget","i":"1","p":null})
      forged = Marten::Core::Signer.new.sign(payload, expires: nil)
      MartenGlobalId.locate(forged, purpose: "default").should be_nil
    end

    it "returns nil on a payload whose 'c' field is a hash" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class
      payload = %({"c":{"nested":"value"},"i":"1","p":"default"})
      forged = Marten::Core::Signer.new.sign(payload, expires: nil)
      MartenGlobalId.locate(forged, purpose: "default").should be_nil
    end

    # H2: the signer can raise `Time::Format::Error` when the embedded
    # `_marten.expires` string isn't a valid ISO-8601 timestamp. The
    # locator must catch that and return nil so the documented "never
    # raises" contract holds.
    it "returns nil when the signed payload's expires field is malformed" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class

      # Manually build a Marten signer envelope with a broken `expires`
      # string (the signer's `unsign` calls `Time.parse_iso8601` on it).
      inner = {"c" => "Widget", "i" => "1", "p" => "default"}.to_json
      envelope = {
        "_marten" => {
          "value"   => Base64.strict_encode(inner),
          "expires" => "this-is-not-a-timestamp",
        },
      }.to_json
      forged = Marten::Core::Signer.new.sign(envelope, expires: nil)

      MartenGlobalId.locate(forged, purpose: "default").should be_nil
    end

    # M2: an abstract Marten model class in the allowlist used to raise
    # ("Records can only be queried from non-abstract model classes")
    # from `klass.get`. The locator should treat it as "not registered".
    it "returns nil when the named class is registered but abstract" do
      Marten.settings.global_id.allowed_classes = [AbstractDoodad] of Marten::DB::Model.class
      payload = {"c" => "AbstractDoodad", "i" => "1", "p" => "default"}.to_json
      forged = Marten::Core::Signer.new.sign(payload, expires: nil)
      MartenGlobalId.locate(forged, purpose: "default").should be_nil
    end

    # MGR-N1: `Marten::Core::Signer#unsign` uses `dig("_marten", "value")`
    # / `.as_s` unsafely, so a key-holder can hand-craft three envelope
    # shapes that bubble exceptions out past the signer. `safe_unsign`
    # must translate all three to nil so `locate`'s "never raises"
    # contract holds. (Reachable only by a holder of the signing key,
    # but a documented contract is a documented contract.)

    it "returns nil on a signed envelope whose _marten hash lacks 'value'/'expires'" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class

      # `dig("_marten", "value")` raises KeyError here.
      envelope = {"_marten" => {"unrelated" => "x"}}.to_json
      forged = Marten::Core::Signer.new.sign(envelope, expires: nil)
      MartenGlobalId.locate(forged, purpose: "default").should be_nil
    end

    it "returns nil on a signed envelope with 'value' but no 'expires'" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class

      inner = {"c" => "Widget", "i" => "1", "p" => "default"}.to_json
      envelope = {"_marten" => {"value" => Base64.strict_encode(inner)}}.to_json
      forged = Marten::Core::Signer.new.sign(envelope, expires: nil)
      MartenGlobalId.locate(forged, purpose: "default").should be_nil
    end

    it "returns nil on a signed envelope where '_marten' is a string, not a hash" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class

      # The signer's `parsed_data_hash.dig("_marten", "value")` blows up
      # because `_marten` isn't a hash — bubbles a bare Exception out.
      envelope = {"_marten" => "not a hash"}.to_json
      forged = Marten::Core::Signer.new.sign(envelope, expires: nil)
      MartenGlobalId.locate(forged, purpose: "default").should be_nil
    end
  end

  describe ".sign" do
    # H2: signing an unsaved record used to raise `NilAssertionError`
    # from `record.pk!`. Now raises a shard-specific `Error` with a
    # clearer message.
    it "raises MartenGlobalId::Error when the record is unpersisted" do
      widget = Widget.new(name: "not yet saved")
      expect_raises(MartenGlobalId::Error, /unpersisted/) do
        MartenGlobalId.sign(widget, purpose: "default")
      end
    end

    # MGR-N2: a blank purpose silently used to issue a token redeemable
    # by any other code path that forgot to interpolate either. Match
    # sister shard `marten-signed-id` and raise upfront.
    it "raises ArgumentError when purpose is blank" do
      widget = Widget.create!(name: "x")
      expect_raises(ArgumentError, /purpose must be non-blank/) do
        MartenGlobalId.sign(widget, purpose: "")
      end
    end

    # MGR-N3: a negative/zero `expires_in` produces a token expired
    # the instant it's minted — almost certainly a bug. Use `nil` for
    # "no expiry" instead.
    it "raises ArgumentError when expires_in is non-positive" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class
      widget = Widget.create!(name: "x")

      expect_raises(ArgumentError, /expires_in must be positive/) do
        MartenGlobalId.sign(widget, purpose: "default", expires_in: -1.hour)
      end
      expect_raises(ArgumentError, /expires_in must be positive/) do
        MartenGlobalId.sign(widget, purpose: "default", expires_in: 0.seconds)
      end
    end
  end

  describe ".locate" do
    # MGR-N2: matching sister shard. A blank purpose on the verify side
    # is just as suspicious as on the sign side — likely a forgotten
    # interpolation in caller code.
    it "raises ArgumentError when purpose is blank" do
      expect_raises(ArgumentError, /purpose must be non-blank/) do
        MartenGlobalId.locate("any-token", purpose: "")
      end
    end
  end

  describe ".to_global_id" do
    it "produces a stable gid:// URI for a record" do
      widget = Widget.create!(name: "x")
      MartenGlobalId.to_global_id(widget).should eq("gid://marten/Widget/#{widget.pk}")
    end

    # M3: the unsigned URI form now URL-encodes both segments so a
    # namespaced class name round-trips through `URI.parse` (the bare
    # `:` after the host used to be interpreted as a port separator,
    # rendering the string unparsable).
    it "URL-encodes a namespaced class name into a parseable URI" do
      page = Gadgets::Page.create!(title: "p")
      gid = MartenGlobalId.to_global_id(page)
      gid.should eq("gid://marten/Gadgets%3A%3APage/#{page.pk}")

      uri = URI.parse(gid)
      uri.scheme.should eq("gid")
      uri.host.should eq("marten")
      uri.path.should eq("/Gadgets%3A%3APage/#{page.pk}")
    end

    it "raises MartenGlobalId::Error for an unpersisted record" do
      widget = Widget.new(name: "not yet saved")
      expect_raises(MartenGlobalId::Error, /unpersisted/) do
        MartenGlobalId.to_global_id(widget)
      end
    end
  end

  describe "ModelMixin" do
    it "exposes signed_global_id and global_id on participating models" do
      widget = Widget.create!(name: "T")
      widget.responds_to?(:signed_global_id).should be_true
      widget.responds_to?(:global_id).should be_true
    end

    it "#global_id returns the unsigned URI" do
      widget = Widget.create!(name: "T")
      widget.global_id.should eq("gid://marten/Widget/#{widget.pk}")
    end

    it "#signed_global_id delegates to MartenGlobalId.sign" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class

      widget = Widget.create!(name: "T")
      token = widget.signed_global_id(purpose: "markdown_upload")
      MartenGlobalId.locate(token, purpose: "markdown_upload").not_nil!.pk.should eq(widget.pk)
    end

    it "#signed_global_id honours expires_in" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class

      widget = Widget.create!(name: "T")
      # 1-second expiry + sleep, same shape as the top-level expired
      # token spec (negative spans are now rejected upfront — MGR-N3).
      token = widget.signed_global_id(purpose: "test", expires_in: 1.second)
      sleep 1.1.seconds
      MartenGlobalId.locate(token, purpose: "test").should be_nil
    end
  end
end
