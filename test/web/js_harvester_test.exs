defmodule Web.JSHarvesterTest do
  use ExUnit.Case, async: true

  alias Web.Platform.Test.JSHarvester

  test "load!/2 harvests supported cases from balanced check and push blocks" do
    source = """
    /* block comment before checks */
    check("primitive string, double quotes", "hello", compare_primitive);
    // line comment between checks
    check('primitive bigint', 9007199254740993n, compare_primitive);
    check('primitive nan', NaN, compare_primitive);
    check('primitive infinity', Infinity, compare_primitive);
    check('primitive negative infinity', -Infinity, compare_primitive);
    check('Date 0', new Date(0), compare_Date);
    function helperBlob() { return new Blob(['\\uD800'], {"type": "text/plain"}); }
    check("Blob helper", helperBlob, compare_Blob);
    check('Blob inline', new Blob([]), compare_Blob);
    check('Array with identical property values', function() { const obj = {}; return [obj, obj]; }, compare_Array(check_identical_property_values("0", "1")));
    check('Object with identical property values', function() { const obj = {}; return {a: obj, b: obj}; }, compare_Object(check_identical_property_values("a", "b")));
    check('Ignored comparator', new RegExp(''), compare_RegExp('(?:)'));
    structuredCloneBatteryOfTests.push({ description: "Serializing a non-serializable platform object fails", async f(runner, t) {} });
    structuredCloneBatteryOfTests.push({
      description: 'ArrayBuffer',
      async f(runner) {
        const buffer = new Uint8Array([1, 2, 3]).buffer;
      }
    });
    structuredCloneBatteryOfTests.push({ description: 'Transferring a non-transferable platform object fails', async f(runner, t) {} });
    structuredCloneBatteryOfTests.push({ description: 'Ignored push', async f() {} });
    """

    cases = JSHarvester.load!("http://example.test/custom.js", source)

    assert find_case(cases, "primitive string, double quotes")["value"] == "hello"
    assert find_case(cases, "primitive bigint")["value"] == 9_007_199_254_740_993
    assert find_case(cases, "primitive nan")["value"] == {:js_special_number, :nan}
    assert find_case(cases, "primitive infinity")["value"] == {:js_special_number, :infinity}

    assert find_case(cases, "primitive negative infinity")["value"] ==
             {:js_special_number, :negative_infinity}

    assert find_case(cases, "Date 0")["unix_ms"] == 0

    assert find_case(cases, "Blob helper") == %{
             "comment" => "Blob helper",
             "kind" => "blob",
             "parts" => [<<0xED, 0xA0, 0x80>>],
             "type" => "text/plain"
           }

    assert find_case(cases, "Blob inline")["parts"] == []
    assert find_case(cases, "Blob inline")["type"] == ""

    assert find_case(cases, "Array with identical property values")["kind"] ==
             "shared_reference_array"

    assert find_case(cases, "Object with identical property values")["kind"] ==
             "shared_reference_object"

    assert find_case(cases, "Serializing a non-serializable platform object fails")["kind"] ==
             "data_clone_error"

    assert find_case(cases, "ArrayBuffer")["bytes"] == [1, 2, 3]

    assert find_case(cases, "Transferring a non-transferable platform object fails")["kind"] ==
             "transfer_blob_error"

    refute Enum.any?(cases, &(&1["comment"] == "Ignored comparator"))
    refute Enum.any?(cases, &(&1["comment"] == "Ignored push"))
  end

  test "load!/2 extracts whitespace-tolerant check push and test invocations" do
    source = """
    check   ( 'primitive spaced', true, compare_primitive );

    structuredCloneBatteryOfTests
      .push (
        {
          description: 'ArrayBuffer',
          async f(runner) {
            const buffer = new Uint8Array([4, 5]).buffer;
          }
        }
      );

    test (
      () => {},
      "harness description"
    );
    """

    cases = JSHarvester.load!("http://example.test/spaced.js", source)

    assert find_case(cases, "primitive spaced")["value"] == true
    assert find_case(cases, "ArrayBuffer")["bytes"] == [4, 5]
    assert find_case(cases, "harness description")["kind"] == "test"
  end

  test "load!/2 covers fallback test descriptions and inline line comments" do
    source = """
    test('inline description', () => {});
    test(() => {});
    check(helperDescription(), true, compare_primitive);
    check('bad primitive', helperValue(), compare_primitive);
    check(
      'ignored line comment comparator',
      function() {
        // inline comment
        return true;
      },
      compare_other
    );
    check(
      'line comment string',
      "abc",
      compare_primitive
    );
    """

    cases = JSHarvester.load!("http://example.test/line-comments.js", source)

    assert find_case(cases, "inline description")["kind"] == "test"
    assert find_case(cases, "line comment string")["value"] == "abc"
    refute Enum.any?(cases, &(&1["comment"] == "bad primitive"))
  end

  test "parse_literal!/1 supports strings, containers, special numbers, and surrogate forms" do
    assert JSHarvester.parse_literal!("[]") == []
    assert JSHarvester.parse_literal!("{}") == %{}
    assert JSHarvester.parse_literal!("null") == nil
    assert JSHarvester.parse_literal!("true") == true
    assert JSHarvester.parse_literal!("false") == false
    assert JSHarvester.parse_literal!("-0") == -0.0
    assert JSHarvester.parse_literal!("1.25e2") == 125.0
    assert JSHarvester.parse_literal!("9007199254740993n") == 9_007_199_254_740_993

    assert JSHarvester.parse_literal!(~s(["a", {"b": 1, c: 2}])) == [
             "a",
             %{"b" => 1, "c" => 2}
           ]

    assert JSHarvester.parse_literal!(~s("double quoted")) == "double quoted"

    assert JSHarvester.parse_literal!(~S('\n\r\t\f\b\0\'\"\\\/\v\a')) ==
             "\n\r\t\f" <> <<8, 0>> <> "'\"\\/" <> <<11>> <> "a"

    assert JSHarvester.parse_literal!(~S("\u0041")) == "A"
    assert JSHarvester.parse_literal!(~S("\uD83D\uDE00")) == "😀"
    assert JSHarvester.parse_literal!(~S("\uD800\u0041")) == <<0xED, 0xA0, 0x80, ?A>>
    assert JSHarvester.parse_literal!(~S("\uDC00")) == <<0xED, 0xB0, 0x80>>
  end

  test "load!/2 and parse_literal!/1 surface parser errors explicitly" do
    assert_raise ArgumentError, ~r/Unsupported WPT JS dataset/, fn ->
      JSHarvester.load!("http://example.test/empty.js", "")
    end

    assert_raise ArgumentError, ~r/Unsupported structured clone check block/, fn ->
      JSHarvester.load!("http://example.test/bad-check.js", "check('broken', true);")
    end

    assert_raise ArgumentError, ~r/Unsupported WPT JS dataset/, fn ->
      JSHarvester.load!(
        "http://example.test/missing-helper.js",
        "check('Blob helper', missingHelper, compare_Blob);"
      )
    end

    assert_raise ArgumentError, ~r/Unsupported WPT JS dataset/, fn ->
      JSHarvester.load!(
        "http://example.test/bad-helper.js",
        "function badHelper() { const x = 1; } check('Blob helper', badHelper, compare_Blob);"
      )
    end

    assert_raise ArgumentError, ~r/Unsupported WPT JS dataset/, fn ->
      JSHarvester.load!(
        "http://example.test/empty-helper.js",
        "function emptyHelper() { return ; } check('Blob helper', emptyHelper, compare_Blob);"
      )
    end

    assert_raise ArgumentError, ~r/Unsupported WPT JS dataset/, fn ->
      JSHarvester.load!(
        "http://example.test/broken-helper.js",
        "function brokenHelper() check('Blob helper', brokenHelper, compare_Blob);"
      )
    end

    assert_raise ArgumentError, ~r/Unsupported WPT JS dataset/, fn ->
      JSHarvester.load!(
        "http://example.test/bad-push.js",
        "structuredCloneBatteryOfTests.push({ async f() {} });"
      )
    end

    assert_raise ArgumentError, ~r/Unsupported ArrayBuffer transfer block/, fn ->
      JSHarvester.load!(
        "http://example.test/bad-transfer.js",
        "structuredCloneBatteryOfTests.push({ description: 'ArrayBuffer', async f() {} });"
      )
    end

    assert_raise ArgumentError, ~r/Unsupported WPT JS dataset/, fn ->
      JSHarvester.load!(
        "http://example.test/unsupported.js",
        "check('ignored', 1, compare_other); structuredCloneBatteryOfTests.push({ description: 'Ignored push', async f() {} });"
      )
    end

    assert_raise ArgumentError, ~r/Unterminated JS block/, fn ->
      JSHarvester.load!(
        "http://example.test/unterminated.js",
        "check('primitive', true, compare_primitive;"
      )
    end

    assert_raise ArgumentError, ~r/Unsupported trailing JS literal content/, fn ->
      JSHarvester.parse_literal!("true nope")
    end

    assert_raise ArgumentError, ~r/Unsupported JS object key/, fn ->
      JSHarvester.parse_literal!("{1: true}")
    end

    assert_raise ArgumentError, ~r/Expected \":\" in JS literal/, fn ->
      JSHarvester.parse_literal!("{a true}")
    end

    assert_raise ArgumentError, ~r/Unsupported JS object literal/, fn ->
      JSHarvester.parse_literal!("{a: true b: false}")
    end

    assert_raise ArgumentError, ~r/Unsupported JS array literal/, fn ->
      JSHarvester.parse_literal!("[1 2]")
    end

    assert_raise ArgumentError, ~r/Unsupported JS numeric literal/, fn ->
      JSHarvester.parse_literal!("foo")
    end
  end

  test "load!/2 ignores non-standalone signature matches" do
    source = """
    check('start', true, compare_primitive);
    xcheck('skip lower', true, compare_primitive);
    Xcheck('skip upper', true, compare_primitive);
    1check('skip digit', true, compare_primitive);
    _check('skip underscore', true, compare_primitive);
    $check('skip dollar', true, compare_primitive);
    obj.check('skip dot', true, compare_primitive);
    """

    cases = JSHarvester.load!("http://example.test/non-standalone.js", source)

    assert Enum.map(cases, & &1["comment"]) == ["start"]
  end

  test "load!/2 skips unsupported date literals and handles block comments inside invocations" do
    source = """
    check('Unsupported date', undefined, compare_Date);
    check('Ignored comparator', function() { /* block comment inside invocation */ return true; }, compare_other);
    check('primitive after block', true, compare_primitive);
    """

    cases = JSHarvester.load!("http://example.test/block-comment.js", source)

    assert Enum.map(cases, & &1["comment"]) == ["primitive after block"]
  end

  defp find_case(cases, comment) do
    Enum.find(cases, &(&1["comment"] == comment)) || flunk("missing case #{inspect(comment)}")
  end
end
