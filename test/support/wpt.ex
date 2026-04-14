defmodule Web.Platform.Test do
  @moduledoc false

  use Web

  alias Web.AsyncContext.Variable

  @cache_dir Path.expand("tmp/wpt_cache", Elixir.File.cwd!())
  # The infrastructure uses an AsyncContext.Variable (referenced via
  # @context_key) to store the URL of the remote spec being processed.
  # Because WPT tests are metaprogrammed into hundreds of individual
  # test blocks, if a failure occurs deep within a shared helper or a
  # JSON parsing task, the Logger can automatically output which spec
  # file (e.g., urlpatterntestdata.json) caused the error without that
  # URL being passed through every single function.
  @context_key {__MODULE__, :current_url}

  @callback web_platform_test(map()) :: any()

  defmacro __using__(opts) do
    opts = normalize_use_options!(opts)
    urls = Keyword.fetch!(opts, :urls)
    prefix = Keyword.fetch!(opts, :prefix)
    datasets = load_many!(urls)

    test_blocks =
      Enum.map(datasets, fn %{url: url, cases: test_cases} ->
        test_asts =
          Enum.with_index(test_cases, 1)
          |> Enum.map(fn {test_case, index} ->
            quote do
              test unquote(wpt_case_name(test_case, index)) do
                __MODULE__.web_platform_test(unquote(Macro.escape(test_case)))
              end
            end
          end)

        describe_term = "#{prefix} (#{suite_name(url)})"

        quote do
          describe unquote(describe_term) do
            (unquote_splicing(test_asts))
          end
        end
      end)

    quote do
      @behaviour Web.Platform.Test

      unquote_splicing(test_blocks)
    end
  end

  def load_many!(urls) when is_list(urls) do
    Enum.map(urls, fn url ->
      %{url: url, cases: load_json!(url)}
    end)
  end

  def suite_name(url), do: Path.basename(url)

  def wpt_case_name(test_case, index) do
    cond do
      is_binary(test_case["//"]) -> "#{index}: #{test_case["//"]}"
      is_binary(test_case["comment"]) -> "#{index}: #{test_case["comment"]}"
      true -> "case #{index}"
    end
  end

  def load_json!(url) when is_binary(url) do
    Elixir.File.mkdir_p!(@cache_dir)

    {cache_path, meta_path} = cache_paths(url)
    meta = read_meta(meta_path)

    Variable.run(fetch_context_variable(), url, fn ->
      fetch_with_cache(url, cache_path, meta_path, meta)
    end)
  end

  defp fetch_with_cache(url, cache_path, meta_path, meta) do
    headers = conditional_headers(meta)

    try do
      response = Web.await(Web.fetch(url, headers: headers))

      case response.status do
        200 ->
          persist_fresh_response(response, cache_path, meta_path)

        304 ->
          read_cached_json!(cache_path, url)

        status when status in 400..599 ->
          fallback_to_cache_or_raise(cache_path, url, "HTTP #{status} fetching WPT data")

        status ->
          fallback_to_cache_or_raise(
            cache_path,
            url,
            "Unexpected HTTP #{status} fetching WPT data"
          )
      end
    rescue
      error ->
        fallback_to_cache_or_raise(cache_path, url, Exception.message(error))
    catch
      :exit, reason ->
        fallback_to_cache_or_raise(
          cache_path,
          url,
          "Network error fetching WPT data: #{inspect(reason)}"
        )

      kind, reason ->
        fallback_to_cache_or_raise(
          cache_path,
          url,
          "Fetch failure (#{kind}) fetching WPT data: #{inspect(reason)}"
        )
    end
  end

  defp persist_fresh_response(response, cache_path, meta_path) do
    {json_response, text_response} = Web.Response.clone(response)
    raw = Web.await(Web.Response.text(text_response))
    decoded = decode_payload(json_response, raw)

    Elixir.File.write!(cache_path, raw)

    meta = %{
      etag: Web.Headers.get(response.headers, "etag"),
      last_modified: Web.Headers.get(response.headers, "last-modified")
    }

    Elixir.File.write!(meta_path, Jason.encode!(meta))
    decoded
  end

  defp decode_payload(json_response, raw) do
    Web.await(Web.Response.json(json_response))
  rescue
    _ ->
      raw
      |> repair_surrogates()
      |> Jason.decode!()
  catch
    :exit, _reason ->
      raw
      |> repair_surrogates()
      |> Jason.decode!()
  end

  defp fallback_to_cache_or_raise(cache_path, url, reason) do
    if Elixir.File.exists?(cache_path) do
      read_cached_json!(cache_path, url)
    else
      raise ArgumentError,
            "#{reason}. Connect to the internet and rerun the tests once to populate #{cache_path} for #{url}."
    end
  end

  defp read_cached_json!(cache_path, _url) do
    cache_path
    |> Elixir.File.read!()
    |> repair_surrogates()
    |> Jason.decode!()
  end

  defp conditional_headers(meta) do
    []
    |> maybe_put_header("if-none-match", meta["etag"])
    |> maybe_put_header("if-modified-since", meta["last_modified"])
  end

  defp maybe_put_header(headers, _name, nil), do: headers
  defp maybe_put_header(headers, _name, ""), do: headers
  defp maybe_put_header(headers, name, value), do: [{name, value} | headers]

  defp cache_paths(url) do
    basename = Path.basename(url)
    {Path.join(@cache_dir, basename), Path.join(@cache_dir, basename <> ".meta")}
  end

  defp read_meta(path) do
    if Elixir.File.exists?(path) do
      path
      |> Elixir.File.read!()
      |> Jason.decode!()
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp fetch_context_variable do
    case :persistent_term.get(@context_key, nil) do
      nil ->
        variable = Variable.new("wpt_url")
        :persistent_term.put(@context_key, variable)
        variable

      variable ->
        variable
    end
  end

  defp normalize_use_options!(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      urls = opts |> Keyword.fetch!(:urls) |> normalize_urls_option!()
      prefix = Keyword.get(opts, :prefix, "WPT compliance")

      [urls: urls, prefix: prefix]
    else
      raise ArgumentError,
            "use Web.Platform.Test expects keyword options including urls: [...] and optional prefix: \"...\", got: #{inspect(opts)}"
    end
  end

  defp normalize_use_options!(other) do
    raise ArgumentError,
          "use Web.Platform.Test expects keyword options including urls: [...] and optional prefix: \"...\", got: #{inspect(other)}"
  end

  defp normalize_urls_option!(urls) when is_list(urls) do
    if Keyword.keyword?(urls) do
      raise ArgumentError,
            "urls: expects a list of URL strings, got keyword list: #{inspect(urls)}"
    else
      Enum.map(urls, &normalize_url!/1)
    end
  end

  defp normalize_urls_option!(other) do
    raise ArgumentError, "urls: expects a list of URL strings, got: #{inspect(other)}"
  end

  defp normalize_url!(url) when is_binary(url), do: url

  defp repair_surrogates(text) do
    Regex.replace(
      ~r/\\u([Dd][89AaBb][0-9A-Fa-f]{2})\\u([Dd][C-Fc-f][0-9A-Fa-f]{2})|\\u([Dd][89A-Fa-f][0-9A-Fa-f]{2})/,
      text,
      fn
        _, high, low, "" ->
          h = String.to_integer(high, 16)
          l = String.to_integer(low, 16)
          cp = 0x10000 + (h - 0xD800) * 0x400 + (l - 0xDC00)
          cp |> List.wrap() |> List.to_string() |> Jason.encode!() |> String.slice(1..-2//1)

        _, "", "", _lone ->
          "\\uFFFD"
      end
    )
  end
end
