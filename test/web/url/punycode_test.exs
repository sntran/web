defmodule Web.URL.PunycodeTest do
  use ExUnit.Case, async: false

  alias Web.URL.Punycode

  test "encode/1 gives the Punycode form of a label" do
    assert Punycode.encode("bücher") == "bcher-kva"
  end

  test "host_to_ascii/1 converts a host to its ASCII form" do
    assert Punycode.host_to_ascii("") == ""
    assert Punycode.host_to_ascii("Example。Com") == "example.com"
    assert Punycode.host_to_ascii("bücher.example.") == "xn--bcher-kva.example."
    assert Punycode.host_to_ascii("faß.de") == "xn--fa-hia.de"
    assert Punycode.host_to_ascii("☃.com") == "xn--n3h.com"
    assert Punycode.host_to_ascii("ab\u00AD.com") == "ab.com"
    assert Punycode.host_to_ascii("l·l.com") == "xn--ll-0ea.com"
    assert Punycode.host_to_ascii("a·b.com") == "xn--ab-0ea.com"
  end

  test "host_to_ascii/1 keeps an empty label" do
    assert Punycode.host_to_ascii("bücher..example") == "xn--bcher-kva..example"
    assert Punycode.valid_host?("bücher..example")
  end

  test "host_to_ascii/1 returns the lowercase input for a host that is not valid" do
    assert Punycode.host_to_ascii("Foo Bar") == "foo bar"
    assert Punycode.host_to_ascii("XN--0") == "xn--0"
  end

  test "valid_host?/1 rejects a host that becomes empty" do
    refute Punycode.valid_host?(<<0xAD::utf8>>)
  end

  test "valid_host?/1 applies the rules for joiners" do
    # A joiner after a virama is valid.
    assert Punycode.valid_host?(<<0x915::utf8, 0x94D::utf8, 0x200D::utf8, ".com">>)
    assert Punycode.valid_host?(<<0x915::utf8, 0x94D::utf8, 0x200C::utf8, ".com">>)

    # U+200C between two Arabic letters that join is valid. A transparent
    # mark between them has no effect.
    assert Punycode.valid_host?(<<0x644::utf8, 0x670::utf8, 0x200C::utf8, 0x6EF::utf8>>)

    refute Punycode.valid_host?(<<0x644::utf8, 0x200C::utf8>>)
    refute Punycode.valid_host?(<<0x200D::utf8, "a.com">>)
  end

  test "valid_host?/1 applies the Bidi rule to each label of a Bidi domain" do
    assert Punycode.valid_host?(<<0x5D0::utf8, ".example">>)
    refute Punycode.valid_host?(<<0x5D0::utf8, ".1example">>)
  end

  test "valid_host?/1 rejects a label with the prefix xn-- that is not valid" do
    # The decoded label is ASCII only.
    refute Punycode.valid_host?("xn--ascii-")
    # The decoded label starts with a combining mark.
    refute Punycode.valid_host?("xn--" <> Punycode.encode(<<0x301::utf8, "a">>))
    # The decoded label is not in the mapped form.
    refute Punycode.valid_host?("xn--" <> Punycode.encode(<<0xFF41::utf8, 0xE9::utf8>>))
    # The decoded label has a value that is not a Unicode code point.
    refute Punycode.valid_host?("xn--0000000b")
    # The label contains a character that is not ASCII.
    refute Punycode.valid_host?(<<"xn--a", 0xE9::utf8>>)
  end

  test "valid_host?/1 accepts a valid host" do
    assert Punycode.valid_host?("☃.com")
    assert Punycode.valid_host?("l·l.com")
  end

  test "valid_host?/1 rejects a host that is not valid" do
    refute Punycode.valid_host?("xn--")
    refute Punycode.valid_host?("xn--0")
    refute Punycode.valid_host?("xn--mañana.com")
    refute Punycode.valid_host?("foo bar")
    refute Punycode.valid_host?("́a.com")
    refute Punycode.valid_host?("a\u200Cb.com")
    refute Punycode.valid_host?("a\u200Db.com")
    refute Punycode.valid_host?("a\u00A0b.com")
    refute Punycode.valid_host?("abcא.com")
    refute Punycode.valid_host?("�.com")
    # A host that ends in a number is an IPv4 address, not a domain.
    refute Punycode.valid_host?(<<0xE9::utf8, ".1">>)
    refute Punycode.valid_host?(<<0xE9::utf8, 0xFE>>)
    assert Punycode.host_to_ascii(<<0xE9::utf8, 0xFE>>) == <<0xE9::utf8, 0xFE>>
  end

  test "a file in the working directory does not change the result" do
    tmp_dir = Path.join(System.tmp_dir!(), "web-punycode-#{System.unique_integer([:positive])}")
    fixture_dir = Path.join([tmp_dir, "tmp", "wpt_cache"])
    File.mkdir_p!(fixture_dir)

    File.write!(
      Path.join(fixture_dir, "toascii.json"),
      Jason.encode!([%{"input" => "fixture.example", "output" => "mapped.example"}])
    )

    try do
      File.cd!(tmp_dir, fn ->
        assert Punycode.host_to_ascii("fixture.example") == "fixture.example"
      end)
    after
      File.rm_rf!(tmp_dir)
    end
  end
end
