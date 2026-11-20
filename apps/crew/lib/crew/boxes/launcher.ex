defmodule Crew.Boxes.Launcher do
  @moduledoc """
  The `linux-vm` and `mac-vm` launchers (§12.3), Foreman's `vm.sh` and
  `mac.sh` for Crew: `priv/agent/*-vm.sh`, served at `/agent/<type>.sh`
  with this control plane's URL and the release's pins
  (`images/flatcar/VERSION`, through `Crew.Boxes.Flatcar.pins/0`) filled
  in, so a launcher always installs the Flatcar its release was built
  for. A placeholder is `__KEY__`, inside double quotes.
  """

  @dir Path.expand("../../../priv/agent", __DIR__)
  @types ~w(linux-vm mac-vm)
  for type <- @types, do: @external_resource(Path.join(@dir, "#{type}.sh"))
  @scripts Map.new(@types, &{&1, File.read!(Path.join(@dir, "#{&1}.sh"))})

  # The URL goes into the script in double quotes and in comments, so it
  # can't hold anything sh or a line break would act on.
  @url ~r"\Ahttps?://[A-Za-z0-9.\-\[\]:]+(/[A-Za-z0-9._~/-]*)?\z"

  @doc "The launcher for `type`, for a control plane at `base_url`."
  def script(type, base_url) when type in @types do
    if is_binary(base_url) and Regex.match?(@url, base_url) do
      values = Map.put(Crew.Boxes.Flatcar.pins(), "CREW_URL", String.trim_trailing(base_url, "/"))

      {:ok,
       Regex.replace(~r/__([A-Z0-9_]+)__/, @scripts[type], fn whole, key ->
         Map.get(values, key, whole)
       end)}
    else
      {:error, :bad_url}
    end
  end
end
