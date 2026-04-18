defmodule Web.Platform.Test do
  @moduledoc false

  use Web
  @on_load :ensure_fetch_governor

  alias Web.AsyncContext.Variable
  alias Web.Platform.Test, as: PlatformTest
  alias Web.Platform.Test.JSHarvester

  @cache_dir Path.expand("tmp/wpt_cache", Elixir.File.cwd!())
  # The infrastructure uses an AsyncContext.Variable (referenced via
  # @context_key) to store the URL of the remote spec being processed.
  # Because WPT tests are metaprogrammed into hundreds of individual
  # test blocks, if a failure occurs deep within a shared helper or a
  # JSON parsing task, the Logger can automatically output which spec
  # file (e.g., urlpatterntestdata.json) caused the error without that
  # URL being passed through every single function.
  @context_key {__MODULE__, :current_url}
  @governor_key {__MODULE__, :fetch_governor}
  @governor_lock_key {__MODULE__, :fetch_governor_lock}
  @default_governor_capacity 5
  @default_max_fetch_attempts 6
  @default_fetch_timeout_ms 30_000
  @default_max_total_fetch_ms 60_000
  @default_base_backoff_ms 500
  @default_max_backoff_ms 10_000
  @default_max_retry_after_ms 30_000

  @callback web_platform_test(any()) :: any()

  def ensure_fetch_governor do
    _ = fetch_governor()
    :ok
  end

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
              test unquote(PlatformTest.wpt_case_name(test_case, index)) do
                __MODULE__.web_platform_test(unquote(Macro.escape(test_case)))
              end
            end
          end)

        describe_term = "#{prefix} (#{PlatformTest.suite_name(url)})"

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
      %{url: url, cases: load_cases!(url)}
    end)
  end

  def suite_name(url), do: Path.basename(url)

  def wpt_case_name(test_case, index) do
    cond do
      is_binary(test_case) ->
        "#{index}: #{String.slice(test_case, 0, 96)}"

      is_map(test_case) and is_binary(test_case["//"]) ->
        "#{index}: #{test_case["//"]}"

      is_map(test_case) and is_binary(test_case["comment"]) ->
        "#{index}: #{test_case["comment"]}"

      is_map(test_case) and is_binary(test_case["description"]) ->
        "#{index}: #{test_case["description"]}"

      true ->
        "case #{index}"
    end
  end

  def load_json!(url) when is_binary(url) do
    Elixir.File.mkdir_p!(@cache_dir)

    {cache_path, meta_path} = cache_paths(url)
    meta = read_meta(meta_path)
    fetch_url = normalize_fetch_url(url)
    started_at = System.monotonic_time(:millisecond)

    Variable.run(fetch_context_variable(), url, fn ->
      fetch_governor()
      |> Governor.with(fn ->
        fetch_json_with_cache(fetch_url, cache_path, meta_path, meta, started_at)
      end)
      |> Web.await()
    end)
  end

  defp load_cases!(url) when is_binary(url) do
    case resource_format(url) do
      :js -> normalize_cases(url, JSHarvester.load!(url, load_source!(url)))
      :json -> normalize_cases(url, load_json!(url))
    end
  end

  defp load_source!(url) when is_binary(url) do
    Elixir.File.mkdir_p!(@cache_dir)

    {cache_path, meta_path} = cache_paths(url)
    meta = read_meta(meta_path)
    fetch_url = normalize_fetch_url(url)
    started_at = System.monotonic_time(:millisecond)

    Variable.run(fetch_context_variable(), url, fn ->
      fetch_governor()
      |> Governor.with(fn ->
        fetch_source_with_cache(fetch_url, cache_path, meta_path, meta, started_at)
      end)
      |> Web.await()
    end)
  end

  defp fetch_source_with_cache(url, cache_path, meta_path, meta, started_at) do
    meta
    |> conditional_headers()
    |> fetch_with_retry(url, started_at)
    |> handle_fetch_source_response(url, cache_path, meta_path)
  rescue
    error ->
      fallback_to_cache_source_or_raise(cache_path, url, Exception.message(error))
  catch
    :exit, reason ->
      fallback_to_cache_source_or_raise(
        cache_path,
        url,
        "Network error fetching WPT data: #{inspect(reason)}"
      )

    kind, reason ->
      fallback_to_cache_source_or_raise(
        cache_path,
        url,
        "Fetch failure (#{kind}) fetching WPT data: #{inspect(reason)}"
      )
  end

  defp fetch_json_with_cache(url, cache_path, meta_path, meta, started_at) do
    meta
    |> conditional_headers()
    |> fetch_with_retry(url, started_at)
    |> handle_fetch_json_response(url, cache_path, meta_path)
  rescue
    error ->
      fallback_to_cache_json_or_raise(cache_path, url, Exception.message(error))
  catch
    :exit, reason ->
      fallback_to_cache_json_or_raise(
        cache_path,
        url,
        "Network error fetching WPT data: #{inspect(reason)}"
      )

    kind, reason ->
      fallback_to_cache_json_or_raise(
        cache_path,
        url,
        "Fetch failure (#{kind}) fetching WPT data: #{inspect(reason)}"
      )
  end

  defp fetch_with_retry(headers, url, started_at, attempt \\ 1)

  defp fetch_with_retry(headers, url, started_at, attempt) do
    signal = fetch_timeout_signal(started_at)
    response = Web.await(Web.fetch(url, headers: headers, signal: signal))

    remaining = remaining_budget_ms(started_at)

    if retryable_fetch_status?(response.status) and attempt < max_fetch_attempts() and
         remaining > 0 do
      discard_response_body(response)

      remaining
      |> min(retry_delay_ms(response, attempt))
      |> sleep_if_needed()

      fetch_with_retry(headers, url, started_at, attempt + 1)
    else
      response
    end
  catch
    :exit, reason ->
      if retryable_fetch_error?(reason) and attempt < max_fetch_attempts() and
           remaining_budget_ms(started_at) > 0 do
        started_at
        |> remaining_budget_ms()
        |> min(backoff_delay_ms(attempt))
        |> sleep_if_needed()

        fetch_with_retry(headers, url, started_at, attempt + 1)
      else
        exit(reason)
      end
  end

  defp handle_fetch_source_response(response, url, cache_path, meta_path) do
    case response.status do
      200 ->
        persist_fresh_source(response, cache_path, meta_path)

      304 ->
        read_cached_source!(cache_path, url)

      status when status in 400..599 ->
        discard_response_body(response)

        reason =
          if retryable_fetch_status?(status) do
            "HTTP #{status} fetching WPT data after #{max_fetch_attempts()} attempts"
          else
            "HTTP #{status} fetching WPT data"
          end

        fallback_to_cache_source_or_raise(cache_path, url, reason)

      status ->
        discard_response_body(response)

        fallback_to_cache_source_or_raise(
          cache_path,
          url,
          "Unexpected HTTP #{status} fetching WPT data"
        )
    end
  end

  defp handle_fetch_json_response(response, url, cache_path, meta_path) do
    case response.status do
      200 ->
        persist_fresh_json(response, cache_path, meta_path)

      304 ->
        read_cached_json!(cache_path, url)

      status when status in 400..599 ->
        discard_response_body(response)

        reason =
          if retryable_fetch_status?(status) do
            "HTTP #{status} fetching WPT data after #{max_fetch_attempts()} attempts"
          else
            "HTTP #{status} fetching WPT data"
          end

        fallback_to_cache_json_or_raise(cache_path, url, reason)

      status ->
        discard_response_body(response)

        fallback_to_cache_json_or_raise(
          cache_path,
          url,
          "Unexpected HTTP #{status} fetching WPT data"
        )
    end
  end

  defp retry_delay_ms(response, attempt) do
    header_delay =
      [retry_after_delay_ms(response), rate_limit_reset_delay_ms(response)]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0 end)

    max(header_delay, backoff_delay_ms(attempt))
  end

  defp retry_after_delay_ms(response) do
    case Web.Headers.get(response.headers, "retry-after") do
      nil ->
        nil

      value ->
        retry_after = value |> to_string() |> String.trim()

        case Integer.parse(retry_after) do
          {seconds, ""} when seconds >= 0 -> min(seconds * 1000, max_retry_after_ms())
          _ -> retry_after_http_date_delay_ms(retry_after)
        end
    end
  end

  defp retry_after_http_date_delay_ms(retry_after) do
    case :httpd_util.convert_request_date(String.to_charlist(retry_after)) do
      {{year, month, day}, {hour, minute, second}} ->
        retry_at =
          DateTime.new!(Date.new!(year, month, day), Time.new!(hour, minute, second), "Etc/UTC")

        max(DateTime.diff(retry_at, DateTime.utc_now(), :millisecond), 0)
        |> min(max_retry_after_ms())

      _ ->
        nil
    end
  rescue
    _ ->
      nil
  end

  defp rate_limit_reset_delay_ms(response) do
    remaining = Web.Headers.get(response.headers, "x-ratelimit-remaining")
    reset = Web.Headers.get(response.headers, "x-ratelimit-reset")

    case {remaining, reset} do
      {"0", reset_value} when not is_nil(reset_value) ->
        case Integer.parse(to_string(reset_value)) do
          {reset_epoch, ""} ->
            now = System.system_time(:second)
            wait_seconds = max(reset_epoch - now, 0)
            min(wait_seconds * 1000, max_retry_after_ms())

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp sleep_if_needed(delay_ms) when delay_ms > 0 do
    Process.sleep(delay_ms)
  end

  defp sleep_if_needed(_delay_ms), do: :ok

  defp backoff_delay_ms(attempt) do
    pow = max(attempt - 1, 0)
    delay = trunc(base_backoff_ms() * :math.pow(2, pow))
    min(delay, max_backoff_ms())
  end

  defp fetch_timeout_signal(started_at) do
    case remaining_budget_ms(started_at) do
      remaining when remaining > 0 ->
        Web.AbortSignal.any([
          Web.AbortSignal.timeout(fetch_timeout_ms()),
          Web.AbortSignal.timeout(remaining)
        ])

      _ ->
        Web.AbortSignal.abort(:timeout)
    end
  end

  defp retryable_fetch_status?(status) do
    status in [403, 408, 425, 429] or status >= 500
  end

  defp retryable_fetch_error?(%Mint.TransportError{reason: reason}) do
    transient_network_error?(reason)
  end

  defp retryable_fetch_error?({:aborted, _reason}), do: true
  defp retryable_fetch_error?({:shutdown, reason}), do: retryable_fetch_error?(reason)
  defp retryable_fetch_error?(reason), do: transient_network_error?(reason)

  defp transient_network_error?(reason)

  defp transient_network_error?(reason)
       when reason in [:aborted, :timeout, :closed, :econnaborted, :econnrefused, :econnreset] do
    true
  end

  defp transient_network_error?(reason)
       when reason in [:enetdown, :enetunreach, :ehostdown, :ehostunreach, :etimedout, :nxdomain] do
    true
  end

  defp transient_network_error?({:failed_connect, _details}), do: true
  defp transient_network_error?(_reason), do: false

  defp remaining_budget_ms(started_at) do
    max(max_total_fetch_ms() - elapsed_ms(started_at), 0)
  end

  defp elapsed_ms(started_at) do
    System.monotonic_time(:millisecond) - started_at
  end

  defp discard_response_body(%Web.Response{body: body}) do
    _ = Enum.reduce_while(body, :ok, fn _, acc -> {:halt, acc} end)
    :ok
  rescue
    _ ->
      :ok
  catch
    :exit, _reason ->
      :ok
  end

  defp persist_fresh_source(response, cache_path, meta_path) do
    raw = Web.await(Web.Response.text(response))

    Elixir.File.write!(cache_path, raw)

    meta = %{
      etag: Web.Headers.get(response.headers, "etag"),
      last_modified: Web.Headers.get(response.headers, "last-modified")
    }

    Elixir.File.write!(meta_path, Jason.encode!(meta))
    raw
  end

  defp persist_fresh_json(response, cache_path, meta_path) do
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
      decode_fallback_payload(raw)
  catch
    :exit, _reason ->
      decode_fallback_payload(raw)
  end

  defp decode_fallback_payload(raw) do
    raw
    |> repair_surrogates()
    |> Jason.decode!()
  end

  defp fallback_to_cache_source_or_raise(cache_path, url, reason) do
    if Elixir.File.exists?(cache_path) do
      read_cached_source!(cache_path, url)
    else
      raise ArgumentError,
            "#{reason}. Connect to the internet and rerun the tests once to populate #{cache_path} for #{url}."
    end
  end

  defp fallback_to_cache_json_or_raise(cache_path, url, reason) do
    if Elixir.File.exists?(cache_path) do
      read_cached_json!(cache_path, url)
    else
      raise ArgumentError,
            "#{reason}. Connect to the internet and rerun the tests once to populate #{cache_path} for #{url}."
    end
  end

  defp read_cached_source!(cache_path, _url), do: Elixir.File.read!(cache_path)

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

  defp fetch_governor do
    governor = :persistent_term.get(@governor_key, nil)

    if live_fetch_governor?(governor) do
      governor
    else
      init_fetch_governor()
    end
  end

  defp init_fetch_governor do
    :global.trans(@governor_lock_key, fn ->
      governor = :persistent_term.get(@governor_key, nil)

      if live_fetch_governor?(governor) do
        governor
      else
        new_fetch_governor()
      end
    end)
  end

  defp new_fetch_governor do
    governor = CountingGovernor.new(governor_capacity())
    :persistent_term.put(@governor_key, governor)
    governor
  end

  defp live_fetch_governor?(%CountingGovernor{pid: pid}) when is_pid(pid) do
    Process.alive?(pid) and pid_governor_capacity(pid) == governor_capacity()
  end

  defp live_fetch_governor?(_), do: false

  defp pid_governor_capacity(pid) do
    :sys.get_state(pid).capacity
  rescue
    _ -> nil
  end

  defp governor_capacity, do: runtime_option(:governor_capacity, @default_governor_capacity)
  defp max_fetch_attempts, do: runtime_option(:max_fetch_attempts, @default_max_fetch_attempts)
  defp fetch_timeout_ms, do: runtime_option(:fetch_timeout_ms, @default_fetch_timeout_ms)
  defp max_total_fetch_ms, do: runtime_option(:max_total_fetch_ms, @default_max_total_fetch_ms)
  defp base_backoff_ms, do: runtime_option(:base_backoff_ms, @default_base_backoff_ms)
  defp max_backoff_ms, do: runtime_option(:max_backoff_ms, @default_max_backoff_ms)
  defp max_retry_after_ms, do: runtime_option(:max_retry_after_ms, @default_max_retry_after_ms)

  defp normalize_fetch_url(url) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: "github.com",
        path: "/web-platform-tests/wpt/raw/refs/heads/" <> rest
      } ->
        "https://raw.githubusercontent.com/web-platform-tests/wpt/" <> rest

      _ ->
        url
    end
  end

  defp runtime_option(key, default) do
    :web
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
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

  defp resource_format(url) do
    case url |> URI.parse() |> Map.get(:path, "") |> Path.extname() do
      ".js" -> :js
      _ -> :json
    end
  end

  defp normalize_cases(url, payload) when is_binary(url) and is_list(payload), do: payload

  defp normalize_cases(url, payload) when is_binary(url) and is_map(payload), do: [payload]

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
