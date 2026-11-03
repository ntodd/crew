defmodule CrewWeb.FlashTest do
  use CrewWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CrewWeb.Layouts

  defp flash_group(flash),
    do: render_component(&Layouts.flash_group/1, flash: flash) |> LazyHTML.from_fragment()

  defp attr(html, selector, name),
    do: html |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()

  test "a flash hides itself after 6 seconds" do
    html = flash_group(%{"info" => "Saved.", "error" => "Not saved."})

    for id <- ["#flash-info", "#flash-error"] do
      assert attr(html, id, "data-autohide") == "6000"
      assert attr(html, id, "phx-hook") =~ "AutoHide"
    end
  end

  test "the connection notices stay while they apply" do
    html = flash_group(%{})

    for id <- ["#client-error", "#server-error"],
        do: assert(attr(html, id, "data-autohide") == nil)
  end
end
