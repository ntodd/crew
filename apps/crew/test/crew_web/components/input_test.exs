defmodule CrewWeb.Components.InputTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  test "a field without an id gets one from its name, so its label points at it" do
    html =
      render_component(&CrewWeb.CoreComponents.input/1, name: "host", value: "", label: "Host")

    assert html =~ ~s(for="host")
    assert html =~ ~s(id="host")
  end

  test "names with brackets make valid ids" do
    html =
      render_component(&CrewWeb.CoreComponents.input/1,
        name: "registry[host]",
        value: "",
        label: "Host"
      )

    assert html =~ ~s(for="registry_host")
  end
end
