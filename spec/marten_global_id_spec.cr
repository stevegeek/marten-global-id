require "./spec_helper"

# Port of Rails' GlobalID::Locator.locate_signed. Covers the sign →
# locate round-trip + every reason a token can be rejected, plus the
# host-driven `config.global_id.allowed_classes` opt-in surface.
describe MartenGlobalId do
  describe ".sign and .locate" do
    it "round-trips a record through the default purpose" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class

      widget = Widget.create!(name: "Handbook")
      token = MartenGlobalId.sign(widget)

      found = MartenGlobalId.locate(token)
      found.should_not be_nil
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
      # Negative span expires the token immediately (the signer compares
      # against Time.utc on verify).
      token = MartenGlobalId.sign(widget, expires_in: -1.second)
      MartenGlobalId.locate(token).should be_nil
    end

    it "returns nil on a tampered/garbage token" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class

      MartenGlobalId.locate("garbage").should be_nil
      MartenGlobalId.locate("").should be_nil
      MartenGlobalId.locate(nil).should be_nil
    end

    it "returns nil when the resolved class isn't in the allowlist" do
      # Allowlist is empty (per before_each). Construct a payload that
      # signs cleanly but names a class the host hasn't registered.
      payload = {"c" => "Widget", "i" => "1", "p" => "default"}.to_json
      forged = Marten::Core::Signer.new.sign(payload, expires: nil)
      MartenGlobalId.locate(forged).should be_nil
    end

    it "returns nil when the resolved record no longer exists" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class

      widget = Widget.create!(name: "Handbook")
      token = MartenGlobalId.sign(widget)
      widget.delete
      MartenGlobalId.locate(token).should be_nil
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

      MartenGlobalId.locate(MartenGlobalId.sign(widget)).as(Widget).pk.should eq(widget.pk)
      MartenGlobalId.locate(MartenGlobalId.sign(page)).as(Gadgets::Page).pk.should eq(page.pk)
    end

    it "rejects a class that *was* registered but is no longer" do
      Marten.settings.global_id.allowed_classes = [Widget] of Marten::DB::Model.class
      widget = Widget.create!(name: "still here")
      token = MartenGlobalId.sign(widget)

      # Host de-registers Widget before the token is redeemed (e.g. config
      # was reloaded). Locator should treat it like any other unknown class.
      Marten.settings.global_id.allowed_classes = [] of Marten::DB::Model.class
      MartenGlobalId.locate(token).should be_nil
    end
  end

  describe ".to_global_id" do
    it "produces a stable gid:// URI for a record" do
      widget = Widget.create!(name: "x")
      MartenGlobalId.to_global_id(widget).should eq("gid://marten/Widget/#{widget.pk}")
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
      token = widget.signed_global_id(purpose: "test", expires_in: -1.minute)
      MartenGlobalId.locate(token, purpose: "test").should be_nil
    end
  end
end
