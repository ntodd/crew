defmodule CrewWeb.StaleAssets do
  @moduledoc """
  Reloads a page whose CSS and JavaScript predate the running release.

  A tab left open across a deploy reconnects to the new server and gets
  new markup, but keeps the stylesheet and scripts it loaded first, so
  anything that changed in both renders wrong until a hard refresh. The
  root layout tracks those assets (`phx-track-static`); when they've
  changed, the page reloads at the same URL instead.
  """
  import Phoenix.LiveView

  def on_mount(:reload, _params, _session, socket) do
    # static_changed?/1 can only be asked during mount, but the URL to
    # reload only arrives with handle_params.
    if connected?(socket) and static_changed?(socket),
      do: {:cont, attach_hook(socket, :stale_assets, :handle_params, &reload/3)},
      else: {:cont, socket}
  end

  defp reload(_params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    {:halt, redirect(socket, to: if(query, do: "#{path}?#{query}", else: path))}
  end
end
