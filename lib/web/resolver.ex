defmodule Web.Resolver do
  @moduledoc false

  # Finds the dispatcher of `Web.fetch/2` for the scheme of a URL: HTTP for
  # `http:` and `https:`, `Web.Dispatcher.Blob` for `blob:`, and TCP for
  # `tcp:` and for an rclone remote such as `remote:path`. Each other scheme
  # goes to HTTP.

  @spec resolve(Web.URL.t()) :: module()
  def resolve(%Web.URL{} = url) do
    protocol = Web.URL.protocol(url)

    cond do
      protocol in ["http:", "https:"] ->
        Web.Dispatcher.HTTP

      protocol == "tcp:" ->
        Web.Dispatcher.TCP

      protocol == "blob:" ->
        Web.Dispatcher.Blob

      Web.URL.rclone?(url) ->
        Web.Dispatcher.TCP

      true ->
        Web.Dispatcher.HTTP
    end
  end
end
